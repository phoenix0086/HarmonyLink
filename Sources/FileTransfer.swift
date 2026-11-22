import Darwin
import Foundation

enum PhoneFileTransfer {
    static let displayFolder = "下载"
    private static let folder = "/storage/media/100/local/files/Docs/Download"

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
        let seconds = max(60, Double(values.fileSize ?? 0) / 500_000 + 30)
        let result = await Tools.run(hdc, ["-t", device.id, "file", "send", local.path, folder + "/" + name], timeout: seconds)
        if result.code == 0, result.output.localizedCaseInsensitiveContains("FileTransfer finish") { return nil }
        return "无法保存到手机下载目录。\n" + result.message
    }
}
