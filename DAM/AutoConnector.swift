//
//  AutoConnector.swift
//
//  Connects the AirPlay display or iPad that AutoConnectPlan picks from the Connect
//  Automatically list (AutoConnect.swift). In DAM only: the login window agent has neither.
//

import AppKit

/// Connects the AirPlay display or iPad that `AutoConnectPlan` picks, checked every few
/// seconds, from DAM's start at login on. OpenDisplay receivers are OpenDisplaySender's own.
final class AutoConnector {
    static let interval: TimeInterval = 3
    static let retryDelay: TimeInterval = 10
    /// How long an attempt may take before another is allowed: a stand-in display and the
    /// Sidecar connection can each take several seconds, and so can Control Center's panel.
    static let attemptTimeout: TimeInterval = 45
    /// AirPlay waits this long after the last key press: driving Control Center's panel moves
    /// the focus, which would take keys meant for something else, as just after login.
    static let quietAfterTyping: TimeInterval = 2

    private let sidecar: SidecarManager
    private weak var video: VideoManager?
    private var timer: Timer?
    private var attempts: [String: AutoConnectPlan.Attempt] = [:]
    /// Control Center answered Accessibility once; it may be slow to start after login.
    private var controlCenterAnswered = false

    init(sidecar: SidecarManager, video: VideoManager) {
        self.sidecar = sidecar
        self.video = video
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    private func tick() {
        guard let video else { return }
        let entries = AutoConnectList.entries
        // Nothing to look for: neither SidecarCore nor Control Center is asked.
        guard entries.contains(where: { if case .openDisplay = $0.target { return false } else { return true } }) else {
            attempts = [:]
            return
        }
        sidecar.refresh()
        let candidates = video.allAirPlayDevices.map {
            AutoConnectCandidate(kind: .airPlay, name: $0.name, isConnected: $0.isConnected)
        } + sidecar.devices.map {
            AutoConnectCandidate(kind: .sidecar, name: $0.name, isConnected: $0.isConnected, onUSB: $0.link == .usb)
        }
        let now = Date()
        let plan = AutoConnectPlan.plan(entries: entries, candidates: candidates, attempts: attempts,
                                        hasOwnDisplay: video.hasOwnDisplay(), airPlayReady: airPlayReady(),
                                        windows: AutoConnectSession.now, now: now)
        attempts = plan.attempts
        guard let candidate = plan.connect else { return }
        let key = candidate.attemptKey
        attempts[key]?.count += 1
        attempts[key]?.nextTry = now + Self.attemptTimeout
        acLog.debug("connecting \(candidate.name, privacy: .public), attempt \(self.attempts[key]?.count ?? 0)")
        let finished: (Bool) -> Void = { [weak self] connected in
            guard let self, self.attempts[key] != nil else { return }
            if connected {
                self.attempts[key]?.done = true
            } else {
                self.attempts[key]?.nextTry = Date() + Self.retryDelay
            }
        }
        switch candidate.kind {
        case .airPlay:
            guard let display = video.allAirPlayDevices.first(where: { $0.name == candidate.name }) else { return }
            video.connectAirPlay(deviceName: display.name,
                                 announcing: ConnectTarget.airPlay(display).connectingAnnouncement,
                                 completion: finished)
        case .sidecar:
            guard let device = sidecar.devices.first(where: { $0.name == candidate.name }) else { return }
            SpeechSynthesizer.shared.announce(ConnectTarget.sidecar(device).connectingAnnouncement)
            sidecar.connect(device, videoManager: video) { error in finished(error == nil) }
        }
    }

    /// Whether Control Center's panel can be driven now without getting in the way: with
    /// Accessibility granted (never asked for here), Control Center answering, and no key
    /// pressed for a moment.
    private func airPlayReady() -> Bool {
        guard VideoManager.hasAccessibilityAccess(prompting: false) else { return false }
        if !controlCenterAnswered { controlCenterAnswered = Self.controlCenterAnswers() }
        return controlCenterAnswered
            && CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) >= Self.quietAfterTyping
    }

    /// Whether Control Center is running and answers Accessibility, without opening anything.
    private static func controlCenterAnswers() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var children: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success
    }
}
