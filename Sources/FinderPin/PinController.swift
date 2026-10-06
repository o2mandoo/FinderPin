import AppKit

enum Settings {
    static let enabledKey = "enabled"
    static let autoPinKey = "autoPinNewWindows"
    static let forceColumnKey = "forceColumnView"
    static let launcherKey = "optCmdSpaceLauncher"

    static func register() {
        UserDefaults.standard.register(defaults: [enabledKey: true, autoPinKey: true, forceColumnKey: true, launcherKey: true])
    }

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    static var autoPin: Bool {
        get { UserDefaults.standard.bool(forKey: autoPinKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoPinKey) }
    }
    static var launcher: Bool {
        get { UserDefaults.standard.bool(forKey: launcherKey) }
        set { UserDefaults.standard.set(newValue, forKey: launcherKey) }
    }
    static var forceColumnView: Bool {
        get { UserDefaults.standard.bool(forKey: forceColumnKey) }
        set { UserDefaults.standard.set(newValue, forKey: forceColumnKey) }
    }
}

/// Decides which Finder windows are pinned and keeps one mirror overlay per
/// pinned, on-screen window. Overlays are shown only while another app is
/// frontmost; while Finder is active its real windows are already on top.
final class PinController {
    private let tracker: FinderTracker
    private(set) var pinned: Set<CGWindowID> = []
    private var overlays: [CGWindowID: MirrorOverlay] = [:]
    /// While set, overlays stay up even though Finder is still frontmost: a switch to
    /// another app is in flight (see SwitchAwayDetector).
    private var preShowUntil: Date?

    init(tracker: FinderTracker) {
        self.tracker = tracker
    }

    func windowAppeared(_ w: FinderWindow) {
        if Settings.autoPin { pinned.insert(w.id) }
    }

    func isPinned(_ id: CGWindowID) -> Bool { pinned.contains(id) }

    func toggle(_ id: CGWindowID) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        update()
    }

    func update() {
        pinned.formIntersection(tracker.windows.keys)

        var keep: [FinderWindow] = []
        if Settings.enabled {
            for w in tracker.windows.values where w.onScreen && pinned.contains(w.id) {
                keep.append(w)
                let overlay = overlays[w.id] ?? makeOverlay(for: w.id)
                overlay.track(cgFrame: w.frame)
            }
        }
        let keepIDs = Set(keep.map(\.id))
        for (id, overlay) in overlays where !keepIDs.contains(id) {
            overlay.tearDown()
            overlays[id] = nil
        }

        let preShowing = preShowUntil.map { Date() < $0 } ?? false
        let finderActive = tracker.isFinderFrontmost && !preShowing
        // Back to front, so the overlay of Finder's frontmost window ends up on top.
        for w in keep.sorted(by: { $0.zIndex > $1.zIndex }) {
            guard let overlay = overlays[w.id] else { continue }
            if finderActive { overlay.conceal() } else { overlay.present() }
        }
    }

    /// Put overlays up *before* the other app raises its window, so the Finder
    /// window never visibly drops behind it. If Finder is still frontmost after the
    /// grace period (e.g. the click did not switch apps), the overlays go away again.
    func preShow(untilCommandReleased: Bool) {
        guard Settings.enabled else { return }
        preShowUntil = untilCommandReleased ? .distantFuture : Date().addingTimeInterval(0.4)
        update()
        if !untilCommandReleased { scheduleRecheck() }
    }

    func commandReleased() {
        guard preShowUntil != nil else { return }
        preShowUntil = Date().addingTimeInterval(0.4)
        scheduleRecheck()
    }

    /// Finder became active (user picked it): drop any pending pre-show.
    func finderActivated() {
        preShowUntil = nil
        update()
    }

    private func scheduleRecheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.update() }
    }

    private func makeOverlay(for id: CGWindowID) -> MirrorOverlay {
        let overlay = MirrorOverlay(windowID: id)
        overlay.onActivate = { [weak self] in self?.bringForward(id) }
        overlay.onReady = { [weak self] in self?.update() }
        overlays[id] = overlay
        return overlay
    }

    /// Hands control to the real Finder window: raise it and activate Finder.
    /// Uses AX (kAXFrontmostAttribute) because NSRunningApplication.activate from a
    /// background app is subject to cooperative activation since macOS 14.
    func bringForward(_ id: CGWindowID) {
        guard let w = tracker.windows[id], let app = tracker.appElement else { return }
        preShowUntil = nil
        AX.set(w.element, kAXMainAttribute, kCFBooleanTrue)
        AX.perform(w.element, kAXRaiseAction)
        AX.set(app, kAXFrontmostAttribute, kCFBooleanTrue)
    }

    /// Hotkey target: Finder's focused window when Finder is active, otherwise the
    /// Finder window under the mouse pointer (falling back to Finder's focused window).
    func toggleCurrent() -> (FinderWindow, Bool)? {
        var target: CGWindowID?
        if !tracker.isFinderFrontmost, let p = CGEvent(source: nil)?.location {
            target = tracker.window(at: p)?.id
        }
        target = target ?? tracker.focusedWindowID
        guard let id = target, let w = tracker.windows[id] else { return nil }
        toggle(id)
        return (w, pinned.contains(id))
    }
}
