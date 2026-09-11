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

// MARK: - Palette state

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

/// Why confirming a row did not run anything, shown in the surface's footer.
enum PaletteNotice: Equatable {
    /// The row has no live command yet, and the scan that will provide one is
    /// still running.
    case waitingForScan
    /// The row has no live command, and no scan is coming to provide one.
    case unavailable
    /// The app reported the command disabled at the moment it was pressed.
    case disabledNow
}

/// The latest scan's commands, with their live AX references.
///
/// Exists only while the surface is open, so the command the user picks can be
/// pressed without walking the menu bar again. Never written anywhere.
private struct LiveMenuCommands {
    let result: MenuScanResult
    /// The first command at each path.
    let firstIndexByPath: [[String]: Int]

    init(result: MenuScanResult) {
        self.result = result
        var firstIndexByPath: [[String]: Int] = [:]
        for (index, command) in result.commands.enumerated() where firstIndexByPath[command.path] == nil {
            firstIndexByPath[command.path] = index
        }
        self.firstIndexByPath = firstIndexByPath
    }
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

    /// Cmd+Shift+Y. The key code is `kVK_ANSI_Y`, written as a literal so the
    /// droplet does not import Carbon. The host drops it if the user already has
    /// something on it.
    ///
    /// The modifiers are `NSEvent.ModifierFlags` raw values, not the Carbon mask
    /// DroppyKit's doc comment for `DropletKeyboardShortcut.modifiers` names.
    /// Droppy records its own shortcuts in the Cocoa form (0x1e0000 for
    /// Control-Option-Shift-Command), and Carbon's `cmdKey | shiftKey` (0x300)
    /// holds none of those bits, so the host bound it to Y with no modifiers.
    static let defaultShortcut = DropletKeyboardShortcut(
        keyCode: 0x10,
        modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
    )

    private var host: DropletHost?
    private var diskCache: MenuCommandDiskCache?
    private var usageStore: MenuCommandUsageStore?
    private let scanner = MenuCommandScanner()
    private let executor = MenuCommandExecutor()
    private var permissionTask: Task<Void, Never>?
    private var executionTask: Task<Void, Never>?
    private var presentation: ExpandedSurfacePresentation?

    /// The palette opened by the latest shortcut press. Work that finishes for
    /// an older one is dropped.
    private var sessionID: UUID?
    private var sessionTask: Task<Void, Never>?
    /// The app the open palette reads, captured when the shortcut fired.
    private var target: MenuScanTarget?
    private var liveCommands: LiveMenuCommands?
    /// Whether `rows` came from a live scan rather than the disk.
    private var rowsAreLive = false

    /// The search field's text. Cleared every time the surface opens.
    @Published var query = "" {
        didSet {
            selectedPath = nil
            notice = nil
        }
    }
    @Published private(set) var rows: [PaletteRow] = []
    @Published private(set) var status: PaletteStatus = .idle
    @Published private(set) var targetName: String?
    /// The target app's command usage, for ranking.
    @Published private(set) var usage: [[String]: MenuCommandUsage] = [:]
    /// The selected row, by path so it survives re-ranking and the switch from
    /// cached to live rows. `nil` selects the first row.
    @Published private(set) var selectedPath: [String]?
    @Published private(set) var notice: PaletteNotice?

