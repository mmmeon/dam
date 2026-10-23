import XCTest
@testable import DAM

final class AutoConnectTests: XCTestCase {

    private let tv = AutoConnectCandidate(kind: .airPlay, name: "Den", isConnected: false)
    private let pad = AutoConnectCandidate(kind: .sidecar, name: "iPad", isConnected: false, onUSB: true)
    private let wirelessPad = AutoConnectCandidate(kind: .sidecar, name: "iPad", isConnected: false)

    private func plan(_ entries: [AutoConnectEntry], _ candidates: [AutoConnectCandidate],
                      attempts: [String: AutoConnectPlan.Attempt] = [:], hasOwnDisplay: Bool = false,
                      airPlayReady: Bool = true, now: Date = Date())
        -> (connect: AutoConnectCandidate?, attempts: [String: AutoConnectPlan.Attempt]) {
        AutoConnectPlan.plan(entries: entries, candidates: candidates, attempts: attempts,
                             hasOwnDisplay: hasOwnDisplay, airPlayReady: airPlayReady, now: now)
    }

    private func entry(_ target: AutoConnectTarget, onlyWithoutOwnDisplay: Bool = false) -> AutoConnectEntry {
        AutoConnectEntry(target: target, onlyWithoutOwnDisplay: onlyWithoutOwnDisplay)
    }

    // MARK: - Order

    func testTheFirstListedInReachIsConnected() {
        let list = [entry(.sidecar(name: "iPad")), entry(.airPlay(name: "Den"))]
        XCTAssertEqual(plan(list, [tv, pad]).connect, pad)
        XCTAssertEqual(plan(list.reversed(), [tv, pad]).connect, tv)
        XCTAssertEqual(plan(list, [tv]).connect, tv)
    }

    func testDisplaysNotListedAreLeftAlone() {
        XCTAssertNil(plan([entry(.airPlay(name: "Kitchen"))], [tv, pad]).connect)
        XCTAssertNil(plan([], [tv, pad]).connect)
    }

    func testOpenDisplayEntriesAreNotTheConnectorsToDial() {
        XCTAssertNil(plan([entry(.openDisplay(key: "Den"))], [tv]).connect)
    }

    // MARK: - One at a time

    func testNothingMoreWhileAnAirPlayDisplayOrAnIPadIsConnected() {
        let list = [entry(.sidecar(name: "iPad")), entry(.airPlay(name: "Den"))]
        let connectedTV = AutoConnectCandidate(kind: .airPlay, name: "Den", isConnected: true)
        XCTAssertNil(plan(list, [connectedTV, pad]).connect, "the iPad ranks higher, but the TV is enough")
        let connectedOther = AutoConnectCandidate(kind: .airPlay, name: "Kitchen", isConnected: true)
        XCTAssertNil(plan(list, [connectedOther, pad]).connect, "connected by hand, not listed")
    }

    // MARK: - Conditions

    func testOnlyWithoutOwnDisplay() {
        let list = [entry(.anyIPadOnUSB, onlyWithoutOwnDisplay: true)]
        XCTAssertEqual(plan(list, [pad]).connect, pad)
        XCTAssertNil(plan(list, [pad], hasOwnDisplay: true).connect)
    }

    func testAnyIPadOnUSBLeavesWirelessIPadsAlone() {
        XCTAssertNil(plan([entry(.anyIPadOnUSB)], [wirelessPad]).connect)
        XCTAssertEqual(plan([entry(.sidecar(name: "iPad"))], [wirelessPad]).connect, wirelessPad)
    }

    // MARK: - Attempts

    func testDisconnectedByHandStaysDisconnectedUntilItLeavesAndComesBack() {
        let list = [entry(.airPlay(name: "Den"))]
        let connected = AutoConnectCandidate(kind: .airPlay, name: "Den", isConnected: true)
        var result = plan(list, [connected])
        result = plan(list, [tv], attempts: result.attempts)
        XCTAssertNil(result.connect)
        result = plan(list, [], attempts: result.attempts)
        result = plan(list, [tv], attempts: result.attempts)
        XCTAssertEqual(result.connect, tv)
    }

