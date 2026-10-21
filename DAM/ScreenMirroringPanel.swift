//
//  ScreenMirroringPanel.swift
//
//  Toggles an AirPlay display by driving Control Center's Screen Mirroring panel
//  through the Accessibility API: opens the panel from its menu-bar extra (or from
//  the Screen Mirroring tile inside Control Center when the extra is hidden), presses
//  the device's checkbox, then closes the panel again. Each step waits on Accessibility
//  notifications, with a slow poll as a safety net, rather than on fixed delays.
//

import AppKit
import ApplicationServices
import os

private let smLog = Logger(subsystem: AppIdentity.bundleID, category: "ScreenMirroring")

enum ScreenMirroringPanelError: Error, CustomStringConvertible {
    case busy
    case cancelled
    case controlCenterNotRunning
    case openerNotFound
    case tileNotFound
    case deviceNotFound(String)
    case pressFailed(AXError)

    var description: String {
        switch self {
        case .busy:                    return "another Screen Mirroring change is in progress"
        case .cancelled:               return "cancelled before the device was pressed"
        case .controlCenterNotRunning: return "Control Center is not running"
        case .openerNotFound:          return "no Screen Mirroring or Control Center menu bar item"
        case .tileNotFound:            return "no Screen Mirroring tile in Control Center"
        case .deviceNotFound(let n):   return "\"\(n)\" is not listed in Screen Mirroring"
        case .pressFailed(let e):      return "pressing failed (AXError \(e.rawValue))"
        }
    }

    /// What to say when the toggle fails: what went wrong, and the manual route through
    /// the system's own Screen Mirroring control when the app cannot drive it. Nothing
    /// for a cancel the user asked for.
    var announcement: String? {
        switch self {
        case .cancelled:
            return nil
        case .busy:
            return Spoken.screenMirroringBusy
        case .deviceNotFound(let n):
            return Spoken.notInScreenMirroring(n)
        case .controlCenterNotRunning:
            return Spoken.controlCenterNotRunning
        case .openerNotFound, .tileNotFound, .pressFailed:
            return Spoken.couldNotOpenScreenMirroring
        }
    }
}

final class ScreenMirroringPanel {

    typealias Completion = (Result<Void, ScreenMirroringPanelError>) -> Void
    /// Called on the main thread once the device's row is found, before it is pressed,
    /// with a continuation: `true` presses it, `false` closes the panel without pressing
    /// and the toggle ends in `.cancelled`.
    typealias Gate = (_ proceed: @escaping (Bool) -> Void) -> Void

