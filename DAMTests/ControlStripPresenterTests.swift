import XCTest
@testable import DAM

final class ControlStripPresenterTests: XCTestCase {

    // MARK: - Helpers

    private func nativeMode(_ w: Int, _ h: Int, ioModeID: Int32, hz: Double = 60,
                             hiDPI: Bool = false) -> DisplayMode {
        DisplayMode(id: "\(w)x\(h)@\(hz)", ioModeID: ioModeID,
                    width: w, height: h, pixelWidth: hiDPI ? w * 2 : w,
                    pixelHeight: hiDPI ? h * 2 : h,
                    refreshRate: hz, isHiDPI: hiDPI)
    }

    private func virtualMode(_ w: Int, _ h: Int, hz: Double = 60) -> DisplayMode {
        DisplayMode(id: "\(w)x\(h)@\(hz)_virtual", ioModeID: 0,
                    width: w, height: h, pixelWidth: w, pixelHeight: h,
                    refreshRate: hz, isHiDPI: false, isVirtual: true)
    }

    private func anchorMode(_ w: Int, _ h: Int, hz: Double = 60) -> DisplayMode {
        // currentMode() returns isVirtual=false; pixel dims equal logical for non-HiDPI virtual display
        DisplayMode(id: "\(w)x\(h)@\(hz)", ioModeID: 99,
                    width: w, height: h, pixelWidth: w, pixelHeight: h,
                    refreshRate: hz, isHiDPI: false)
    }

    // Typical 5-segment list for an AirPlay display with virtual anchor active:
    //   [native 720p HiDPI, native 1080p, virtual 4K, virtual 1440p, virtual 1080p]
    private var airPlayModes: [DisplayMode] {
        [
            nativeMode(1280, 720,  ioModeID: 10, hiDPI: true),   // index 0: 720p↑
            nativeMode(1920, 1080, ioModeID: 11),                 // index 1: 1080p
            virtualMode(3840, 2160),                              // index 2: 2160p✦
            virtualMode(2560, 1440),                              // index 3: 1440p✦
            virtualMode(1920, 1080),                              // index 4: 1080p✦
        ]
    }

    // MARK: - The Touch Bar's AirPlay sizes (ResolutionChoices.flattened)

    func testAirPlayChoices_dropOtherAspectNatives_thenAppendVirtual() {
        let native = [nativeMode(1920, 1080, ioModeID: 1), nativeMode(1024, 768, ioModeID: 2),
                      nativeMode(1280, 720, ioModeID: 3)]
        let virtual = [virtualMode(3840, 2160), virtualMode(1920, 1080)]
        let choices = ResolutionChoices.airPlay(
            native: native, virtual: virtual, current: (native: 2, virtual: nil)).flattened(nativeInLargestAspect: true)
        XCTAssertEqual(choices.modes.map(\.shortLabel), ["1080p", "720p", "2160p ✦", "1080p ✦"])
        XCTAssertEqual(choices.current, 1, "The native index shifts past the dropped 4:3 size")
    }

    func testAirPlayChoices_virtualCurrent_indexesPastNatives() {
        let native = [nativeMode(1920, 1080, ioModeID: 1), nativeMode(1024, 768, ioModeID: 2)]
        let virtual = [virtualMode(3840, 2160), virtualMode(1920, 1080)]
        let choices = ResolutionChoices.airPlay(
            native: native, virtual: virtual, current: (native: nil, virtual: 1)).flattened(nativeInLargestAspect: true)
        XCTAssertEqual(choices.current, 2)
    }

    func testAirPlayChoices_currentNativeOfOtherAspect_isNotMarked() {
        let native = [nativeMode(1920, 1080, ioModeID: 1), nativeMode(1024, 768, ioModeID: 2)]
        let choices = ResolutionChoices.airPlay(
            native: native, virtual: [virtualMode(1920, 1080)], current: (native: 1, virtual: nil)).flattened(nativeInLargestAspect: true)
        XCTAssertNil(choices.current)
    }

    // MARK: - Virtual anchor active

    func testVirtualAnchor_1440p_highlightsVirtual1440Segment() {
        let idx = VideoManager.currentModeIndex(
            in: airPlayModes,
            anchorCurrent: anchorMode(2560, 1440),
            nativeCurrent: nil
        )
        XCTAssertEqual(idx, 3, "1440p anchor should highlight the virtual 1440p✦ segment (index 3)")
    }

