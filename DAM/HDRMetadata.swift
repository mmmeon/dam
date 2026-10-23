//
//  HDRMetadata.swift
//
//  HDR10's mastering metadata, as Moonlight sends it and the encoder writes it into the
//  stream.
//

import Foundation

/// HDR10's static metadata: the mastering display's colour volume and the content's light
/// levels, which the encoder writes into the stream and the control stream sends Moonlight
/// (its HDR mode message, which Moonlight hands the OS to tone-map by).
struct MoonlightHDRMetadata: Equatable {
    /// Red, green and blue, then white, as CIE 1931 x and y in units of 0.00002.
    var primaries: [(x: UInt16, y: UInt16)]
    var whitePoint: (x: UInt16, y: UInt16)
    /// The mastering display's brightest, in nits, and darkest, in 0.0001 nit.
    var maxLuminance: UInt16
    var minLuminance: UInt16
    /// The content's brightest pixel and brightest frame on average, in nits.
    var maxContentLightLevel: UInt16
    var maxFrameAverageLightLevel: UInt16

    /// A BT.2020 display of 1000 nits, D65, as ScreenCaptureKit's canonical HDR display is
    /// taken to be; the light levels are the same bounds.
    static let canonical = MoonlightHDRMetadata(
        primaries: [(35400, 14600), (8500, 39850), (6550, 2300)], whitePoint: (15635, 16450),
        maxLuminance: 1000, minLuminance: 50, maxContentLightLevel: 1000, maxFrameAverageLightLevel: 400)

    /// SDR in HDR10, as a display is captured before macOS 15: nothing brighter than SDR
    /// white at 203 nits. Said so, a player has no highlights to make room for and shows
    /// white as its SDR white; with 1000 nits, macOS's tone-mapping dims it to leave room.
    static let sdr = MoonlightHDRMetadata(
        primaries: canonical.primaries, whitePoint: canonical.whitePoint,
        maxLuminance: 203, minLuminance: 50, maxContentLightLevel: 203, maxFrameAverageLightLevel: 203)

    static func == (a: Self, b: Self) -> Bool {
        a.primaries.map { [$0.x, $0.y] } == b.primaries.map { [$0.x, $0.y] } &&
        [a.whitePoint.x, a.whitePoint.y, a.maxLuminance, a.minLuminance, a.maxContentLightLevel, a.maxFrameAverageLightLevel] ==
        [b.whitePoint.x, b.whitePoint.y, b.maxLuminance, b.minLuminance, b.maxContentLightLevel, b.maxFrameAverageLightLevel]
    }

    /// The HDR mode message's type on the control stream.
    static let messageType: UInt16 = 0x010e

    /// The HDR mode message's payload, as Sunshine sends it: whether HDR is on, then the
    /// metadata, little-endian, the last field (the display's full-frame brightest) unknown.
    func controlPayload(enabled: Bool) -> Data {
        var payload = Data([enabled ? 1 : 0])
        let points: [UInt16] = primaries.flatMap { [$0.x, $0.y] } + [whitePoint.x, whitePoint.y]
        let levels: [UInt16] = [maxLuminance, minLuminance, maxContentLightLevel, maxFrameAverageLightLevel, 0]
        for value in points + levels { payload.append(littleEndian: value) }
        return payload
    }

    /// The mastering display colour volume as VideoToolbox writes it into the stream's SEI:
    /// big-endian, green, blue then red, white, then the brightest and darkest in 0.0001 nit.
    var masteringDisplayColorVolume: Data {
        var data = Data()
        let points: [UInt16] = [primaries[1], primaries[2], primaries[0], whitePoint].flatMap { [$0.x, $0.y] }
        for value in points { data.append(bigEndian: value) }
        data.append(bigEndian: UInt32(maxLuminance) * 10_000)
        data.append(bigEndian: UInt32(minLuminance))
        return data
    }

    /// The content light level as VideoToolbox writes it into the stream's SEI: big-endian.
    var contentLightLevel: Data {
        var data = Data()
        data.append(bigEndian: maxContentLightLevel)
        data.append(bigEndian: maxFrameAverageLightLevel)
        return data
    }
}
