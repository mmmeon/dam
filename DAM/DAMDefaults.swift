//
//  DAMDefaults.swift
//
//  Where DAM keeps its preferences.
//

import Foundation

extension UserDefaults {
    /// Where DAM keeps its preferences. Under tests it's a store of their own, so tests
    /// neither see nor change the user's settings. Each test process gets its own, as tests
    /// run in parallel processes; it starts empty.
    static let dam: UserDefaults = {
        guard NSClassFromString("XCTestCase") != nil else { return .standard }
        removeStaleTestSuites()
        UserDefaults.standard.removePersistentDomain(forName: testSuite)
        return UserDefaults(suiteName: testSuite)!
    }()

    private static let testSuitePrefix = "\(AppIdentity.shortID).tests."
    private static let testSuite = testSuitePrefix + "\(getpid())"

    /// Test processes are killed rather than exiting, so a later run removes their stores
    /// once the process that made each is gone.
    private static func removeStaleTestSuites() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for file in files where file.hasPrefix(testSuitePrefix) && file.hasSuffix(".plist") {
            let suite = String(file.dropLast(".plist".count))
            guard let pid = pid_t(suite.dropFirst(testSuitePrefix.count)),
                  kill(pid, 0) != 0, errno == ESRCH else { continue }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
    }
}