    func testVirtualAnchor_4K_highlightsVirtual4KSegment() {
        let idx = VideoManager.currentModeIndex(
            in: airPlayModes,
            anchorCurrent: anchorMode(3840, 2160),
            nativeCurrent: nil
        )
        XCTAssertEqual(idx, 2, "4K anchor should highlight the virtual 2160p✦ segment (index 2)")
    }

    func testVirtualAnchor_1080p_highlightsVirtual1080Segment_notNative() {
        // Both native 1080p (index 1) and virtual 1080p✦ (index 4) are in the list.
        // When anchor is active the virtual one must win.
        let idx = VideoManager.currentModeIndex(
            in: airPlayModes,
            anchorCurrent: anchorMode(1920, 1080),
            nativeCurrent: nil
        )
        XCTAssertEqual(idx, 4, "1080p anchor should highlight virtual 1080p✦ (index 4), not native 1080p (index 1)")
    }

    func testVirtualAnchor_ioModeIDCollision_doesNotHighlightNativeSegment() {
        // Simulate an ioModeID collision: native 1080p has the same Int32 value as the anchor's
        // current mode ID.  The pool separation must prevent the native segment from being chosen.
        let collidingID: Int32 = 42
        let modes: [DisplayMode] = [
            nativeMode(1920, 1080, ioModeID: collidingID),   // index 0: native 1080p – colliding ID
            virtualMode(2560, 1440),                          // index 1: virtual 1440p✦
        ]
        let anchor = DisplayMode(id: "2560x1440@60", ioModeID: collidingID,
                                 width: 2560, height: 1440,
                                 pixelWidth: 2560, pixelHeight: 1440,
                                 refreshRate: 60, isHiDPI: false)
        let idx = VideoManager.currentModeIndex(
            in: modes,
            anchorCurrent: anchor,
            nativeCurrent: nil
        )
        XCTAssertEqual(idx, 1, "Virtual 1440p✦ should be selected even when its ioModeID collides with a native mode")
    }

    // MARK: - No anchor (native mode)

    func testNoAnchor_native1080p_highlightsNativeSegment() {
        let native1080 = nativeMode(1920, 1080, ioModeID: 11)
        let idx = VideoManager.currentModeIndex(
            in: airPlayModes,
            anchorCurrent: nil,
            nativeCurrent: native1080
        )
        XCTAssertEqual(idx, 1, "Native 1080p current mode should highlight the native 1080p segment (index 1)")
    }

    func testNoAnchor_native720pHiDPI_highlightsHiDPISegment() {
        let native720HiDPI = nativeMode(1280, 720, ioModeID: 10, hiDPI: true)
        let idx = VideoManager.currentModeIndex(
            in: airPlayModes,
            anchorCurrent: nil,
            nativeCurrent: native720HiDPI
        )
        XCTAssertEqual(idx, 0, "Native 720p HiDPI should highlight index 0")
    }

    func testNoAnchor_noMatchingMode_returnsNil() {
        let unknownMode = nativeMode(1024, 768, ioModeID: 99)
        let idx = VideoManager.currentModeIndex(
            in: airPlayModes,
            anchorCurrent: nil,
            nativeCurrent: unknownMode
        )
        XCTAssertNil(idx, "An unrecognised native mode should return nil")
    }

    func testNoAnchor_virtualModeNeverMatchesNativePool() {
        // Even if nativeCurrent has pixel dims matching a virtual mode,
        // native modes are matched by ioModeID only — no accidental virtual match.
        let modes: [DisplayMode] = [
            virtualMode(2560, 1440),  // index 0: virtual 1440p✦ — NOT matchable via nativeCurrent
            nativeMode(1920, 1080, ioModeID: 11),  // index 1
        ]
        // Construct a nativeCurrent whose ioModeID doesn't match any native mode.
        let cur = nativeMode(2560, 1440, ioModeID: 7)
        let idx = VideoManager.currentModeIndex(
            in: modes, anchorCurrent: nil, nativeCurrent: cur)
        XCTAssertNil(idx, "nativeCurrent should not match a virtual segment")
    }

    // MARK: - Anchor present but cgID not yet resolved

    func testAnchorActive_cgIDNotYetResolved_noNativeFallback() {
        // hasAnchor=true but anchorCGID=0 → anchorCurrent=nil, nativeCurrent=nil.
        // No segment should be highlighted rather than falling back to native 1080p.
        let idx = VideoManager.currentModeIndex(
            in: airPlayModes,
            anchorCurrent: nil,
            nativeCurrent: nil
        )
        XCTAssertNil(idx, "While anchor is being established no segment should be selected")
    }

