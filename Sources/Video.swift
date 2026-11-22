import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MirrorVideo: NSView, @preconcurrency NSTextInputClient, NSDraggingSource {
    private let display = AVSampleBufferDisplayLayer()
    private var sps = Data()
    private var pps = Data()
    private var format: CMVideoFormatDescription?
    private var screen = CGSize.zero
    private var touchActive = false
    private var photoPress: (event: NSEvent, photo: GalleryPhoto)?
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
    var onDragPhotos: (([GalleryPhoto], Bool) -> [GalleryPhotoPromise])?
    var onSelectGalleryPhoto: ((GalleryPhoto, @escaping (GalleryPhoto?) -> Void) -> Void)?
    private var pendingPhotoSelection: UUID?

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
            self.startPhotoDrag(self.photoPromises(), with: event)
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
        if !selectedPhotos.isEmpty { return onDragPhotos?(selectedPhotos, false) ?? [] }
        if let galleryPhoto { return onDragPhotos?([galleryPhoto], true) ?? [] }
        return []
    }

    private func savePhotos() {
        guard let window else { return }
        let promises = photoPromises()
        if promises.count == 1, let promise = promises.first {
            let panel = NSSavePanel()
            panel.title = "保存手机照片"
            panel.nameFieldStringValue = promise.filename
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                promise.export(to: url, replacing: true) { _ in }
            }
        } else if !promises.isEmpty {
            let panel = NSOpenPanel()
            panel.title = "选择原图保存位置"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let folder = panel.url else { return }
                var names = Set<String>()
                for promise in promises {
                    let stem = (promise.filename as NSString).deletingPathExtension
                    let ext = (promise.filename as NSString).pathExtension
                    var name = promise.filename
                    var index = 2
                    while names.contains(name.lowercased()) ||
                            FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                        name = "\(stem) \(index).\(ext)"
                        index += 1
                    }
                    names.insert(name.lowercased())
                    promise.export(to: folder.appendingPathComponent(name), replacing: false) { _ in }
                }
            }
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
        photoHandle.title = count > 0 ? "拖出 \(count) 张原图" : "拖出原图"
        photoHandle.isEnabled = count > 0 || galleryPhoto != nil
        photoHandle.toolTip = photoHandle.isEnabled
            ? "按住拖到 Finder 或桌面，点击也可以保存原图"
            : "在投屏中打开一张图库照片"
        let alreadySelected = selectedPhotos.contains { $0.uri == galleryPhoto?.uri }
        addPhotoButton.image = NSImage(systemSymbolName: alreadySelected ? "checkmark" : "plus", accessibilityDescription: nil)
        addPhotoButton.setAccessibilityLabel(alreadySelected ? "移出批量" : "加入批量")
        addPhotoButton.toolTip = alreadySelected ? "移出批量" : "加入批量"
        addPhotoButton.isEnabled = galleryPhoto != nil && pendingPhotoSelection == nil
        clearPhotosButton.isHidden = count == 0
        let y = bounds.maxY - photoBarHeight + 4
        let width = min(140, max(96, photoHandle.fittingSize.width))
        photoHandle.frame = CGRect(x: 8, y: y, width: width, height: 28)
        addPhotoButton.frame = CGRect(x: photoHandle.frame.maxX + 5, y: y, width: 32, height: 28)
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
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        display.flushAndRemoveImage()
        sps = Data()
        pps = Data()
        format = nil
        dimensions = .zero
        screen = .zero
        touchActive = false
        galleryPhoto = nil
        clearPhotos()
        photoPress = nil
    }

    func setScreen(width: Int, height: Int) {
        screen = CGSize(width: width, height: height)
        needsLayout = true
    }

    @discardableResult
    func consume(_ data: Data) -> Bool {
        let nalUnits = Self.annexBRanges(data)
        var accessUnit = Data()
        var hasSlice = false
        var keyframe = false
        for range in nalUnits {
            let nal = data[range]
            guard let first = nal.first else { continue }
            switch first & 0x1f {
            case 7:
                if sps != nal { sps = Data(nal); format = nil }
            case 8:
                if pps != nal { pps = Data(nal); format = nil }
            case 1, 5:
                hasSlice = true
                keyframe = keyframe || (first & 0x1f == 5)
                Self.append(nal, to: &accessUnit)
            case 6:
                Self.append(nal, to: &accessUnit)
            default:
                break
            }
        }
        guard hasSlice else { return false }
        if display.status == .failed {
            display.flushAndRemoveImage()
            format = nil
        }
        if format == nil {
            guard keyframe, !sps.isEmpty, !pps.isEmpty else { return false }
            var description: CMFormatDescription?
            let status = sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    let pointers = [
                        spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                        ppsBytes.bindMemory(to: UInt8.self).baseAddress!
                    ]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: pointers, parameterSetSizes: [sps.count, pps.count],
                        nalUnitHeaderLength: 4, formatDescriptionOut: &description
                    )
                }
            }
            guard status == noErr, let description else { return false }
            let size = CMVideoFormatDescriptionGetDimensions(description)
            dimensions = CGSize(width: Int(size.width), height: Int(size.height))
            display.flush()
            format = description
        }

        var block: CMBlockBuffer?
        let length = accessUnit.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: 0, blockBufferOut: &block
        ) == noErr, let block, let format else { return false }

        let copyStatus = accessUnit.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copyStatus == noErr else { return false }
        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample,
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else {
            return false
        }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        display.enqueue(sample)
        return true
    }

    private static func append(_ nal: Data, to data: inout Data) {
        var size = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(nal)
    }

    nonisolated static func annexBRanges(_ data: Data) -> [Range<Data.Index>] {
        data.withUnsafeBytes { bytes in
            var units = [Range<Data.Index>]()
            var start: Int?
            var index = 0
            let base = data.startIndex
            while index + 2 < bytes.count {
                guard bytes[index] == 0, bytes[index + 1] == 0 else {
                    index += 1
                    continue
                }
                let prefix: Int
                if bytes[index + 2] == 1 {
                    prefix = 3
                } else if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    prefix = 4
                } else {
                    index += 1
                    continue
                }
                if let start, index > start { units.append((base + start)..<(base + index)) }
                start = index + prefix
                index += prefix
            }
            if let start, start < bytes.count { units.append((base + start)..<data.endIndex) }
            return units
        }
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
            onBack?()
            onCheckGallery?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = phonePoint(event, clip: false) else { return }
        if let galleryPhoto, galleryPhoto.bounds.contains(point) {
            photoPress = (event, galleryPhoto)
        } else {
            touchActive = send("down", event, clip: false)
        }
        inputAnchor = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        inputContext?.invalidateCharacterCoordinates()
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = photoPress {
            let point = convert(event.locationInWindow, from: nil)
            let origin = convert(start.event.locationInWindow, from: nil)
            let dx = abs(point.x - origin.x)
            let dy = abs(point.y - origin.y)
            let approachingEdge = dx > max(8, dy)
                && (point.x < origin.x ? point.x <= bounds.minX + 9 : point.x >= bounds.maxX - 9)
            if (approachingEdge || event.modifierFlags.contains(.option) && dx + dy > 6),
               let promises = onDragPhotos?([start.photo], true), !promises.isEmpty {
                photoPress = nil
                startPhotoDrag(promises, with: start.event)
                return
            }
            guard dy > max(10, dx) else { return }
            photoPress = nil
            touchActive = send("down", start.event, clip: true)
        }
        if touchActive { _ = send("move", event, clip: true) }
    }

    override func mouseUp(with event: NSEvent) {
        if let start = photoPress {
            photoPress = nil
            touchActive = send("down", start.event, clip: true)
            if abs(event.locationInWindow.x - start.event.locationInWindow.x) > 4 {
                _ = send("dragRelease", event, clip: true)
            }
        }
        if touchActive { _ = send("up", event, clip: true) }
        touchActive = false
        onCheckGallery?()
    }

    private func startPhotoDrag(_ promises: [GalleryPhotoPromise], with event: NSEvent) {
        guard !promises.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        let items = promises.enumerated().map { index, promise in
            let provider = NSFilePromiseProvider(fileType: promise.photo.type, delegate: promise)
            provider.userInfo = promise
            let item = NSDraggingItem(pasteboardWriter: provider)
            let icon = NSWorkspace.shared.icon(for: UTType(promise.photo.type) ?? .image)
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
        guard let event = press else { return }
        press = nil
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