    /// Toggles `deviceName` — connecting it, or disconnecting it when it is connected —
    /// and calls `completion` on the main thread. One toggle runs at a time. With `gate`,
    /// the panel is opened and the device located right away, but the press waits for
    /// the gate's answer — so a cancel window can run while the driver gets ready.
    static func toggle(deviceName: String, gate: Gate? = nil, completion: @escaping Completion) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard current == nil else { return completion(.failure(.busy)) }
        let panel = ScreenMirroringPanel(deviceName: deviceName, gate: gate, completion: completion)
        current = panel
        panel.start()
    }

    /// Whether Control Center currently shows its Screen Mirroring item in the menu bar,
    /// as Control Center itself records it. The item is the quick path: one press opens
    /// the device list. Hidden — Control Center's "Show When Active" default — means the
    /// slower route through the Screen Mirroring tile inside Control Center.
    static var isExtraVisible: Bool {
        CFPreferencesCopyAppValue("NSStatusItem Visible ScreenMirroring" as CFString,
                                  "com.apple.controlcenter" as CFString) as? Bool ?? false
    }

    /// Opens Control Center's settings, where Screen Mirroring can be set to "Always
    /// Show in Menu Bar". Control Center only reads that setting itself, so the app
    /// cannot change it directly.
    static func openControlCenterSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// The row's identifier (or its title, when it has none) ends with the device name.
    /// Each device also has a disclosure triangle with the same identifier, which only
    /// expands the device's options, so that role is skipped.
    static func matchesDevice(identifier: String?, title: String?, role: String?,
                              deviceName: String) -> Bool {
        let label = identifier ?? title ?? ""
        return label.hasSuffix(deviceName) && role != kAXDisclosureTriangleRole
    }

    // MARK: - Timing

    /// Covers the popover opening and its device list filling in.
    private static let deviceTimeout: TimeInterval = 6
    private static let closeTimeout: TimeInterval  = 2
    private static let closeAttempts               = 2
    /// Lets the press register before the panel is closed.
    private static let settle: TimeInterval        = 0.5
    /// How long the panel holds at the row for the gate's answer before closing unpressed,
    /// so a lost answer doesn't leave every later toggle busy.
    private static let gateTimeout: TimeInterval   = 30

    // MARK: - State

    private static var current: ScreenMirroringPanel?
    /// Receives every logged step while set, for the debug diagnosis.
    private static var trace: ((String) -> Void)?

    private let deviceName: String
    private let gate: Gate?
    private let completion: Completion
    private var pid: pid_t = 0
    private var app: AXUIElement!
    /// The menu bar item that opened the panel; pressed again to close it.
    private var opener: AXUIElement?
    private var viaControlCenter = false
    private var waiter: AXWaiter?

    private init(deviceName: String, gate: Gate?, completion: @escaping Completion) {
        self.deviceName = deviceName
        self.gate = gate
        self.completion = completion
    }

    // MARK: - Steps

    /// Control Center keeps a window open even when nothing is showing, so each step looks
    /// for what it needs in every window rather than waiting for a window to appear.
    private func start() {
        guard let cc = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { return finish(.failure(.controlCenterNotRunning)) }
        pid = cc.processIdentifier
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)

        let extras = app.menuBarItems
        if let item = extras.first(where: { $0.identifier?.contains("screen-mirroring") == true }) {
            opener = item
        } else if let item = extras.first(where: { $0.identifier?.contains("controlcenter") == true }) {
            opener = item
            viaControlCenter = true
        } else {
            logTree(app, maxDepth: 2, titles: Self.trace == nil)
            return finish(.failure(.openerNotFound))
        }
        let via = viaControlCenter ? "Control Center" : "the Screen Mirroring extra"
        Self.log("opening via \(via) (\(opener?.identifier ?? "-")) for \(deviceName)", isPrivate: true)

        // A panel left open (say, by an interrupted toggle) would be closed by the press.
        if !isPanelShowing() {
            if let error = opener!.press() { return finish(.failure(.pressFailed(error))) }
        }
        if viaControlCenter { openTile() } else { pressDevice() }
    }

    /// Whether any of Control Center's windows shows Screen Mirroring content — the tile
    /// or the device list. When nothing is showing, Control Center has no windows at all
    /// (unless its Screen Mirroring extra is visible, which keeps one).
    private func isPanelShowing() -> Bool {
        app.windows.contains { window in
            window.descendant(maxDepth: 5) { $0.identifier?.contains("screen-mirroring") == true } != nil
        }
    }

    /// Opens Screen Mirroring from its tile inside Control Center.
    private func openTile() {
        var tile: AXUIElement?
        waitForContent(timeout: Self.deviceTimeout, probe: { [app] in
            tile = app!.windows.lazy.compactMap { window in
                window.descendant(maxDepth: 3) { $0.identifier?.contains("screen-mirroring") == true }
            }.first
            return tile != nil
        }) { [weak self] found in
            guard let self else { return }
            guard found, let tile else {
                self.logWindows()
                return self.finish(.failure(.tileNotFound))
            }
            // AXPress does nothing on the tile on Ventura — only its first listed action does.
            if let error = tile.performFirstAction() { return self.finish(.failure(.pressFailed(error))) }
            self.pressDevice()
        }
    }

    private func pressDevice() {
        var device: AXUIElement?
        var popover: AXUIElement?
        waitForContent(timeout: Self.deviceTimeout, probe: { [app, deviceName] in
            for window in app!.windows {
                if let found = Self.findDevice(named: deviceName, in: window) {
                    device = found
                    popover = window
                    return true
                }
            }
            return false
        }) { [weak self] found in
            guard let self else { return }
            guard found, let device, let popover else {
                self.logWindows()
                return self.finish(.failure(.deviceNotFound(self.deviceName)))
            }
            // A diagnosis records the panel as found too, so a run that works still shows
            // how this macOS lays it out.
            if Self.trace != nil { self.logTree(popover, titles: true) }
            guard let gate = self.gate else { return self.press(device, in: popover) }
            Self.log("holding at \(device.identifier ?? device.title ?? "?")", isPrivate: true)
            var answered = false
            gate { [weak self] go in
                guard let self, !answered else { return }
                answered = true
                if go {
                    self.press(device, in: popover)
                } else {
                    Self.log("cancelled before the press")
                    self.close(popover, then: .failure(.cancelled))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.gateTimeout) { [weak self] in
                guard let self, !answered else { return }
                answered = true
                Self.log("no answer to press, closing", error: true)
                self.close(popover, then: .failure(.cancelled))
            }
        }
    }

    private func press(_ device: AXUIElement, in popover: AXUIElement) {
        if let error = device.press() { return finish(.failure(.pressFailed(error))) }
        Self.log("pressed \(device.role ?? "?") \(device.identifier ?? device.title ?? "?")", isPrivate: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { self.close(popover) }
    }

    /// Presses the opener until the panel is gone, then finishes with `result`. From
    /// inside Control Center the first press only backs out of the Screen Mirroring view
    /// to the main panel; the second closes it.
    private func close(_ popover: AXUIElement, attempt: Int = 1,
                       then result: Result<Void, ScreenMirroringPanelError> = .success(())) {
        let isOpen = { [app] in app!.windows.contains { CFEqual($0, popover) } }
        guard isOpen() else { return finish(result) }
        guard attempt <= Self.closeAttempts else {
            Self.log("the panel stayed open", error: true)
            return finish(result)
        }
        wait(for: [kAXUIElementDestroyedNotification], on: popover, timeout: Self.closeTimeout,
             probe: { !isOpen() }) { [weak self] closed in
            guard let self else { return }
            if closed { return self.finish(result) }
            self.close(popover, attempt: attempt + 1, then: result)
        }
        if let error = opener?.press() { Self.log("closing the panel failed: \(error.rawValue)", error: true) }
    }

    private func finish(_ result: Result<Void, ScreenMirroringPanelError>) {
        waiter?.cancel()
        waiter = nil
        if case .failure(let error) = result { Self.log(error.description, error: true) }
        Self.current = nil
        completion(result)
    }

    // MARK: - Helpers

    /// Logs a step, and hands it to `trace` while a diagnosis runs. `isPrivate` keeps a line
    /// that names devices or shows other UI out of the readable log.
    private static func log(_ line: String, error: Bool = false, isPrivate: Bool = false) {
        switch (error, isPrivate) {
        case (true, true):   smLog.error("\(line, privacy: .private)")
        case (true, false):  smLog.error("\(line, privacy: .public)")
        case (false, true):  smLog.debug("\(line, privacy: .private)")
        case (false, false): smLog.debug("\(line, privacy: .public)")
        }
        trace?(line)
    }

    /// Runs `probe` now, on each of `notifications` from `element`, and every 250 ms as a
    /// fallback, until it returns true or `timeout` elapses; then calls `done`.
    private func wait(for notifications: [String], on element: AXUIElement, timeout: TimeInterval,
                      probe: @escaping () -> Bool, done: @escaping (Bool) -> Void) {
        waiter?.cancel()
        let waiter = AXWaiter(pid: pid, element: element, notifications: notifications,
                              timeout: timeout, probe: probe) { [weak self] found in
            self?.waiter = nil
            done(found)
        }
        self.waiter = waiter
        waiter.start()
    }

    /// Waits for content to appear somewhere in the application's windows.
    private func waitForContent(timeout: TimeInterval, probe: @escaping () -> Bool,
                                done: @escaping (Bool) -> Void) {
        wait(for: [kAXWindowCreatedNotification, kAXLayoutChangedNotification, kAXCreatedNotification],
             on: app, timeout: timeout, probe: probe, done: done)
    }

    private static func findDevice(named name: String, in window: AXUIElement) -> AXUIElement? {
        let rows = window.descendants(maxDepth: 5).filter {
            matchesDevice(identifier: $0.identifier, title: $0.title, role: $0.role, deviceName: name)
        }
        return rows.first { $0.role == kAXCheckBoxRole } ?? rows.first
    }

    /// Logs every window's element tree, for diagnosing an item that was not found. A
    /// diagnosis leaves the titles out: these windows can show anything Control Center does
    /// (network and device names, what is playing).
    private func logWindows() {
        for window in app.windows { logTree(window, titles: Self.trace == nil) }
    }

    /// Logs an element tree, for diagnosing an item that was not found.
    private func logTree(_ root: AXUIElement, depth: Int = 0, maxDepth: Int = 5, titles: Bool) {
        let indent = String(repeating: "  ", count: depth)
        let title = titles ? (root.title ?? "-") : (root.title == nil ? "-" : "…")
        Self.log("\(indent)\(root.role ?? "?") id=\(root.identifier ?? "-") title=\(title)", isPrivate: true)
        guard depth < maxDepth else { return }
        for child in root.children { logTree(child, depth: depth + 1, maxDepth: maxDepth, titles: titles) }
    }
}

// MARK: - Report redaction

/// Replaces names in a diagnosis report with tokens, so it can be shared without naming
/// anyone's devices: AirPlay displays become "Display 1", "Display 2"…, iPads "iPad 1"…,
/// and the user's and the Mac's names "the user" and "this Mac".
struct ReportRedactor {

    /// Name and token pairs, longest name first, so a name that contains another is replaced
    /// whole.
    private let replacements: [(name: String, token: String)]

    init(displays: [String], iPads: [String],
         userNames: [String] = [NSFullUserName(), NSUserName()],
         computerNames: [String] = [Host.current().localizedName].compactMap { $0 }) {
        var pairs: [(name: String, token: String)] = []
        func add(_ names: [String], token: (Int) -> String) {
            var n = 0
            for name in names where name.count >= 3 && !pairs.contains(where: { $0.name == name }) {
                n += 1
                pairs.append((name, token(n)))
            }
        }
        add(displays) { "Display \($0)" }
        add(iPads) { "iPad \($0)" }
        add(userNames) { _ in "the user" }
        add(computerNames) { _ in "this Mac" }
        replacements = pairs.sorted { $0.name.count > $1.name.count }
    }

    func redact(_ text: String) -> String {
        replacements.reduce(text) { $0.replacingOccurrences(of: $1.name, with: $1.token) }
    }
}

#if DEBUG
// MARK: - Diagnosis

extension ScreenMirroringPanel {

    /// Toggles `deviceName` without pressing it: opens Screen Mirroring, finds the device's
    /// row and closes the panel again. `done` gets a report of the setup and every step,
    /// with Control Center's element trees, and whether the row was found. `displays` are the
    /// AirPlay displays the app found and `iPads` the Sidecar ones; their names, the user's
    /// and the Mac's are replaced with tokens throughout the report.
    static func diagnose(deviceName: String, displays: [(name: String, isConnected: Bool)], iPads: [String],
                         done: @escaping (_ report: String, _ ok: Bool) -> Void) {
        let redactor = ReportRedactor(displays: displays.map(\.name), iPads: iPads)
        var lines = [
            "Device, user and computer names are replaced with tokens, and other apps' menu bar",
            "items are left out. A name \(AppIdentity.name) did not find on the network can still",
            "appear: read the report before posting it.",
            "",
        ]
        lines += setupSummary()
        lines.append("AirPlay displays found: \(displays.count)")
        lines += displays.map { "  " + $0.name + ($0.isConnected ? " (connected)" : "") }
        lines += statusItemDefaults()
        lines += ["", "Dry run for \"\(deviceName)\":"]
        trace = { lines.append("  " + $0) }
        toggle(deviceName: deviceName, gate: { $0(false) }) { result in
            trace = nil
            let ok: Bool
            switch result {
            case .failure(.cancelled):
                ok = true
                lines += ["", "Result: OK, the device was found (and not pressed)"]
            case .failure(let error):
                ok = false
                lines += ["", "Result: FAILED, \(error.description)"]
            case .success:
                ok = true
                lines += ["", "Result: the device was pressed"]
            }
            done(redactor.redact(lines.joined(separator: "\n")), ok)
        }
    }

    /// The app, the system, the permissions and Control Center's menu bar items, as the
    /// first step finds them.
    private static func setupSummary() -> [String] {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        var lines = [
            "\(AppIdentity.name) \(version)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(arch)",
            "Accessibility access: \(AXIsProcessTrusted() ? "yes" : "no")",
            "Screen Mirroring in the menu bar: \(isExtraVisible ? "always" : "not always")",
        ]
        lines += menuBarAgentTree()
        guard let cc = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { return lines + ["Control Center: not running"] }
        let app = AXUIElementCreateApplication(cc.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 2)
        let items = app.menuBarItems
        lines.append("Control Center menu bar items:")
        if items.isEmpty { lines.append("  none readable") }
        // Identifiers only: the titles show the time, the battery and the user's name.
        lines += items.map { "  \($0.role ?? "?") id=\($0.identifier ?? "-")" }
        return lines
    }

    /// Control Center's NSStatusItem preferences, which record which of its items show in the
    /// menu bar; the keys have changed across releases.
    private static func statusItemDefaults() -> [String] {
        let domain = "com.apple.controlcenter" as CFString
        let keys = [kCFPreferencesAnyHost, kCFPreferencesCurrentHost].flatMap { host in
            (CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, host) as? [String]) ?? []
        }
        let statusKeys = Set(keys.filter { $0.hasPrefix("NSStatusItem") }).sorted()
        var lines = ["Control Center NSStatusItem preferences:"]
        if statusKeys.isEmpty { lines.append("  none") }
        lines += statusKeys.map { key in
            let value = CFPreferencesCopyAppValue(key as CFString, domain).map { "\($0)" } ?? "?"
            return "  \(key) = \(value)"
        }
        return lines
    }

    /// The menu bar slots of MenuBarAgent, which hosts every display's menu bar items from
    /// macOS 27 (one window per display, one child per item slot), so the system extras may be
    /// found there rather than in Control Center's menu bar. A slot's content comes from the
    /// process that made the item; only the agent's own (the system extras) are read, for
    /// their identifiers. Other apps' items are never asked anything: they can show anything,
    /// and an unresponsive app would stall the report.
    private static func menuBarAgentTree() -> [String] {
        guard let agent = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
        else { return ["MenuBarAgent: not running"] }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 2)
        let windows = app.windows
        var lines = ["MenuBarAgent windows:"]
        if windows.isEmpty { lines.append("  none readable") }
        for (i, window) in windows.enumerated() {
            lines.append("  window \(i + 1)")
            for slot in window.children {
                guard let content = slot.children.first else {
                    lines.append("    slot with no content (the overflow chevron?)")
                    continue
                }
                guard content.pid == agent.processIdentifier else {
                    lines.append("    another app's item")
                    continue
                }
                let extra = content.children.first ?? content
                lines.append("    system extra id=\(extra.identifier ?? content.identifier ?? "-")")
            }
        }
        return lines
    }
}
#endif