    // MARK: - Edge cases

    func testEmptyModesList_returnsNil() {
        let idx = VideoManager.currentModeIndex(
            in: [],
            anchorCurrent: anchorMode(2560, 1440),
            nativeCurrent: nil
        )
        XCTAssertNil(idx)
    }

    func testVirtualAnchor_720p_highlightsVirtual720Segment() {
        let modes: [DisplayMode] = [
            nativeMode(1280, 720,  ioModeID: 10),  // index 0: native 720p
            virtualMode(1280, 720),                 // index 1: virtual 720p✦
        ]
        let idx = VideoManager.currentModeIndex(
            in: modes,
            anchorCurrent: anchorMode(1280, 720),
            nativeCurrent: nil
        )
        XCTAssertEqual(idx, 1, "720p anchor should select virtual 720p✦, not native 720p")
    }

    func testVirtualAnchor_fractionalRate_matchesRoundedVirtualRate() {
        let modes = [virtualMode(1920, 1080, hz: 144), virtualMode(1920, 1080, hz: 120)]
        let idx = VideoManager.currentModeIndex(
            in: modes, anchorCurrent: anchorMode(1920, 1080, hz: 119.88), nativeCurrent: nil)
        XCTAssertEqual(idx, 1, "119.88 Hz anchor should match the 120 Hz virtual segment")
    }

    func testVirtualAnchor_sameSizeDifferentRates_matchesCurrentRateOnly() {
        let modes = [virtualMode(1920, 1080, hz: 120), virtualMode(1920, 1080, hz: 60)]
        let idx = VideoManager.currentModeIndex(
            in: modes, anchorCurrent: anchorMode(1920, 1080, hz: 60), nativeCurrent: nil)
        XCTAssertEqual(idx, 1)
    }

    func testVirtualAnchor_hiDPI_matchesHiDPISegmentNot1x() {
        let hiDPI720 = VideoManager.virtualMode(width: 1280, height: 720, refreshRate: 60,
                                                pixelWidth: 2560, pixelHeight: 1440)
        let modes = [virtualMode(1280, 720), hiDPI720]
        let anchor = DisplayMode(id: "1280x720@60.0@2x", ioModeID: 99, width: 1280, height: 720,
                                 pixelWidth: 2560, pixelHeight: 1440, refreshRate: 60, isHiDPI: true)
        XCTAssertEqual(VideoManager.currentModeIndex(in: modes, anchorCurrent: anchor, nativeCurrent: nil), 1)
    }

    // MARK: - window(_:around:limit:)

    func testWindow_shortList_returnsAll() {
        XCTAssertEqual(Array(ControlStripPresenter.window([1, 2, 3], around: 2, limit: 5)), [1, 2, 3])
    }

    func testWindow_noCurrent_keepsFirstItems() {
        XCTAssertEqual(Array(ControlStripPresenter.window(Array(0..<8), around: nil, limit: 5)), [0, 1, 2, 3, 4])
    }

    func testWindow_currentNearEnd_staysVisible() {
        // e.g. rates [144, 120, 100, 75, 60, 50, 30] with 50 Hz current (index 5)
        let w = ControlStripPresenter.window(Array(0..<7), around: 5, limit: 5)
        XCTAssertEqual(Array(w), [2, 3, 4, 5, 6])
    }

    func testWindow_currentInMiddle_isCentred() {
        XCTAssertEqual(Array(ControlStripPresenter.window(Array(0..<9), around: 4, limit: 5)), [2, 3, 4, 5, 6])
    }

    // MARK: - ConnectTarget.isSame

