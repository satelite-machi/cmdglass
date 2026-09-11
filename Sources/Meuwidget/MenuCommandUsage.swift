//
//  MenuCommandUsage.swift
//  Meuwidget
//
//  How often, and how recently, the user ran each command, per app.
//
//  Kept apart from the menu cache on purpose. The cache describes one version
//  of an app and is thrown away when the app updates; what the user reaches
//  for survives an update. So this is keyed by bundle identifier and command
//  path only, never by version, and lives in its own file.
//

import Foundation

/// How often, and how recently, the user ran one command.
public struct MenuCommandUsage: Codable, Sendable, Equatable {
    public var count: Int
    public var lastUsed: Date

    public init(count: Int, lastUsed: Date) {
        self.count = count
        self.lastUsed = lastUsed
    }
}

/// Per-app command usage, in `<container>/menu-usage.json`.
///
/// An actor, so records never interleave and the file work stays off the main
/// actor. The file is read once, on first use, and rewritten on every record;
/// it holds counts and dates, so it stays small.
public actor MenuCommandUsageStore {
    /// Past this many commands for one app, the least recently used are
    /// forgotten, so the file stays small for an app used for years.
    public static let maximumCommandsPerApp = 500

    private static let schemaVersion = 1

    private struct StoredFile: Codable {
        let schemaVersion: Int
        let apps: [String: [Entry]]
    }

    private struct Entry: Codable {
        let path: [String]
        let count: Int
        let lastUsed: Date
    }

    private let file: URL
    /// Every app's usage, keyed by bundle identifier then path. `nil` until the
    /// file has been read.
    private var apps: [String: [[String]: MenuCommandUsage]]?

    public init(containerDirectory: URL) {
        file = containerDirectory.appending(path: "menu-usage.json", directoryHint: .notDirectory)
    }

    /// The usage recorded for one app, keyed by command path.
    public func usage(forBundleIdentifier bundleIdentifier: String) -> [[String]: MenuCommandUsage] {
        loadedApps()[bundleIdentifier] ?? [:]
    }

    /// Counts one run of the command at `path` in the app.
    public func recordUse(of path: [String], bundleIdentifier: String, at date: Date = Date()) throws {
        var all = loadedApps()
        var commands = all[bundleIdentifier] ?? [:]
        var usage = commands[path] ?? MenuCommandUsage(count: 0, lastUsed: date)
        usage.count += 1
        usage.lastUsed = date
        commands[path] = usage

        if commands.count > Self.maximumCommandsPerApp {
            let overflow = commands.count - Self.maximumCommandsPerApp
            for (stalePath, _) in commands.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }).prefix(overflow) {
                commands[stalePath] = nil
            }
        }

        all[bundleIdentifier] = commands
        apps = all
        try write(all)
    }

    /// Forgets every app's usage.
    public func removeAll() throws {
        apps = [:]
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: file)
    }

    private func loadedApps() -> [String: [[String]: MenuCommandUsage]] {
        if let apps { return apps }

        var loaded: [String: [[String]: MenuCommandUsage]] = [:]
        // A missing, unreadable or older file starts empty; the next record
        // replaces it.
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode(StoredFile.self, from: data),
           stored.schemaVersion == Self.schemaVersion {
            for (bundleIdentifier, entries) in stored.apps {
                var commands: [[String]: MenuCommandUsage] = [:]
                for entry in entries {
                    commands[entry.path] = MenuCommandUsage(count: entry.count, lastUsed: entry.lastUsed)
                }
                loaded[bundleIdentifier] = commands
            }
        }
        apps = loaded
        return loaded
    }

    private func write(_ all: [String: [[String]: MenuCommandUsage]]) throws {
        let stored = StoredFile(
            schemaVersion: Self.schemaVersion,
            apps: all.mapValues { commands in
                commands.map { Entry(path: $0.key, count: $0.value.count, lastUsed: $0.value.lastUsed) }
            }
        )
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: file, options: .atomic)
    }
}
