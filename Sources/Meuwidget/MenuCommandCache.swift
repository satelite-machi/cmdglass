//
//  MenuCommandCache.swift
//  Meuwidget
//
//  What the palette remembers between presses: menu command titles on disk,
//  per app and version, in the droplet's own container.
//
//  Only what can be shown is written: the path, the joined title, whether the
//  item was enabled and its shortcut label. The AX reference never is; it only
//  means something inside this process, while the app keeps that menu.
//

import Foundation

/// Which app, at which version, a cached menu belongs to.
public struct MenuCacheKey: Codable, Sendable, Hashable {
    public let bundleIdentifier: String
    /// `CFBundleShortVersionString (CFBundleVersion)`, or whichever of the two
    /// the app has.
    public let version: String

    public init(bundleIdentifier: String, version: String) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
    }

    /// The key for a scan target, or `nil` when the app has no bundle
    /// identifier to key on.
    ///
    /// The version is read from the app's Info.plist on disk rather than
    /// through `Bundle`, which keeps one instance per path for the life of the
    /// process and so could go on reporting the version from before an update.
    public static func resolve(for target: MenuScanTarget) -> MenuCacheKey? {
        guard let bundleIdentifier = target.bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return MenuCacheKey(bundleIdentifier: bundleIdentifier, version: version(ofBundleAt: target.bundleURL))
    }

    private static func version(ofBundleAt bundleURL: URL?) -> String {
        guard let plistURL = bundleURL?.appending(path: "Contents/Info.plist", directoryHint: .notDirectory),
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return "unknown"
        }
        let shortVersion = plist["CFBundleShortVersionString"] as? String
        let build = plist["CFBundleVersion"] as? String
        switch (shortVersion, build) {
        case let (shortVersion?, build?) where shortVersion != build: return "\(shortVersion) (\(build))"
        case let (shortVersion?, _): return shortVersion
        case let (nil, build?): return build
        case (nil, nil): return "unknown"
        }
    }
}

/// One command as the disk cache keeps it.
public struct CachedMenuCommand: Codable, Sendable, Equatable {
    public let path: [String]
    public let fullTitle: String
    public let isEnabled: Bool
    /// ``MenuKeyboardShortcut/displayString`` at the time of the scan.
    public let shortcutDisplay: String?

    public init(_ command: MenuCommand) {
        path = command.path
        fullTitle = command.fullTitle
        isEnabled = command.isEnabled
        shortcutDisplay = command.shortcut?.displayString
    }
}

/// A scan's commands, as written to disk.
public struct CachedMenu: Codable, Sendable {
    public let schemaVersion: Int
    public let key: MenuCacheKey
    public let scannedAt: Date
    public let isTruncated: Bool
    public let commands: [CachedMenuCommand]

    public init(key: MenuCacheKey, result: MenuScanResult, scannedAt: Date = Date()) {
        schemaVersion = MenuCommandDiskCache.schemaVersion
        self.key = key
        self.scannedAt = scannedAt
        isTruncated = result.isTruncated
        commands = result.commands.map(CachedMenuCommand.init)
    }
}

/// The on-disk menu cache: one JSON file per app version, under
/// `<container>/menu-cache/<bundle id>/<version>.json`.
///
/// An actor, so a clear and a write never interleave and the file work stays
/// off the main actor.
public actor MenuCommandDiskCache {
    public static let schemaVersion = 1

    private let directory: URL

    /// Bumped by ``removeAll()``. A write carries the value it read before its
    /// scan started, and is dropped when a clear happened since, so a scan that
    /// was already running cannot put back what the user just deleted.
    public private(set) var generation = 0

    public init(containerDirectory: URL) {
        directory = containerDirectory.appending(path: "menu-cache", directoryHint: .isDirectory)
    }

    /// The cached menu for `key`, or `nil`. A file that no longer decodes, or
    /// that was written by another schema, is deleted rather than returned.
    public func load(_ key: MenuCacheKey) -> CachedMenu? {
        let file = fileURL(for: key)
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let menu = try? JSONDecoder().decode(CachedMenu.self, from: data),
              menu.schemaVersion == Self.schemaVersion,
              menu.key == key else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return menu
    }

    /// Writes `menu`, replacing any other version cached for the same app.
    ///
    /// Returns `false`, having written nothing, when ``removeAll()`` ran after
    /// `expectedGeneration` was read.
    @discardableResult
    public func save(_ menu: CachedMenu, generation expectedGeneration: Int) throws -> Bool {
        guard expectedGeneration == generation else { return false }

        let fileManager = FileManager.default
        let folder = folderURL(for: menu.key.bundleIdentifier)
        let file = fileURL(for: menu.key)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        // One version per app: once it updates, the old version's menus are
        // only clutter.
        let existing = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for old in existing where old.lastPathComponent != file.lastPathComponent {
            try? fileManager.removeItem(at: old)
        }

        try JSONEncoder().encode(menu).write(to: file, options: .atomic)
        return true
    }

    /// Deletes every cached menu.
    public func removeAll() throws {
        generation += 1
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func folderURL(for bundleIdentifier: String) -> URL {
        directory.appending(path: Self.pathComponent(bundleIdentifier), directoryHint: .isDirectory)
    }

    private func fileURL(for key: MenuCacheKey) -> URL {
        folderURL(for: key.bundleIdentifier)
            .appending(path: Self.pathComponent(key.version) + ".json", directoryHint: .notDirectory)
    }

    /// One safe path component: ASCII letters, digits, `.`, `-` and `_`, never
    /// starting with a dot, so a version such as `../x` cannot leave the cache
    /// directory. Two keys that clean up to the same name are told apart by the
    /// key stored inside the file.
    static func pathComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars.prefix(120) {
            scalars.append(allowed.contains(scalar) ? scalar : "_")
        }
        var component = String(scalars)
        if component.hasPrefix(".") { component = "_" + component.dropFirst() }
        return component.isEmpty ? "_" : component
    }
}