    func testConnectTarget_isSame_byDeviceWhateverItsState() {
        let tv = DisplayInfo(id: "tv", name: "tv", isConnected: false, cgDisplayID: 0,
                             isMirroring: false, isBuiltIn: false, isMain: false)
        let tvNow = DisplayInfo(id: "tv", name: "tv", isConnected: true, cgDisplayID: 5,
                                isMirroring: false, isBuiltIn: false, isMain: false)
        let other = DisplayInfo(id: "office", name: "office", isConnected: false, cgDisplayID: 0,
                                isMirroring: false, isBuiltIn: false, isMain: false)
        let pad = SidecarDevice(id: "tv", name: "tv", isConnected: false)
        XCTAssertTrue(ConnectTarget.airPlay(tv).isSame(as: .airPlay(tvNow)))
        XCTAssertFalse(ConnectTarget.airPlay(tv).isSame(as: .airPlay(other)))
        XCTAssertFalse(ConnectTarget.airPlay(tv).isSame(as: .sidecar(pad)), "An iPad is never an AirPlay display")
        XCTAssertTrue(ConnectTarget.sidecar(pad).isSame(as: .sidecar(SidecarDevice(id: "tv", name: "tv", isConnected: true))))
        let receiver = OpenDisplaySender.Receiver(key: "tv", name: "tv", transports: [.wifi], isOn: false, status: "Off")
        var streaming = receiver
        streaming.isOn = true
        streaming.transport = .usb
        streaming.displayID = 7
        XCTAssertTrue(ConnectTarget.openDisplay(receiver).isSame(as: .openDisplay(streaming)))
        XCTAssertFalse(ConnectTarget.openDisplay(receiver).isSame(as: .sidecar(pad)), "A receiver is never an iPad")
        XCTAssertFalse(ConnectTarget.openDisplay(receiver).isConnected)
        XCTAssertTrue(ConnectTarget.openDisplay(streaming).isConnected)
    }

    func testAReceiverIsAnnouncedOverTheLinkItIsDialedOn() {
        let both = OpenDisplaySender.Receiver(key: "k", name: "Pad", transports: [.wifi, .usb], isOn: false, status: "Off")
        XCTAssertEqual(ConnectTarget.openDisplay(both).connectingAnnouncement, Spoken.connecting(to: "Pad", over: "USB"))
        let none = OpenDisplaySender.Receiver(key: "k", name: "Pad", transports: [], isOn: true, status: "Not found")
        XCTAssertEqual(ConnectTarget.openDisplay(none).connectingAnnouncement, Spoken.connecting(to: "Pad"))
    }

    func testAWatchAddressNamesTheDisplaysApp() {
        let url = URL(string: "http://localhost:47995/watch?token=abc")!
        XCTAssertEqual(AppDelegate.watchURL(url, app: 2).absoluteString, "http://localhost:47995/watch?token=abc&app=2")
        XCTAssertEqual(AppDelegate.watchURL(url, app: nil), url)
    }

    // MARK: - Switcher visibility

    /// The switcher has closed once a bar was seen and none has shown for two checks; a
    /// moment between pages doesn't close it.
    func testSwitcherClosesOnceNoBarShowsForTwoChecks() {
        var visibility = SwitcherVisibility()
        XCTAssertEqual(visibility.check(showing: false), .open, "not up yet")
        XCTAssertEqual(visibility.check(showing: true), .open)
        XCTAssertEqual(visibility.check(showing: false), .open, "between pages")
        XCTAssertEqual(visibility.check(showing: true), .open)
        XCTAssertEqual(visibility.check(showing: false), .open)
        XCTAssertEqual(visibility.check(showing: false), .closed)
    }

    /// Where no bar is ever seen showing, the switcher isn't taken for closed: focus stays.
    func testSwitcherNeverSeenShowingIsNotTakenForClosed() {
        var visibility = SwitcherVisibility()
        for _ in 1..<SwitcherVisibility.unseenChecks {
            XCTAssertEqual(visibility.check(showing: false), .open)
        }
        XCTAssertEqual(visibility.check(showing: false), .unknown)
    }

    // MARK: - Ways out of the switcher's pages

    /// Every page of a display has a way out: the resolutions page a ◀ back to the switcher,
    /// the others a ◀ back to it (`.back`, in their own items), and while DAM is the active
    /// app, when the system shows no close box, DAM's own close button on each.
    func testEveryDisplayPageHasAWayOut() {
        let back = NSTouchBarItem.Identifier(ControlStripPresenter.displayResPrefix + "tv.switcher")
        for onResolutions in [true, false] {
            let active = ControlStripPresenter.pageExits(displayID: "tv", onResolutions: onResolutions, damActive: true)
            XCTAssertEqual(active.first, ControlStripPresenter.modalCloseID, "the close button comes first")
            let inactive = ControlStripPresenter.pageExits(displayID: "tv", onResolutions: onResolutions, damActive: false)
            XCTAssertFalse(inactive.contains(ControlStripPresenter.modalCloseID), "the system's close box shows then")
            XCTAssertEqual(active.contains(back), onResolutions)
            XCTAssertEqual(inactive.contains(back), onResolutions)
        }
    }