    func testFailedAttemptsAreRetriedAfterADelayAndThenGivenUp() {
        let now = Date()
        let list = [entry(.anyIPadOnUSB)]
        var waiting = AutoConnectPlan.Attempt(count: 1, nextTry: now + 5)
        XCTAssertNil(plan(list, [pad], attempts: [pad.attemptKey: waiting], now: now).connect)
        waiting.nextTry = now - 1
        XCTAssertEqual(plan(list, [pad], attempts: [pad.attemptKey: waiting], now: now).connect, pad)
        waiting.count = AutoConnectPlan.maxAttempts
        XCTAssertNil(plan(list, [pad], attempts: [pad.attemptKey: waiting], now: now).connect)
    }

    func testABetterDisplayWaitingToBeTriedAgainIsWaitedFor() {
        let now = Date()
        let list = [entry(.sidecar(name: "iPad")), entry(.airPlay(name: "Den"))]
        let waiting = AutoConnectPlan.Attempt(count: 1, nextTry: now + 5)
        XCTAssertNil(plan(list, [tv, pad], attempts: [pad.attemptKey: waiting], now: now).connect)
        let givenUp = AutoConnectPlan.Attempt(count: AutoConnectPlan.maxAttempts)
        XCTAssertEqual(plan(list, [tv, pad], attempts: [pad.attemptKey: givenUp], now: now).connect, tv)
    }

    func testAirPlayNotReadyHoldsTheListBack() {
        let list = [entry(.airPlay(name: "Den")), entry(.sidecar(name: "iPad"))]
        XCTAssertNil(plan(list, [tv, pad], airPlayReady: false).connect, "the TV ranks higher")
        XCTAssertEqual(plan(list.reversed(), [tv, pad], airPlayReady: false).connect, pad)
    }

    // MARK: - The list

    func testMigrationFromTheOlderSettings() {
        XCTAssertEqual(AutoConnectList.migrated(receivers: ["a", "b"], sidecarWithoutDisplay: true),
                       [entry(.openDisplay(key: "a")), entry(.openDisplay(key: "b")),
                        entry(.anyIPadOnUSB, onlyWithoutOwnDisplay: true)])
        XCTAssertEqual(AutoConnectList.migrated(receivers: [], sidecarWithoutDisplay: false), [])
    }

    func testEntriesSurviveStorage() {
        let list = [entry(.openDisplay(key: "k")), entry(.airPlay(name: "Den")),
                    entry(.sidecar(name: "iPad"), onlyWithoutOwnDisplay: true), entry(.anyIPadOnUSB)]
        XCTAssertEqual(list.compactMap { AutoConnectEntry(dictionary: $0.dictionary) }, list)
        XCTAssertNil(AutoConnectEntry(dictionary: ["kind": "carrierPigeon", "id": "x"]))
        XCTAssertNil(AutoConnectEntry(dictionary: ["kind": "airPlay"]))
    }

    func testTheListIsStoredAndReadBack() {
        let list = [entry(.airPlay(name: "Den")), entry(.openDisplay(key: "k")), entry(.airPlay(name: "Den"))]
        AutoConnectList.entries = list
        XCTAssertEqual(AutoConnectList.entries, Array(list.prefix(2)), "a target is listed once")
    }

    func testReceiversAreAddedAtTheEndAndRemoved() {
        var list = [entry(.airPlay(name: "Den"))]
        list = AutoConnectList.settingOpenDisplay("k", on: true, in: list)
        XCTAssertEqual(list, [entry(.airPlay(name: "Den")), entry(.openDisplay(key: "k"))])
        XCTAssertEqual(AutoConnectList.settingOpenDisplay("k", on: true, in: list), list)
        XCTAssertEqual(AutoConnectList.settingOpenDisplay("k", on: false, in: list), [entry(.airPlay(name: "Den"))])
    }

    func testARenamedReceiverKeepsItsPlace() {
        let list = [entry(.openDisplay(key: "usb:1")), entry(.airPlay(name: "Den"))]
        XCTAssertEqual(AutoConnectList.renamingOpenDisplay("usb:1", to: "id", in: list),
                       [entry(.openDisplay(key: "id")), entry(.airPlay(name: "Den"))])
        let both = [entry(.airPlay(name: "Den")), entry(.openDisplay(key: "id")), entry(.openDisplay(key: "usb:1"))]
        XCTAssertEqual(AutoConnectList.renamingOpenDisplay("usb:1", to: "id", in: both), Array(both.prefix(2)))
    }

