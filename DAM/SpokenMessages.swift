//
//  SpokenMessages.swift
//
//  Every message the app speaks (and shows as a caption), in one place. Edit the English
//  text here; it is also the lookup key in en.lproj/Localizable.strings, so change the
//  key and value there to match. To translate, add a language in the project's Info tab
//  (or copy en.lproj to <lang>.lproj and add it to the Localizable.strings variant group)
//  and translate the values; Product > Export Localizations also produces an XLIFF from
//  these calls. Interpolated values (\(label) etc.) are %@ / %lld in the keys; use
//  %1$@, %2$@ in a translation to reorder them. Changing an English string here makes it
//  a new key, so its existing translations need redoing.
//
//  Names, addresses and error.localizedDescription from the system are passed in, not
//  written here.
//

import Foundation

enum Spoken {

    // MARK: - Connecting

    static func connecting(to label: String) -> String {
        String(localized: "Connecting to \(label)", comment: "Spoken when a display or iPad starts connecting")
    }

    /// `link` is the iPad's connection, e.g. "USB" or "Wi-Fi".
    static func connecting(to label: String, over link: String) -> String {
        String(localized: "Connecting to \(label) over \(link)",
               comment: "Spoken when an iPad starts connecting; the second value is USB or Wi-Fi")
    }

    static func selected(_ label: String) -> String {
        String(localized: "Selected \(label)", comment: "Spoken after an AirPlay display is turned on in Screen Mirroring")
    }

    static let noAirPlayOrIPads = String(localized: "No AirPlay displays or iPads found",
                                         comment: "Quick-connect hotkey with nothing to connect to")

    static func alreadyConnected(to label: String) -> String {
        String(localized: "Already connected to \(label)", comment: "Quick-connect hotkey when the only display is connected")
    }

    static let allAlreadyConnected = String(localized: "All displays already connected",
                                            comment: "Quick-connect hotkey when every display is connected")

    /// "Select a display. 1. Living Room TV. 2. pad"
    static func selectDisplay(_ labels: [String]) -> String {
        let list = labels.enumerated()
            // Only the first nine have a number: no key picks the others.
            .map { $0.offset < 9
                ? String(localized: "\($0.offset + 1). \($0.element)", comment: "One numbered display in the spoken list")
                : $0.element }
            .joined(separator: ". ")
        return String(localized: "Select a display. \(list)", comment: "Quick-connect hotkey; followed by the numbered list")
    }

    static func needsAccessibility(appName: String) -> String {
        String(localized: "\(appName) needs Accessibility access to connect AirPlay. Allow it in Privacy and Security settings, or use Screen Mirroring in Control Center",
               comment: "Connecting AirPlay without Accessibility permission")
    }

    // MARK: - Disconnecting

    static func deselected(_ label: String) -> String {
        String(localized: "Deselected \(label)", comment: "Spoken after an AirPlay display is turned off in Screen Mirroring")
    }

    static func disconnecting(_ label: String) -> String {
        String(localized: "Disconnecting \(label)", comment: "Spoken when an iPad starts disconnecting")
    }

    // MARK: - Screen Mirroring

    static let screenMirroringBusy = String(localized: "Screen Mirroring is still changing. Try again in a moment",
                                            comment: "Screen Mirroring is busy with another change")

    static func notInScreenMirroring(_ name: String) -> String {
        String(localized: "\(name) is not listed in Screen Mirroring. Check that it is on and nearby",
               comment: "The AirPlay display is missing from Screen Mirroring")
    }

    static let controlCenterNotRunning = String(localized: "Control Center is not running. Connect from Displays settings instead",
                                                comment: "Control Center is not running")

    static let couldNotOpenScreenMirroring = String(localized: "Could not open Screen Mirroring. Use Screen Mirroring in Control Center instead",
                                                    comment: "The app could not open or press the Screen Mirroring panel")

    // MARK: - Display errors

    static let displayNotConnected = String(localized: "The display is not connected", comment: "Display error")
    static let noOtherDisplayToMirror = String(localized: "No other display to mirror", comment: "Display error")
    static let displayChangeFailed = String(localized: "The display change failed", comment: "Display error")
    static let displayChangeDidNotFinish = String(localized: "The display change did not finish", comment: "Display error")
    static let noOtherDisplay = String(localized: "No other display", comment: "Arrange or main display with only one display")

    // MARK: - Sidecar

    static func noLongerNearby(_ name: String) -> String {
        String(localized: "\(name) is no longer nearby", comment: "The iPad went away before connecting")
    }

    static let sidecarUnavailable = String(localized: "Sidecar is not available", comment: "Sidecar error")

    // MARK: - Rotation

    /// The name of a rotation, as the menu lists it and the rotation picker speaks it.
    static func rotation(_ rotation: DisplayRotation) -> String {
        switch rotation {
        case .standard:      return String(localized: "Standard", comment: "A display's normal rotation, as System Settings names it")
        case .quarter:       return String(localized: "90°", comment: "A display turned a quarter turn clockwise")
        case .half:          return String(localized: "180°", comment: "A display turned upside down")
        case .threeQuarters: return String(localized: "270°", comment: "A display turned three quarters clockwise")
        }
    }

