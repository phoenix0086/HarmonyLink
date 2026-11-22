import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PhotoSource: String, CaseIterable, Identifiable {
    case gallery = "图库"
    case downloads = "下载"
    var id: Self { self }
}

struct PhotoExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum PhonePhotoExport {
    static func imageType(for name: String) -> UTType? {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\0"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "heic": return .heic
        case "heif": return .heif
        case "gif": return .gif
        case "tif", "tiff": return .tiff
        case "webp": return .webP
        default:
            guard let type = UTType(filenameExtension: ext), type.conforms(to: .image) else { return nil }
            return type
        }
    }

    static func receive(name: String, source: PhotoSource, hdc: String, device: Device, directory: URL,
                        galleryURI: String? = nil) async throws -> URL {
        guard imageType(for: name) != nil else {
            throw PhotoExportError(message: "请输入完整的照片文件名，包含扩展名。")
        }
        let args = ["-t", device.id]
        var remote = "/storage/media/100/local/files/Docs/Download/" + name
        var staged = false
        if source == .gallery {
            let uri: String
            if let galleryURI {
                uri = galleryURI
            } else {
                let query = await Tools.run(hdc, args + ["shell", "mediatool query " + quote(name) + " -u"])
                try Task.checkCancellation()
                let pattern = #"file://media/Photo/[0-9]+(?=/|\"|\s|$)"#
                let matches = try NSRegularExpression(pattern: pattern).matches(
                    in: query.output, range: NSRange(query.output.startIndex..., in: query.output))
                let ids = Set(matches.compactMap { Range($0.range, in: query.output).map { String(query.output[$0]) } })
                guard ids.count == 1, let match = ids.first else {
                    throw PhotoExportError(message: ids.isEmpty ? "图库里没找到这张照片。请在图库的照片详情里核对文件名。"
                                                                : "图库里有重名照片。请先在手机上将目标照片改成唯一文件名。")
                }
                uri = match
            }
            remote = "/data/local/tmp/hl-photo-" + UUID().uuidString + "." + URL(fileURLWithPath: name).pathExtension.lowercased()
            staged = true
            let copied = await Tools.run(hdc, args + ["shell", "mediatool recv " + quote(uri) + " " + remote], timeout: 60)
            if !copied.output.contains(remote) || copied.failed || Task.isCancelled {
                await cleanup(remote: remote, hdc: hdc, args: args)
                throw PhotoExportError(message: "图库导出失败，请确认这张照片的原图已下载到手机。")
            }
        }

        let staging = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("part")
        let result = await Tools.run(hdc, args + ["file", "recv", remote, staging.path], timeout: 180)
        if staged { await cleanup(remote: remote, hdc: hdc, args: args) }
        defer { try? FileManager.default.removeItem(at: staging) }
        try Task.checkCancellation()
        guard result.code == 0, result.output.localizedCaseInsensitiveContains("FileTransfer finish"),
              let values = try? staging.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) > 0 else {
            throw PhotoExportError(message: "接收失败。请确认照片在所选位置，并且 USB 仍连接。")
        }
        let exportFolder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        let output = exportFolder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: staging, to: output)
        return output
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func cleanup(remote: String, hdc: String, args: [String]) async {
        await Task.detached {
            _ = await Tools.run(hdc, args + ["shell", "rm -f " + remote], timeout: 4)
        }.value
    }
}

@MainActor
final class PhotoExportModel: ObservableObject {
    @Published var name = ""
    @Published var source = PhotoSource.gallery
    @Published private(set) var image: NSImage?
    @Published private(set) var file: URL?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private var receiveTask: Task<Void, Never>?
    private var directory: URL?

    func receive(from device: Device) {
        guard !busy, let hdc = Tools.hdc else { return }
        let filename = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = source
        let root = directory ?? URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("HarmonyLink-photos-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            message = "无法创建临时照片目录。"
            return
        }
        directory = root
        file = nil
        image = nil
        message = nil
        busy = true
        receiveTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.busy = false } }
            do {
                let url = try await PhonePhotoExport.receive(name: filename, source: source, hdc: hdc, device: device, directory: root)
                guard !Task.isCancelled else { return }
                guard let preview = NSImage(contentsOf: url) else {
                    self.message = "Mac 无法预览这张照片，仍可拖出或保存原图。"
                    self.file = url
                    return
                }
                self.image = preview
                self.file = url
                self.message = "把照片拖到 Finder 或桌面。"
            } catch is CancellationError {
                return
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    func save() {
        guard let file else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.begin { [weak self] result in
            guard result == .OK, let destination = panel.url else { return }
            do {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                try data.write(to: destination, options: .atomic)
                self?.message = "已保存到 Mac。"
            } catch {
                self?.message = "保存失败：" + error.localizedDescription
            }
        }
    }

    func close() {
        let task = receiveTask
        task?.cancel()
        guard let directory else { return }
        self.directory = nil
        // Allow Finder to finish reading the source after an accepted drag.
        Task.detached {
            _ = await task?.value
            try? await Task.sleep(for: .seconds(120))
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

struct PhotoExportSheet: View {
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PhotoExportModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从手机取照片").font(.headline)
            Picker("照片位置", selection: $model.source) {
                ForEach(PhotoSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.busy)
            TextField("完整文件名", text: $model.name, prompt: Text("例如 IMG_001.jpg"))
                .textFieldStyle(.roundedBorder)
                .disabled(model.busy)
                .onSubmit { model.receive(from: device) }
            Text("图库里打开照片，点「详情」查看文件名。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("取原图") { model.receive(from: device) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if let file = model.file {
                VStack(spacing: 6) {
                    DraggablePhoto(file: file, image: model.image)
                        .frame(height: 120)
                    Label(file.lastPathComponent, systemImage: "arrow.up.right")
                        .font(.caption)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .onDrag { NSItemProvider(object: file as NSURL) }
                Button("存到 Mac…") { model.save() }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(17)
        .frame(width: 290)
        .onDisappear { model.close() }
    }
}

private struct DraggablePhoto: View {
    let file: URL
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").font(.system(size: 36)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel("拖出照片：" + file.lastPathComponent)
    }
}
