import XCTest
@testable import DAM

/// How the resolution hotkey's picker lists an AirPlay display's native and virtual sizes.
final class ResolutionPickerTests: XCTestCase {

    private func mode(_ w: Int, _ h: Int, virtual: Bool = false) -> DisplayMode {
        DisplayMode(id: "\(w)x\(h)", ioModeID: 0, width: w, height: h,
                    pixelWidth: w, pixelHeight: h, refreshRate: 60, isHiDPI: false, isVirtual: virtual)
    }

    func testChoices_nativeThenVirtual() {
        let native  = [mode(1920, 1080), mode(1280, 720)]
        let virtual = [mode(3840, 2160, virtual: true)]
        let (modes, _) = ResolutionPicker.choices(native: native, virtual: virtual, current: (nil, nil))
        XCTAssertEqual(modes, native + virtual)
    }

    func testChoices_currentNative() {
        let (_, current) = ResolutionPicker.choices(native: [mode(1920, 1080), mode(1280, 720)],
                                                    virtual: [mode(3840, 2160, virtual: true)],
                                                    current: (1, nil))
        XCTAssertEqual(current, 1)
    }

    func testChoices_currentVirtual_offsetPastNative() {
        let (_, current) = ResolutionPicker.choices(native: [mode(1920, 1080), mode(1280, 720)],
                                                    virtual: [mode(3840, 2160, virtual: true),
                                                              mode(2560, 1440, virtual: true)],
                                                    current: (nil, 1))
        XCTAssertEqual(current, 3)
    }

    func testChoices_noneCurrent() {
        let (_, current) = ResolutionPicker.choices(native: [mode(1920, 1080)], virtual: [],
                                                    current: (nil, nil))
        XCTAssertNil(current)
    }
}