    public func activate(host: DropletHost) throws {
        self.host = host
        diskCache = MenuCommandDiskCache(containerDirectory: host.environment.containerDirectory)
        usageStore = MenuCommandUsageStore(containerDirectory: host.environment.containerDirectory)
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
        executionTask?.cancel()
        executionTask = nil
        endSession()
        if presentation != nil {
            host?.notchSurface.dismissExpandedSurface(Self.commandsSurfaceID)
        }
        presentation = nil
        host?.shortcuts.unregister(id: Self.shortcutID)
        diskCache = nil
        usageStore = nil
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

    /// Opens the surface for `target` and fills it: usage and the disk cache
    /// first, when there are any, then a fresh scan of that app alone.
    private func openPalette(for target: MenuScanTarget?, canScan: Bool) {
        guard presentCommands() else { return }
        endSession()

        guard let target else {
            status = .noTargetApp
            return
        }
        self.target = target
        targetName = target.localizedName
        status = canScan ? .scanning : .needsAccessibility

        let sessionID = UUID()
        self.sessionID = sessionID
        let cache = diskCache
        let usageStore = usageStore
        let scanner = scanner

        // Off the main actor: the file reads and, above all, the scan, which is
        // a synchronous message to the app per menu item.
        sessionTask = Task.detached(priority: .userInitiated) { [weak self] in
            if let bundleIdentifier = target.bundleIdentifier, let usageStore {
                let usage = await usageStore.usage(forBundleIdentifier: bundleIdentifier)
                await self?.showUsage(usage, sessionID: sessionID)
            }

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
                        await self?.logFailure("could not write the menu cache: \(error)")
                    }
                }
            } catch {
                await self?.scanDidFail(error, sessionID: sessionID)
            }
        }
    }

    private func showUsage(_ usage: [[String]: MenuCommandUsage], sessionID: UUID) {
        guard sessionID == self.sessionID else { return }
        self.usage = usage
    }

    private func showCachedRows(_ cachedRows: [PaletteRow], sessionID: UUID) {
        // A scan that already landed is newer than the disk.
        guard sessionID == self.sessionID, !rowsAreLive else { return }
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
        liveCommands = LiveMenuCommands(result: result)
        rows = liveRows
        rowsAreLive = true
        status = .ready
        if notice == .waitingForScan { notice = nil }
    }

    private func scanDidFail(_ error: MenuScanError, sessionID: UUID) {
        guard sessionID == self.sessionID, error != .cancelled else { return }
        host?.log.notice("menu scan failed: \(error)")
        status = error == .accessibilityNotAuthorized ? .needsAccessibility : .failed
        if notice == .waitingForScan { notice = .unavailable }
    }

    private func logFailure(_ message: String) {
        host?.log.error(message)
    }

    /// Ends the palette's session: stops its scan, forgets the live references
    /// and empties what the surface shows. A command already being pressed
    /// carries on.
    private func endSession() {
        sessionTask?.cancel()
        sessionTask = nil
        sessionID = nil
        target = nil
        liveCommands = nil
        rowsAreLive = false
        rows = []
        usage = [:]
        status = .idle
        targetName = nil
        query = ""
        selectedPath = nil
        notice = nil
    }

    // MARK: Selection and running

    /// The rows in the order they are shown: match relevance, then frequency,
    /// then recency.
    var rankedRows: [PaletteRow] {
        PaletteRanking.rank(rows, query: query, usage: usage)
    }

    func selectedRow(in rankedRows: [PaletteRow]) -> PaletteRow? {
        rankedRows.first { $0.path == selectedPath } ?? rankedRows.first
    }

    func moveSelection(by offset: Int) {
        let ranked = rankedRows
        guard !ranked.isEmpty else { return }
        let current = ranked.firstIndex { $0.path == selectedPath } ?? 0
        selectedPath = ranked[min(max(current + offset, 0), ranked.count - 1)].path
        notice = nil
    }

    func confirmSelection() {
        guard let row = selectedRow(in: rankedRows) else { return }
        confirm(row)
    }

    /// The live command behind a palette row, found by its path. `nil` when
    /// there is nothing safe to press: the rows still come from the disk, the
    /// scan has not finished, or there is no permission to scan.
    func liveCommand(for row: PaletteRow) -> MenuCommand? {
        guard let liveCommands else { return nil }
        let commands = liveCommands.result.commands
        // The same position almost always holds the same command; the path
        // decides.
        if commands.indices.contains(row.id), commands[row.id].path == row.path {
            return commands[row.id]
        }
        return liveCommands.firstIndexByPath[row.path].map { commands[$0] }
    }

    /// Runs the command behind `row`, if there is a live one to press.
    ///
    /// The surface stays open until the command has run. The target app comes
    /// forward first, with the surface still up; then the executor reads the
    /// item's enabled state again from its live reference and presses it only
    /// if the app reports it enabled at that moment. The row's enabled state is
    /// only what the scan saw, and an app that was not active then can report
    /// most of its items disabled, so it decides nothing here.
    ///
    /// - It ran: the surface closes, leaving the target app in front.
    /// - Refused as disabled, and the surface is still presented: the footer
    ///   says so and the palette stays, so another item can be chosen.
    /// - Refused as disabled, but the surface is gone: logged, nothing reopens.
    /// - Any other failure: the surface closes and the failure is logged.
    ///
    /// Not yet confirmed in Droppy: that the surface stays visible while
    /// another app is activated. The harness cannot show it, and the Playground
    /// needs a bundle `droppykit build` cannot produce with Swift 6.3.3. If
    /// Droppy closes the surface on activation, the refusal is only logged.
    ///
    /// Also not yet confirmed: whether activating the target app takes keyboard
    /// focus away from the search field. After a refusal the surface asks for
    /// the field's focus back, defensively. That can only reach the field if
    /// the surface's window is key again, and DroppyKit 1.2.0 gives a droplet no
    /// way to make it so; if Droppy leaves it unfocused, the user clicks the
    /// field to keep going.
    func confirm(_ row: PaletteRow) {
        selectedPath = row.path
        guard executionTask == nil else { return }
        guard let command = liveCommand(for: row), let target else {
            // Never a reference from an older scan: wait for this one.
            notice = status == .scanning ? .waitingForScan : .unavailable
            return
        }
        notice = nil

        let confirmedPresentation = presentation
        let usageStore = usageStore
        let executor = executor

        executionTask = Task { [weak self] in
            let isFrontmost = await Self.bringForward(target)
            let failure = await Task.detached(priority: .userInitiated) { () -> MenuCommandPressError? in
                do throws(MenuCommandPressError) {
                    try executor.press(command)
                    return nil
                } catch {
                    return error
                }
            }.value

            guard let self else { return }
            self.executionTask = nil
            if !isFrontmost {
                self.host?.log.notice("the target app did not come forward before the press")
            }

            switch failure {
            case nil:
                self.dismissSurface(ifStill: confirmedPresentation)
                if let bundleIdentifier = target.bundleIdentifier, let usageStore {
                    do {
                        try await usageStore.recordUse(of: command.path, bundleIdentifier: bundleIdentifier)
                    } catch {
                        self.host?.log.error("could not record command usage: \(error)")
                    }
                }
            case .disabled?:
                if self.isStillPresented(confirmedPresentation) {
                    self.notice = .disabledNow
                } else {
                    self.host?.log.notice("the menu command was disabled when pressed and the surface had already closed; nothing ran")
                }
            case let failure?:
                self.host?.log.notice("pressing the menu command failed: \(failure)")
                self.dismissSurface(ifStill: confirmedPresentation)
            }
        }
    }

    /// Whether the presentation a row was confirmed from is still on screen,
    /// by the host's account as well as ours.
    private func isStillPresented(_ confirmedPresentation: ExpandedSurfacePresentation?) -> Bool {
        guard let confirmedPresentation, presentation == confirmedPresentation else { return false }
        return host?.notchSurface.expandedState.current?.id == confirmedPresentation.id
    }

    /// Closes the surface, unless the presentation a row was confirmed from has
    /// already gone. Dismissal ends the session.
    private func dismissSurface(ifStill confirmedPresentation: ExpandedSurfacePresentation?) {
        guard isStillPresented(confirmedPresentation) else { return }
        host?.notchSurface.dismissExpandedSurface(Self.commandsSurfaceID)
    }

    /// Asks for `target` to become the active app and waits, at most half a
    /// second, until it is. Activation is cooperative since macOS 14: Droppy
    /// yields it, the target takes it, and the system may still decline.
    private static func bringForward(_ target: MenuScanTarget) async -> Bool {
        let pid = target.processIdentifier
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
            return false
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }

        NSApp.yieldActivation(to: application)
        application.activate(from: .current, options: [])
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(20))
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        }
        return false
    }

    // MARK: Cache

    /// Deletes everything the droplet keeps on disk, at once: every cached menu
    /// and every app's command usage. A scan already running does not write its
    /// menu back; a command already being run when this is called is still
    /// counted. The palette that is open keeps showing what it has.
    public func clearMenuCache() async throws {
        guard let diskCache, let usageStore else { return }
        try await diskCache.removeAll()
        try await usageStore.removeAll()
        host?.log.info("menu cache and command usage cleared")
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
                infoTip: "Títulos, atalhos de teclado e estado habilitado dos comandos de cada app, e quantas vezes e quando cada um foi usado. Fica tudo só neste Mac, e limpar apaga tudo de uma vez."
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
///
/// Up and down move the selection, Return runs it, and a click runs the row
/// clicked. Why a confirmation did not run anything shows in the footer.
private struct CommandsSurface: View {
    @ObservedObject var droplet: MeuwidgetDroplet
    let context: ExpandedSurfaceContext
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let rankedRows = droplet.rankedRows
        let selectedID = droplet.selectedRow(in: rankedRows)?.id

        VStack(alignment: .leading, spacing: DroppySpacing.md) {
            searchField

            if rankedRows.isEmpty {
                Spacer(minLength: 0)
                Text(verbatim: placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rankedRows) { row in
                                CommandRow(
                                    row: row,
                                    isSelected: row.id == selectedID,
                                    isRunnable: droplet.liveCommand(for: row) != nil
                                )
                                .id(row.id)
                                .contentShape(Rectangle())
                                .onTapGesture { droplet.confirm(row) }
                            }
                        }
                    }
                    .onChange(of: selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }

            if let noticeText {
                Text(verbatim: noticeText)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DroppySpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if !context.isPreview { isSearchFocused = true }
        }
        .onChange(of: droplet.notice) { _, notice in
            // Bringing the target app forward for the press may have taken
            // focus from the field. After a refusal the palette is still in
            // use, so ask for it back. See MeuwidgetDroplet.confirm(_:).
            if notice == .disabledNow, !context.isPreview { isSearchFocused = true }
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
            .onSubmit { droplet.confirmSelection() }
            .onKeyPress(.downArrow) {
                droplet.moveSelection(by: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                droplet.moveSelection(by: -1)
                return .handled
            }

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

    private var appName: String {
        droplet.targetName ?? "o app em uso"
    }

    private var noticeText: String? {
        switch droplet.notice {
        case .waitingForScan: return "Aguardando terminar a leitura dos menus de \(appName) para executar"
        case .unavailable: return "Este comando só pode ser executado depois de uma leitura atual dos menus"
        case .disabledNow: return "Este comando não está disponível agora"
        case nil: return nil
        }
    }

    private var placeholder: String {
        if !droplet.rows.isEmpty { return "Nenhum comando corresponde à busca" }
        switch droplet.status {
        case .idle: return "Nenhum comando carregado ainda"
        case .noTargetApp: return "Nenhum app em uso para ler os menus"
        case .needsAccessibility: return "Sem acesso de Acessibilidade, os menus não podem ser lidos"
        case .scanning: return "Lendo os menus de \(appName)…"
        case .ready: return "Nenhum comando encontrado em \(appName)"
        case .failed: return "Não foi possível ler os menus de \(appName)"
        }
    }
}

private struct CommandRow: View {
    let row: PaletteRow
    let isSelected: Bool
    /// Whether a live command stands behind the row. A row from the disk
    /// cache is shown but cannot run until the scan lands. A row the scan saw
    /// disabled is only dimmed: it can still be selected and confirmed.
    let isRunnable: Bool

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
            if isSelected, !isRunnable {
                Text("Aguardando")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            } else if let shortcut = row.shortcut {
                Text(verbatim: shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
        }
        .padding(.horizontal, DroppySpacing.md)
        .padding(.vertical, DroppySpacing.xsm)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                    .fill(AdaptiveColors.notchSurfaceCardFill)
            }
        }
    }
}
