import AppKit
import UniformTypeIdentifiers

struct SharedPhotoBatch {
    let id: UUID
    let directory: URL
    let files: [URL]

    func cleanUpLater() {
        let directory = directory
        Task.detached {
            // Finder may still be copying the files after the drag session ends.
            try? await Task.sleep(for: .seconds(120))
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

final class SharedPhotoPromise: NSObject, NSFilePromiseProviderDelegate {
    private let source: URL
    private let didCopy: @MainActor () -> Void

    init(source: URL, didCopy: @escaping @MainActor () -> Void) {
        self.source = source
        self.didCopy = didCopy
    }

    func makeProvider() -> NSFilePromiseProvider {
        let type = PhonePhotoExport.imageType(for: source.lastPathComponent) ?? .image
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = self
        return provider
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType type: String) -> String {
        source.lastPathComponent
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            try FileManager.default.copyItem(at: source, to: url)
            completionHandler(nil)
            Task { @MainActor in didCopy() }
        } catch {
            completionHandler(error)
        }
    }
}

enum GalleryShareInbox {
    private static let bundle = "com.harmonylink.share"
    // UIAbilityContext.filesDir is scoped to the entry module.
    private static let inbox = "./data/storage/el2/base/haps/entry/files/share-inbox"

    private struct Manifest: Decodable {
        struct Photo: Decodable {
            let name: String
            let size: Int64
        }
        let version: Int
        let files: [Photo]
    }

    static func isInstalled(hdc: String, device: Device) async -> Bool {
        let result = await Tools.run(hdc, ["-t", device.id, "shell", "bm dump -n " + bundle], timeout: 5)
        return result.code == 0 && result.output.contains("\"" + bundle + "\"")
    }

    static func pending(hdc: String, device: Device) async -> [UUID] {
        let result = await Tools.run(hdc, ["-t", device.id, "shell", "-b", bundle, "ls -1t " + inbox], timeout: 4)
        guard result.code == 0 else { return [] }
        return result.output.split(whereSeparator: \.isNewline).compactMap { UUID(uuidString: String($0)) }
    }

    static func receive(_ batch: UUID, hdc: String, device: Device) async throws -> SharedPhotoBatch {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("HarmonyLink-share-" + UUID().uuidString,
                                                                     isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        do {
            let component = batch.uuidString.lowercased()
            let remote = inbox + "/" + component
            let result = await Tools.run(hdc, ["-t", device.id, "file", "recv", "-b", bundle, remote, directory.path],
                                         timeout: 300)
            try Task.checkCancellation()
            guard !result.failed, result.output.localizedCaseInsensitiveContains("FileTransfer finish") else {
                throw PhotoExportError(message: "原图传输中断。")
            }
            let staged = directory.appendingPathComponent(component, isDirectory: true)
            let manifestFile = staged.appendingPathComponent("manifest.json")
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestFile))
            guard manifest.version == 1, (1...500).contains(manifest.files.count) else {
                throw PhotoExportError(message: "分享清单无效。")
            }
            let received = directory.appendingPathComponent("原图", isDirectory: true)
            try fm.createDirectory(at: received, withIntermediateDirectories: false)
            var names = Set<String>()
            let files = try manifest.files.enumerated().map { index, photo in
                let source = staged.appendingPathComponent(String(index))
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard PhonePhotoExport.imageType(for: photo.name) != nil,
                      photo.name.utf8.count <= 230,
                      values.isRegularFile == true, Int64(values.fileSize ?? 0) == photo.size,
                      photo.size > 0 else {
                    throw PhotoExportError(message: "分享的原图不完整或格式不支持。")
                }
                let filename = photo.name as NSString
                var name = photo.name
                var suffix = 2
                while !names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted {
                    name = "\(filename.deletingPathExtension) \(suffix).\(filename.pathExtension)"
                    suffix += 1
                }
                let file = received.appendingPathComponent(name)
                try fm.moveItem(at: source, to: file)
                return file
            }
            try fm.removeItem(at: staged)
            return SharedPhotoBatch(id: batch, directory: directory, files: files)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    static func acknowledge(_ batch: UUID, hdc: String, device: Device) async {
        let path = inbox + "/" + batch.uuidString.lowercased()
        _ = await Tools.run(hdc, ["-t", device.id, "shell", "-b", bundle, "rm -r " + path], timeout: 8)
    }
}
