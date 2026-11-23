import AppKit
import UniformTypeIdentifiers

struct GalleryPhoto: Sendable, Equatable {
    let uri: String
    let name: String
    let type: String
    let bounds: CGRect

    struct Node: Decodable {
        let attributes: [String: String]
        let children: [Node]

        var visible: Bool { attributes["visible"] == "true" }

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
        guard let root = await layout(hdc: hdc, device: device) else { return nil }
        return photo(in: root)
    }

    static func layout(hdc: String, device: Device) async -> Node? {
        let path = "/data/local/tmp/hl-gallery-\(UUID().uuidString).json"
        let command = "uitest dumpLayout -p \(path) && cat \(path); rm -f \(path)"
        let result = await Tools.run(hdc, ["-t", device.id, "shell", command], timeout: 6)
        if result.code == -1 {
            _ = await Task.detached {
                await Tools.run(hdc, ["-t", device.id, "shell", "rm -f \(path)"], timeout: 4)
            }.value
        }
        guard !Task.isCancelled, result.code == 0 else { return nil }
        return decode(result.output)
    }

    private static func decode(_ output: String) -> Node? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else { return nil }
        return try? JSONDecoder().decode(Node.self, from: Data(output[start...end].utf8))
    }

    static func parse(_ output: String) -> GalleryPhoto? {
        decode(output).flatMap { photo(in: $0) }
    }

    static func gallery(in layout: Node) -> Node? {
        layout.first {
            $0.visible && $0.attributes["type"] == "root"
                && $0.attributes["bundleName"] == "com.huawei.hmos.photos"
        }
    }

    static func fromMediaURI(_ raw: String, bounds: CGRect) -> GalleryPhoto? {
        guard let uri = URL(string: raw), uri.scheme == "file", uri.host == "media",
              uri.query == nil, uri.fragment == nil,
              uri.pathComponents.count == 5, uri.pathComponents[1] == "Photo",
              uri.pathComponents[2].range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
              let type = PhonePhotoExport.imageType(for: uri.lastPathComponent) else { return nil }
        return GalleryPhoto(uri: uri.absoluteString, name: uri.lastPathComponent, type: type.identifier, bounds: bounds)
    }

    static func photo(in layout: Node) -> GalleryPhoto? {
        guard let gallery = gallery(in: layout) else { return nil }
        let prefix = "browserFocusColumn"
        var photos = [GalleryPhoto]()
        gallery.visit { node in
            guard let key = node.attributes["id"], key.hasPrefix(prefix),
                  node.attributes["visible"] == "true",
                  let bounds = node.first(where: {
                      $0.attributes["id"] == "browserFocus_" && $0.attributes["visible"] == "true"
                  })?.attributes["bounds"] else { return }
            let coordinates = bounds.split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Int($0) }
            guard coordinates.count == 4, coordinates[2] > coordinates[0], coordinates[3] > coordinates[1] else { return }
            let rect = CGRect(x: coordinates[0], y: coordinates[1],
                              width: coordinates[2] - coordinates[0], height: coordinates[3] - coordinates[1])
            if let photo = fromMediaURI(String(key.dropFirst(prefix.count)), bounds: rect) { photos.append(photo) }
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
    private let transfers: GalleryTransferQueue
    private let isCurrentSession: @MainActor @Sendable () -> Bool
    private let update: @MainActor (String, Bool) -> Void

    init(photo: GalleryPhoto, filename: String, hdc: String, device: Device,
         transfers: GalleryTransferQueue, isCurrentSession: @escaping @MainActor @Sendable () -> Bool,
         update: @escaping @MainActor (String, Bool) -> Void) {
        self.photo = photo
        self.filename = filename
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

    func export(toFolder folder: URL, completion: @escaping (Error?) -> Void) {
        enqueue(destination: { PhonePhotoExport.availableDestination(in: folder, filename: self.filename) },
                replacing: false, completion: completion)
    }

    func export(to url: URL, replacing: Bool, completion: @escaping (Error?) -> Void) {
        enqueue(destination: { url }, replacing: replacing, completion: completion)
    }

    private func enqueue(destination: @escaping @Sendable () -> URL, replacing: Bool,
                         completion: @escaping (Error?) -> Void) {
        Task { await transfers.enqueue { [self] in
            do {
                try await checkSession()
                await update("正在接收 · " + filename, true)
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("HarmonyLink-drop-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: root) }
                let file = try await PhonePhotoExport.receive(name: photo.name, source: .gallery,
                                                             hdc: hdc, device: device, directory: root,
                                                             galleryURI: photo.uri)
                try await checkSession()
                try Self.writeOriginal(file, to: destination(), replacing: replacing)
                completion(nil)
                await update("已保存 · " + filename, false)
            } catch {
                completion(error)
                await update("接收照片失败。\(error.localizedDescription)", false)
            }
        } }
    }

    private static func writeOriginal(_ source: URL, to destination: URL, replacing: Bool) throws {
        var coordinationError: NSError?
        var writeError: Error?
        func write(to url: URL) throws {
            if replacing {
                try Data(contentsOf: source, options: .mappedIfSafe).write(to: url, options: .atomic)
            } else {
                try FileManager.default.copyItem(at: source, to: url)
            }
        }
        var coordinated = false
        NSFileCoordinator().coordinate(writingItemAt: destination, options: replacing ? .forReplacing : [],
                                       error: &coordinationError) { url in
            coordinated = true
            do {
                try write(to: url)
            } catch {
                writeError = error
            }
        }
        if let error = writeError { throw error }
        if !coordinated, coordinationError?.domain == NSCocoaErrorDomain,
           coordinationError?.code == NSFileWriteUnknownError {
            try write(to: destination)
        } else if let error = coordinationError {
            throw error
        }
    }
}

// AppKit needs pasteboard items during mouseDragged. Resolve originals off the UI
// thread while Finder tracks the drag, then fulfill each promise at its drop URL.
final class GalleryTileDrag: @unchecked Sendable {
    private let count: Int
    private let ready = DispatchGroup()
    private var result: Result<[GalleryPhotoPromise], Error>?
    private var lookup: Task<Void, Never>?

    init(count: Int, resolve: @escaping @Sendable () async throws -> [GalleryPhotoPromise]) {
        self.count = count
        ready.enter()
        lookup = Task.detached(priority: .userInitiated) { [self] in
            defer { ready.leave() }
            do {
                let photos = try await resolve()
                guard photos.count == count else { throw PhotoExportError(message: "图库选区已变化。") }
                result = .success(photos)
            } catch { result = .failure(error) }
        }
    }

    func cancel() { lookup?.cancel() }

    func providers() -> [NSFilePromiseProvider] {
        (0..<count).map { index in
            let delegate = Item(batch: self, index: index)
            let provider = NSFilePromiseProvider(fileType: UTType.image.identifier, delegate: delegate)
            provider.userInfo = delegate
            return provider
        }
    }

    private func promise(at index: Int) throws -> GalleryPhotoPromise {
        ready.wait()
        guard let result else { throw CancellationError() }
        return try result.get()[index]
    }

    private final class Item: NSObject, NSFilePromiseProviderDelegate {
        let batch: GalleryTileDrag
        let index: Int

        init(batch: GalleryTileDrag, index: Int) { self.batch = batch; self.index = index }

        func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType type: String) -> String {
            (try? batch.promise(at: index).filename) ?? "照片-\(index + 1)"
        }

        func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            return queue
        }

        func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            do {
                try batch.promise(at: index).export(to: url, replacing: false, completion: completionHandler)
            } catch { completionHandler(error) }
        }
    }
}
