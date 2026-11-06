import AppKit
import ApplicationServices

let safariID = "com.apple.Safari"

final class AppDelegate: NSObject, NSApplicationDelegate {
    let bridge = SafariBridge()
    var recent = RecentTabs()
    var statusItem: NSStatusItem!
    var statusLine: NSMenuItem!
    var pauseItem: NSMenuItem!
    var timer: Timer?
    var tap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var paused = false
    var armed = false
    var gesture = false
    var suppressedKeys = Set<Int64>()
    var step = 0
    var frozen: TabSnapshot?
    var frozenOrder: [Int] = []
    var frontmostID = ""
    var activationObserver: NSObjectProtocol?
    var permissionTimer: Timer?
    var hud: NSPanel!
    var pickerReveal: DispatchWorkItem?
    var picker: TabPicker!
    var reading = false
    var pendingSwitches = 0
    var revision = 0
    var setupWindow: NSWindow?
    var setupLabel: NSTextField?
    var latestError = ""
    var lastSwitchError = ""
    var lastDiagnosticState: NSDictionary?
    var diagnosticURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SafariRecentTabs-status-\(ProcessInfo.processInfo.processIdentifier).json")
    }

    func writeDiagnostics() {
        let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "path": Bundle.main.bundlePath, "accessibility": AXIsProcessTrusted(),
            "tap": tap != nil, "armed": armed,
            "tabs": recent.snapshot?.tabs.count ?? 0, "error": latestError, "lastSwitchError": lastSwitchError,
            "frontmost": frontmostID,
            "status": statusLine?.title ?? "Starting"]
        let comparable = state as NSDictionary
        if lastDiagnosticState != comparable,
           let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            do {
                try data.write(to: diagnosticURL, options: .atomic)
                lastDiagnosticState = comparable
            } catch { /* Retry on the next status update. */ }
        }
        guard setupWindow?.isVisible == true else { return }
        let text = (statusLine?.title ?? "Starting") + "\n\n" +
            "Shortcut access: \(AXIsProcessTrusted() ? "Allowed" : "Needs permission")\n" +
            "Keyboard listener: \(tap == nil ? "Not active" : "Active")\n" +
            "Safari tabs loaded: \(recent.snapshot?.tabs.count ?? 0)\n\n" + (lastSwitchError.isEmpty ? latestError : lastSwitchError)
        if setupLabel?.stringValue != text { setupLabel?.stringValue = text }
    }

    @objc func showStatus() {
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 285), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Keeping Tabs — Status"
            window.isReleasedWhenClosed = false
            let label = NSTextField(wrappingLabelWithString: "Checking setup…")
            label.frame = NSRect(x: 24, y: 72, width: 462, height: 190)
            label.font = .systemFont(ofSize: 14)
            window.contentView?.addSubview(label)
            let button = NSButton(title: "Set Up Permissions…", target: self, action: #selector(setup))
            button.frame = NSRect(x: 24, y: 22, width: 190, height: 32)
            window.contentView?.addSubview(button)
            setupWindow = window
            setupLabel = label
            window.center()
        }
        setupWindow?.makeKeyAndOrderFront(nil)
        writeDiagnostics()
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatus()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Keeping Tabs")
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Setup required", action: nil, keyEquivalent: "")
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(item("Status…", #selector(showStatus)))
        menu.addItem(item("Set Up Permissions…", #selector(setup)))
        pauseItem = item("Pause", #selector(togglePause))
        menu.addItem(pauseItem)
        menu.addItem(item("Clear Recent Tabs", #selector(clear)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Keeping Tabs", #selector(quit)))
        statusItem.menu = menu
        makeHUD()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.foregroundChanged() }
        // Permission recovery remains available even when Safari is inactive.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.installTap()
            self.writeDiagnostics()
        }
        foregroundChanged()
        showWelcome()
        showStatus()
    }

    func foregroundChanged() {
        let next = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if next != frontmostID {
            revision += 1
            cancel()
            armed = false
            frontmostID = next
        }
        updatePolling()
        writeDiagnostics()
    }

    func updatePolling() {
        timer?.invalidate()
        timer = nil
        guard frontmostID == safariID, !paused else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
    }

    func item(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    func showWelcome() {
        if UserDefaults.standard.bool(forKey: "welcomed") { return }
        let alert = NSAlert()
        alert.messageText = "Keeping Tabs"
        alert.informativeText = "Control-Tab returns to your last Safari tab. Hold Control and keep pressing Tab to browse recent tabs; release Control to switch. Shift reverses direction and Escape cancels.\n\nSetup needs Accessibility permission for the shortcut, and permission to control Safari. Tab history stays in memory and is cleared when you quit."
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        UserDefaults.standard.set(true, forKey: "welcomed")
        if response == .alertFirstButtonReturn { setup() }
    }

    @objc func setup() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            statusLine.title = "Enable Accessibility, then return to Safari"
            return
        }
        installTap()
        if !NSRunningApplication.runningApplications(withBundleIdentifier: safariID).isEmpty {
            poll(force: true)
        } else { statusLine.title = "Open Safari to finish setup" }
    }

    @objc func togglePause() {
        revision += 1
        paused.toggle()
        pauseItem.title = paused ? "Resume" : "Pause"
        cancel()
        armed = false
        statusLine.title = paused ? "Paused" : "Ready — Control-Tab in Safari"
        updatePolling()
        writeDiagnostics()
    }
    @objc func clear() { revision += 1; cancel(); recent = RecentTabs(); armed = false }
    @objc func quit() { bridge.stop(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        permissionTimer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        try? FileManager.default.removeItem(at: diagnosticURL)
        bridge.stop()
    }

    func installTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            statusLine.title = "Shortcut permission needed for this app copy"
            return
        }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                 | (CGEventMask(1) << CGEventType.keyUp.rawValue)
                 | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let app = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
                return app.handle(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { statusLine.title = "Shortcut unavailable — check Accessibility"; return }
        permissionTimer?.invalidate()
        permissionTimer = nil
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        statusLine.title = "Keyboard listener active — switch to Safari"
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            DispatchQueue.main.async { self.cancel() }
            return Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, suppressedKeys.remove(key) != nil {
            return nil
        }
        // Unrelated keys need no workspace lookup or dispatch to the UI.
        if !gesture && !(type == .keyDown && key == 48 && event.flags.contains(.maskControl)) {
            return Unmanaged.passUnretained(event)
        }
        guard !paused, frontmostID == safariID else {
            if gesture { DispatchQueue.main.async { self.cancel() } }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged, gesture, !event.flags.contains(.maskControl) {
            gesture = false
            DispatchQueue.main.async { self.commit() }
        }
        if type == .keyDown, gesture, let action = PickerKey.action(for: key) {
            suppressedKeys.insert(key)
            switch action {
            case .move(let direction):
                DispatchQueue.main.async { self.cycle(first: false, direction: direction) }
            case .commit:
                gesture = false
                DispatchQueue.main.async { self.commit() }
            case .cancel:
                gesture = false
                DispatchQueue.main.async { self.cancel() }
            }
            return nil
        }
        if type == .keyDown, key == 48, event.flags.contains(.maskControl),
           !event.flags.contains(.maskCommand), !event.flags.contains(.maskAlternate), armed {
            // Validate focus only for a shortcut we are about to intercept.
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariID else {
                return Unmanaged.passUnretained(event)
            }
            suppressedKeys.insert(key)
            let first = !gesture
            gesture = true
            let direction = event.flags.contains(.maskShift) ? -1 : 1
            // The event callback returns immediately; Safari requests happen later.
            DispatchQueue.main.async { self.cycle(first: first, direction: direction) }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    func poll(force: Bool = false) {
        defer { writeDiagnostics() }
        guard !paused else { return }
        if tap == nil { installTap() }
        guard tap != nil else { return }
        let safari = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariID
        if !safari && !force {
            foregroundChanged()
            armed = false
            return
        }
        guard !gesture, frozen == nil, !reading, pendingSwitches == 0 else { return }
        reading = true
        let version = revision
        bridge.request(BridgeRequest(action: "read")) { [weak self] result in
            guard let self else { return }
            self.reading = false
            self.latestError = result.error ?? ""
            defer { self.writeDiagnostics() }
            guard self.revision == version, !self.gesture, self.frozen == nil,
                  !self.paused, self.pendingSwitches == 0,
                  (force || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariID) else { return }
            if let snapshot = result.snapshot, result.error == nil {
                self.recent.observe(snapshot)
                SiteIcons.shared.load(snapshot.tabs) { [weak self] in self?.picker.needsDisplay = true }
                self.armed = snapshot.tabs.count > 1
                self.statusLine.title = self.lastSwitchError.isEmpty ? "Ready — Control-Tab in Safari" : "Last switch failed — see Status…"
            } else {
                self.armed = false
                self.statusLine.title = result.error == nil ? "Open two Safari tabs" : "Safari access unavailable — Set Up Permissions…"
            }
        }
    }

    func cycle(first: Bool, direction: Int) {
        if first {
            // All picker navigation uses memory. No Apple events on the keypress path.
            frozen = recent.snapshot
            frozenOrder = recent.order
            step = 0
        }
        guard let frozen, !frozenOrder.isEmpty else { cancel(); return }
        step = ((step + direction) % frozenOrder.count + frozenOrder.count) % frozenOrder.count
        picker.update(snapshot: frozen, order: frozenOrder, selected: step)
        hud.setContentSize(picker.frame.size)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            hud.setFrameOrigin(NSPoint(x: frame.midX - hud.frame.width / 2, y: frame.midY - hud.frame.height / 2))
        }
        if first {
            pickerReveal?.cancel()
            let reveal = DispatchWorkItem { [weak self] in
                guard let self, self.gesture, self.frozen != nil,
                      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariID else { return }
                self.hud.orderFrontRegardless()
            }
            pickerReveal = reveal
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.150, execute: reveal)
        }
    }

    func commit() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariID,
              let snapshot = frozen, frozenOrder.indices.contains(step) else { cancel(); return }
        let index = frozenOrder[step]
        cancel()
        guard index != snapshot.selected else { return }
        revision += 1
        pendingSwitches += 1
        // Promote optimistically so quick repeated taps toggle correctly even while
        // Safari is processing a previous request. The helper preserves request order.
        var predicted = snapshot
        predicted.selected = index
        recent.observe(predicted)
        bridge.request(BridgeRequest(action: "select", windowID: snapshot.windowID, index: index, expectedURL: snapshot.tabs[index].url)) { [weak self] result in
            guard let self else { return }
            self.pendingSwitches -= 1
            if result.error != nil || !result.switched {
                self.revision += 1
                self.armed = false
                self.recent = RecentTabs()
                self.lastSwitchError = result.error ?? "Safari did not switch tabs."
                self.statusLine.title = "Last switch failed — see Status…"
            } else {
                self.lastSwitchError = ""
            }
            self.writeDiagnostics()
            if self.pendingSwitches == 0 { self.poll() }
        }
    }

    func cancel() {
        pickerReveal?.cancel()
        pickerReveal = nil
        gesture = false
        frozen = nil
        frozenOrder = []
        hud?.orderOut(nil)
    }

    func makeHUD() {
        picker = TabPicker(frame: NSRect(x: 0, y: 0, width: 560, height: 200))
        hud = NSPanel(contentRect: picker.frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.level = .floating
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.ignoresMouseEvents = true
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.contentView = picker
    }
}

if CommandLine.arguments.contains("--bridge") {
    runBridge()
    exit(0)
}
let app = NSApplication.shared
if let flag = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > flag + 1 {
    renderPicker(to: CommandLine.arguments[flag + 1])
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
