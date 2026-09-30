import Foundation

enum LegacyMigration {
    private static let migrationKey = "whisprGo.brandMigrationVersion"
    private static let currentVersion = 1
    private static let legacyBundleID = "com.whisprflow.app"
    private static let explicitKeys = [
        "selectedModelID",
        "appendTrailingSpace",
        "keepMicrophoneActive",
        "defaultModelVersion",
    ]

    static func run() {
        let current = UserDefaults.standard
        guard current.integer(forKey: migrationKey) < currentVersion else { return }

        if let legacy = UserDefaults(suiteName: legacyBundleID) {
            for key in explicitKeys where current.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) {
                    current.set(value, forKey: key)
                }
            }

            for (key, value) in legacy.dictionaryRepresentation()
            where (key.hasPrefix("modelCache.path.") || key.hasPrefix("modelCache.storage."))
                && current.object(forKey: key) == nil
            {
                current.set(value, forKey: key)
            }
        }

        current.set(currentVersion, forKey: migrationKey)
    }
}
