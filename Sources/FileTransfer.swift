import Darwin
import Foundation

enum PhoneFileTransfer {
    private static let downloads = "/storage/media/100/local/files/Docs/Download"

    static func isPhoto(_ file: URL) -> Bool {
        PhonePhotoExport.imageType(for: file.lastPathComponent) != nil
    }

    private static func cameraAlbum(hdc: String, device: Device) async -> String? {
        let root = PhoneGallery.root
        let probe = "for album in 相机 Camera; do if test -d '\(root)'/\"$album\"; then echo \"$album\"; break; fi; done"
        let result = await Tools.run(hdc, ["-t", device.id, "shell", probe])
        guard result.code == 0, ["相机", "Camera"].contains(result.message) else { return nil }
        return root + "/" + result.message
    }

    static func send(_ file: URL, using hdc: String, to device: Device) async -> String? {
        let opened = file.startAccessingSecurityScopedResource()
        defer { if opened { file.stopAccessingSecurityScopedResource() } }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return "只能发送普通文件。" }

        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("harmonylink-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        if clonefile(file.path, local.path, 0) != 0 {
            do { try FileManager.default.copyItem(at: file, to: local) }
            catch { return "无法读取待发送的文件。" }
        }
        guard !Task.isCancelled else { return "已取消发送。" }
        let extensionPart = file.pathExtension.isEmpty ? "" : "." + file.pathExtension
        let basename = extensionPart.isEmpty ? file.lastPathComponent : file.deletingPathExtension().lastPathComponent
        let name = basename + "-hl-" + token + extensionPart
        let folder: String
        let photo = isPhoto(file)
        if photo {
            guard let album = await cameraAlbum(hdc: hdc, device: device) else {
                return "无法访问手机图库的相机相册。"
            }
            folder = album
        } else {
            folder = downloads
        }
        let seconds = max(60, Double(values.fileSize ?? 0) / 500_000 + 30)
        let result = await Tools.run(hdc, ["-t", device.id, "file", "send", local.path, folder + "/" + name], timeout: seconds)
        if result.code == 0, result.output.localizedCaseInsensitiveContains("FileTransfer finish") { return nil }
        return (photo ? "无法将照片导入手机图库。" : "无法保存到手机下载目录。") + "\n" + result.message
    }
}
