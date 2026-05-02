//
//  boarApp.swift
//  boar
//

import SwiftUI

@main
struct boarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
