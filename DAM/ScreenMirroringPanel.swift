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
    case controlCenterNotRunning
    case openerNotFound
    case tileNotFound
    case deviceNotFound(String)
    case pressFailed(AXError)

    var description: String {
        switch self {
        case .busy:                    return "another Screen Mirroring change is in progress"
        case .controlCenterNotRunning: return "Control Center is not running"
        case .openerNotFound:          return "no Screen Mirroring or Control Center menu bar item"
        case .tileNotFound:            return "no Screen Mirroring tile in Control Center"
        case .deviceNotFound(let n):   return "\"\(n)\" is not listed in Screen Mirroring"
        case .pressFailed(let e):      return "pressing failed (AXError \(e.rawValue))"
        }
    }

    /// What to say when the toggle fails.
    var announcement: String {
        switch self {
        case .deviceNotFound(let n): return "\(n) is not listed in Screen Mirroring"
        default:                     return "Could not open Screen Mirroring"
        }
    }
}

final class ScreenMirroringPanel {

    typealias Completion = (Result<Void, ScreenMirroringPanelError>) -> Void

    /// Toggles `deviceName` — connecting it, or disconnecting it when it is connected —
    /// and calls `completion` on the main thread. One toggle runs at a time.
    static func toggle(deviceName: String, completion: @escaping Completion) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard current == nil else { return completion(.failure(.busy)) }
        let panel = ScreenMirroringPanel(deviceName: deviceName, completion: completion)
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
    /// Lets the press register before the panel is closed.
    private static let settle: TimeInterval        = 0.5

    // MARK: - State

    private static var current: ScreenMirroringPanel?

    private let deviceName: String
    private let completion: Completion
    private var pid: pid_t = 0
    private var app: AXUIElement!
    /// The menu bar item that opened the panel; pressed again to close it.
    private var opener: AXUIElement?
    private var viaControlCenter = false
    private var waiter: AXWaiter?

    private init(deviceName: String, completion: @escaping Completion) {
        self.deviceName = deviceName
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
            logTree(app, maxDepth: 2)
            return finish(.failure(.openerNotFound))
        }
        let via = viaControlCenter ? "Control Center" : "the Screen Mirroring extra"
        smLog.debug("opening via \(via, privacy: .public) for \(self.deviceName, privacy: .public)")

        if let error = opener!.press() { return finish(.failure(.pressFailed(error))) }
        if viaControlCenter { openTile() } else { pressDevice() }
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
            if let error = device.press() { return self.finish(.failure(.pressFailed(error))) }
            smLog.debug("pressed \(device.role ?? "?", privacy: .public) \(device.identifier ?? device.title ?? "?", privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { self.close(popover) }
        }
    }

    private func close(_ popover: AXUIElement) {
        let isOpen = { [app] in app!.windows.contains { CFEqual($0, popover) } }
        guard isOpen() else { return finish(.success(())) }
        wait(for: [kAXUIElementDestroyedNotification], on: popover, timeout: Self.closeTimeout,
             probe: { !isOpen() }) { [weak self] closed in
            if !closed { smLog.error("the panel stayed open") }
            self?.finish(.success(()))
        }
        if let error = opener?.press() { smLog.error("closing the panel failed: \(error.rawValue)") }
    }

    private func finish(_ result: Result<Void, ScreenMirroringPanelError>) {
        waiter?.cancel()
        waiter = nil
        if case .failure(let error) = result { smLog.error("\(error.description, privacy: .public)") }
        Self.current = nil
        completion(result)
    }

    // MARK: - Helpers

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

    /// Logs every window's element tree, for diagnosing an item that was not found.
    private func logWindows() {
        for window in app.windows { logTree(window) }
    }

    /// Logs an element tree, for diagnosing an item that was not found.
    private func logTree(_ root: AXUIElement, depth: Int = 0, maxDepth: Int = 5) {
        let indent = String(repeating: "  ", count: depth)
        smLog.debug("\(indent, privacy: .public)\(root.role ?? "?", privacy: .public) id=\(root.identifier ?? "-", privacy: .public) title=\(root.title ?? "-", privacy: .public)")
        guard depth < maxDepth else { return }
        for child in root.children { logTree(child, depth: depth + 1, maxDepth: maxDepth) }
    }
}

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
