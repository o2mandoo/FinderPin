import AppKit
import ScreenCaptureKit

/// A floating panel owned by FinderPin that sits exactly over a Finder window
/// and shows a live ScreenCaptureKit capture of it.
///
/// macOS does not let one process change another process's window level, so this
/// is how a Finder window is kept visually on top while another app is active.
/// Clicking (or dragging files onto) the overlay hands control to the real window.
final class MirrorOverlay: NSPanel {
    let windowID: CGWindowID
    var onActivate: (() -> Void)?
    /// First captured frame arrived; the overlay can now be presented.
    var onReady: (() -> Void)?

    private let mirrorView = MirrorView()
    private var capture: WindowCapture?
    private(set) var hasFrame = false

    init(windowID: CGWindowID) {
        self.windowID = windowID
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.ignoresCycle, .fullScreenNone]
        title = "FinderPin overlay \(windowID)"
        contentView = mirrorView
        mirrorView.onActivate = { [weak self] in self?.onActivate?() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `cgFrame` is in global CG coordinates (top-left origin).
    func track(cgFrame: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let rect = NSRect(x: cgFrame.minX, y: primaryHeight - cgFrame.maxY,
                          width: cgFrame.width, height: cgFrame.height)
        // Capture at the pixel density and color space of the display the window is
        // on; otherwise a window moved from a 1x to a 2x display is shown upscaled
        // (blurry) and P3 colors look washed out.
        let display = Self.displayTraits(for: rect)
        if frame != rect { setFrame(rect, display: false) }
        mirrorView.layer?.contentsScale = display.scale
        if let capture {
            capture.update(size: rect.size, scale: display.scale, colorSpace: display.colorSpace)
        } else {
            let c = WindowCapture(windowID: windowID, size: rect.size, scale: display.scale, colorSpace: display.colorSpace)
            c.onFrame = { [weak self] surface in
                guard let self else { return }
                self.mirrorView.show(surface)
                if !self.hasFrame {
                    self.hasFrame = true
                    self.onReady?()
                }
            }
            c.start()
            capture = c
        }
    }

    private static func displayTraits(for rect: NSRect) -> (scale: CGFloat, colorSpace: CFString) {
        let screen = NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
            return ia.width * ia.height < ib.width * ib.height
        } ?? NSScreen.main
        let p3 = screen?.canRepresent(.p3) ?? false
        return (screen?.backingScaleFactor ?? 2, p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)
    }

    func present() {
        // Never show an empty overlay: it would hide the window behind a transparent pane.
        guard hasFrame else { return }
        if !isVisible { orderFrontRegardless() }
    }

    func conceal() {
        if isVisible { orderOut(nil) }
    }

    func tearDown() {
        capture?.stop()
        capture = nil
        orderOut(nil)
        close()
    }
}

private final class MirrorView: NSView {
    var onActivate: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onActivate?() }
    override func rightMouseDown(with event: NSEvent) { onActivate?() }

    // Dragging a file over the mirror brings the real Finder window forward, so the
    // drop lands in Finder (the drag session re-targets once the overlay is gone).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onActivate?()
        return .generic
    }
}

/// One ScreenCaptureKit stream for one window. Frames arrive only when the
/// window content changes, so an idle Finder window costs almost nothing.
private final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let windowID: CGWindowID
    var onFrame: ((IOSurface) -> Void)?

    private var size: CGSize
    private var scale: CGFloat
    private var colorSpace: CFString
    private var stream: SCStream?
    private var stopped = false

    init(windowID: CGWindowID, size: CGSize, scale: CGFloat, colorSpace: CFString) {
        self.windowID = windowID
        self.size = size
        self.scale = scale
        self.colorSpace = colorSpace
    }

    func start() {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard !stopped, let window = content.windows.first(where: { $0.windowID == windowID }) else { return }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let s = SCStream(filter: filter, configuration: configuration(), delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                try await s.startCapture()
                if stopped { try? await s.stopCapture(); return }
                stream = s
            } catch {
                NSLog("[FinderPin] capture start failed for window \(windowID): \(error.localizedDescription)")
            }
        }
    }

    func update(size newSize: CGSize, scale newScale: CGFloat, colorSpace newColorSpace: CFString) {
        guard newSize != size || newScale != scale || newColorSpace != colorSpace else { return }
        size = newSize
        scale = newScale
        colorSpace = newColorSpace
        stream?.updateConfiguration(configuration()) { error in
            if let error { NSLog("[FinderPin] capture reconfigure failed: \(error.localizedDescription)") }
        }
    }

    func stop() {
        stopped = true
        let s = stream
        stream = nil
        s?.stopCapture { _ in }
    }

    private func configuration() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = max(1, Int(size.width * scale))
        c.height = max(1, Int(size.height * scale))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = colorSpace
        c.captureResolution = .best
        c.scalesToFit = false
        c.showsCursor = false
        c.capturesAudio = false
        c.ignoreShadowsSingleWindow = true
        c.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        c.queueDepth = 4
        return c
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        onFrame?(unsafeBitCast(surface, to: IOSurface.self))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[FinderPin] capture for window \(windowID) stopped: \(error.localizedDescription)")
    }
}
