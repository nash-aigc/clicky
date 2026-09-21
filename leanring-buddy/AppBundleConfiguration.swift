//
//  AppBundleConfiguration.swift
//  leanring-buddy
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation

enum AppBundleConfiguration {
    /// Name of the gitignored plist that holds secrets (API keys) kept out of
    /// version control. It lives alongside the other sources and is copied into
    /// the app bundle automatically, so it can be read the same way as Info.plist.
    private static let secretsResourceName = "BailianSecrets"

    static func stringValue(forKey key: String) -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        if let infoPlistValue = stringValueFromBundledPlist(resourceName: "Info", forKey: key) {
            return infoPlistValue
        }

        // Secrets are stored in a separate, gitignored plist so the API key never
        // ends up in a tracked file. Checked last so Info.plist still wins if both
        // happen to define the same key.
        if let bundledSecretsValue = stringValueFromBundledPlist(resourceName: secretsResourceName, forKey: key) {
            return bundledSecretsValue
        }

        return stringValueFromApplicationSupportPlist(forKey: key)
    }

    private static func stringValueFromBundledPlist(resourceName: String, forKey key: String) -> String? {
        guard let plistPath = Bundle.main.path(forResource: resourceName, ofType: "plist"),
              let plistContents = NSDictionary(contentsOfFile: plistPath),
              let value = plistContents[key] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    /// Absolute path of the out-of-bundle secrets file, or nil if the Application
    /// Support directory can't be resolved.
    static var applicationSupportSecretsPath: String? {
        guard let applicationSupportDirectory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }

        return applicationSupportDirectory
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("\(secretsResourceName).plist")
            .path
    }

    /// Last-resort fallback that does not depend on Xcode copying
    /// `BailianSecrets.plist` into the app bundle.
    ///
    /// Whether a loose `.plist` inside the synchronized source folder is copied
    /// into the bundle is not something the project can verify without building,
    /// and an unreadable API key is a hard failure for every feature in the app.
    /// Reading the same file from Application Support means the key is found
    /// whether or not the bundling copy happens. See README for how to install it.
    private static func stringValueFromApplicationSupportPlist(forKey key: String) -> String? {
        guard let secretsPath = applicationSupportSecretsPath,
              let plistContents = NSDictionary(contentsOfFile: secretsPath),
              let value = plistContents[key] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
