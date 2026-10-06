import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let tracker = FinderTracker()
    private lazy var pins = PinController(tracker: tracker)
    private lazy var columnEnforcer = ColumnViewEnforcer(tracker: tracker)
    private lazy var launcher = FinderLauncher(tracker: tracker, pins: pins)
    private let switchDetector = SwitchAwayDetector()
    private var statusItem: NSStatusItem!

    private enum HotKeyID {
        static let togglePin: UInt32 = 1
        static let launcher: UInt32 = 2
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        installSignalHandlers()
        requestPermissionsIfNeeded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        tracker.onChange = { [weak self] in self?.pins.update() }
        tracker.onWindowCreated = { [weak self] w in
            self?.pins.windowAppeared(w)
            self?.launcher.windowCreated(w)
        }
        tracker.onWindowsClosed = { closed in
            // Several at once (⌥⌘W): remember the one that was in front.
            if let front = closed.filter({ $0.folder != nil }).min(by: { $0.zIndex < $1.zIndex }) {
                LastLocation.save(front)
            }
        }
        tracker.onFocusOrNavigation = { [weak self] in self?.enforceColumnView() }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            self.tracker.reconcile()
            self.pins.update()
            if (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == finderBundleID {
                self.pins.finderActivated()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.enforceColumnView() }
            }
        }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tracker.reconcile()
            self?.pins.update()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tracker.reconcile()
            self?.pins.update()
        }

        tracker.start()
        pins.update()

        switchDetector.isArmed = { [weak self] in
            Settings.enabled && (self?.tracker.isFinderFrontmost ?? false)
        }
        switchDetector.onSwitchLikely = { [weak self] untilCmdUp in self?.pins.preShow(untilCommandReleased: untilCmdUp) }
        switchDetector.onCommandReleased = { [weak self] in self?.pins.commandReleased() }
        startSwitchDetector()

        // ⌃⌥⌘P: pin/unpin the current Finder window.
        if !HotKeyCenter.shared.register(id: HotKeyID.togglePin, keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey | cmdKey,
                                         action: { [weak self] in self?.toggleCurrentWindow() }) {
            NSLog("[FinderPin] could not register ⌃⌥⌘P (already in use?)")
        }
        applyLauncherSetting()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Hand ⌥⌘Space back to macOS ("Show Finder search window").
        SymbolicHotKeys.setEnabled(SymbolicHotKeys.finderSearchWindow, true)
    }

    /// `kill`/`pkill` (SIGTERM) and Ctrl-C bypass applicationWillTerminate; route them
    /// through a normal quit so ⌥⌘Space is always handed back.
    private var signalSources: [DispatchSourceSignal] = []
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// The tap needs Accessibility; retry until it is granted.
    private func startSwitchDetector() {
        switchDetector.start()
        if !switchDetector.isRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startSwitchDetector() }
        }
    }

    /// ⌥⌘Space: activate Finder / reopen the last closed location.
    private func applyLauncherSetting() {
        if Settings.launcher {
            SymbolicHotKeys.setEnabled(SymbolicHotKeys.finderSearchWindow, false)
            if !HotKeyCenter.shared.register(id: HotKeyID.launcher, keyCode: kVK_Space, modifiers: optionKey | cmdKey,
                                             action: { [weak self] in self?.launcher.trigger() }) {
                NSLog("[FinderPin] could not register ⌥⌘Space")
            }
        } else {
            HotKeyCenter.shared.unregister(id: HotKeyID.launcher)
            SymbolicHotKeys.setEnabled(SymbolicHotKeys.finderSearchWindow, true)
        }
    }

    private func requestPermissionsIfNeeded() {
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    private func enforceColumnView() {
        guard Settings.forceColumnView else { return }
        columnEnforcer.enforceOnFocusedWindow()
    }

    private func toggleCurrentWindow() {
        guard let (w, pinned) = pins.toggleCurrent() else {
            NSSound.beep()
            return
        }
        Toast.show(pinned ? "📌 항상 위에 고정" : "고정 해제", over: w.frame)
    }

    private func refreshIcon() {
        let name = Settings.enabled ? "pin.fill" : "pin.slash"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "FinderPin")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        tracker.reconcile()
        menu.removeAllItems()

        menu.addItem(toggleItem("Finder 항상 위에 (Always-on-Top)", Settings.enabled, #selector(toggleEnabled)))
        menu.addItem(toggleItem("새 Finder 창 자동 고정", Settings.autoPin, #selector(toggleAutoPin)))
        menu.addItem(toggleItem("Column View 강제", Settings.forceColumnView, #selector(toggleColumn)))
        menu.addItem(toggleItem("⌥⌘Space: 마지막 위치로 Finder 열기", Settings.launcher, #selector(toggleLauncher)))
        if let last = LastLocation.folder {
            let item = NSMenuItem(title: "    마지막 위치: \(last.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Finder 창 (클릭하여 고정/해제)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let windows = tracker.windows.values.sorted { $0.zIndex < $1.zIndex }
        if windows.isEmpty {
            let none = NSMenuItem(title: "  열린 Finder 창 없음", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for w in windows {
            let title = (w.title.isEmpty ? "(제목 없음)" : w.title) + (w.onScreen ? "" : "  — 다른 Space/최소화")
            let item = NSMenuItem(title: "  " + title, action: #selector(toggleWindow(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(w.id)
            item.state = pins.isPinned(w.id) ? .on : .off
            menu.addItem(item)
        }
        let hint = NSMenuItem(title: "현재 Finder 창 고정/해제: ⌃⌥⌘P", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let ax = AXIsProcessTrusted(), sc = CGPreflightScreenCaptureAccess()
        let perm = NSMenuItem(title: "권한: 손쉬운 사용 \(ax ? "✓" : "✗")  ·  화면 기록 \(sc ? "✓" : "✗")",
                              action: ax && sc ? nil : #selector(openPrivacySettings), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)
        if !(ax && sc) {
            // Screen Recording only takes effect after a relaunch.
            let relaunch = NSMenuItem(title: "권한 허용 후 FinderPin 다시 시작", action: #selector(relaunch), keyEquivalent: "")
            relaunch.target = self
            menu.addItem(relaunch)
        }
        menu.addItem(toggleItem("로그인 시 실행", SMAppService.mainApp.status == .enabled, #selector(toggleLoginItem)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "FinderPin 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func toggleItem(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        refreshIcon()
        pins.update()
    }

    @objc private func toggleAutoPin() { Settings.autoPin.toggle() }

    @objc private func toggleLauncher() {
        Settings.launcher.toggle()
        applyLauncherSetting()
    }

    @objc private func toggleColumn() {
        Settings.forceColumnView.toggle()
        enforceColumnView()
    }

    @objc private func toggleWindow(_ sender: NSMenuItem) {
        pins.toggle(CGWindowID(sender.tag))
    }

    @objc private func openPrivacySettings() {
        let pane = AXIsProcessTrusted() ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    @objc private func relaunch() {
        // Start the new instance only after this one has quit, so our quit handler
        // (which hands ⌥⌘Space back to macOS) cannot undo the new instance's setup.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("[FinderPin] login item: \(error.localizedDescription)")
        }
    }
}

/// Small transient HUD used as hotkey feedback.
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String, over cgFrame: CGRect) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 32, height: label.frame.height + 18)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let origin = NSPoint(x: cgFrame.midX - size.width / 2, y: primaryHeight - cgFrame.minY - size.height - 60)

        let p = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        label.frame.origin = NSPoint(x: 16, y: 9)
        bg.addSubview(label)
        p.contentView = bg
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if panel === p { p.orderOut(nil); panel = nil }
        }
    }
}
