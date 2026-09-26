//
//  AppSupportDirectory.swift
//  Wanna
//
//  The one place that knows where this app keeps its files under
//  `~/Library/Application Support/`.
//
//  Every store used to build that path itself: fifteen copies of the same
//  literal, in two shapes (`appendingPathComponent("Wanna", isDirectory:)` for
//  the folder, and `appendingPathComponent("Wanna/文件名")` for a file inside
//  it). Two shapes meant a grep for one of them missed five sites — which is
//  exactly how a rename leaves one store still reading the old directory and
//  silently starting from defaults. They all resolve through here now.
//
//  A one-shot migration from the folder's previous name used to live here. It
//  was removed on 2026-09-26 along with every other trace of that name: this
//  machine's older folder no longer exists, so the migration had nothing left
//  to find, and a branch that can only do nothing is worse than no branch —
//  it says the old name is still meaningful when it is not. Adding a migration
//  back is only worth it if that folder ever exists again.
//

import Foundation

nonisolated enum AppSupportDirectory {

    /// The folder this app writes under Application Support.
    static let folderName = "Wanna"

    /// `~/Library/Application Support/Wanna`.
    static let folderURL: URL? = {
        guard let applicationSupportDirectory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }

        return applicationSupportDirectory
            .appendingPathComponent(folderName, isDirectory: true)
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
}
