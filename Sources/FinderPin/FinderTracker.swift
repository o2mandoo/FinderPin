import AppKit
import ApplicationServices

let finderBundleID = "com.apple.finder"

struct FinderWindow {
    let id: CGWindowID
    let element: AXUIElement
    /// Global CG coordinates (top-left origin of the primary display).
    var frame: CGRect
    /// On screen in the current Space (not minimized, not hidden, not on another Space).
    var onScreen: Bool
    /// Front-to-back position among on-screen windows (lower = more in front).
    var zIndex: Int
    var title: String
    /// Folder shown in the window (from the path bar), if known.
    var folder: URL?
}

/// Tracks Finder browser windows via AXObserver events plus a periodic reconcile.
final class FinderTracker {
    private(set) var windows: [CGWindowID: FinderWindow] = [:]
    private(set) var appElement: AXUIElement?
    private(set) var finderPID: pid_t = 0

    var onChange: (() -> Void)?
    var onWindowCreated: ((FinderWindow) -> Void)?
    /// Windows that no longer exist anywhere (closed), with their last known state.
    var onWindowsClosed: (([FinderWindow]) -> Void)?
    /// Focused window changed / title changed while Finder is frontmost.
    var onFocusOrNavigation: (() -> Void)?

    private var observer: AXObserver?
    private var nonBrowserIDs: Set<CGWindowID> = []
    private var timer: Timer?
    private var pendingReconcile = false

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == finderBundleID {
                // Finder needs a moment before its AX tree is ready.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.attach() }
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == finderBundleID {
                self?.detach()
                self?.reconcile()
            }
        }
        attach()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Covers Accessibility being granted after launch.
            if self.observer == nil { self.attach() } else { self.reconcile() }
        }
    }

    /// Coalesces bursts of AX notifications into one reconcile on the next runloop turn.
    func setNeedsReconcile() {
        guard !pendingReconcile else { return }
        pendingReconcile = true
        DispatchQueue.main.async { [weak self] in
            self?.pendingReconcile = false
            self?.reconcile()
        }
    }

    private func attach() {
        detach()
        guard AXIsProcessTrusted(),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID).first else { return }
        finderPID = finder.processIdentifier
        let app = AXUIElementCreateApplication(finderPID)
        appElement = app

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<FinderTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.handle(notification as String)
        }
        guard AXObserverCreate(finderPID, callback, &obs) == .success, let obs else {
            NSLog("[FinderPin] AXObserverCreate failed (Accessibility permission?)")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
                  kAXFocusedWindowChangedNotification, kAXWindowMovedNotification,
                  kAXWindowResizedNotification, kAXWindowMiniaturizedNotification,
                  kAXWindowDeminiaturizedNotification, kAXApplicationHiddenNotification,
                  kAXApplicationShownNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        reconcile()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        finderPID = 0
    }

    private func handle(_ notification: String) {
        setNeedsReconcile()
        if notification == kAXFocusedWindowChangedNotification || notification == kAXTitleChangedNotification
            || notification == kAXWindowCreatedNotification {
            // Let Finder finish building the window/view first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.onFocusOrNavigation?() }
        }
    }

    func reconcile() {
        guard let app = appElement, finderPID != 0 else {
            if !windows.isEmpty { windows = [:]; onChange?() }
            return
        }

        // AX only lists windows on the current Space, so window existence comes from
        // the window server (all Spaces); AX is used for new-window detection/control.
        let all = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let existing = Set(all.compactMap { d -> CGWindowID? in
            guard (d[kCGWindowOwnerPID as String] as? pid_t) == finderPID,
                  (d[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return d[kCGWindowNumber as String] as? CGWindowID
        })

        // Front-to-back list of on-screen Finder windows on the normal layer.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var onScreen: [CGWindowID: (CGRect, Int)] = [:]
        for (i, d) in info.enumerated() {
            guard (d[kCGWindowOwnerPID as String] as? pid_t) == finderPID,
                  (d[kCGWindowLayer as String] as? Int) == 0,
                  let wid = d[kCGWindowNumber as String] as? CGWindowID,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { continue }
            onScreen[wid] = (rect, i)
        }

        var next: [CGWindowID: FinderWindow] = [:]
        for e in AX.elements(app, kAXWindowsAttribute) {
            guard AX.string(e, kAXSubroleAttribute) == kAXStandardWindowSubrole,
                  let id = AX.windowID(e), !nonBrowserIDs.contains(id) else { continue }
            if windows[id] == nil && !Self.isBrowserWindow(e) {
                nonBrowserIDs.insert(id) // Get Info, copy progress, etc.
                continue
            }
            let screen = onScreen[id]
            next[id] = FinderWindow(id: id, element: e,
                                   frame: screen?.0 ?? .zero,
                                   onScreen: screen != nil,
                                   zIndex: screen?.1 ?? Int.max,
                                   title: AX.string(e, kAXTitleAttribute) ?? "",
                                   folder: Self.currentFolder(e) ?? windows[id]?.folder)
        }

        // Still open on another Space: keep it (and its pin state), marked off-screen.
        // (Finder keeps *closed* windows alive but on no Space, so existence alone is not enough.)
        for (id, old) in windows where next[id] == nil && existing.contains(id)
            && (WindowSpaces.isOnAnySpace(id) ?? true) {
            var w = old
            w.onScreen = onScreen[id] != nil
            w.zIndex = onScreen[id]?.1 ?? Int.max
            next[id] = w
        }

        let added = next.keys.filter { windows[$0] == nil }
        let closed = windows.values.filter { next[$0.id] == nil }
        let changed = added.count > 0 || next.count != windows.count || next.contains { id, w in
            guard let old = windows[id] else { return true }
            return old.frame != w.frame || old.onScreen != w.onScreen || old.title != w.title || old.zIndex != w.zIndex
        }
        windows = next
        nonBrowserIDs.formIntersection(existing)
        if !closed.isEmpty { onWindowsClosed?(closed) }
        for id in added { onWindowCreated?(next[id]!) }
        if changed { onChange?() }
    }

    /// The folder a Finder window shows, read from its path bar (an AXList whose items
    /// carry file URLs, root → current). In Column View the last item can be the
    /// selected file, in which case its parent folder is used. Needs the path bar
    /// to be visible (Finder ▸ View ▸ Show Path Bar).
    static func currentFolder(_ window: AXUIElement) -> URL? {
        func search(_ e: AXUIElement, _ depth: Int) -> URL? {
            guard depth < 4 else { return nil }
            for c in AX.children(e) {
                switch AX.string(c, kAXRoleAttribute) {
                case kAXListRole?:
                    let urls = AX.children(c).compactMap { AX.value($0, kAXURLAttribute) as? URL }
                    if let last = urls.last { return (last as NSURL).filePathURL }
                case kAXSplitGroupRole?, kAXGroupRole?:
                    if let u = search(c, depth + 1) { return u }
                default:
                    break
                }
            }
            return nil
        }
        guard let url = search(window, 0) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        let isFolder = isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path)
        return isFolder ? url : url.deletingLastPathComponent()
    }

    /// Finder browser windows have a toolbar or a sidebar split view; Get Info / progress windows do not.
    private static func isBrowserWindow(_ e: AXUIElement) -> Bool {
        AX.children(e).contains { c in
            let r = AX.string(c, kAXRoleAttribute)
            return r == kAXToolbarRole || r == kAXSplitGroupRole
        }
    }

    var isFinderFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderBundleID
    }

    var focusedWindowID: CGWindowID? {
        guard let app = appElement, let w = AX.element(app, kAXFocusedWindowAttribute) else { return nil }
        return AX.windowID(w)
    }

    /// Topmost tracked window under a global CG point.
    func window(at cgPoint: CGPoint) -> FinderWindow? {
        windows.values.filter { $0.onScreen && $0.frame.contains(cgPoint) }.min { $0.zIndex < $1.zIndex }
    }
}
