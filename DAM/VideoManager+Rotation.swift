//
//  VideoManager+Rotation.swift
//
//  Which displays can be turned and how: a streaming display by DAM (see
//  VideoManager+StreamingDisplay.swift), a display macOS can turn by macOS (see
//  DisplayRotation.swift), and any other through a stand-in shown on it turned (see
//  RotatedPresentation.swift).
//

import AppKit
import CoreGraphics
import Foundation
import os.log

private let rotLog = Logger(subsystem: AppIdentity.bundleID, category: "Rotation")

/// A rotation picked in the menu for a display.
struct RotationSelection {
    let rotation: DisplayRotation
    let display: DisplayInfo
}

extension VideoManager {

    /// How far `display` is turned now, or nil when it can't be turned: it is off, follows an
    /// iPad's anchor, or has no screen to show a stand-in on.
    func rotation(of display: DisplayInfo) -> DisplayRotation? {
        let id = display.cgDisplayID
        guard display.isConnected, id != 0, anchoredMaster(of: display) == nil else { return nil }
        if display.isStreaming { return streamingRotation(of: id) }
        if let presentation = rotatedPresentations[display.name] { return presentation.rotation }
        if !hasVirtualAnchor(for: display.name), SystemRotation.canRotate(id) { return SystemRotation.current(of: id) }
        return RotatedPresentation.screen(resolutionControlID(for: display)) != nil ? .standard : nil
    }

    /// Turns `display` to `rotation`; `completion` gets whether it was done, on the main queue.
    func setRotation(_ rotation: DisplayRotation, for display: DisplayInfo,
                     completion: @escaping (Bool) -> Void = { _ in }) {
        guard let current = self.rotation(of: display) else { return completion(false) }
        guard rotation != current else { return completion(true) }
        if display.isStreaming {
            rotateStreamingDisplay(id: display.cgDisplayID, to: rotation, completion: completion)
        } else if let presentation = rotatedPresentations[display.name] {
            guard rotation != .standard else {
                PresentedRotationPreferences.setRotation(.standard, for: display.name)
                endPresentation(for: display.name)
                return completion(true)
            }
            rotateStreamingDisplay(id: presentation.standInID, to: rotation) { done in
                if done {
                    presentation.rotation = rotation
                    PresentedRotationPreferences.setRotation(rotation, for: display.name)
                }
                completion(done)
            }
        } else if !hasVirtualAnchor(for: display.name), SystemRotation.canRotate(display.cgDisplayID) {
            completion(SystemRotation.set(rotation, for: display.cgDisplayID))
        } else {
            startPresentation(on: display, rotation: rotation) { done in
                if done { PresentedRotationPreferences.setRotation(rotation, for: display.name) }
                completion(done)
            }
        }
    }

    /// Where the screens stand-ins cover go when the displays are arranged: past the right
    /// edge of the rest, top-aligned, one after another, out of the way of the pointer.
    func coveredScreenOrigins(besides origins: [CGDirectDisplayID: CGPoint]) -> [CGDirectDisplayID: CGPoint] {
        let covered = rotatedPresentations.values.map(\.screenID).filter { $0 != 0 && origins[$0] == nil }
        var x = origins.map { $0.value.x + CGDisplayBounds($0.key).width }.max() ?? 0
        var parked: [CGDirectDisplayID: CGPoint] = [:]
        for id in covered {
            parked[id] = CGPoint(x: x, y: 0)
            x += CGDisplayBounds(id).width
        }
        return parked
    }

