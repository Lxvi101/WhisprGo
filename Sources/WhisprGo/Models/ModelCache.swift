import Foundation

enum ModelCache {
    private static let pathPrefix = "modelCache.path."
    private static let storagePrefix = "modelCache.storage."
    private static let appSupportFolderName = "WhisprGo"
    private static let legacyAppSupportFolderName = "Whispr Flow"
    private static let parakeetModelID = "local.parakeet.v3"
    private static let parakeetFolderName = "parakeet-tdt-0.6b-v3"

    enum CacheError: LocalizedError {
        case unsafeRemovalPath

        var errorDescription: String? {
            "WhisprGo refused to remove a model outside its own model folder."
        }
    }

    private static func modelsRoot() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport
            .appendingPathComponent(appSupportFolderName, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try migrateLegacyModels(in: applicationSupport, to: root)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    /// A private root for one model. Keeping downloads isolated makes removal
    /// complete and prevents one model's cache cleanup from touching another.
    static func downloadRoot(for modelID: String) throws -> URL {
        let root = try modelsRoot().appendingPathComponent(
            safePathComponent(modelID),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        UserDefaults.standard.set(root.path, forKey: storagePrefix + modelID)
        return root
    }

    static func parakeetDirectory(for modelID: String) throws -> URL {
        try downloadRoot(for: modelID)
            .appendingPathComponent(parakeetFolderName, isDirectory: true)
    }

    static func cachedFolder(for modelID: String) -> URL? {
        // Trigger the one-time brand migration before resolving persisted
        // paths so a selected model moves without being downloaded again.
        let migratedModelsRoot = try? modelsRoot()
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: pathPrefix + modelID),
           FileManager.default.fileExists(atPath: path)
        {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        // Early builds recorded FluidAudio's remote repository name, which
        // ends in "-coreml". Its local cache intentionally drops that suffix.
        // Repair the pointer without downloading a second 469 MB model.
        guard modelID == parakeetModelID else { return nil }
        let storageRoot: URL
        if let storedRoot = defaults.string(forKey: storagePrefix + modelID) {
            storageRoot = URL(fileURLWithPath: storedRoot, isDirectory: true)
        } else if let root = migratedModelsRoot {
            storageRoot = root.appendingPathComponent(
                safePathComponent(modelID),
                isDirectory: true
            )
        } else {
            return nil
        }

        let repaired = storageRoot.appendingPathComponent(
            parakeetFolderName,
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: repaired.path) else { return nil }
        defaults.set(storageRoot.path, forKey: storagePrefix + modelID)
        defaults.set(repaired.path, forKey: pathPrefix + modelID)
        return repaired
    }

    static func record(folder: URL, for modelID: String) {
        UserDefaults.standard.set(folder.path, forKey: pathPrefix + modelID)
    }

    static func isDownloaded(_ modelID: String) -> Bool {
        cachedFolder(for: modelID) != nil
    }

    static func removeDownload(for modelID: String) throws {
        let root = try modelsRoot().standardizedFileURL
        let defaults = UserDefaults.standard
        let storedRoot = defaults.string(forKey: storagePrefix + modelID)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let legacyFolder = cachedFolder(for: modelID)
        let target = storedRoot ?? legacyFolder

        if let target {
            let standardizedTarget = target.standardizedFileURL
            let allowedPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard standardizedTarget.path.hasPrefix(allowedPrefix) else {
                throw CacheError.unsafeRemovalPath
            }
            if FileManager.default.fileExists(atPath: standardizedTarget.path) {
                try FileManager.default.removeItem(at: standardizedTarget)
            }
        }

        defaults.removeObject(forKey: pathPrefix + modelID)
        defaults.removeObject(forKey: storagePrefix + modelID)
    }

    private static func safePathComponent(_ modelID: String) -> String {
        String(modelID.map { character in
            character.isLetter || character.isNumber ? character : "_"
        })
    }

    /// Early builds stored models under the former product name. Moving the
    /// directory on the same volume is effectively instant, so upgrading does
    /// not redownload or duplicate multi-hundred-megabyte model bundles.
    private static func migrateLegacyModels(
        in applicationSupport: URL,
        to destination: URL
    ) throws {
        let fileManager = FileManager.default
        let legacy = applicationSupport
            .appendingPathComponent(legacyAppSupportFolderName, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        guard fileManager.fileExists(atPath: legacy.path) else { return }

        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacy, to: destination)
        } else {
            let legacyDownloads = try fileManager.contentsOfDirectory(
                at: legacy,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for download in legacyDownloads {
                let migrated = destination.appendingPathComponent(
                    download.lastPathComponent,
                    isDirectory: true
                )
                guard !fileManager.fileExists(atPath: migrated.path) else { continue }
                try fileManager.moveItem(at: download, to: migrated)
            }
        }

        rewriteCachedPaths(from: legacy, to: destination)
    }

    private static func rewriteCachedPaths(from legacy: URL, to destination: URL) {
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix(pathPrefix) || key.hasPrefix(storagePrefix),
                  let path = value as? String,
                  path == legacy.path || path.hasPrefix(legacy.path + "/")
            else { continue }

            let suffix = String(path.dropFirst(legacy.path.count))
            let migrated = destination.path + suffix
            if FileManager.default.fileExists(atPath: migrated) {
                defaults.set(migrated, forKey: key)
            }
        }
    }
}