    static func cannotRotate(_ label: String) -> String {
        String(localized: "\(label) cannot be rotated", comment: "Rotation hotkey on a display macOS can't turn")
    }

    static func couldNotRotate(_ label: String) -> String {
        String(localized: "Could not rotate \(label)", comment: "Turning a display failed")
    }

    // MARK: - Streaming display and Moonlight

    static let creatingStreamingDisplay = String(localized: "Creating a streaming display", comment: "Menu action")

    static func removing(_ label: String) -> String {
        String(localized: "Removing \(label)", comment: "Removing a streaming display")
    }

    /// `name` is the app's, e.g. "RustDesk".
    static func remoteSessionStarted(_ name: String) -> String {
        String(localized: "\(name) session started", comment: "Another app's remote session started; the value is the app")
    }

    static func remoteSessionEnded(_ name: String) -> String {
        String(localized: "\(name) session ended", comment: "Another app's remote session ended; the value is the app")
    }

    static let moonlightCanConnect = String(localized: "Moonlight can connect", comment: "Moonlight hosting turned on")
    static let moonlightCanNoLongerConnect = String(localized: "Moonlight can no longer connect", comment: "Moonlight hosting turned off")
    static let moonlightCouldNotStart = String(localized: "Moonlight could not start", comment: "Moonlight hosting failed with no reason")
    static let moonlightPortsInUse = String(localized: "Another app is using Moonlight's ports", comment: "Moonlight hosting failed")

    static func moonlightCouldNotStart(_ reason: String) -> String {
        String(localized: "Could not start: \(reason)", comment: "Moonlight hosting failed to start; the value is the system's reason")
    }

    static func moonlightStopped(_ reason: String) -> String {
        String(localized: "Stopped: \(reason)", comment: "Moonlight hosting stopped; the value is the system's reason")
    }

    static let browsersCanWatch = String(localized: "Browsers can watch", comment: "Browser stream turned on")
    static let browsersCanNoLongerWatch = String(localized: "Browsers can no longer watch", comment: "Browser stream turned off")
    static let browserStreamCouldNotStart = String(localized: "The browser stream could not start",
                                                   comment: "Browser stream failed with no reason")

    static let browserWantsToPair = String(localized: "A browser wants to watch. Type the code it shows.",
                                           comment: "Shown with the browser pairing prompt")

    static let moonlightWantsToPair = String(localized: "Moonlight wants to pair. Type the PIN it shows.",
                                             comment: "Shown with the pairing PIN prompt")

    static let copiedLink = String(localized: "Copied the link", comment: "A player link for the browser stream was copied")

    static func copied(_ address: String) -> String {
        String(localized: "Copied \(address)", comment: "The player page address was copied")
    }

    static func forgot(_ name: String) -> String {
        String(localized: "Forgot \(name)", comment: "A Moonlight device was unpaired")
    }

    // MARK: - Pickers

    static let noAirPlayDisplayConnected = String(localized: "No AirPlay display connected", comment: "Mirror picker with nothing to mirror")
    static let noAudioOutputs = String(localized: "No audio outputs enabled", comment: "Audio output picker with nothing to pick")

    static func follows(_ label: String, _ master: String) -> String {
        String(localized: "\(label) follows \(master)", comment: "Resolution picker on a display that mirrors another")
    }

    static func noOtherResolution(for label: String) -> String {
        String(localized: "No other resolution for \(label)", comment: "Resolution picker with one resolution")
    }

    // MARK: - Arrange

    /// The arrange preview's sentence, e.g. "<moving> left of <other>", where both are
    /// display names: "tv left of LEN T24i-20".
    static func placed(_ moving: String, _ side: PlacementSide, _ other: String) -> String {
        switch side {
        case .left:  return String(localized: "\(moving) left of \(other)", comment: "Arrange preview: the first value is the display being moved, the second the display it is placed next to")
        case .right: return String(localized: "\(moving) right of \(other)", comment: "Arrange preview: the first value is the display being moved, the second the display it is placed next to")
        case .above: return String(localized: "\(moving) above \(other)", comment: "Arrange preview: the first value is the display being moved, the second the display it is placed next to")
        case .below: return String(localized: "\(moving) below \(other)", comment: "Arrange preview: the first value is the display being moved, the second the display it is placed next to")
        }
    }

    // MARK: - Debug

    static let checkingScreenMirroring = String(localized: "Checking Screen Mirroring", comment: "Debug menu")

    static func screenMirroringCheck(ok: Bool, saved: Bool) -> String {
        switch (ok, saved) {
        case (true, true):   return String(localized: "Screen Mirroring works. Report saved on the Desktop", comment: "Debug menu")
        case (true, false):  return String(localized: "Screen Mirroring works. The report could not be saved", comment: "Debug menu")
        case (false, true):  return String(localized: "Screen Mirroring failed. Report saved on the Desktop", comment: "Debug menu")
        case (false, false): return String(localized: "Screen Mirroring failed. The report could not be saved", comment: "Debug menu")
        }
    }

    static let captionPreview = String(localized: "Mirroring Living Room TV", comment: "Debug menu: sample caption")
}
