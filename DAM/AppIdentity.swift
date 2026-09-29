//
//  AppIdentity.swift
//
//  Single source of truth for the app's name and identifiers.
//  To rename the app, change APP_NAME (and optionally APP_BUNDLE_PREFIX)
//  in the project-level build settings; everything below derives from
//  the generated Info.plist.
//

import Foundation

enum AppIdentity {
    /// User-visible app name (APP_NAME → CFBundleDisplayName).
    static let name: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? ProcessInfo.processInfo.processName

    /// Reverse-DNS bundle identifier (APP_BUNDLE_ID), e.g. AppIdentity.bundleID.
    static let bundleID: String = Bundle.main.bundleIdentifier ?? "local.\(shortID)"

    /// Lowercase short identifier, e.g. "dam". Namespaces defaults keys and UI identifiers.
    static let shortID: String =
        Bundle.main.bundleIdentifier?.split(separator: ".").last.map(String.init)
        ?? name.lowercased()

    /// Four-character code derived from the name (e.g. "DAM "), for Carbon hotkey signatures.
    static let fourCharCode: FourCharCode = {
        let chars = Array((name.uppercased().filter(\.isASCII) + "    ").utf8.prefix(4))
        return chars.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }()
}