// MARK: - AXWaiter

/// Waits for a condition on an accessibility element: probes immediately, on each
/// requested notification, and on a slow poll; gives up after a timeout.
private final class AXWaiter {
    private let pid: pid_t
    private let element: AXUIElement
    private let notifications: [String]
    private let timeout: TimeInterval
    private let probe: () -> Bool
    private let done: (Bool) -> Void

    private var observer: AXObserver?
    private var poll: Timer?
    private var deadline: DispatchWorkItem?
    private var finished = false

    init(pid: pid_t, element: AXUIElement, notifications: [String], timeout: TimeInterval,
         probe: @escaping () -> Bool, done: @escaping (Bool) -> Void) {
        self.pid = pid
        self.element = element
        self.notifications = notifications
        self.timeout = timeout
        self.probe = probe
        self.done = done
    }

    func start() {
        if check() { return }

        var observer: AXObserver?
        if AXObserverCreate(pid, axWaiterCallback, &observer) == .success, let observer {
            self.observer = observer
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for name in notifications {
                AXObserverAddNotification(observer, element, name as CFString, refcon)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }

        let poll = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in _ = self?.check() }
        RunLoop.main.add(poll, forMode: .common)
        self.poll = poll

        let deadline = DispatchWorkItem { [weak self] in self?.complete(false) }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
    }

