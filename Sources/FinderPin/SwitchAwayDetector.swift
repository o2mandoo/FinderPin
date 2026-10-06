import AppKit

/// Sees input *before* it reaches other apps (active CGEventTap, requires
/// Accessibility) so overlays can be ordered in front before another app raises
/// its window. Without this, overlays only appear after the app-activation
/// notification and the Finder window visibly drops back for a moment.
final class SwitchAwayDetector {
    /// True when Finder is frontmost and FinderPin is enabled.
    var isArmed: () -> Bool = { false }
    /// A switch away from Finder is about to happen.
    var onSwitchLikely: (_ untilCommandReleased: Bool) -> Void = { _ in }
    /// ⌘ was released after a ⌘Tab; the switch (if any) is done.
    var onCommandReleased: () -> Void = {}

    private var tap: CFMachPort?
    private var commandTabActive = false

    func start() {
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<SwitchAwayDetector>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("[FinderPin] event tap unavailable (Accessibility permission?)")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    var isRunning: Bool { tap != nil }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if isArmed(), !Self.isFinderOrSystemUI(at: event.location) { onSwitchLikely(false) }
        case .keyDown:
            // ⌘Tab (keycode 48) opens the app switcher.
            if event.getIntegerValueField(.keyboardEventKeycode) == 48, event.flags.contains(.maskCommand), isArmed() {
                commandTabActive = true
                onSwitchLikely(true)
            }
        case .flagsChanged:
            if commandTabActive, !event.flags.contains(.maskCommand) {
                commandTabActive = false
                onCommandReleased()
            }
        default:
            break
        }
    }

    /// Whether the click lands on Finder itself (its windows or the desktop) or on
    /// menu-bar-level UI, none of which makes another app's window come forward.
    private static func isFinderOrSystemUI(at point: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return true }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for d in list {
            guard let layer = d[kCGWindowLayer as String] as? Int, layer < 1000,
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.contains(point) else { continue }
            let pid = d[kCGWindowOwnerPID as String] as? pid_t
            if pid == ownPID { return true }
            if layer >= Int(CGWindowLevelForKey(.mainMenuWindow)) { return true }
            return NSRunningApplication(processIdentifier: pid ?? 0)?.bundleIdentifier == finderBundleID
        }
        return true // desktop
    }
}
