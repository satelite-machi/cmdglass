//
//  MeuwidgetDroplet.swift
//  Meuwidget
//

import AppKit
import Combine
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(MeuwidgetPrincipal)
public final class MeuwidgetPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { MeuwidgetDroplet() }
}

// MARK: - Palette model

/// One row of the palette.
struct PaletteRow: Identifiable, Equatable, Sendable {
    /// The command's position in the list it came from.
    let id: Int
    let fullTitle: String
    let shortcut: String?
    let isEnabled: Bool

    init(id: Int, command: MenuCommand) {
        self.id = id
        fullTitle = command.fullTitle
        shortcut = command.shortcut?.displayString
        isEnabled = command.isEnabled
    }

    init(id: Int, cached: CachedMenuCommand) {
        self.id = id
        fullTitle = cached.fullTitle
        shortcut = cached.shortcutDisplay
        isEnabled = cached.isEnabled
    }
}

/// What the palette is doing, for the line it shows when it has no rows.
enum PaletteStatus: Equatable {
    /// Closed, or open with nothing loaded.
    case idle
    /// No other app was in front when the shortcut fired.
    case noTargetApp
    /// Accessibility is not granted, so the menus cannot be read.
    case needsAccessibility
    /// A scan is running. Rows, if any, are from the disk cache.
    case scanning
    /// The rows are from the scan that just finished.
    case ready
    /// The scan failed. Rows, if any, are from the disk cache.
    case failed
}

/// The latest scan's commands, with their live AX references.
///
/// Exists only while the surface is open, so the command the user picks can be
/// run without walking the menu bar again. Never written anywhere.
private struct LiveMenuCommands {
    let scanID: UUID
    let result: MenuScanResult
}

// MARK: - Droplet

