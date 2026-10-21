//
//  onlinedisplays.swift
//
//  What tools/streamtest's displays and tools/sessiontest's layout both read of the displays.
//  Built into each with build_swift (tools/common/common.zsh).
//

import CoreGraphics

/// The vendor DAM's virtual displays carry, and the product its streaming displays carry.
let damVendor: UInt32 = 0x3456
let streamingProduct: UInt32 = 0x1236

/// The displays online, as CoreGraphics lists them.
func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

/// Whether `id` is one of DAM's streaming displays.
func isStreaming(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayVendorNumber(id) == damVendor && CGDisplayModelNumber(id) == streamingProduct
}

/// What both tools' lines tell of display `id`, in this order: x y width height pixel-width
/// hz main mirrors. x and y are CoreGraphics coordinates, from the top left of the main
/// display; main is 1 or 0; mirrors is the ID of the display it mirrors, or 0.
func displayFields(_ id: CGDirectDisplayID) -> [Any] {
    let bounds = CGDisplayBounds(id)
    let mode = CGDisplayCopyDisplayMode(id)
    return [
        Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height),
        mode?.pixelWidth ?? 0, Int((mode?.refreshRate ?? 0).rounded()),
        CGDisplayIsMain(id) != 0 ? 1 : 0, CGDisplayMirrorsDisplay(id),
    ]
}
