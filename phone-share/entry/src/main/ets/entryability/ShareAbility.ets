import { UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { systemShare } from '@kit.ShareKit';

const ACTION = 'ohos.want.action.sendData';
const MAX_FILES = 500;

interface SharedPhoto {
  name: string;
  size: number;
}

interface ShareManifest {
  version: number;
  files: SharedPhoto[];
}

export default class ShareAbility extends UIAbility {
  private windowStage?: window.WindowStage;
  private showPage: boolean = true;
  private pendingShares: number = 0;
  private shareFailed: boolean = false;

  onCreate(want: Want): void {
    this.showPage = want.action !== ACTION;
    this.handleShare(want);
  }

  onNewWant(want: Want): void {
    this.handleShare(want);
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    this.windowStage = stage;
    if (this.showPage) {
      stage.loadContent('pages/Index');
    }
  }

  onWindowStageDestroy(): void {
    this.windowStage = undefined;
  }

  private handleShare(want: Want): void {
    if (want.action === ACTION) {
      void this.receiveShare(want);
    }
  }

  private async receiveShare(want: Want): Promise<void> {
    if (this.pendingShares === 0) {
      this.shareFailed = false;
    }
    this.pendingShares++;
    try {
      if (!(await this.stageShare(want))) {
        this.shareFailed = true;
        this.displayStatus('没能准备这批照片。请确认原图已下载到手机，再从图库分享一次。');
      }
    } finally {
      this.pendingShares--;
    }

    if (this.pendingShares === 0 && !this.shareFailed) {
      try {
        // The complete batch is on disk, so the Mac can receive it after this ability closes.
        await this.context.terminateSelf();
      } catch (_) {
        this.displayStatus('原图已准备好。请返回图库，并在 Mac 上操作。');
      }
    }
  }

  private displayStatus(message: string): void {
    AppStorage.setOrCreate('shareStatus', message);
    if (!this.showPage) {
      this.showPage = true;
      this.windowStage?.loadContent('pages/Index');
    }
  }

  private async stageShare(want: Want): Promise<boolean> {
    const root = this.context.filesDir + '/share-inbox';
    const batch = util.generateRandomUUID();
    const pending = root + '/pending-' + batch;
    try {
      const records = (await systemShare.getSharedData(want)).getRecords();
      if (records.length < 1 || records.length > MAX_FILES) {
        throw new Error('Invalid share count');
      }

      fs.mkdirSync(pending, true);
      const files: SharedPhoto[] = [];
      for (const record of records) {
        const uri = record.uri;
        if (!uri || !uri.startsWith('file://')) {
          throw new Error('Missing file URI');
        }

        let name: string = new fileUri.FileUri(uri).name;
        if (!/\.[a-z0-9]{2,8}$/i.test(name) && record.title && /\.[a-z0-9]{2,8}$/i.test(record.title)) {
          name = record.title;
        }
        const input = await fs.open(uri, fs.OpenMode.READ_ONLY);
        const destination = pending + '/' + files.length.toString();
        try {
          await fs.copyFile(input.fd, destination);
        } finally {
          await fs.close(input);
        }
        const size = (await fs.stat(destination)).size;
        if (size <= 0) {
          throw new Error('Empty original');
        }
        files.push({ name: name, size: size });
      }

      const manifest: ShareManifest = { version: 1, files: files };
      const index = fs.openSync(pending + '/manifest.json', fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE);
      try {
        fs.writeSync(index.fd, JSON.stringify(manifest));
      } finally {
        fs.closeSync(index);
      }
      await fs.rename(pending, root + '/' + batch);
      return true;
    } catch (_) {
      try {
        fs.rmdirSync(pending);
      } catch (_) {
        // The pending directory may not have been created yet.
      }
      return false;
    }
  }
}
