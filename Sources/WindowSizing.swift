import AppKit
import SwiftUI

enum MirrorZoom {
    case inLarger, outSmaller, fit
}

struct MirrorZoomRequest: Equatable {
    let id = UUID()
    let action: MirrorZoom
}

struct MirrorWindowSizing: NSViewRepresentable {
    let aspect: CGFloat?
    let zoomRequest: MirrorZoomRequest?

    func makeNSView(context: Context) -> SizingView { SizingView() }

    func updateNSView(_ view: SizingView, context: Context) {
        view.aspect = aspect
        view.zoomRequest = zoomRequest
    }
}

/// Binds the native resize constraint to the current device video, while allowing
/// the same window to reopen the wider USB / Wi-Fi connection panel.
final class SizingView: NSView {
    var aspect: CGFloat? {
        didSet {
            if oldValue != aspect { scheduleUpdate() }
        }
    }

    var zoomRequest: MirrorZoomRequest? {
        didSet {
            if oldValue != zoomRequest { scheduleUpdate() }
        }
    }

    private var appliedZoomRequest: MirrorZoomRequest?
    private var appliedAspect: CGFloat?
    private var panelFrame: NSRect?
    private var panelUsesFullSizeContent = false
    private var lastMirrorLongSide: CGFloat?
    private var updateScheduled = false
    private let panelMinimum = NSSize(width: 560, height: 510)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didExitFullScreenNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(exitedFullScreen),
                                                   name: NSWindow.didExitFullScreenNotification, object: window)
            scheduleUpdate()
        }
    }

    @objc private func exitedFullScreen() { scheduleUpdate() }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateScheduled = false
            updateWindow()
        }
    }

    private func updateWindow() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        guard let aspect else {
            window.contentMinSize = panelMinimum
            guard appliedAspect != nil else { return }
            let current = window.contentRect(forFrameRect: window.frame)
            lastMirrorLongSide = max(current.width, current.height)
            appliedAspect = nil
            window.contentAspectRatio = .zero
            window.titleVisibility = .visible
            if panelUsesFullSizeContent { window.styleMask.insert(.fullSizeContentView) }
            if let panelFrame { window.setFrame(panelFrame, display: true) }
            panelFrame = nil
            return
        }
        let zoom = zoomRequest == appliedZoomRequest ? nil : zoomRequest?.action
        appliedZoomRequest = zoomRequest
        guard appliedAspect != aspect || zoom != nil else { return }

        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let current = window.contentRect(forFrameRect: window.frame)
        var longSide: CGFloat
        if appliedAspect == nil {
            panelFrame = window.frame
            panelUsesFullSizeContent = window.styleMask.contains(.fullSizeContentView)
            window.styleMask.remove(.fullSizeContentView)
            longSide = lastMirrorLongSide ?? min(670, visible.height * 0.79)
        } else {
            longSide = max(current.width, current.height)
        }
        switch zoom {
        case .inLarger: longSide *= 1.15
        case .outSmaller: longSide /= 1.15
        case .fit: longSide = min(670, visible.height * 0.79)
        case nil: break
        }
        appliedAspect = aspect
        window.titleVisibility = .hidden

        let contentRect = window.contentRect(forFrameRect: window.frame)
        let chromeHeight = max(0, window.frame.height - contentRect.height)
        let chromeWidth = max(0, window.frame.width - contentRect.width)
        let maxHeight = min(visible.height - chromeHeight - 18, (visible.width - chromeWidth - 18) / aspect)
        let minHeight = min(maxHeight, max(216, 224 / aspect))
        let preferredHeight = longSide / max(1, aspect)
        let height = max(1, min(maxHeight, max(minHeight, preferredHeight)))
        window.contentMinSize = NSSize(width: aspect * minHeight, height: minHeight)
        window.contentAspectRatio = NSSize(width: aspect, height: 1)

        let content = NSRect(origin: .zero, size: NSSize(width: aspect * height, height: height))
        var frame = window.frameRect(forContentRect: content)
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        frame.origin.x = min(visible.maxX - frame.width, max(visible.minX, center.x - frame.width / 2))
        frame.origin.y = min(visible.maxY - frame.height, max(visible.minY, center.y - frame.height / 2))
        window.setFrame(frame, display: true)
    }
}
