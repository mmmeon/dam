import XCTest
@testable import DAM

/// How a display's resolution choices flatten into one list, as the menu's resolution
/// picker cycles through them (the Touch Bar's aspect-filtered list is covered in
/// ControlStripPresenterTests).
final class ResolutionChoicesTests: XCTestCase {

    private func mode(_ w: Int, _ h: Int, virtual: Bool = false) -> DisplayMode {
        DisplayMode(id: "\(w)x\(h)", ioModeID: 0, width: w, height: h,
                    pixelWidth: w, pixelHeight: h, refreshRate: 60, isHiDPI: false, isVirtual: virtual)
    }

    func testAirPlay_nativeThenVirtual_keepsEveryAspect() {
        let native  = [mode(1920, 1080), mode(1024, 768), mode(1280, 720)]
        let virtual = [mode(3840, 2160, virtual: true)]
        let (modes, _) = ResolutionChoices.airPlay(native: native, virtual: virtual,
                                                   current: (nil, nil)).flattened()
        XCTAssertEqual(modes, native + virtual)
    }

    func testAirPlay_currentNative() {
        let (_, current) = ResolutionChoices.airPlay(native: [mode(1920, 1080), mode(1280, 720)],
                                                     virtual: [mode(3840, 2160, virtual: true)],
                                                     current: (1, nil)).flattened()
        XCTAssertEqual(current, 1)
    }

    func testAirPlay_currentVirtual_offsetPastNative() {
        let (_, current) = ResolutionChoices.airPlay(native: [mode(1920, 1080), mode(1280, 720)],
                                                     virtual: [mode(3840, 2160, virtual: true),
                                                               mode(2560, 1440, virtual: true)],
                                                     current: (nil, 1)).flattened()
        XCTAssertEqual(current, 3)
    }

    func testAirPlay_noneCurrent() {
        let (_, current) = ResolutionChoices.airPlay(native: [mode(1920, 1080)], virtual: [],
                                                     current: (nil, nil)).flattened()
        XCTAssertNil(current)
    }

    func testPanelAndSidecar_passThrough() {
        let modes = [mode(2560, 1440), mode(1920, 1080)]
        for choices in [ResolutionChoices.panel(modes: modes, current: 1),
                        .sidecar(modes: modes, current: 1)] {
            let flat = choices.flattened(nativeInLargestAspect: true)
            XCTAssertEqual(flat.modes, modes)
            XCTAssertEqual(flat.current, 1)
        }
    }
}
