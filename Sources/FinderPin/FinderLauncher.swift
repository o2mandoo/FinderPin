import AppKit

/// Remembers where the last Finder window was closed (folder + frame).
enum LastLocation {
    private static let pathKey = "lastClosedFolder"
    private static let frameKey = "lastClosedFrame"

    static func save(_ w: FinderWindow) {
        guard let folder = w.folder else { return }
        UserDefaults.standard.set(folder.path, forKey: pathKey)
        if w.frame.width > 0 {
            UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: frameKey)
        }
    }

    static var folder: URL? {
        UserDefaults.standard.string(forKey: pathKey).map { URL(fileURLWithPath: $0) }
    }

    /// Global CG coordinates (top-left origin).
    static var frame: CGRect? {
        UserDefaults.standard.string(forKey: frameKey).map { NSRectFromString($0) }
    }
}

/// ⌥⌘Space: bring Finder forward. If no Finder window is open in the current
/// Space, open a new one at the folder and position of the last closed window.
final class FinderLauncher {
    private let tracker: FinderTracker
    private let pins: PinController
    private var pendingFrame: (frame: CGRect, deadline: Date)?

    init(tracker: FinderTracker, pins: PinController) {
        self.tracker = tracker
        self.pins = pins
    }

    func trigger() {
        tracker.reconcile()
        if let front = tracker.windows.values.filter(\.onScreen).min(by: { $0.zIndex < $1.zIndex }) {
            pins.bringForward(front.id)
            return
        }

        let folder = Self.existingAncestor(of: LastLocation.folder)
        if let frame = LastLocation.frame, Self.isVisibleOnSomeScreen(frame) {
            pendingFrame = (frame, Date().addingTimeInterval(3))
        }
        guard let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderBundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: finderURL, configuration: config) { _, error in
            if let error { NSLog("[FinderPin] open \(folder.path) failed: \(error.localizedDescription)") }
        }
    }

    /// Called for every newly detected Finder window; places the one we just opened.
    func windowCreated(_ w: FinderWindow) {
        guard let pending = pendingFrame else { return }
        pendingFrame = nil
        guard Date() < pending.deadline else { return }
        var origin = pending.frame.origin
        var size = pending.frame.size
        if let pos = AXValueCreate(.cgPoint, &origin) { AX.set(w.element, kAXPositionAttribute, pos) }
        if let sz = AXValueCreate(.cgSize, &size) { AX.set(w.element, kAXSizeAttribute, sz) }
        // Finder may not activate itself when the open request comes from a background app.
        if let app = tracker.appElement {
            AX.perform(w.element, kAXRaiseAction)
            AX.set(app, kAXFrontmostAttribute, kCFBooleanTrue)
        }
        tracker.setNeedsReconcile()
    }

    private static func existingAncestor(of url: URL?) -> URL {
        var candidate = url
        while let c = candidate, c.path != "/" {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: c.path, isDirectory: &isDir), isDir.boolValue { return c }
            candidate = c.deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func isVisibleOnSomeScreen(_ cgFrame: CGRect) -> Bool {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return false }
        let cocoa = NSRect(x: cgFrame.minX, y: primaryHeight - cgFrame.maxY, width: cgFrame.width, height: cgFrame.height)
        return NSScreen.screens.contains { $0.visibleFrame.intersection(cocoa).width >= 100 }
    }
}
