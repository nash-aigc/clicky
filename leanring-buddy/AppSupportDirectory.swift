//
//  AppSupportDirectory.swift
//  leanring-buddy
//
//  The one place that knows where this app keeps its files under
//  `~/Library/Application Support/` — and the one place that still knows the
//  folder used to be called something else.
//
//  Every store used to build that path itself: fifteen copies of the same
//  literal, in two shapes (`appendingPathComponent("Clicky", isDirectory:)` for
//  the folder, and `appendingPathComponent("Clicky/文件名")` for a file inside
//  it). Two shapes meant a grep for one of them missed five sites — which is
//  exactly how a rename leaves one store still reading the old directory and
//  silently starting from defaults. They all resolve through here now.
//
//  The migration hangs off `folderURL`'s lazy initializer rather than sitting in
//  `CompanionManager.start()`. A `static let` is initialised on first access,
//  and the first access IS some store's first read, so the move is guaranteed to
//  happen before anything reads a path — no matter which of the app's many
//  lazily built collaborators happens to touch a store first.
//

import Foundation

nonisolated enum AppSupportDirectory {

    /// The folder this app writes under Application Support.
    static let folderName = "Wanna"

    /// What that folder was called before the rename. Deliberately the only
    /// mention of the old name left in the app — it exists so the migration can
    /// find the data, and nothing else may depend on it.
    private static let legacyFolderName = "Clicky"

    /// `~/Library/Application Support/Wanna`, moving the old folder across the
    /// first time anything asks.
    static let folderURL: URL? = {
        guard let applicationSupportDirectory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }

        let currentFolder = applicationSupportDirectory
            .appendingPathComponent(folderName, isDirectory: true)
        let legacyFolder = applicationSupportDirectory
            .appendingPathComponent(legacyFolderName, isDirectory: true)

        migrateFolderIfNeeded(from: legacyFolder, to: currentFolder)

        return currentFolder
    }()

    /// A file inside the app's folder — `fileURL(named: "AppSettings.json")`.
    static func fileURL(named fileName: String) -> URL? {
        folderURL?.appendingPathComponent(fileName)
    }

    /// The same folder, for the callers that cannot express "no directory".
    ///
    /// The four stores that used `URLs(for:in:).first!` and the two that fell
    /// back to the home directory already had to answer this question; this is
    /// the answer they gave, kept in one place instead of six.
    static var folderURLOrHome: URL {
        folderURL ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Moves `Application Support/Clicky` to `Application Support/Wanna`, once.
    ///
    /// Idempotent and never fatal: it runs at most once per launch, does nothing
    /// unless the old folder is there and the new one is not, and a failure
    /// leaves the data where it was rather than deleting anything.
    private static func migrateFolderIfNeeded(from legacyFolder: URL, to currentFolder: URL) {
        let fileManager = FileManager.default
        var legacyFolderIsDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: legacyFolder.path, isDirectory: &legacyFolderIsDirectory),
              legacyFolderIsDirectory.boolValue else {
            return  // A fresh install, or a machine that has already migrated.
        }

        // Both folders present means this build has already run at least once.
        // Merging two live folders is not something this can do safely, and
        // numbering them (`Wanna.1`, `Wanna.2`) would split one user's data
        // across copies — so the old folder is left exactly where it is, and
        // the fact is said out loud rather than resolved by guessing.
        guard !fileManager.fileExists(atPath: currentFolder.path) else {
            print("⚠️ \(folderName): both \"\(legacyFolderName)\" and \"\(folderName)\" exist under Application Support — using \"\(folderName)\" and leaving \"\(legacyFolderName)\" untouched.")
            return
        }

        do {
            try fileManager.moveItem(at: legacyFolder, to: currentFolder)
            print("📦 \(folderName): moved \"\(legacyFolderName)/\" → \"\(folderName)/\" under Application Support")
        } catch {
            // The old data is still on disk and nothing was deleted; the stores
            // simply start from defaults in the new folder.
            print("⚠️ \(folderName): could not move \"\(legacyFolderName)/\" → \"\(folderName)/\": \(error)")
        }
    }
}
