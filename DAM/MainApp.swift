//
//  MainApp.swift
//

import SwiftUI

/// Starts the app, or, run with a command (see ControlSocket.swift), sends it to the app
/// that is running and exits.
@main
enum Launch {
    static func main() {
        if ControlCLI.isCommand(CommandLine.arguments) { exit(ControlCLI.run(CommandLine.arguments)) }
        MainApp.main()
    }
}

struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
