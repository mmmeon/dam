import XCTest
@testable import HLDM

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
}