    @discardableResult
    func check() -> Bool {
        guard !finished else { return true }
        guard probe() else { return false }
        complete(true)
        return true
    }

    func cancel() {
        finished = true
        if let observer {
            for name in notifications {
                AXObserverRemoveNotification(observer, element, name as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            self.observer = nil
        }
        poll?.invalidate()
        poll = nil
        deadline?.cancel()
        deadline = nil
    }

    private func complete(_ found: Bool) {
        guard !finished else { return }
        cancel()
        done(found)
    }
}

private let axWaiterCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    Unmanaged<AXWaiter>.fromOpaque(refcon).takeUnretainedValue().check()
}

// MARK: - AXUIElement

private extension AXUIElement {

    func attribute(_ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ name: String) -> String? { attribute(name) as? String }

    func elements(_ name: String) -> [AXUIElement] {
        guard let array = attribute(name) as? [AnyObject] else { return [] }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    func element(_ name: String) -> AXUIElement? {
        guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The items of every menu bar an application exposes. Control Center's status
    /// items live in its extras menu bar, not the regular one.
    var menuBarItems: [AXUIElement] {
        var bars = [kAXMenuBarAttribute, kAXExtrasMenuBarAttribute].compactMap { element($0) }
        bars += children.filter { $0.role == kAXMenuBarRole }
        return bars.flatMap(\.children)
    }

    var children: [AXUIElement] { elements(kAXChildrenAttribute) }
    var windows: [AXUIElement]  { elements(kAXWindowsAttribute) }
    var role: String?           { string(kAXRoleAttribute) }
    var identifier: String?     { string(kAXIdentifierAttribute) }
    var title: String?          { string(kAXTitleAttribute) }
    /// The process that vends the element; asks nothing of that process.
    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success ? pid : nil
    }

    /// Performs AXPress; nil on success.
    func press() -> AXError? {
        let error = AXUIElementPerformAction(self, kAXPressAction as CFString)
        return error == .success ? nil : error
    }

    /// Performs the element's first listed action (AXPress when it has none); nil on success.
    func performFirstAction() -> AXError? {
        var names: CFArray?
        guard AXUIElementCopyActionNames(self, &names) == .success,
              let first = (names as? [String])?.first else { return press() }
        let error = AXUIElementPerformAction(self, first as CFString)
        return error == .success ? nil : error
    }

    func descendant(maxDepth: Int, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        descendants(maxDepth: maxDepth).first(where: predicate)
    }

    /// Breadth-first, excluding self.
    func descendants(maxDepth: Int) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var level = children
        var depth = 1
        while !level.isEmpty && depth <= maxDepth {
            result += level
            level = level.flatMap(\.children)
            depth += 1
        }
        return result
    }
}
