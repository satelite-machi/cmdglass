//
//  MenuPalette.swift
//  Meuwidget
//
//  The palette's rows and the order they are shown in.
//

import Foundation

/// One row of the palette.
struct PaletteRow: Identifiable, Equatable, Sendable {
    /// The command's position in the list it came from.
    let id: Int
    /// Menu, submenus and command. What a row is matched to a live command by.
    let path: [String]
    let fullTitle: String
    let shortcut: String?
    /// What the scan saw. It only dims the row: whether the command runs is
    /// decided when it is confirmed.
    let isEnabled: Bool
    /// The command's own title, folded for matching once here rather than on
    /// every keystroke.
    let searchTitle: String
    /// The whole path, folded the same way.
    let searchPath: String

    init(id: Int, path: [String], fullTitle: String, shortcut: String?, isEnabled: Bool) {
        self.id = id
        self.path = path
        self.fullTitle = fullTitle
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        searchTitle = PaletteRanking.fold(path.last ?? fullTitle)
        searchPath = PaletteRanking.fold(path.joined(separator: " "))
    }

    init(id: Int, command: MenuCommand) {
        self.init(
            id: id,
            path: command.path,
            fullTitle: command.fullTitle,
            shortcut: command.shortcut?.displayString,
            isEnabled: command.isEnabled
        )
    }

    init(id: Int, cached: CachedMenuCommand) {
        self.init(
            id: id,
            path: cached.path,
            fullTitle: cached.fullTitle,
            shortcut: cached.shortcutDisplay,
            isEnabled: cached.isEnabled
        )
    }
}

/// Orders palette rows: how well they match the query first, then how often
/// the command was used, then how recently, then menu order.
enum PaletteRanking {
    static func rank(_ rows: [PaletteRow], query: String, usage: [[String]: MenuCommandUsage]) -> [PaletteRow] {
        let foldedQuery = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let scored: [(row: PaletteRow, relevance: Int, usage: MenuCommandUsage?)] = rows.compactMap { row in
            guard let relevance = relevance(of: row, foldedQuery: foldedQuery) else { return nil }
            return (row, relevance, usage[row.path])
        }
        return scored.sorted { lhs, rhs in
            if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
            let lhsCount = lhs.usage?.count ?? 0
            let rhsCount = rhs.usage?.count ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            let lhsLastUsed = lhs.usage?.lastUsed ?? .distantPast
            let rhsLastUsed = rhs.usage?.lastUsed ?? .distantPast
            if lhsLastUsed != rhsLastUsed { return lhsLastUsed > rhsLastUsed }
            return lhs.row.id < rhs.row.id
        }
        .map(\.row)
    }

    /// How well `row` matches an already folded query, higher is better, or
    /// `nil` when it does not match. An empty query matches every row equally.
    ///
    /// The command's own title counts for more than the menus above it:
    /// "Export" should find File > Export before Export > PDF.
    static func relevance(of row: PaletteRow, foldedQuery query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let title = row.searchTitle
        if title == query { return 5 }
        if title.hasPrefix(query) { return 4 }
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(query) }) { return 3 }
        if title.contains(query) { return 2 }
        let tokens = query.split(separator: " ")
        if !tokens.isEmpty, tokens.allSatisfy({ row.searchPath.contains($0) }) { return 1 }
        return nil
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
