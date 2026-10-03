import XCTest
import CoreGraphics
@testable import DAM

final class VideoManagerFilterTests: XCTestCase {

    private let airPlayKey      = "\(AppIdentity.shortID).hidden.airplay"
    private let displayKey      = "\(AppIdentity.shortID).hidden.displays"

    override func tearDown() {
        super.tearDown()
        [airPlayKey, displayKey].forEach { UserDefaults.standard.removeObject(forKey: $0) }
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
        let key = "\(AppIdentity.shortID).virtual.airplay.refreshRates"
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

    // MARK: - VideoManager.airPlayResolutionOptions / airPlayRateOptions

    private func nativeMode(_ w: Int, _ h: Int, hz: Double, io: Int32) -> DisplayMode {
        DisplayMode(id: "\(w)x\(h)@\(hz)", ioModeID: io, width: w, height: h,
                    pixelWidth: w, pixelHeight: h, refreshRate: hz, isHiDPI: false)
    }

    /// 1080p and 720p at 120 and 60 Hz, plus 720p HiDPI at 60 Hz.
    private var sampleVirtual: [DisplayMode] {
        [VideoManager.virtualMode(width: 1920, height: 1080, refreshRate: 120),
         VideoManager.virtualMode(width: 1920, height: 1080, refreshRate: 60),
         VideoManager.virtualMode(width: 1280, height: 720, refreshRate: 60,
                                  pixelWidth: 2560, pixelHeight: 1440),
         VideoManager.virtualMode(width: 1280, height: 720, refreshRate: 120),
         VideoManager.virtualMode(width: 1280, height: 720, refreshRate: 60)]
    }

    func testAirPlayResolutions_listEachSizeOnce_atCurrentRate() {
        let n1080at60 = nativeMode(1920, 1080, hz: 60, io: 1)
        let n1080at30 = nativeMode(1920, 1080, hz: 30, io: 2)
        let n720at60  = nativeMode(1280, 720, hz: 60, io: 3)
        let anchor = VideoManager.virtualMode(width: 1280, height: 720, refreshRate: 120)
        let opts = VideoManager.airPlayResolutionOptions(
            nativePerSize: [n1080at60, n720at60], nativeAll: [n1080at60, n1080at30, n720at60],
            virtual: sampleVirtual, anchorCurrent: anchor, nativeCurrent: nil)

        XCTAssertEqual(opts.native.map(\.ioModeID), [1, 3], "No native 120 Hz — keeps each size's best")
        XCTAssertEqual(opts.virtual.map(\.resolutionLabel), ["1920 × 1080 ✦", "1280 × 720  HiDPI ✦", "1280 × 720 ✦"])
        // 120 Hz where offered; the HiDPI size has only 60 Hz.
        XCTAssertEqual(opts.virtual.map(\.roundedRefreshRate), [120, 60, 120])
        XCTAssertNil(opts.current.native)
        XCTAssertEqual(opts.current.virtual, 2)
    }

    func testAirPlayResolutions_nativeCurrent_keepsRate_andMarksNativeOnly() {
        let n1080at60 = nativeMode(1920, 1080, hz: 60, io: 1)
        let n1080at30 = nativeMode(1920, 1080, hz: 30, io: 2)
        let n720at30  = nativeMode(1280, 720, hz: 30, io: 3)
        let opts = VideoManager.airPlayResolutionOptions(
            nativePerSize: [n1080at60, n720at30], nativeAll: [n1080at60, n1080at30, n720at30],
            virtual: sampleVirtual, anchorCurrent: nil, nativeCurrent: n720at30)

        XCTAssertEqual(opts.native.map(\.ioModeID), [2, 3])
        XCTAssertEqual(opts.virtual.map(\.roundedRefreshRate), [60, 60, 60], "30 Hz isn't virtual — falls back to 60")
        XCTAssertEqual(opts.current.native, 1)
        XCTAssertNil(opts.current.virtual)
    }

    func testAirPlayRates_anchorActive_preferVirtualAtCurrentSize() {
        let anchor = VideoManager.virtualMode(width: 1920, height: 1080, refreshRate: 60)
        let native = [nativeMode(1920, 1080, hz: 60, io: 1), nativeMode(1920, 1080, hz: 30, io: 2),
                      nativeMode(1280, 720, hz: 50, io: 3)]
        let rates = VideoManager.airPlayRateOptions(nativeAll: native, virtual: sampleVirtual,
                                                    anchorCurrent: anchor, nativeCurrent: nil)
        XCTAssertEqual(rates.map(\.rateLabel), ["120 Hz ✦", "60 Hz ✦", "30 Hz"])
        XCTAssertEqual(VideoManager.currentModeIndex(in: rates, anchorCurrent: anchor, nativeCurrent: nil), 1)
    }

    func testAirPlayRates_nativeCurrent_preferNative_keepCurrentFractionalMode() {
        let current = nativeMode(1920, 1080, hz: 59.94, io: 2)
        let native = [nativeMode(1920, 1080, hz: 60, io: 1), current]
        let rates = VideoManager.airPlayRateOptions(nativeAll: native, virtual: sampleVirtual,
                                                    anchorCurrent: nil, nativeCurrent: current)
        XCTAssertEqual(rates.map(\.rateLabel), ["120 Hz ✦", "60 Hz"])
        XCTAssertEqual(rates.last?.ioModeID, 2)
        XCTAssertEqual(VideoManager.currentModeIndex(in: rates, anchorCurrent: nil, nativeCurrent: current), 1)
    }

    func testAirPlayRates_noCurrentMode_isEmpty() {
        XCTAssertTrue(VideoManager.airPlayRateOptions(nativeAll: [], virtual: sampleVirtual,
                                                      anchorCurrent: nil, nativeCurrent: nil).isEmpty)
    }

    // MARK: - VideoManager.defaultVirtualMode(for:)

    func testDefaultVirtualMode_noneStored_isNil() {
        let key = "\(AppIdentity.shortID).virtual.airplay.defaultResolution"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        VisibilityPreferences.setDefaultVirtualResolution(nil, for: .airPlay)
        XCTAssertNil(VideoManager.defaultVirtualMode(for: .airPlay))
    }

    func testDefaultVirtualMode_prefers60HzAt1x_elseHighestEnabledRate() {
        let resKey   = "\(AppIdentity.shortID).virtual.airplay.defaultResolution"
        let ratesKey = "\(AppIdentity.shortID).virtual.airplay.refreshRates"
        let savedRes = UserDefaults.standard.object(forKey: resKey)
        let savedRates = UserDefaults.standard.object(forKey: ratesKey)
        defer {
            UserDefaults.standard.set(savedRes, forKey: resKey)
            UserDefaults.standard.set(savedRates, forKey: ratesKey)
        }
        VisibilityPreferences.setDefaultVirtualResolution("1920x1080", for: .airPlay)

        VisibilityPreferences.setVirtualRefreshRates([30, 60, 120], for: .airPlay)
        let mode = VideoManager.defaultVirtualMode(for: .airPlay)
        XCTAssertEqual(mode?.width, 1920)
        XCTAssertEqual(mode?.height, 1080)
        XCTAssertEqual(mode?.roundedRefreshRate, 60)
        XCTAssertEqual(mode?.isHiDPI, false)
        XCTAssertEqual(mode?.isVirtual, true)

        // 60 Hz is always offered, so it stays the choice even when only 120 is checked.
        VisibilityPreferences.setVirtualRefreshRates([120], for: .airPlay)
        XCTAssertEqual(VideoManager.defaultVirtualMode(for: .airPlay)?.roundedRefreshRate, 60)
    }

    func testDefaultVirtualMode_unknownResolution_isNil() {
        let key = "\(AppIdentity.shortID).virtual.airplay.defaultResolution"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        VisibilityPreferences.setDefaultVirtualResolution("800x600", for: .airPlay)
        XCTAssertNil(VideoManager.defaultVirtualMode(for: .airPlay))
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
        XCTAssertEqual(names(kept), ["1920x1080H", "1680x945H", "1280x720H"])
    }

    func testPickerResolutions_4K_menuAddsLarger1x() {
        let kept = VideoManager.pickerResolutions(fourK, native: (3840, 2160), current: nil,
                                                  includeLarger1x: true)
        XCTAssertEqual(names(kept), ["3840x2160", "1920x1080H", "1680x945H", "1280x720H"])
    }

    func testPickerResolutions_1xMatchingHiDPIBacking_isDropped() {
        // A 1x 2560×1440 duplicates 1280×720 HiDPI's pixels and is below 1920×1080 HiDPI.
        let modes = [hiDPI(1920, 1080), mode(2560, 1440), hiDPI(1280, 720)]
        let kept = VideoManager.pickerResolutions(modes, native: (3840, 2160), current: nil)
        XCTAssertEqual(names(kept), ["1920x1080H", "1280x720H"])
    }

    func testPickerResolutions_1xBelowSmallestHiDPI_isKept() {
        // 1x sizes between the smallest and largest HiDPI go; a smaller one stays.
        let modes = [hiDPI(1920, 1080), mode(1600, 900), hiDPI(1504, 846), mode(1344, 756)]
        let kept = VideoManager.pickerResolutions(modes, native: (3840, 2160), current: nil)
        XCTAssertEqual(names(kept), ["1920x1080H", "1504x846H", "1344x756"])
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

    func testOnePerSize_1080pPanel_keeps16x9() {
        // The LEN T24i-20: 1080p, yet macOS offers HiDPI sizes backed by up to 6720×3780.
        // Preferring HiDPI per size used to drop the 1x 1920×1080, making 16:10 1680×1050
        // the "native" size and letting 16:10 sizes into the list.
        let all = [hiDPI(1920, 1080), hiDPI(1680, 945), hiDPI(1280, 720), hiDPI(1024, 576),
                   hiDPI(960, 600), mode(1920, 1080), mode(1680, 1050), mode(1600, 900),
                   mode(1440, 900), mode(1344, 756), mode(1280, 1024), mode(1280, 720),
                   hiDPI(720, 450), mode(1024, 576), mode(1024, 768), mode(800, 600)]
        let native = VideoManager.nativeSize(of: all)
        XCTAssertEqual(native?.width, 1920)
        XCTAssertEqual(native?.height, 1080)
        let kept = VideoManager.pickerResolutions(VideoManager.onePerSize(all, native: native),
                                                  native: native, current: mode(1920, 1080),
                                                  includeLarger1x: true)
        XCTAssertEqual(names(kept), ["1920x1080", "1600x900", "1344x756", "1280x720", "1024x576"])
    }

    func testOnePerSize_prefersHiDPIThatFitsPanel() {
        let kept = VideoManager.onePerSize([mode(1920, 1080), hiDPI(1920, 1080), mode(1280, 720),
                                            hiDPI(1280, 720)], native: (2560, 1440))
        XCTAssertEqual(names(kept), ["1280x720H", "1920x1080"])
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

    func testDisplayMode_shortLabel_usesHeight() {
        XCTAssertEqual(mode(1920, 1080).shortLabel, "1080p")
        XCTAssertEqual(mode(3840, 2160).shortLabel, "2160p")
        // Any ratio: the pickers only list sizes in the panel's own ratio.
        XCTAssertEqual(mode(800, 600).shortLabel, "600p")
    }

    // MARK: - DisplayMode.id

    func testDisplayMode_id_encodesWidthHeightRate() {
        let m = mode(2560, 1440, hz: 60)
        XCTAssertEqual(m.id, "2560x1440@60.0")
    }
}