    func testReceiversToDialFollowTheListAndConditions() {
        let list = [entry(.openDisplay(key: "b")), entry(.airPlay(name: "Den")),
                    entry(.openDisplay(key: "a"), onlyWithoutOwnDisplay: true)]
        XCTAssertEqual(AutoConnectList.openDisplayKeys(in: list, hasOwnDisplay: false), ["b", "a"])
        XCTAssertEqual(AutoConnectList.openDisplayKeys(in: list, hasOwnDisplay: true), ["b"])
    }

    // MARK: - Modes and windows

    func testModesApplyInTheirWindows() {
        let login = AutoConnectEntry(target: .airPlay(name: "Den"), mode: .login)
        let startup = AutoConnectEntry(target: .openDisplay(key: "k"), mode: .startup)
        let always = AutoConnectEntry(target: .airPlay(name: "Den"))
        XCTAssertTrue(always.applies(hasOwnDisplay: false, windows: .none))
        XCTAssertFalse(login.applies(hasOwnDisplay: false, windows: .none))
        XCTAssertTrue(login.applies(hasOwnDisplay: false, windows: AutoConnectWindows(login: true)))
        XCTAssertFalse(startup.applies(hasOwnDisplay: false, windows: .none))
        XCTAssertTrue(startup.applies(hasOwnDisplay: false, windows: AutoConnectWindows(login: true)), "at every sign-in")
    }

    func testAnEntryAtLoginIsLeftAloneOutsideTheWindow() {
        let list = [AutoConnectEntry(target: .airPlay(name: "Den"), mode: .login)]
        XCTAssertNil(AutoConnectPlan.plan(entries: list, candidates: [tv], attempts: [:], hasOwnDisplay: false,
                                          airPlayReady: true, windows: .none, now: Date()).connect)
        XCTAssertEqual(AutoConnectPlan.plan(entries: list, candidates: [tv], attempts: [:], hasOwnDisplay: false,
                                            airPlayReady: true, windows: AutoConnectWindows(login: true), now: Date()).connect, tv)
    }

    func testReceiversToDialFollowTheirModes() {
        let list = [AutoConnectEntry(target: .openDisplay(key: "a"), mode: .startup),
                    AutoConnectEntry(target: .openDisplay(key: "b"), mode: .login),
                    AutoConnectEntry(target: .openDisplay(key: "c"))]
        XCTAssertEqual(AutoConnectList.openDisplayKeys(in: list, hasOwnDisplay: false, windows: .none), ["c"])
        XCTAssertEqual(AutoConnectList.openDisplayKeys(in: list, hasOwnDisplay: false, windows: AutoConnectWindows(login: true)),
                       ["a", "b", "c"])
        XCTAssertEqual(AutoConnectList.openDisplayKeys(in: list, hasOwnDisplay: false), ["a", "b", "c"])
    }

    func testOnlyReceiversCanBeConnectedAtStartup() {
        XCTAssertEqual(AutoConnectEntry.modes(for: .openDisplay(key: "k")), [.always, .login, .startup])
        XCTAssertEqual(AutoConnectEntry.modes(for: .airPlay(name: "Den")), [.always, .login])
        let stored = AutoConnectEntry(dictionary: ["kind": "airPlay", "id": "Den", "mode": "startup"])
        XCTAssertEqual(stored?.mode, .always)
    }

    func testModesSurviveStorageAndOlderEntriesAreAlways() {
        let entry = AutoConnectEntry(target: .openDisplay(key: "k"), mode: .startup)
        XCTAssertEqual(AutoConnectEntry(dictionary: entry.dictionary), entry)
        XCTAssertEqual(AutoConnectEntry(dictionary: ["kind": "openDisplay", "id": "k"])?.mode, .always)
        XCTAssertTrue(AutoConnectList.migrated(receivers: ["a"], sidecarWithoutDisplay: true).allSatisfy { $0.mode == .always })
    }

    func testTheWindowOfAStartAtLogin() {
        let login = Date(timeIntervalSince1970: 2_000)
        let launch = login + 20
        let end = AutoConnectWindows.end(launch: launch, login: login, length: 120)
        XCTAssertEqual(end, launch + 120)
        XCTAssertEqual(AutoConnectWindows.at(launch + 119, end: end), AutoConnectWindows(login: true))
        XCTAssertEqual(AutoConnectWindows.at(launch + 121, end: end), .none)
        // Opened by hand long after login, or with no login known: none.
        XCTAssertNil(AutoConnectWindows.end(launch: login + 600, login: login, length: 120))
        XCTAssertNil(AutoConnectWindows.end(launch: launch, login: nil, length: 120))
    }
}