/// Meu Widget.
@MainActor
public final class MeuwidgetDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "meuwidget"

    static let shortcutID = "open-commands"
    static let commandsSurfaceID: ExpandedSurfaceID = "commands"

    /// Cmd+Shift+Y. The key code is `kVK_ANSI_Y` and the modifiers are Carbon's
    /// `cmdKey | shiftKey`, written as literals so the droplet does not import
    /// Carbon. The host drops it if the user already has something on it.
    static let defaultShortcut = DropletKeyboardShortcut(keyCode: 0x10, modifiers: 0x0100 | 0x0200)

    private var host: DropletHost?
    private var diskCache: MenuCommandDiskCache?
    private let scanner = MenuCommandScanner()
    private var permissionTask: Task<Void, Never>?
    private var presentation: ExpandedSurfacePresentation?

    /// The palette opened by the latest shortcut press. Work that finishes for
    /// an older one is dropped.
    private var sessionID: UUID?
    private var sessionTask: Task<Void, Never>?
    private var liveCommands: LiveMenuCommands?
    /// The live scan `rows` came from, or `nil` while they come from the disk.
    private var rowsScanID: UUID?

    /// The search field's text. Cleared every time the surface opens.
    @Published var query = ""
    @Published private(set) var rows: [PaletteRow] = []
    @Published private(set) var status: PaletteStatus = .idle
    @Published private(set) var targetName: String?

    public func activate(host: DropletHost) throws {
        self.host = host
        diskCache = MenuCommandDiskCache(containerDirectory: host.environment.containerDirectory)
        // Needs `global-shortcuts`; without it the host refuses and logs, and
        // the shelf widget keeps working.
        host.shortcuts.register(
            id: Self.shortcutID,
            title: "Open menu commands",
            defaultShortcut: Self.defaultShortcut
        ) { [weak self] in
            self?.shortcutPressed()
        }
        host.log.info("Meu Widget activated")
    }

    public func deactivate() {
        // Everything activate() started is torn down here. Swift cannot unload
        // code, so anything left running keeps running until Droppy relaunches.
        permissionTask?.cancel()
        permissionTask = nil
        endSession()
        if presentation != nil {
            host?.notchSurface.dismissExpandedSurface(Self.commandsSurfaceID)
        }
        presentation = nil
        host?.shortcuts.unregister(id: Self.shortcutID)
        diskCache = nil
        host = nil
    }

    // MARK: Shortcut

    /// The shortcut's handler, and the only place in the droplet that checks or
    /// requests Accessibility: the permission is asked for when the user reaches
    /// for the feature, never at activation.
    private func shortcutPressed() {
        guard let host else { return }
        // Captured first: presenting the surface or a permission prompt can
        // change which app is in front.
        let target = Self.frontmostTarget()
        let status = host.permissions.status(for: .accessibility)
        switch status {
        case .granted:
            openPalette(for: target, canScan: true)
        case .notDetermined:
            permissionTask?.cancel()
            permissionTask = Task { [weak self] in
                guard let self, let host = self.host else { return }
                let resolved = await host.permissions.request(.accessibility)
                guard !Task.isCancelled else { return }
                host.log.info("accessibility request resolved to \(resolved)")
                self.openPalette(for: target, canScan: resolved == .granted)
            }
        default:
            // Denied or unavailable. The SDK says not to re-ask after a denial;
            // the surface still opens, with whatever the disk cache has.
            host.log.notice("accessibility is \(status); opening the surface without scanning")
            openPalette(for: target, canScan: false)
        }
    }

    private static func frontmostTarget() -> MenuScanTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != getpid() else { return nil }
        return MenuScanTarget(application)
    }

    // MARK: Palette session

    /// Opens the surface for `target` and fills it: the disk cache first, when
    /// there is one, then a fresh scan of that app alone.
    private func openPalette(for target: MenuScanTarget?, canScan: Bool) {
        guard presentCommands() else { return }
        endSession()

        guard let target else {
            status = .noTargetApp
            return
        }
        targetName = target.localizedName
        status = canScan ? .scanning : .needsAccessibility

        let sessionID = UUID()
        self.sessionID = sessionID
        let cache = diskCache
        let scanner = scanner

        // Off the main actor: the disk read and, above all, the scan, which is
        // a synchronous message to the app per menu item.
        sessionTask = Task.detached(priority: .userInitiated) { [weak self] in
            let key = MenuCacheKey.resolve(for: target)

            if let key, let cache, let cached = await cache.load(key) {
                let cachedRows = cached.commands.enumerated().map { PaletteRow(id: $0.offset, cached: $0.element) }
                await self?.showCachedRows(cachedRows, sessionID: sessionID)
            }
            guard canScan, !Task.isCancelled else { return }

            let generation = await cache?.generation
            await self?.scanWillStart(sessionID: sessionID)
            do throws(MenuScanError) {
                let result = try scanner.scan(target)
                let liveRows = result.commands.enumerated().map { PaletteRow(id: $0.offset, command: $0.element) }
                await self?.scanDidFinish(result, rows: liveRows, sessionID: sessionID)

                if let key, let cache, let generation {
                    do {
                        try await cache.save(CachedMenu(key: key, result: result), generation: generation)
                    } catch {
                        await self?.logCacheWriteFailure(String(describing: error))
                    }
                }
            } catch {
                await self?.scanDidFail(error, sessionID: sessionID)
            }
        }
    }

    private func showCachedRows(_ cachedRows: [PaletteRow], sessionID: UUID) {
        // A scan that already landed is newer than the disk.
        guard sessionID == self.sessionID, rowsScanID == nil else { return }
        rows = cachedRows
    }

    private func scanWillStart(sessionID: UUID) {
        guard sessionID == self.sessionID else { return }
        // A new scan makes the previous one's references the wrong things to
        // press, so they go before it starts.
        liveCommands = nil
    }

    private func scanDidFinish(_ result: MenuScanResult, rows liveRows: [PaletteRow], sessionID: UUID) {
        // The surface closed, or another press replaced this palette: the
        // references are not kept.
        guard sessionID == self.sessionID, presentation != nil else { return }
        let scanID = UUID()
        liveCommands = LiveMenuCommands(scanID: scanID, result: result)
        rows = liveRows
        rowsScanID = scanID
        status = .ready
    }

    private func scanDidFail(_ error: MenuScanError, sessionID: UUID) {
        guard sessionID == self.sessionID, error != .cancelled else { return }
        host?.log.notice("menu scan of \(targetName ?? "the frontmost app") failed: \(error)")
        status = error == .accessibilityNotAuthorized ? .needsAccessibility : .failed
    }

    private func logCacheWriteFailure(_ description: String) {
        host?.log.error("could not write the menu cache: \(description)")
    }

    /// The live command behind a palette row, for running it. `nil` while the
    /// rows still come from the disk cache, and once the surface has closed.
    func liveCommand(for row: PaletteRow) -> MenuCommand? {
        guard let liveCommands, rowsScanID == liveCommands.scanID,
              liveCommands.result.commands.indices.contains(row.id) else { return nil }
        return liveCommands.result.commands[row.id]
    }

    /// Ends the palette's session: stops its scan, forgets the live references
    /// and empties what the surface shows.
    private func endSession() {
        sessionTask?.cancel()
        sessionTask = nil
        sessionID = nil
        liveCommands = nil
        rowsScanID = nil
        rows = []
        status = .idle
        targetName = nil
        query = ""
    }

    /// Deletes every menu cached on disk. A scan already running does not write
    /// its result back; the palette that is open keeps showing what it has.
    public func clearMenuCache() async throws {
        guard let diskCache else { return }
        try await diskCache.removeAll()
        host?.log.info("menu cache cleared")
    }

    @discardableResult
    private func presentCommands() -> Bool {
        guard let host else { return false }
        presentation = host.notchSurface.presentExpandedSurface(
            ExpandedSurfacePresentationRequest(surfaceID: Self.commandsSurfaceID, opensShelf: true)
        )
        if presentation == nil {
            host.log.notice("host refused to present the commands surface")
        }
        return presentation != nil
    }
}

