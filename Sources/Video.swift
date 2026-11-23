import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MirrorVideo: NSView, @preconcurrency NSTextInputClient, NSDraggingSource {
    private let display = AVSampleBufferDisplayLayer()
    private var displayedFormat: CMVideoFormatDescription?
    private var needsKeyframe = true
    private var screen = CGSize.zero
    private var touchActive = false
    private var photoPress: (event: NSEvent, photo: GalleryPhoto?, exportRequested: Bool)?
    var dragTiles = [GallerySelection.DragTile]()
    var onDragTile: ((GallerySelection.DragTile, CGPoint) -> GalleryTileDrag?)?
    var onHoldTile: ((CGPoint) -> Void)?
    private var tilePress: (event: NSEvent, point: CGPoint, tile: GallerySelection.DragTile)?
    private var tileDrag: GalleryTileDrag?
    private let photoHandle = GalleryDragHandle(frame: .zero)
    private let addPhotoButton = NSButton()
    private let clearPhotosButton = NSButton()
    private var selectedPhotos = [GalleryPhoto]()
    private let photoBarHeight: CGFloat = 36
    private var videoBounds: CGRect {
        CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, bounds.height - photoBarHeight))
    }
    private var tracking: NSTrackingArea?
    private(set) var dimensions = CGSize.zero
    var aspectRatio: CGFloat? { dimensions.height > 0 ? dimensions.width / dimensions.height : nil }
    private var marked = NSAttributedString()
    private var compositionSelection = NSRange(location: 0, length: 0)
    private var inputAnchor = NSPoint.zero
    var onText: ((String) -> Void)?
    var onEditKey: ((PhoneEditKey) -> Void)?
    var canDropFiles: (() -> Bool)?
    var onFileHover: ((Bool) -> Void)?
    var onFiles: (([URL]) -> Bool)?
    var onBack: (() -> Void)?
    var onTouch: ((String, Int, Int) -> Void)?
    var galleryPhoto: GalleryPhoto? {
        didSet { needsLayout = true }
    }
    var onCheckGallery: (() -> Void)?
    var onReadGallerySelection: (([GalleryPhoto]) async throws -> [GalleryPhoto])?
    private var selectionSaveTask: Task<Void, Never>?
    var onPhotoSaveStatus: ((String, Bool) -> Void)?
    private var sharedSaveTask: Task<Void, Never>?
    private var photoSavePanel: NSOpenPanel?
    var onDragPhotos: (([GalleryPhoto]) -> [GalleryPhotoPromise])?
    var onSelectGalleryPhoto: ((GalleryPhoto, @escaping (GalleryPhoto?) -> Void) -> Void)?
    private var pendingPhotoSelection: UUID?
    var sharedBatch: SharedPhotoBatch? { didSet { needsLayout = true } }
    var onSharedBatchDropped: ((SharedPhotoBatch) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        display.videoGravity = .resizeAspect
        layer?.addSublayer(display)
        setAccessibilityLabel("鸿蒙手机实时画面")
        registerForDraggedTypes([.fileURL])
        addSubview(photoHandle)
        photoHandle.onDrag = { [weak self] event in
            guard let self else { return }
            if let batch = self.sharedBatch { self.startSharedDrag(batch, with: event) }
            else { self.startPhotoDrag(self.photoPromises(), with: event) }
        }
        photoHandle.onSave = { [weak self] in self?.savePhotos() }
        configurePhotoButton(addPhotoButton, icon: "plus", label: "加入批量", action: #selector(togglePhoto))
        configurePhotoButton(clearPhotosButton, icon: "xmark", label: "清空批量", action: #selector(clearPhotos))
    }

    private func configurePhotoButton(_ button: NSButton, icon: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        addSubview(button)
    }

    @objc private func togglePhoto() {
        guard let photo = galleryPhoto, pendingPhotoSelection == nil, let verify = onSelectGalleryPhoto else { return }
        if let index = selectedPhotos.firstIndex(where: { $0.uri == photo.uri }) {
            selectedPhotos.remove(at: index)
            needsLayout = true
            return
        }
        let request = UUID()
        pendingPhotoSelection = request
        needsLayout = true
        verify(photo) { [weak self] confirmed in
            guard let self, self.pendingPhotoSelection == request else { return }
            self.pendingPhotoSelection = nil
            if let confirmed, !self.selectedPhotos.contains(where: { $0.uri == confirmed.uri }) {
                self.selectedPhotos.append(confirmed)
            }
            self.needsLayout = true
        }
    }

    @objc private func clearPhotos() {
        pendingPhotoSelection = nil
        selectedPhotos.removeAll()
        needsLayout = true
    }

    private func photoPromises() -> [GalleryPhotoPromise] {
        if !selectedPhotos.isEmpty { return onDragPhotos?(selectedPhotos) ?? [] }
        if let galleryPhoto { return onDragPhotos?([galleryPhoto]) ?? [] }
        return []
    }

    private func savePhotos() {
        guard let window, window.attachedSheet == nil, sharedSaveTask == nil,
              selectionSaveTask == nil, let read = onReadGallerySelection else { return }
        let pending = selectedPhotos
        let shared = sharedBatch
        choosePhotoFolder(for: window) { [weak self] folder in
            guard let self else { return }
            self.selectionSaveTask = Task {
                defer { self.selectionSaveTask = nil; self.needsLayout = true }
                self.onPhotoSaveStatus?("正在读取图库选中的照片…", true)
                var saved = 0
                do {
                    let photos = try await read(pending)
                    try Task.checkCancellation()
                    if photos.isEmpty, let shared, self.sharedBatch?.id == shared.id {
                        self.saveSharedPhotos(shared, to: folder)
                        return
                    }
                    guard !photos.isEmpty else {
                        throw PhotoExportError(message: "请先在手机图库中勾选要保存的照片。")
                    }
                    let promises = self.onDragPhotos?(photos) ?? []
                    guard promises.count == photos.count else {
                        throw PhotoExportError(message: "手机连接已断开。")
                    }
                    for promise in promises {
                        try Task.checkCancellation()
                        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
                            promise.export(toFolder: folder) { error in
                                if let error { completion.resume(throwing: error) }
                                else { completion.resume() }
                            }
                        }
                        saved += 1
                    }
                    if !Task.isCancelled { self.onPhotoSaveStatus?("已保存 " + String(saved) + " 张原图", false) }
                } catch {
                    guard !Task.isCancelled else { return }
                    let prefix = saved == 0 ? "" : "已保存 " + String(saved) + " 张。"
                    self.onPhotoSaveStatus?(prefix + error.localizedDescription, false)
                }
            }
            self.needsLayout = true
        }
    }

    private func choosePhotoFolder(for window: NSWindow, save: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "选择 Mac 保存位置"
        panel.prompt = "保存"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        photoSavePanel = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self, let panel, self.photoSavePanel === panel else { return }
            self.photoSavePanel = nil
            guard response == .OK, let folder = panel.url else { return }
            save(folder)
        }
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let videoFrame = videoBounds
        display.frame = layer?.isGeometryFlipped == true ? videoFrame : videoFrame.offsetBy(dx: 0, dy: photoBarHeight)
        CATransaction.commit()
        layoutPhotoHandle()
    }

    private func layoutPhotoHandle() {
        let count = selectedPhotos.count
        photoHandle.title = "选择手机照片"
        photoHandle.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)
        photoHandle.isEnabled = sharedSaveTask == nil && selectionSaveTask == nil && onReadGallerySelection != nil
        photoHandle.toolTip = "将手机图库中已选的照片保存到 Mac。"
        let alreadySelected = selectedPhotos.contains { $0.uri == galleryPhoto?.uri }
        addPhotoButton.image = NSImage(systemSymbolName: alreadySelected ? "checkmark" : "plus", accessibilityDescription: nil)
        addPhotoButton.setAccessibilityLabel(alreadySelected ? "移出批量" : "加入批量")
        addPhotoButton.toolTip = alreadySelected ? "移出批量" : "加入批量"
        addPhotoButton.isEnabled = galleryPhoto != nil && pendingPhotoSelection == nil
        addPhotoButton.isHidden = sharedBatch != nil || galleryPhoto == nil
        clearPhotosButton.isHidden = count == 0 || sharedBatch != nil
        let y = bounds.maxY - photoBarHeight + 4
        let width = min(140, max(96, photoHandle.fittingSize.width))
        photoHandle.frame = CGRect(x: max(8, bounds.maxX - width - 8), y: y, width: width, height: 28)
        addPhotoButton.frame = CGRect(x: 8, y: y, width: 32, height: 28)
        clearPhotosButton.frame = CGRect(x: addPhotoButton.frame.maxX + 4, y: y, width: 26, height: 28)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onCheckGallery?()
    }

    func reset() {
        selectionSaveTask?.cancel()
        selectionSaveTask = nil
        let panel = photoSavePanel
        photoSavePanel = nil
        panel?.cancel(nil)
        sharedSaveTask?.cancel()
        sharedSaveTask = nil
        sharedBatch?.cleanUpLater()
        sharedBatch = nil
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        display.flushAndRemoveImage()
        displayedFormat = nil
        needsKeyframe = true
        dimensions = .zero
        screen = .zero
        touchActive = false
        dragTiles = []
        tilePress = nil
        tileDrag?.cancel()
        tileDrag = nil
        galleryPhoto = nil
        clearPhotos()
        photoPress = nil
    }

    func setScreen(width: Int, height: Int) {
        screen = CGSize(width: width, height: height)
        needsLayout = true
    }

    @discardableResult
    func present(_ frame: MirrorFrame) -> Bool {
        if display.status == .failed || display.requiresFlushToResumeDecoding {
            needsKeyframe = true
            guard frame.keyframe else { return false }
            display.flushAndRemoveImage()
        }
        // After dropping a frame, wait for an IDR before resuming inter-frame decoding.
        guard !needsKeyframe || frame.keyframe else { return false }
        guard display.isReadyForMoreMediaData else {
            needsKeyframe = true
            return false
        }
        if needsKeyframe || displayedFormat != frame.format {
            display.flush()
            displayedFormat = frame.format
            let size = CMVideoFormatDescriptionGetDimensions(frame.format)
            dimensions = CGSize(width: Int(size.width), height: Int(size.height))
        }
        display.enqueue(frame.sample)
        needsKeyframe = false
        return true
    }

    private var phoneSize: CGSize? {
        guard dimensions.width > 0, dimensions.height > 0, screen.width > 0, screen.height > 0 else { return nil }
        let rotated = (screen.width > screen.height) != (dimensions.width > dimensions.height)
        return rotated ? CGSize(width: screen.height, height: screen.width) : screen
    }

    private func phonePoint(_ event: NSEvent, clip: Bool) -> CGPoint? {
        guard let size = phoneSize else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let draw = AVMakeRect(aspectRatio: dimensions, insideRect: videoBounds)
        guard draw.width > 0, draw.height > 0, clip || draw.contains(point) else { return nil }
        let width = Int(size.width)
        let height = Int(size.height)
        let x = min(width - 1, max(0, Int((point.x - draw.minX) / draw.width * CGFloat(width))))
        let y = min(height - 1, max(0, Int((point.y - draw.minY) / draw.height * CGFloat(height))))
        return CGPoint(x: x, y: y)
    }

    private func send(_ phase: String, _ event: NSEvent, clip: Bool) -> Bool {
        guard let point = phonePoint(event, clip: clip) else { return false }
        onTouch?(phase, Int(point.x), Int(point.y))
        return true
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accept = sender.draggingSourceOperationMask.contains(.copy)
            && canDropFiles?() == true && !fileURLs(from: sender).isEmpty
        onFileHover?(accept)
        return accept ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onFileHover?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onFileHover?(false)
        return onFiles?(fileURLs(from: sender)) == true
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if AVMakeRect(aspectRatio: dimensions, insideRect: videoBounds).contains(point) {
            galleryPhoto = nil
            onBack?()
            onCheckGallery?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = phonePoint(event, clip: false) else { return }
        let exportRequested = event.modifierFlags.contains(.option)
        if let tile = dragTiles.first(where: { $0.bounds.contains(point) }) {
            tilePress = (event, point, tile)
        } else if exportRequested || galleryPhoto?.bounds.contains(point) == true {
            photoPress = (event, galleryPhoto, exportRequested)
            if galleryPhoto == nil { onCheckGallery?() }
        } else {
            touchActive = send("down", event, clip: false)
        }
        inputAnchor = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        inputContext?.invalidateCharacterCoordinates()
    }

    override func mouseDragged(with event: NSEvent) {
        if let press = tilePress {
            let dx = abs(event.locationInWindow.x - press.event.locationInWindow.x)
            let dy = abs(event.locationInWindow.y - press.event.locationInWindow.y)
            guard max(dx, dy) >= 5 else { return }
            tilePress = nil
            if dx >= dy || event.modifierFlags.contains(.option) {
                if let batch = onDragTile?(press.tile, press.point) {
                    tileDrag = batch
                    startPromiseDrag(batch.providers(), with: event)
                }
                return
            }
            touchActive = send("down", press.event, clip: true)
        }
        if let start = photoPress {
            let point = convert(event.locationInWindow, from: nil)
            let origin = convert(start.event.locationInWindow, from: nil)
            let dx = abs(point.x - origin.x)
            let dy = abs(point.y - origin.y)
            let approachingEdge = dx > max(8, dy)
                && (point.x < origin.x ? point.x <= bounds.minX + 16 : point.x >= bounds.maxX - 16)
            let explicitlyDragging = start.exportRequested || event.modifierFlags.contains(.option)
            if (approachingEdge || explicitlyDragging && dx + dy > 4),
               let photo = start.photo ?? galleryPhoto,
               let promises = onDragPhotos?([photo]), !promises.isEmpty {
                photoPress = nil
                startPhotoDrag(promises, with: event)
                return
            }
            guard !explicitlyDragging, dy > max(10, dx) else { return }
            photoPress = nil
            touchActive = send("down", start.event, clip: true)
        }
        if touchActive { _ = send("move", event, clip: true) }
    }

    override func mouseUp(with event: NSEvent) {
        if let press = tilePress {
            tilePress = nil
            if event.timestamp - press.event.timestamp >= 0.45 {
                onHoldTile?(press.point)
                return
            }
            touchActive = send("down", press.event, clip: true)
        }
        if let start = photoPress {
            photoPress = nil
            if !start.exportRequested {
                touchActive = send("down", start.event, clip: true)
                if abs(event.locationInWindow.x - start.event.locationInWindow.x) > 4 {
                    _ = send("dragRelease", event, clip: true)
                }
            }
        }
        if touchActive {
            galleryPhoto = nil
            _ = send("up", event, clip: true)
        }
        touchActive = false
        onCheckGallery?()
    }

    private func startPhotoDrag(_ promises: [GalleryPhotoPromise], with event: NSEvent) {
        guard !promises.isEmpty else { return }
        let providers = promises.map { promise in
            let provider = NSFilePromiseProvider(fileType: promise.photo.type, delegate: promise)
            provider.userInfo = promise
            return provider
        }
        startPromiseDrag(providers, with: event)
    }

    private func startPromiseDrag(_ providers: [NSFilePromiseProvider], with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let items = providers.enumerated().map { index, provider in
            let item = NSDraggingItem(pasteboardWriter: provider)
            let icon = NSWorkspace.shared.icon(for: UTType(provider.fileType) ?? .image)
            let offset = CGFloat(min(index, 3)) * 3
            item.setDraggingFrame(CGRect(x: point.x - 20 + offset, y: point.y - 20 + offset,
                                         width: 40, height: 40), contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.isEmpty { tileDrag?.cancel() }
        tileDrag = nil
        onCheckGallery?()
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    private func startSharedDrag(_ batch: SharedPhotoBatch, with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let icon = NSWorkspace.shared.icon(for: .image)
        var copied = Set<URL>()
        let items = batch.files.enumerated().map { index, url in
            let promise = SharedPhotoPromise(source: url) { [weak self] in
                copied.insert(url)
                if copied.count == batch.files.count { self?.onSharedBatchDropped?(batch) }
            }
            let item = NSDraggingItem(pasteboardWriter: promise.makeProvider())
            let offset = CGFloat(min(index, 3)) * 3
            item.setDraggingFrame(CGRect(x: point.x - 20 + offset, y: point.y - 20 + offset,
                                         width: 40, height: 40), contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    private func saveSharedPhotos(_ batch: SharedPhotoBatch, to folder: URL) {
        onPhotoSaveStatus?("正在保存 \(batch.files.count) 张原图…", true)
        sharedSaveTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                for file in batch.files {
                    try Task.checkCancellation()
                    let destination = PhonePhotoExport.availableDestination(in: folder, filename: file.lastPathComponent)
                    try FileManager.default.copyItem(at: file, to: destination)
                }
            }
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            self.sharedSaveTask = nil
            self.needsLayout = true
            switch result {
            case .success:
                self.onSharedBatchDropped?(batch)
                self.onPhotoSaveStatus?("已保存 \(batch.files.count) 张原图", false)
            case .failure(let error):
                self.onPhotoSaveStatus?("保存原图失败。\(error.localizedDescription)", false)
            }
        }
        needsLayout = true
    }

    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }
        interpretKeyEvents([event])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard window?.firstResponder === self, modifiers == .command,
              event.charactersIgnoringModifiers?.lowercased() == "v" else {
            return super.performKeyEquivalent(with: event)
        }
        if let text = NSPasteboard.general.string(forType: .string) {
            insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        inputContext?.discardMarkedText()
        unmarkText()
        return super.resignFirstResponder()
    }

    func insertText(_ value: Any, replacementRange: NSRange) {
        let text = (value as? NSAttributedString)?.string ?? value as? String ?? ""
        unmarkText()
        if !text.isEmpty { onText?(text) }
    }

    func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = value as? NSAttributedString ?? NSAttributedString(string: value as? String ?? "")
        compositionSelection = selectedRange
    }

    func unmarkText() {
        marked = NSAttributedString()
        compositionSelection = NSRange(location: 0, length: 0)
    }

    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange { NSRange(location: hasMarkedText() ? 0 : NSNotFound, length: marked.length) }
    func selectedRange() -> NSRange { compositionSelection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, range.location <= marked.length else { return nil }
        let available = NSRange(location: range.location, length: min(range.length, marked.length - range.location))
        guard available.length > 0 else { return nil }
        actualRange?.pointee = available
        return marked.attributedSubstring(from: available)
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let rect = NSRect(origin: inputAnchor, size: NSSize(width: 1, height: 18))
        return window?.convertToScreen(convert(rect, to: nil)) ?? .zero
    }

    override func doCommand(by selector: Selector) {
        // AppKit's input context handles editing commands while IME composition is active.
        guard !hasMarkedText() else { return }
        if let key = PhoneEditKey(command: selector) { onEditKey?(key) }
    }
}

@MainActor
private final class GalleryDragHandle: NSButton {
    var onDrag: ((NSEvent) -> Void)?
    var onSave: (() -> Void)?
    private var press: NSEvent?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = "拖出原图"
        image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
        imagePosition = .imageLeading
        bezelStyle = .rounded
        controlSize = .regular
        toolTip = "按住拖到 Finder 或桌面，点击也可以保存原图"
        target = self
        action = #selector(save)
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        press = event
        highlight(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press, hypot(event.locationInWindow.x - press.locationInWindow.x,
                               event.locationInWindow.y - press.locationInWindow.y) > 4 else { return }
        self.press = nil
        highlight(false)
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = press != nil
        press = nil
        highlight(false)
        if wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) {
            save()
        }
    }

    @objc private func save() { onSave?() }
}

struct VideoSurface: NSViewRepresentable {
    let view: MirrorVideo
    func makeNSView(context: Context) -> MirrorVideo { view }
    func updateNSView(_ nsView: MirrorVideo, context: Context) {}
}
