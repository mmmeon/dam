//
//  VideoManager+Rotation.swift
//
//  Which displays can be turned and how: a streaming display by DAM (see
//  VideoManager+StreamingDisplay.swift), any other by macOS where it allows it (see
//  DisplayRotation.swift).
//

import CoreGraphics
import Foundation

/// A rotation picked in the menu for a display.
struct RotationSelection {
    let rotation: DisplayRotation
    let display: DisplayInfo
}

extension VideoManager {

    /// How far `display` is turned now, or nil when it can't be turned: it is off, follows an
    /// iPad's anchor, is shown through an anchor (which macOS can't turn), or macOS doesn't
    /// offer rotation for it.
    func rotation(of display: DisplayInfo) -> DisplayRotation? {
        let id = display.cgDisplayID
        guard display.isConnected, id != 0, anchoredMaster(of: display) == nil else { return nil }
        if display.isStreaming { return streamingRotation(of: id) }
        guard !hasVirtualAnchor(for: display.name), SystemRotation.canRotate(id) else { return nil }
        return SystemRotation.current(of: id)
    }

    /// Turns `display` to `rotation`; `completion` gets whether it was done, on the main queue.
    func setRotation(_ rotation: DisplayRotation, for display: DisplayInfo,
                     completion: @escaping (Bool) -> Void = { _ in }) {
        guard let current = self.rotation(of: display) else { return completion(false) }
        guard rotation != current else { return completion(true) }
        if display.isStreaming {
            rotateStreamingDisplay(id: display.cgDisplayID, to: rotation, completion: completion)
        } else {
            completion(SystemRotation.set(rotation, for: display.cgDisplayID))
        }
    }
}