// MARK: - Shelf widget

extension MeuwidgetDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "meuwidget",
                title: "Meu Widget",
                systemImage: "drop.fill",
                layoutTraits: ShelfWidgetLayoutTraits(
                    // Both are required. Droppy refuses a descriptor that
                    // leaves either to a host fallback.
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(150)
                )
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(MeuwidgetWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? {
        AnyView(MenuCacheSettingsPopover(droplet: self))
    }
}

/// The widget's settings popover: the one control the disk cache needs, so the
/// user can clear it without a settings pane of its own.
private struct MenuCacheSettingsPopover: View {
    private enum ClearState {
        case idle, clearing, cleared, failed
    }

    @ObservedObject var droplet: MeuwidgetDroplet
    @State private var clearState = ClearState.idle

    var body: some View {
        DropletSettingsCard {
            DropletControlRow(
                title: "Cache de menus",
                icon: "internaldrive",
                infoTip: "Títulos, atalhos de teclado e estado habilitado dos comandos de cada app, guardados só neste Mac."
            ) {
                HStack(spacing: DroppySpacing.sm) {
                    if let statusText {
                        Text(statusText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("Limpar cache", action: clear)
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        .disabled(clearState == .clearing)
                }
            }
        }
        .padding(DroppySpacing.md)
        .frame(width: 320)
    }

    private var statusText: String? {
        switch clearState {
        case .idle: return nil
        case .clearing: return "Limpando…"
        case .cleared: return "Cache limpo"
        case .failed: return "Não foi possível limpar"
        }
    }

    private func clear() {
        clearState = .clearing
        Task {
            do {
                try await droplet.clearMenuCache()
                clearState = .cleared
            } catch {
                clearState = .failed
            }
        }
    }
}

/// The widget.
///
/// Solo and paired are different compositions, not one view at two widths.
/// Branch on `context.isCompact`, never on a width comparison.
private struct MeuwidgetWidget: View {
    @ObservedObject var droplet: MeuwidgetDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 12, weight: .medium))
                Text("Meu Widget")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)

            Text(context.isCompact ? "Compact" : "Standalone")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)

            Spacer(minLength: 0)
        }
        .padding(DroppySpacing.mdl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Expanded surface

extension MeuwidgetDroplet: ExpandedSurfaceProviding {
    public var expandedSurfaces: [ExpandedSurfaceDescriptor] {
        [
            ExpandedSurfaceDescriptor(
                id: Self.commandsSurfaceID,
                title: "Menu commands",
                systemImage: "command",
                // The user types into this with the pointer elsewhere, so the
                // host's pointer-based auto-collapse would close it under them.
                // Clicking away and swiping still dismiss it.
                suppresses: [.shelfWidgets, .autoCollapse]
            )
        ]
    }

    public func makeExpandedSurfaceView(_ id: ExpandedSurfaceID, context: ExpandedSurfaceContext) -> AnyView {
        guard id == Self.commandsSurfaceID else { return AnyView(EmptyView()) }
        return AnyView(CommandsSurface(droplet: self, context: context))
    }

    public func expandedSurfaceDidDismiss(
        _ id: ExpandedSurfaceID,
        presentation: ExpandedSurfacePresentation,
        reason: ExpandedSurfaceDismissalReason
    ) {
        // A late teardown can arrive after the shortcut summoned a fresh one.
        guard presentation == self.presentation else { return }
        self.presentation = nil
        // The live references only live while the surface is open.
        endSession()
    }
}

extension MeuwidgetDroplet: ExpandedSurfaceHosting {
    public var expandedSurfaceProvider: (any ExpandedSurfaceProviding)? { self }
}

/// The commands surface: a search field over the app's menu commands.
private struct CommandsSurface: View {
    @ObservedObject var droplet: MeuwidgetDroplet
    let context: ExpandedSurfaceContext
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let visibleRows = filteredRows
        VStack(alignment: .leading, spacing: DroppySpacing.md) {
            searchField

            if visibleRows.isEmpty {
                Spacer(minLength: 0)
                Text(verbatim: placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleRows) { row in
                            CommandRow(row: row)
                        }
                    }
                }
            }
        }
        .padding(DroppySpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if !context.isPreview { isSearchFocused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            TextField(
                "",
                text: $droplet.query,
                prompt: Text("Buscar comandos")
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .focused($isSearchFocused)

            if droplet.status == .scanning, !droplet.rows.isEmpty {
                Text("Atualizando")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
        }
        .padding(.horizontal, DroppySpacing.md)
        .padding(.vertical, DroppySpacing.smd)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                .fill(AdaptiveColors.notchSurfaceCardFill)
        )
    }

    private var filteredRows: [PaletteRow] {
        let query = droplet.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return droplet.rows }
        return droplet.rows.filter { $0.fullTitle.localizedStandardContains(query) }
    }

    private var placeholder: String {
        if !droplet.rows.isEmpty { return "Nenhum comando corresponde à busca" }
        let app = droplet.targetName ?? "o app em uso"
        switch droplet.status {
        case .idle: return "Nenhum comando carregado ainda"
        case .noTargetApp: return "Nenhum app em uso para ler os menus"
        case .needsAccessibility: return "Sem acesso de Acessibilidade, os menus não podem ser lidos"
        case .scanning: return "Lendo os menus de \(app)…"
        case .ready: return "Nenhum comando encontrado em \(app)"
        case .failed: return "Não foi possível ler os menus de \(app)"
        }
    }
}

private struct CommandRow: View {
    let row: PaletteRow

    var body: some View {
        HStack(spacing: DroppySpacing.md) {
            Text(verbatim: row.fullTitle)
                .font(.system(size: 13))
                .foregroundStyle(
                    row.isEnabled ? AdaptiveColors.notchSurfacePrimaryText : AdaptiveColors.notchSurfaceTertiaryText
                )
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DroppySpacing.sm)
            if let shortcut = row.shortcut {
                Text(verbatim: shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
        }
        .padding(.horizontal, DroppySpacing.md)
        .padding(.vertical, DroppySpacing.xsm)
    }
}
