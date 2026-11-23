import Foundation

// Join each checked grid cell to the original URI bound to that same thumbnail.
enum GallerySelection {
    typealias Node = GalleryPhoto.Node

    private static let changed = PhotoExportError(message: "图库选区已变化，请在图库中确认勾选后再保存。")

    private static func bounds(_ node: Node?) -> CGRect? {
        guard let text = node?.attributes["bounds"] else { return nil }
        let n = text.split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Int($0) }
        guard n.count == 4, n[2] > n[0], n[3] > n[1] else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
    }

    private static func count(_ gallery: Node, title: String) -> Int? {
        guard let label = gallery.first(where: { $0.visible && $0.attributes["id"] == title })?.attributes["text"],
              label.contains("选择") || label.localizedCaseInsensitiveContains("selected"),
              let digits = label.split(whereSeparator: { !$0.isNumber }).first else { return nil }
        return Int(digits)
    }

    private struct Cell: Equatable {
        let id: String
        let thumbnail: String
    }

    private static func foregroundGallery(_ root: Node) -> Node? {
        var windows = [Node]()
        root.visit { if $0.visible && $0.attributes["type"] == "root" { windows.append($0) } }
        guard windows.count == 1 else { return nil }
        return GalleryPhoto.gallery(in: windows[0])
    }

    struct DragTile: Equatable {
        let cellID: String
        let thumbnailID: String
        let bounds: CGRect
        let window: Int
        let selectedCount: Int
        var fileCount: Int { max(1, selectedCount) }
    }

    static func dragTiles(in layout: Node) -> [DragTile] {
        guard let gallery = foregroundGallery(layout),
              let window = Int(gallery.attributes["hostWindowId"] ?? ""),
              let grid = gallery.first(where: { $0.visible && $0.attributes["type"] == "Grid" }) else { return [] }
        let toolbar = bounds(gallery.first { $0.visible && $0.attributes["id"] == "titleBar" })
        let actions = bounds(gallery.first { $0.visible && $0.attributes["id"] == "ActionButton_Share" })
        let count = count(gallery, title: "FirstLevelTitle") ?? 0
        var tiles = [DragTile]()
        grid.visit { node in
            guard node.visible, node.attributes["type"] == "GridItem", let id = node.attributes["id"],
                  let image = node.first(where: { $0.visible && $0.attributes["type"] == "CachedImage" }),
                  let key = image.attributes["id"], !key.isEmpty, let rect = bounds(image) else { return }
            let top = max(rect.minY, toolbar?.maxY ?? rect.minY)
            let bottom = min(rect.maxY, actions?.minY ?? rect.maxY)
            guard top < bottom else { return }
            let hit = CGRect(x: rect.minX, y: top, width: rect.width, height: bottom - top)
            tiles.append(DragTile(cellID: id, thumbnailID: key, bounds: hit, window: window,
                                  selectedCount: node.attributes["selected"] == "true" ? count : 0))
        }
        return tiles
    }

    static func draggedPhotos(_ tile: DragTile, at point: CGPoint, hdc: String, device: Device) async throws -> [GalleryPhoto] {
        guard let layout = await GalleryPhoto.layout(hdc: hdc, device: device),
              let live = dragTiles(in: layout).first(where: { $0.bounds.contains(point) }),
              live.cellID == tile.cellID, live.thumbnailID == tile.thumbnailID,
              live.window == tile.window, live.selectedCount == tile.selectedCount else { throw changed }
        if tile.selectedCount > 1 {
            let photos = try await read(hdc: hdc, device: device, fallback: [])
            guard photos.count == tile.selectedCount else { throw changed }
            return photos
        }
        let cell = Cell(id: tile.cellID, thumbnail: tile.thumbnailID)
        return try await originals(for: [cell], window: tile.window, hdc: hdc, device: device)
    }

    private struct Page {
        let count: Int
        let viewport: CGRect
        let window: Int
        var selected = [Cell]()
        var visible = [String]()

        init?(_ gallery: Node) {
            guard let count = GallerySelection.count(gallery, title: "FirstLevelTitle"),
                  let window = Int(gallery.attributes["hostWindowId"] ?? ""),
                  let grid = gallery.first(where: { $0.visible && $0.attributes["type"] == "Grid" }),
                  let frame = bounds(grid),
                  let toolbar = bounds(gallery.first { $0.visible && $0.attributes["id"] == "titleBar" }),
                  let share = bounds(gallery.first { $0.visible && $0.attributes["id"] == "ActionButton_Share" }) else { return nil }
            let top = max(frame.minY, toolbar.maxY)
            let bottom = min(frame.maxY, share.minY)
            guard bottom > top else { return nil }
            self.window = window
            self.count = count
            let viewport = CGRect(x: frame.minX, y: top, width: frame.width, height: bottom - top)
            self.viewport = viewport
            grid.visit { node in
                guard node.visible, node.attributes["type"] == "GridItem",
                      let id = node.attributes["id"], !id.isEmpty,
                      node.first(where: { $0.attributes["type"] == "Checkbox" && $0.attributes["id"]?.hasPrefix("Selector_") == true }) != nil,
                      let rect = bounds(node) else { return }
                let point = CGPoint(x: rect.midX, y: rect.midY)
                guard viewport.contains(point), rect.height >= 0.55 * rect.width else { return }
                visible.append(id)
                if node.attributes["selected"] == "true" {
                    let thumbnail = node.first { $0.attributes["type"] == "CachedImage" }?.attributes["id"]
                    selected.append(Cell(id: id, thumbnail: thumbnail ?? ""))
                }
            }
        }
    }

    private struct Item: Decodable {
        let uri: String
    }

    private static func originals(for cells: [Cell], window: Int, hdc: String, device: Device) async throws -> [GalleryPhoto] {
        // HDC must run hidumper directly. Piping it on the phone can produce only
        // the service header. Tools.run removes the local temporary output on return.
        let command = "hidumper -s WindowManagerService -a '-w \(window) -default'"
        let dump = await Tools.run(hdc, ["-t", device.id, "shell", command], timeout: 20)
        try Task.checkCancellation()
        let wanted = Set(cells.map(\.thumbnail))
        let cellIDs = Set(cells.map(\.id))
        var currentItem: Item?
        var currentCell: String?
        var inImageItem = false
        var matches = [String: (cell: String, photo: GalleryPhoto)]()
        for line in dump.output.split(whereSeparator: \.isNewline) {
            if let marker = line.range(of: "ComponentName: ") {
                inImageItem = line[marker.upperBound...] == "\"ImageGridItemView\""
                currentItem = nil
                currentCell = nil
            } else if inImageItem, let marker = line.range(of: #"propertyName:"item" value:"#) {
                currentItem = try? JSONDecoder().decode(Item.self, from: Data(line[marker.upperBound...].utf8))
            } else if let item = currentItem, let marker = line.range(of: "compid: ") {
                let id = String(line[marker.upperBound...])
                if cellIDs.contains(id) {
                    currentCell = id
                } else if wanted.contains(id), !id.isEmpty, let cell = currentCell,
                          let photo = GalleryPhoto.fromMediaURI(item.uri, bounds: .zero) {
                    guard matches[id] == nil else { throw changed }
                    matches[id] = (cell, photo)
                }
            }
        }
        return try cells.map { cell in
            guard dump.code == 0, let match = matches[cell.thumbnail], match.cell == cell.id else {
                throw PhotoExportError(message: "无法从当前图库视图确认所选照片的原图。")
            }
            return match.photo
        }
    }

    static func read(hdc: String, device: Device, fallback: [GalleryPhoto]) async throws -> [GalleryPhoto] {
        func screen() async throws -> Node {
            try Task.checkCancellation()
            guard let root = await GalleryPhoto.layout(hdc: hdc, device: device) else {
                throw PhotoExportError(message: "无法读取手机画面，请确认手机已解锁并连接。")
            }
            return root
        }
        func input(_ args: [String]) async throws {
            try Task.checkCancellation()
            let result = await Tools.run(hdc, ["-t", device.id, "shell", "uitest", "uiInput"] + args)
            guard !result.failed else { throw changed }
        }
        var root = try await screen()
        guard var gallery = foregroundGallery(root) else { return fallback }
        if count(gallery, title: "SelectionTitleText") != nil {
            try await input(["keyEvent", "Back"])
            root = try await screen()
            guard let grid = foregroundGallery(root) else { throw changed }
            gallery = grid
        }
        guard var page = Page(gallery) else {
            if count(gallery, title: "FirstLevelTitle") != nil { throw changed }
            if !fallback.isEmpty { return fallback }
            return GalleryPhoto.photo(in: root).map { [$0] } ?? []
        }
        let expected = page.count
        var photos = [GalleryPhoto]()
        var visited = Set<String>()
        var movingToStart = true
        func readPage() async throws -> Page {
            guard let gallery = foregroundGallery(try await screen()), let next = Page(gallery),
                  next.count == expected else { throw changed }
            return next
        }
        while photos.count < expected {
            let cells = page.selected.filter { !visited.contains($0.thumbnail) }
            if !cells.isEmpty {
                let batch = try await originals(for: cells, window: page.window, hdc: hdc, device: device)
                let verified = try await readPage()
                guard verified.window == page.window, verified.selected == page.selected else { throw changed }
                for (cell, photo) in zip(cells, batch) {
                    guard visited.insert(cell.thumbnail).inserted,
                          !photos.contains(where: { $0.uri == photo.uri }) else { throw changed }
                    photos.append(photo)
                }
                guard photos.count <= expected else { throw changed }
                page = verified
            } else {
                let frame = page.viewport
                let x = String(Int(frame.midX))
                let high = String(Int(frame.minY + frame.height * 0.23))
                let low = String(Int(frame.minY + frame.height * 0.77))
                try await input(["swipe", x, movingToStart ? high : low, x, movingToStart ? low : high, "850"])
                let next = try await readPage()
                if next.visible == page.visible {
                    guard movingToStart else { throw changed }
                    movingToStart = false
                }
                page = next
            }
        }
        return photos
    }
}
