@Entry
@Component
struct Index {
  @StorageLink('shareStatus') status: string = '在图库勾选照片，点「分享」，然后选择 HarmonyLink。';

  build() {
    Column({ space: 20 }) {
      Image($r('app.media.app_icon')).width(76).height(76).borderRadius(18)
      Text('HarmonyLink').fontSize(26).fontWeight(FontWeight.Bold)
      Text(this.status).fontSize(17).textAlign(TextAlign.Center).padding({ left: 24, right: 24 })
      Text('保持手机与 Mac 的 HarmonyLink 已连接。')
        .fontSize(14).fontColor('#667085').textAlign(TextAlign.Center)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