    /// The arrange flow's pages have the close button while DAM is active, when opened from
    /// something to close.
    func testArrangePagesHaveACloseButtonWhileDAMIsActive() {
        XCTAssertEqual(ArrangeTouchBar.exits(damActive: true, canClose: true), ["close"])
        XCTAssertEqual(ArrangeTouchBar.exits(damActive: false, canClose: true), [])
        XCTAssertEqual(ArrangeTouchBar.exits(damActive: true, canClose: false), [])
    }

    // MARK: - No re-present after close

    /// A change started while the switcher was open doesn't bring it back once it has closed,
    /// even if it was opened again meanwhile.
    func testAChangeSettlingAfterACloseDoesNotReopen() {
        var closes = SwitcherCloses()
        let started = closes.count
        XCTAssertTrue(closes.noneSince(started))
        closes.closed()
        XCTAssertFalse(closes.noneSince(started))
        let later = closes.count
        XCTAssertTrue(closes.noneSince(later))
    }

    // MARK: - A bar's watch

    private func spin(until done: () -> Bool, timeout: TimeInterval = 3) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// A bar seen showing and then gone, as when its close box is tapped, ends the watch as
    /// closed: a picker then cancels rather than picks.
    func testWatch_barGone_endsClosed() {
        let watch = ModalBarWatch()
        var showing = true
        var ended: [SwitcherVisibility.State] = []
        watch.start(showing: { showing }) { ended.append($0) }
        spin(until: { false }, timeout: 3 * SwitcherVisibility.interval)
        XCTAssertEqual(ended, [], "still showing")
        showing = false
        spin(until: { !ended.isEmpty })
        XCTAssertEqual(ended, [.closed])
        XCTAssertFalse(watch.isWatching)
    }

    /// Stopped, as when the picker dismisses its own bar, the watch says nothing.
    func testWatch_stopped_saysNothing() {
        let watch = ModalBarWatch()
        var ended: [SwitcherVisibility.State] = []
        watch.start(showing: { false }) { ended.append($0) }
        watch.stop()
        spin(until: { false }, timeout: 4 * SwitcherVisibility.interval)
        XCTAssertEqual(ended, [])
    }

    /// It ticks while an alert or a menu is up, in the run loop's other modes.
    func testWatch_ticksInTheModalPanelMode() {
        let watch = ModalBarWatch()
        var showing = true
        var ended: [SwitcherVisibility.State] = []
        watch.start(showing: { showing }) { ended.append($0) }
        let hide = Date().addingTimeInterval(3 * SwitcherVisibility.interval)
        let end = Date().addingTimeInterval(3)
        while ended.isEmpty && Date() < end {
            RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05))
            if Date() > hide { showing = false }
        }
        XCTAssertEqual(ended, [.closed])
    }

    // MARK: - Focus after the switcher

    private final class App {}

    /// Focus goes back to the app DAM came forward from, once, and not while an alert is up.
    func testFocus_handedBackOnce_notOverAnAlert() {
        let mail = App()
        var focus = SwitcherFocus<App>()
        focus.opened(from: mail)
        XCTAssertTrue(focus.closed(alertUp: false) === mail)
        XCTAssertNil(focus.closed(alertUp: false), "forgotten once handed back")
        focus.opened(from: mail)
        XCTAssertNil(focus.closed(alertUp: true))
        XCTAssertNil(focus.previous)
    }

    /// Opened again while open, DAM is active already and the first app is kept.
    func testFocus_reopenedKeepsTheFirstApp() {
        let mail = App()
        var focus = SwitcherFocus<App>()
        focus.opened(from: mail)
        focus.opened(from: nil)
        XCTAssertTrue(focus.closed(alertUp: false) === mail)
    }

    /// The user going on in a window of DAM's, or to another app, keeps focus where they are.
    func testFocus_userMovedOn_keepsIt() {
        var focus = SwitcherFocus<App>()
        focus.opened(from: App())
        focus.userMovedOn()
        XCTAssertNil(focus.closed(alertUp: false))
    }

    /// Where the watch gave up, a later close doesn't hand focus to the app from back then.
    func testFocus_watchGaveUp_forgetsTheApp() {
        var focus = SwitcherFocus<App>()
        focus.opened(from: App())
        focus.watchGaveUp()
        focus.opened(from: nil)
        XCTAssertNil(focus.closed(alertUp: false))
    }
}
