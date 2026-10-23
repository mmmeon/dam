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
            let done = SystemRotation.set(rotation, for: display.cgDisplayID)
            // macOS keeps this one, and one undone in System Settings stays undone: a rotation
            // saved from a stand-in shown on it before (with an anchor, say) would turn it again
            // on every connection.
            if done { PresentedRotationPreferences.setRotation(.standard, for: display.name) }
            completion(done)
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

    /// The displays among `displays` to turn again as they were last turned through a stand-in,
    /// with the rotation saved for each, and the connections ("name@id") tried from now on:
    /// each display connected, not streaming and not shown turned already (`shown`, by name)
    /// whose rotation `saved` isn't standard, once per connection in `tried`. A connection
    /// that went keeps no try: a display often comes back under the same ID.
    static func presentationRestores(displays: [DisplayInfo], shown: Set<String>, tried: Set<String>,
                                     saved: (String) -> DisplayRotation)
        -> (restore: [(display: DisplayInfo, rotation: DisplayRotation)], tried: Set<String>) {
        let connected = displays.filter { $0.isConnected && $0.cgDisplayID != 0 }
        var tried = tried.intersection(connected.map { "\($0.name)@\($0.cgDisplayID)" })
        var restore: [(display: DisplayInfo, rotation: DisplayRotation)] = []
        for display in connected where !display.isStreaming && !shown.contains(display.name) {
            let rotation = saved(display.name)
            let connection = "\(display.name)@\(display.cgDisplayID)"
            guard rotation != .standard, tried.insert(connection).inserted else { continue }
            restore.append((display, rotation))
        }
        return (restore, tried)
    }

    /// Turns a display that came back the way it was last turned through a stand-in, once
    /// it has settled; once per connection.
    private func restorePresentations() {
        let plan = Self.presentationRestores(displays: allAirPlayDevices + allConnectedDisplays,
                                             shown: Set(rotatedPresentations.keys), tried: presentationRestores,
                                             saved: PresentedRotationPreferences.rotation(for:))
        presentationRestores = plan.tried
        for (display, saved) in plan.restore {
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
        swapPlaces(standInID, screenID)
    }

    /// The origins that swap the places of displays `a` and `b`, by where they are in `origins`;
    /// none when either isn't there.
    static func swappedOrigins(_ a: CGDirectDisplayID, _ b: CGDirectDisplayID,
                               in origins: [CGDirectDisplayID: CGPoint]) -> [CGDirectDisplayID: CGPoint] {
        guard a != b, let atA = origins[a], let atB = origins[b] else { return [:] }
        return [a: atB, b: atA]
    }

    /// Swaps the places of a stand-in and the screen it covers, held for a moment by the layout
    /// kept after a streaming change. Committed here, not by putting that layout back: it
    /// leaves an anchor's place to the anchor, and a screen an anchor drives is the anchor.
    private func swapPlaces(_ standInID: CGDirectDisplayID, _ screenID: CGDirectDisplayID) {
        let live = DisplayArrangement.current()
        let swapped = Self.swappedOrigins(standInID, screenID, in: live.origins)
        guard !swapped.isEmpty else { return }
        streamingSettle = (live.replacingOrigins(swapped), Date().addingTimeInterval(5))
        // As a reassert: streaming changes wait for it, and it looks again once it has landed.
        let start = Self.configureDisplays(in: .permanently, { cfg in
            for (id, origin) in swapped { CGConfigureDisplayOrigin(cfg, id, Int32(origin.x), Int32(origin.y)) }
            return true
        }) { [weak self] err in
            rotLog.debug("swap \(standInID) and \(screenID): err=\(err.rawValue)")
            guard let self else { return }
            self.streamingReassertInFlight = false
            self.reassertStreamingLayout()
            self.processStreamingRequests()
        }
        if case .committing = start { streamingReassertInFlight = true }
    }

    /// Stops showing the display named `name` turned, and removes its stand-in. The screen it
    /// covered goes back where the stand-in was, its own place, before the stand-in goes.
    func endPresentation(for name: String) {
        guard let presentation = rotatedPresentations.removeValue(forKey: name) else { return }
        rotLog.debug("end stand-in for \(name, privacy: .public)")
        presentation.stop()
        if presentation.standInID != 0 {
            let online = DisplayArrangement.onlineDisplayIDs()
            if online.contains(presentation.standInID), online.contains(presentation.screenID) {
                swapPlaces(presentation.standInID, presentation.screenID)
            }
            removeStreamingDisplay(id: presentation.standInID)
        }
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
