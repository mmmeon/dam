import XCTest
import CoreGraphics
@testable import HLDM

final class VideoManagerFilterTests: XCTestCase {

    private let airPlayKey      = "hldm.hidden.airplay"
    private let displayKey      = "hldm.hidden.displays"
    private let aspectRatioKey  = "hldm.display.aspectRatio"

    override func tearDown() {
        super.tearDown()
        [airPlayKey, displayKey, aspectRatioKey].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    // MARK: - Helpers

    private func airPlay(_ name: String, connected: Bool = false, cgID: CGDirectDisplayID = 0) -> DisplayInfo {
        DisplayInfo(id: name, name: name, isConnected: connected, cgDisplayID: cgID, isMirroring: false, isBuiltIn: false)
    }

    private func display(_ name: String, connected: Bool = true, cgID: CGDirectDisplayID = 1,
                         mirroring: Bool = false, builtIn: Bool = false) -> DisplayInfo {
        DisplayInfo(id: name, name: name, isConnected: connected, cgDisplayID: cgID,
                    isMirroring: mirroring, isBuiltIn: builtIn)
    }

    private func mode(_ w: Int, _ h: Int, hz: Double = 60) -> DisplayMode {
        DisplayMode(id: "\(w)x\(h)@\(hz)", ioModeID: 0, width: w, height: h,
                    pixelWidth: w, pixelHeight: h, refreshRate: hz, isHiDPI: false)
    }

    // MARK: - VideoManager.filter(airPlayDevices:hidden:)

    func testFilterAirPlay_emptyList_returnsEmpty() {
        let result = VideoManager.filter(airPlayDevices: [], hidden: ["TV"])
        XCTAssertTrue(result.isEmpty)
    }

    func testFilterAirPlay_noHiddenDevices_returnsAll() {
        let devices = [airPlay("TV"), airPlay("Office ATV")]
        let result = VideoManager.filter(airPlayDevices: devices, hidden: [])
        XCTAssertEqual(result.map(\.name), ["TV", "Office ATV"])
    }

    func testFilterAirPlay_allHidden_returnsEmpty() {
        let devices = [airPlay("TV"), airPlay("ATV")]
        let result = VideoManager.filter(airPlayDevices: devices, hidden: ["TV", "ATV"])
        XCTAssertTrue(result.isEmpty)
    }

    func testFilterAirPlay_oneHidden_returnsRest() {
        let devices = [airPlay("TV"), airPlay("ATV"), airPlay("Bedroom")]
        let result = VideoManager.filter(airPlayDevices: devices, hidden: ["ATV"])
        XCTAssertEqual(result.map(\.name), ["TV", "Bedroom"])
    }

    func testFilterAirPlay_preservesIsConnectedState() {
        let devices = [airPlay("TV", connected: true), airPlay("ATV", connected: false)]
        let result = VideoManager.filter(airPlayDevices: devices, hidden: [])
        XCTAssertTrue(result[0].isConnected)
        XCTAssertFalse(result[1].isConnected)
    }

    func testFilterAirPlay_preservesCGDisplayID() {
        let devices = [airPlay("TV", cgID: 42), airPlay("ATV", cgID: 99)]
        let result = VideoManager.filter(airPlayDevices: devices, hidden: [])
        XCTAssertEqual(result[0].cgDisplayID, 42)
        XCTAssertEqual(result[1].cgDisplayID, 99)
    }

    // MARK: - VideoManager.filter(connectedDisplays:hidden:)

    func testFilterDisplays_emptyList_returnsEmpty() {
        let result = VideoManager.filter(connectedDisplays: [], hidden: ["Dell"])
        XCTAssertTrue(result.isEmpty)
    }

    func testFilterDisplays_noHiddenDisplays_returnsAll() {
        let displays = [display("Dell"), display("LG")]
        let result = VideoManager.filter(connectedDisplays: displays, hidden: [])
        XCTAssertEqual(result.map(\.name), ["Dell", "LG"])
    }

    func testFilterDisplays_allHidden_returnsEmpty() {
        let displays = [display("Dell"), display("LG")]
        let result = VideoManager.filter(connectedDisplays: displays, hidden: ["Dell", "LG"])
        XCTAssertTrue(result.isEmpty)
    }

    func testFilterDisplays_oneHidden_returnsRest() {
        let displays = [display("Dell"), display("LG"), display("Studio Display")]
        let result = VideoManager.filter(connectedDisplays: displays, hidden: ["LG"])
        XCTAssertEqual(result.map(\.name), ["Dell", "Studio Display"])
    }

    func testFilterDisplays_preservesBuiltInFlag() {
        let displays = [display("Built-in Retina Display", builtIn: true), display("Dell", builtIn: false)]
        let result = VideoManager.filter(connectedDisplays: displays, hidden: [])
        XCTAssertTrue(result[0].isBuiltIn)
        XCTAssertFalse(result[1].isBuiltIn)
    }

    func testFilterDisplays_preservesMirroringFlag() {
        let displays = [display("TV", mirroring: true), display("Dell", mirroring: false)]
        let result = VideoManager.filter(connectedDisplays: displays, hidden: [])
        XCTAssertTrue(result[0].isMirroring)
        XCTAssertFalse(result[1].isMirroring)
    }

    // MARK: - DisplayMode.label

    func testDisplayMode_label_integerHz_omitsDecimal() {
        let m = mode(1920, 1080, hz: 60)
        XCTAssertTrue(m.label.hasSuffix("60 Hz"), "Expected '60 Hz', got '\(m.label)'")
    }

    func testDisplayMode_label_decimalHz_showsOneDecimalPlace() {
        let m = mode(1920, 1080, hz: 29.97)
        XCTAssertTrue(m.label.hasSuffix("29.97 Hz") || m.label.hasSuffix("30.0 Hz"),
                      "Unexpected label: \(m.label)")
        // 29.97 has a non-zero remainder → should show decimal
        XCTAssertTrue(m.label.contains("."), "Expected decimal in label: \(m.label)")
    }

    func testDisplayMode_label_usesMultiplicationSign_notX() {
        let m = mode(3840, 2160)
        XCTAssertTrue(m.label.contains("×"), "Label should use × not x: \(m.label)")
        XCTAssertFalse(m.label.contains("3840x2160"), "Label should not use lowercase x: \(m.label)")
    }

    func testDisplayMode_label_usesDashSeparator() {
        let m = mode(2560, 1440)
        XCTAssertTrue(m.label.contains("—"), "Label should use — separator: \(m.label)")
    }

    func testDisplayMode_60Hz_labelFormat() {
        let m = mode(3840, 2160, hz: 60)
        XCTAssertEqual(m.label, "3840 × 2160 — 60 Hz")
    }

    func testDisplayMode_120Hz_labelFormat() {
        let m = mode(2560, 1440, hz: 120)
        XCTAssertEqual(m.label, "2560 × 1440 — 120 Hz")
    }

    func testDisplayMode_decimalHz_labelFormat() {
        // 59.94 has a non-zero truncatingRemainder → uses "%.1f Hz"
        let m = mode(1920, 1080, hz: 59.94)
        XCTAssertEqual(m.label, "1920 × 1080 — 59.9 Hz")
    }

    // MARK: - DisplayMode.rateLabel

    func testDisplayMode_rateLabel_roundsFractionalRates() {
        XCTAssertEqual(mode(1920, 1080, hz: 59.94).rateLabel, "60 Hz")
        XCTAssertEqual(mode(1920, 1080, hz: 119.88).rateLabel, "120 Hz")
    }

    func testDisplayMode_rateLabel_marksVirtualRates() {
        XCTAssertEqual(VideoManager.virtualMode(width: 1920, height: 1080, refreshRate: 120).rateLabel, "120 Hz ✦")
    }

    func testDisplayMode_resolutionLabel_notesHiDPI() {
        XCTAssertEqual(mode(1920, 1080).resolutionLabel, "1920 × 1080")
        let hiDPI = DisplayMode(id: "x", ioModeID: 0, width: 1280, height: 720,
                                pixelWidth: 2560, pixelHeight: 1440, refreshRate: 60, isHiDPI: true)
        XCTAssertEqual(hiDPI.resolutionLabel, "1280 × 720  HiDPI")
    }

    // MARK: - VideoManager.virtualModes(for:)

    func testVirtualModes_alwaysInclude60Hz_sortedByResolutionThenRate() {
        let key = "hldm.virtual.airplay.refreshRates"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        VisibilityPreferences.setVirtualRefreshRates([120], for: .airPlay)

        let modes = VideoManager.virtualModes(for: .airPlay)
        // 4 resolutions at 1x plus HiDPI 1080p (4K-backed) and 720p (1440p-backed), × 2 rates.
        XCTAssertEqual(modes.count, (VideoManager.virtualResolutions.count + 2) * 2)
        XCTAssertEqual(modes.prefix(2).map { $0.roundedRefreshRate }, [120, 60])
        XCTAssertTrue(modes.allSatisfy { $0.isVirtual && $0.ioModeID == 0 })
    }

    func testVirtualModes_includeHiDPI720pBackedBy1440p() {
        let hiDPI = VideoManager.virtualModes(for: .airPlay).filter { $0.isHiDPI }
        XCTAssertTrue(hiDPI.contains { $0.width == 1280 && $0.pixelWidth == 2560 })
        XCTAssertTrue(hiDPI.contains { $0.width == 1920 && $0.pixelWidth == 3840 })
        XCTAssertFalse(hiDPI.contains { $0.width == 2560 }, "No 5K backing is advertised")
    }

    // MARK: - VideoManager.pickerResolutions(_:native:current:)

    private func hiDPI(_ w: Int, _ h: Int) -> DisplayMode {
        DisplayMode(id: "\(w)x\(h)@2x", ioModeID: 0, width: w, height: h,
                    pixelWidth: w * 2, pixelHeight: h * 2, refreshRate: 60, isHiDPI: true)
    }

    private func names(_ modes: [DisplayMode]) -> [String] {
        modes.map { "\($0.width)x\($0.height)\($0.isHiDPI ? "H" : "")" }
    }

    /// The 4K HISENSE's one-per-size list (subset), largest first.
    private var fourK: [DisplayMode] {
        [hiDPI(3360, 1890), hiDPI(2560, 1440), hiDPI(2048, 1080), mode(3840, 2160), hiDPI(1920, 1080),
         hiDPI(1680, 945), hiDPI(1280, 720), hiDPI(1152, 648), mode(1600, 1200), hiDPI(800, 600),
         mode(1344, 756), mode(1024, 768)]
    }

    func testPickerResolutions_4K_touchBarList() {
        // Downsampled HiDPI (2560×1440+), other ratios, tiny sizes, and 1x 4K all go.
        let kept = VideoManager.pickerResolutions(fourK, native: (3840, 2160), current: nil)
        XCTAssertEqual(names(kept), ["1920x1080H", "1680x945H", "1344x756", "1280x720H"])
    }

    func testPickerResolutions_4K_menuAddsLarger1x() {
        let kept = VideoManager.pickerResolutions(fourK, native: (3840, 2160), current: nil,
                                                  includeLarger1x: true)
        XCTAssertEqual(names(kept), ["3840x2160", "1920x1080H", "1680x945H", "1344x756", "1280x720H"])
    }

    func testPickerResolutions_1xMatchingHiDPIBacking_isDropped() {
        // A 1x 2560×1440 duplicates 1280×720 HiDPI's pixels and is below 1920×1080 HiDPI.
        let modes = [hiDPI(1920, 1080), mode(2560, 1440), hiDPI(1280, 720)]
        let kept = VideoManager.pickerResolutions(modes, native: (3840, 2160), current: nil)
        XCTAssertEqual(names(kept), ["1920x1080H", "1280x720H"])
    }

    func testPickerResolutions_keepsCurrentEvenWhenFiltered() {
        let kept = VideoManager.pickerResolutions(fourK, native: (3840, 2160), current: mode(3840, 2160))
        XCTAssertTrue(names(kept).contains("3840x2160"))
    }

    func testPickerResolutions_noHiDPI_keeps1xModes() {
        // A 1080p panel: no HiDPI modes, so no 1x mode is "larger than HiDPI".
        let modes = [mode(1920, 1080), mode(1600, 900), mode(1280, 720), mode(640, 360)]
        let kept = VideoManager.pickerResolutions(modes, native: (1920, 1080), current: nil)
        XCTAssertEqual(names(kept), ["1920x1080", "1600x900", "1280x720", "640x360"])
    }

    func testNativeSize_isLargest1xMode() {
        let modes = [hiDPI(3360, 1890), mode(3840, 2160), hiDPI(1920, 1080), mode(1600, 1200)]
        let native = VideoManager.nativeSize(of: modes)
        XCTAssertEqual(native?.width, 3840)
        XCTAssertEqual(native?.height, 2160)
    }

    // MARK: - DisplayMode.shortLabel

    func testDisplayMode_shortLabel_noSpaces() {
        let m = mode(3840, 2160)
        XCTAssertFalse(m.shortLabel.contains(" "), "shortLabel should have no spaces: \(m.shortLabel)")
    }

    func testDisplayMode_shortLabel_virtual_appendsSpacedMarker() {
        let m = VideoManager.virtualMode(width: 1920, height: 1080, refreshRate: 60)
        XCTAssertEqual(m.shortLabel, "1080p ✦")
    }

    func testDisplayMode_shortLabel_hiDPI_appendsSpacedMarker() {
        let m = DisplayMode(id: "1920x1080@60.0@2x", ioModeID: 0, width: 1920, height: 1080,
                            pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60, isHiDPI: true)
        XCTAssertEqual(m.shortLabel, "1080p ↑")
    }

    func testDisplayMode_shortLabel_virtualHiDPI_showsBothMarkers() {
        let m = VideoManager.virtualMode(width: 1280, height: 720, refreshRate: 60,
                                         pixelWidth: 2560, pixelHeight: 1440)
        XCTAssertEqual(m.shortLabel, "720p ↑✦")
    }

    func testDisplayMode_shortLabel_16x9_usesPFormat() {
        // 1920×1080 is 16:9, so the compact "1080p" label is used (shorter than "1920×1080").
        let m = mode(1920, 1080)
        XCTAssertEqual(m.shortLabel, "1080p")
    }

    func testDisplayMode_shortLabel_4K_usesPFormat() {
        // 3840×2160 is 16:9, so "2160p" is shorter than "3840×2160".
        let m = mode(3840, 2160)
        XCTAssertEqual(m.shortLabel, "2160p")
    }

    func testDisplayMode_shortLabel_nonStandardRatio_usesWxH() {
        // 1600×900 is 16:9, but 800×600 is 4:3 — with default 16:9 ratio that's non-matching.
        let m = mode(800, 600)
        XCTAssertEqual(m.shortLabel, "800×600")
    }

    // MARK: - DisplayMode.id

    func testDisplayMode_id_encodesWidthHeightRate() {
        let m = mode(2560, 1440, hz: 60)
        XCTAssertEqual(m.id, "2560x1440@60.0")
    }
}