    /// Turns a display that came back the way it was last turned through a stand-in, once
    /// it has settled; once per connection.
    private func restorePresentations() {
        // A display that went keeps no try: it often comes back under the same ID.
        let live = Set((allAirPlayDevices + allConnectedDisplays).filter { $0.isConnected && $0.cgDisplayID != 0 }
            .map { "\($0.name)@\($0.cgDisplayID)" })
        presentationRestores.formIntersection(live)
        for display in allAirPlayDevices + allConnectedDisplays
        where display.isConnected && display.cgDisplayID != 0 && !display.isStreaming
            && rotatedPresentations[display.name] == nil {
            let saved = PresentedRotationPreferences.rotation(for: display.name)
            let connection = "\(display.name)@\(display.cgDisplayID)"
            guard saved != .standard, !presentationRestores.contains(connection) else { continue }
            presentationRestores.insert(connection)
            rotLog.debug("\(display.name, privacy: .public) was turned \(saved.rawValue); turning it again")
            // AirPlay and anchors move the displays about for some seconds after connecting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self,
                      let now = (self.allAirPlayDevices + self.allConnectedDisplays).first(where: {
                          $0.name == display.name && $0.cgDisplayID == display.cgDisplayID }),
                      PresentedRotationPreferences.rotation(for: now.name) == saved,
                      self.rotation(of: now) == .standard else { return }
                self.setRotation(saved, for: now)
            }
        }
    }

    /// The display a stand-in stands in for, by the stand-in's ID.
    func standInTarget(of standInID: CGDirectDisplayID) -> CGDirectDisplayID? {
        guard standInID != 0,
              let name = rotatedPresentations.first(where: { $0.value.standInID == standInID })?.key else { return nil }
        return (allAirPlayDevices + allConnectedDisplays).first { $0.name == name }?.cgDisplayID
    }

    /// Makes a stand-in for `display`, turned, takes its place on the desktop, and shows it on
    /// the display's screen.
    private func startPresentation(on display: DisplayInfo, rotation: DisplayRotation,
                                   completion: @escaping (Bool) -> Void) {
        let screenID = resolutionControlID(for: display)
        guard let mode = CGDisplayCopyDisplayMode(screenID) else { return completion(false) }
        let rate = Int(mode.refreshRate.rounded())
        let presentation = RotatedPresentation(name: display.name, screenID: screenID, rotation: rotation,
                                               width: mode.pixelWidth, height: mode.pixelHeight,
                                               fps: rate > 0 ? rate : 60)
        rotatedPresentations[display.name] = presentation
        rotLog.debug("stand-in for \(display.name, privacy: .public) on \(screenID) at \(rotation.rawValue)")
        createStandInDisplay(mode: presentation.standInMode,
                             standIn: StandIn(name: display.name, rotation: rotation)) { [weak self] id in
            guard let self else { return }
            // Ended or replaced while the stand-in was made: it would be a desktop nobody shows.
            guard self.rotatedPresentations[display.name] === presentation else {
                if let id { self.removeStreamingDisplay(id: id) }
                return completion(false)
            }
            guard let id else {
                self.rotatedPresentations[display.name] = nil
                return completion(false)
            }
            presentation.standInID = id
            presentation.onStop = { [weak self] in self?.endPresentation(for: display.name) }
            self.putStandIn(id, inPlaceOf: screenID)
            presentation.start()
            self.mergeDevices()
            completion(true)
        }
    }

    /// Puts the stand-in where the screen it covers was, and that screen where the stand-in
    /// was placed, past the others, so the pointer goes from the other displays onto the
    /// stand-in as it went onto the screen.
    private func putStandIn(_ standInID: CGDirectDisplayID, inPlaceOf screenID: CGDirectDisplayID) {
        let swapped = DisplayArrangement.current().replacingOrigins([
            standInID: CGDisplayBounds(screenID).origin,
            screenID: CGDisplayBounds(standInID).origin
        ])
        streamingSettle = (swapped, Date().addingTimeInterval(5))
        reassertStreamingLayout()
    }

    /// Stops showing the display named `name` turned, and removes its stand-in.
    func endPresentation(for name: String) {
        guard let presentation = rotatedPresentations.removeValue(forKey: name) else { return }
        rotLog.debug("end stand-in for \(name, privacy: .public)")
        presentation.stop()
        if presentation.standInID != 0 { removeStreamingDisplay(id: presentation.standInID) }
        mergeDevices()
    }

    /// Ends the presentations whose display or stand-in went away, and hands main to a
    /// stand-in when the screen it covers became main, as when the user made the display
    /// main in System Settings: the covered screen's menu bar can't be seen.
    func keepPresentations() {
        let online = Set(DisplayArrangement.onlineDisplayIDs())
        for (name, presentation) in rotatedPresentations
        where !online.contains(presentation.screenID)
            || (presentation.standInID != 0 && !online.contains(presentation.standInID)) {
            endPresentation(for: name)
        }
        restorePresentations()
        for (name, presentation) in rotatedPresentations
        where presentation.standInID != 0 && CGDisplayIsMain(presentation.screenID) != 0 && !presentation.handingMainBack {
            guard let display = (allAirPlayDevices + allConnectedDisplays).first(where: { $0.name == name }) else { continue }
            rotLog.debug("\(name, privacy: .public)'s covered screen is main; making its stand-in main")
            presentation.handingMainBack = true
            setMainDisplay(display) { _ in presentation.handingMainBack = false }
        }
    }
}
