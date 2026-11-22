import AppKit
import UniformTypeIdentifiers

struct GalleryPhoto: Sendable, Equatable {
    let uri: String
    let name: String
    let type: String
    let bounds: CGRect

    private struct Node: Decodable {
        let attributes: [String: String]
        let children: [Node]

        func first(where matches: (Node) -> Bool) -> Node? {
            if matches(self) { return self }
            for child in children {
                if let match = child.first(where: matches) { return match }
            }
            return nil
        }

        func visit(_ visitNode: (Node) -> Void) {
            visitNode(self)
            for child in children { child.visit(visitNode) }
        }
    }

    static func current(hdc: String, device: Device) async -> GalleryPhoto? {
        let path = "/data/local/tmp/hl-gallery-\(UUID().uuidString).json"
        let command = "uitest dumpLayout -p \(path) && cat \(path); rm -f \(path)"
        let result = await Tools.run(hdc, ["-t", device.id, "shell", command], timeout: 6)
        if result.code == -1 {
            _ = await Task.detached {
                await Tools.run(hdc, ["-t", device.id, "shell", "rm -f \(path)"], timeout: 4)
            }.value
        }
        guard !Task.isCancelled, result.code == 0 else { return nil }
        return parse(result.output)
    }

    static func parse(_ output: String) -> GalleryPhoto? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              let root = try? JSONDecoder().decode(Node.self, from: Data(output[start...end].utf8)),
              let gallery = root.first(where: {
                  $0.attributes["bundleName"] == "com.huawei.hmos.photos"
                      && $0.attributes["type"] == "root" && $0.attributes["visible"] == "true"
              }) else { return nil }
        let prefix = "browserFocusColumn"
        var photos = [GalleryPhoto]()
        gallery.visit { node in
            guard let key = node.attributes["id"], key.hasPrefix(prefix),
                  node.attributes["visible"] == "true",
                  let uri = URL(string: String(key.dropFirst(prefix.count))),
                  uri.scheme == "file", uri.host == "media",
                  uri.pathComponents.count == 5, uri.pathComponents[1] == "Photo",
                  uri.pathComponents[2].range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
                  let type = PhonePhotoExport.imageType(for: uri.lastPathComponent),
                  let bounds = node.first(where: {
                      $0.attributes["id"] == "browserFocus_" && $0.attributes["visible"] == "true"
                  })?.attributes["bounds"] else { return }
            let coordinates = bounds.split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Int($0) }
            guard coordinates.count == 4, coordinates[2] > coordinates[0], coordinates[3] > coordinates[1] else { return }
            let rect = CGRect(x: coordinates[0], y: coordinates[1],
                              width: coordinates[2] - coordinates[0], height: coordinates[3] - coordinates[1])
            photos.append(GalleryPhoto(uri: uri.absoluteString,
                                name: uri.lastPathComponent, type: type.identifier, bounds: rect))
        }
        guard photos.count == 1 else { return nil }
        return photos.first
    }
}

actor GalleryTransferQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
    }
}

final class GalleryPhotoPromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let photo: GalleryPhoto
    let filename: String
    private let hdc: String
    private let device: Device
    private let verifyCurrent: Bool
    private let transfers: GalleryTransferQueue
    private let isCurrentSession: @MainActor @Sendable () -> Bool
    private let update: @MainActor (String, Bool) -> Void

    init(photo: GalleryPhoto, filename: String, verifyCurrent: Bool, hdc: String, device: Device,
         transfers: GalleryTransferQueue, isCurrentSession: @escaping @MainActor @Sendable () -> Bool,
         update: @escaping @MainActor (String, Bool) -> Void) {
        self.photo = photo
        self.filename = filename
        self.verifyCurrent = verifyCurrent
        self.hdc = hdc
        self.device = device
        self.transfers = transfers
        self.isCurrentSession = isCurrentSession
        self.update = update
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        filename
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        export(to: url, replacing: false, completion: completionHandler)
    }

    private func checkSession() async throws {
        guard await isCurrentSession() else {
            throw PhotoExportError(message: "投屏连接已断开，请重新选择照片。")
        }
    }

    func export(to url: URL, replacing: Bool, completion: @escaping (Error?) -> Void) {
        Task { await transfers.enqueue { [self] in
            do {
                try await checkSession()
                await update("正在接收 · " + filename, true)
                if verifyCurrent {
                    guard let current = await GalleryPhoto.current(hdc: hdc, device: device),
                          current.uri == photo.uri, current.name == photo.name else {
                        throw PhotoExportError(message: "手机当前照片已变化，请重新拖拽。")
                    }
                }
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("HarmonyLink-drop-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: root) }
                let file = try await PhonePhotoExport.receive(name: photo.name, source: .gallery,
                                                             hdc: hdc, device: device, directory: root,
                                                             galleryURI: photo.uri)
                try await checkSession()
                if replacing {
                    try Data(contentsOf: file, options: .mappedIfSafe).write(to: url, options: .atomic)
                } else {
                    try FileManager.default.copyItem(at: file, to: url)
                }
                completion(nil)
                await update("已保存 · " + filename, false)
            } catch {
                completion(error)
                await update("接收照片失败。\(error.localizedDescription)", false)
            }
        } }
    }
}
