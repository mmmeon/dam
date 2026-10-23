//
//  StreamingDisplayModes.swift
//
//  What a streaming display is made in and known by: shared by VideoManager, which makes
//  them in DAM, and the login window agent, which makes its own.
//

import CoreGraphics
import Foundation

/// The sizes and rates the streaming display offers, so it can match whatever shows it.
enum StreamingDisplayModes {
    /// Common 16:9, 16:10 and 4:3 sizes. With HiDPI on, macOS offers each one at 2x as well,
    /// even past `maxPixelsWide` × `maxPixelsHigh` (2560 × 1440 at 2x renders 5120 × 2880);
    /// `fits` keeps those out of the resolutions DAM lists.
    static let sizes: [(width: Int, height: Int)] = [
        (1280, 720), (1920, 1080), (2560, 1440), (3840, 2160),
        (1280, 800), (1440, 900), (1680, 1050), (1920, 1200), (2560, 1600),
        (1024, 768), (1600, 1200), (2048, 1536)
    ]
    static let refreshRates = [60, 30, 120]

    /// The most pixels a streaming display is made with on either side (8K), and its highest
    /// rate, whatever a stream asks for.
    static let largestSide = 8192
    static let highestRefreshRate = 480

    /// A mode a streaming display comes up in.
    struct Mode: Equatable {
        var width: Int
        var height: Int
        var refreshRate: Int
        /// Drawn at twice the size in pixels.
        var hiDPI = false

        var pixelWidth: Int { hiDPI ? width * 2 : width }
        var pixelHeight: Int { hiDPI ? height * 2 : height }

        /// Taller than wide.
        var isPortrait: Bool { height > width }

        /// Whether a display can be made in it: every side from 1 to `largestSide` pixels, the
        /// rate from 1 to `highestRefreshRate`. Asked before anything is worked out from it.
        var isValid: Bool {
            let side = 1...StreamingDisplayModes.largestSide
            return side.contains(width) && side.contains(height) && side.contains(pixelWidth)
                && side.contains(pixelHeight) && (1...StreamingDisplayModes.highestRefreshRate).contains(refreshRate)
        }

        /// The same mode turned by `rotation`: on its side, its width and height trade places.
        func rotated(_ rotation: DisplayRotation) -> Mode {
            var mode = self
            (mode.width, mode.height) = rotation.size(width: width, height: height)
            return mode
        }
    }

    /// The mode one comes up in unless asked for another: 1920 × 1080 at 60 Hz, at 1x.
    static let start = Mode(width: 1920, height: 1080, refreshRate: 60)

    /// The mode for a stream of `width` × `height` pixels: the same at 1x, or from 2560
    /// pixels on the long side, HiDPI at half the size, as a Mac picks for a screen that
    /// sharp. A portrait stream gets a portrait mode.
    static func forStream(width: Int, height: Int, fps: Int) -> Mode {
        max(width, height) >= 2560 && width.isMultiple(of: 2) && height.isMultiple(of: 2)
            ? Mode(width: width / 2, height: height / 2, refreshRate: fps, hiDPI: true)
            : Mode(width: width, height: height, refreshRate: fps)
    }

    static let maxPixelsWide = sizes.map(\.width).max() ?? 0
    static let maxPixelsHigh = sizes.map(\.height).max() ?? 0
    /// The most pixels a streaming display is made to take on either side, so it can be
    /// turned on its side where it is.
    static let maxPixelsSide = max(maxPixelsWide, maxPixelsHigh)

    /// Every size at every rate, the start mode first so the display comes up in it.
    static var advertised: [(width: Int, height: Int, refreshRate: Int)] { advertised(startingIn: start) }

    /// Every size at every rate and `start` with them, which comes first. The sizes stand the
    /// way `start` does, so a portrait display lists portrait sizes.
    static func advertised(startingIn start: Mode) -> [(width: Int, height: Int, refreshRate: Int)] {
        let all = sizes.flatMap { size in
            refreshRates.map { start.isPortrait ? (size.height, size.width, $0) : (size.width, size.height, $0) }
        }
        let isStart = { (m: (width: Int, height: Int, refreshRate: Int)) in
            m.width == start.width && m.height == start.height && m.refreshRate == start.refreshRate
        }
        return [(start.width, start.height, start.refreshRate)] + all.filter { !isStart($0) }
    }

    /// The settings that give a streaming display every mode, `start` first.
    static func settings(startingIn start: Mode) -> CGVirtualDisplaySettings {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = advertised(startingIn: start).map {
            CGVirtualDisplayMode(width: UInt($0.width), height: UInt($0.height), refreshRate: Double($0.refreshRate))
        }
        return settings
    }
}

/// What a streaming display made for one app or client is called and known by, in place of
/// "DAM Streaming n" and its slot's serial number.
struct StreamingDisplayIdentity: Equatable {
    /// Its name, as System Settings and the app capturing it show it.
    let name: String
    /// What its serial number comes from (see `VideoManager.streamingSerial(seed:)`).
    let seed: String
}
