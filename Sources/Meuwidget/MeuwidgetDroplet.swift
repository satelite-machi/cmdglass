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

    /// The HUD that explains a surface Droppy closed as it opened.
    static let autoCollapseHintID = "auto-collapse-hint"
    /// Names the setting as Droppy's Settings show it, under Shelf, Behavior.
    static let autoCollapseHint = "Se a barra fechar sozinha, desligue Auto-collapse nas preferências do Droppy."
    /// A dismissal the host reports as the user's, this soon after presenting,
    /// is taken to be Droppy's Auto-collapse: nobody reads the palette and
    /// clicks away inside a second.
    static let autoCollapseWindow: Duration = .seconds(1)

    private var host: DropletHost?
    private var diskCache: MenuCommandDiskCache?
    private var usageStore: MenuCommandUsageStore?
    private let scanner = MenuCommandScanner()
    private let executor = MenuCommandExecutor()
    private var permissionTask: Task<Void, Never>?
    private var executionTask: Task<Void, Never>?
    private var presentation: ExpandedSurfacePresentation?
    /// When `presentation` went up.
    private var presentedAt: ContinuousClock.Instant?

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
        presentedAt = nil
        host?.hud.dismiss(id: Self.autoCollapseHintID)
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

    /// The rest of the best match's own title, when what has been typed is the
    /// start of it: the faint text the field shows after the caret, and what
    /// Tab fills in.
    ///
    /// `nil` when the field is empty, when nothing matched, when the match was
    /// found in the middle of a title rather than at its start, or when the
    /// title has already been typed out in full. The prefix test is the one
    /// the ranking scores highest, on the same folded title, so the suggestion
    /// can only ever be a continuation of what the list already puts first.
    var ghostCompletion: (title: String, suffix: String)? {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, let best = rankedRows.first else { return nil }
        let title = best.path.last ?? best.fullTitle
        let folded = PaletteRanking.fold(typed)
        guard best.searchTitle.hasPrefix(folded) else { return nil }
        // Folding is per character for everything a menu title holds, so the
        // folded length counts characters of the title too. When some title
        // ever folds to a different length, it simply gets no ghost.
        guard best.searchTitle.count == title.count, folded.count < title.count else { return nil }
        return (title, String(title.dropFirst(folded.count)))
    }

    /// Fills the field with the suggested command's title, and runs nothing.
    func completeWithGhost() {
        guard let ghost = ghostCompletion else { return }
        query = ghost.title
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

    /// Closes the palette at the user's request, from Escape in the search
    /// field or the close button.
    ///
    /// The palette's own way out. With Droppy's Auto-collapse off, clicking
    /// outside and hovering did not close it in Droppy Playground 1.0.6, so
    /// without this it stayed up until a command ran. The
    /// host reports this as `dropletRequested`, which never shows the
    /// Auto-collapse notice.
    func closePalette() {
        guard presentation != nil else { return }
        host?.notchSurface.dismissExpandedSurface(Self.commandsSurfaceID)
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
        presentedAt = presentation == nil ? nil : .now
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
                // Clicking away and swiping still dismiss it. Droppy's
                // Auto-collapse setting closes it anyway; see
                // presentAutoCollapseHint().
                suppresses: [.shelfWidgets, .autoCollapse]
            )
        ]
    }

    public func makeExpandedSurfaceView(_ id: ExpandedSurfaceID, context: ExpandedSurfaceContext) -> AnyView {
        guard id == Self.commandsSurfaceID else { return AnyView(EmptyView()) }
        return AnyView(CommandsSurface(droplet: self, context: context))
    }

    /// Tall enough for the search field and several command rows.
    ///
    /// The host's standard content height is 93 points, and the field with the
    /// surface's own padding fills all of it: the list was laid out into the
    /// point or so left over, so no command was ever visible, however many the
    /// scan had found. The width stays the host's, and the height is clamped to
    /// the ceiling the proposal carries. Any other surface id keeps the
    /// default and takes the standard size.
    public func expandedSurfaceSize(
        _ id: ExpandedSurfaceID,
        fitting proposal: ExpandedSurfaceSizeProposal
    ) -> CGSize? {
        guard id == Self.commandsSurfaceID else { return nil }
        return CGSize(
            width: proposal.standardSize.width,
            height: min(CommandsSurfaceMetrics.preferredHeight, proposal.maximumSize.height)
        )
    }

    /// What the commands surface is laid out from, so the height the droplet
    /// asks for and the view that fills it stay in step. Every number here is
    /// a font size or a `DroppySpacing` step `CommandsSurface` uses.
    enum CommandsSurfaceMetrics {
        /// Rows visible before the list scrolls.
        static let visibleRows = 6
        /// The search field: 15pt text inside `smd` vertical padding.
        static let searchFieldHeight: CGFloat = 18 + DroppySpacing.smd * 2
        /// One command row: 13pt text inside `xsm` vertical padding.
        static let rowHeight: CGFloat = 16 + DroppySpacing.xsm * 2
        /// The surface's own padding, on the top and bottom edges.
        static let verticalPadding: CGFloat = DroppySpacing.xl * 2
        /// The content height for `visibleRows` rows, before the host clamps it.
        static var preferredHeight: CGFloat {
            verticalPadding + searchFieldHeight + DroppySpacing.md + rowHeight * CGFloat(visibleRows)
        }
    }

    public func expandedSurfaceDidDismiss(
        _ id: ExpandedSurfaceID,
        presentation: ExpandedSurfacePresentation,
        reason: ExpandedSurfaceDismissalReason
    ) {
        // A late teardown can arrive after the shortcut summoned a fresh one.
        guard presentation == self.presentation else { return }
        let shownFor = presentedAt.map { ContinuousClock.now - $0 }
        self.presentation = nil
        presentedAt = nil
        // The live references only live while the surface is open.
        endSession()
        if reason == .userCollapsedShelf, let shownFor, shownFor < Self.autoCollapseWindow {
            presentAutoCollapseHint()
        }
    }
}

extension MeuwidgetDroplet: ExpandedSurfaceHosting {
    public var expandedSurfaceProvider: (any ExpandedSurfaceProviding)? { self }
}

// MARK: - HUD

extension MeuwidgetDroplet: HUDPresenting {
    /// Says why the commands surface closed as it opened, on the notch, where
    /// the user sees it without opening anything.
    ///
    /// Droppy's Auto-collapse setting closes the surface even though its
    /// descriptor suppresses `.autoCollapse`, whenever the pointer is away from
    /// the notch, which is where it is after a shortcut. Seen in Droppy
    /// Playground 1.0.6: open for as long as it was watched with the setting
    /// off, closed within a second with it on. DroppyKit exposes no host
    /// preference, so the droplet cannot check the setting; it reacts to the
    /// dismissal instead, and a real click away inside a second shows the same
    /// notice.
    private func presentAutoCollapseHint() {
        guard let host else { return }
        let message = Self.autoCollapseHint
        // The card's content is 344pt wide on a notch and 208 on an island,
        // where the sentence needs more lines.
        let height: CGFloat = host.environment.notchGeometry.isHardwareNotch ? 56 : 88
        let request = DropletHUDRequest(
            id: Self.autoCollapseHintID,
            duration: 6,
            accessibilityLabel: message,
            isExpanded: true,
            expandedContentHeight: height
        ) {
            AutoCollapseHintStrip()
        } expanded: {
            AutoCollapseHintCard(message: message)
        }
        if !host.hud.present(request) {
            host.log.notice("host refused the auto-collapse notice")
        }
    }
}

/// The notice's strip, for a host that draws it: the glyph at the far left and
/// the setting's name at the far right, nothing across the camera housing.
private struct AutoCollapseHintStrip: View {
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
            Spacer(minLength: 0)
            Text("Auto-collapse")
                .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }
}

/// The notice's card: which droplet is speaking, then the sentence.
private struct AutoCollapseHintCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            Text("Meu Widget")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Text(verbatim: message)
                .font(.system(size: 13))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The commands surface: a search field over the app's menu commands.
///
/// Up and down move the selection, Return runs it, and a click runs the row
/// clicked. Escape and the close button close the palette. Why a confirmation
/// did not run anything shows in the footer.
private struct CommandsSurface: View {
    /// The search field's type size. The caret is laid out from the same
    /// number, so it stays with the text it follows.
    static let searchFont: CGFloat = 15

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
            // The caret rides at the end of the text. Following the field's
            // real insertion point through a `TextSelection` binding crashed
            // the host on the first keystroke: the index it reports belongs to
            // the field's own copy of the string, and measuring it against the
            // text this view draws traps inside `String.Index.utf16Offset(in:)`
            // when the two are a render apart.
            EndOfTextSearchField(droplet: droplet, isSearchFocused: $isSearchFocused)

            if droplet.status == .scanning, !droplet.rows.isEmpty {
                Text("Atualizando")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }

            // The same action as Escape, visible: nothing about a search field
            // says that Escape closes the palette around it.
            Button {
                droplet.closePalette()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 20))
            .help("Fechar (Esc)")
            .accessibilityLabel("Fechar")
        }
        .padding(.horizontal, DroppySpacing.md)
        .padding(.vertical, DroppySpacing.smd)
        .background(
            // No fill and no icon, deliberately: the faint placeholder and the
            // caret pulsing beside it are the only sign that this line takes
            // typing. `Color.clear` rather than `opacity(0)`, which would stop
            // the field's padding taking the click that has to reach it before
            // anything can be typed.
            RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                .fill(Color.clear)
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

/// The caret that says where typing lands, drawn rather than styled.
///
/// Neither SwiftUI nor AppKit exposes a field's own caret beyond its colour:
/// SwiftUI has `tint(_:)` and nothing else, and the `NSTextView` under it has
/// `insertionPointColor`, also only a colour. A glow and a pulse therefore
/// have to be a view of our own, with the field's caret hidden behind
/// `tint(.clear)`. It follows the typed text rather than the insertion point,
/// so it sits after the last character even if the user moves the real caret
/// with the left and right arrows.
private struct TypingCaret: View {
    @State private var isDim = false

    /// Slow enough to read as breathing rather than blinking. Written out
    /// because no `DroppyAnimation` preset repeats; nothing in the SDK does.
    private static let pulse = Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(AdaptiveColors.notchSurfacePrimaryText)
            .frame(width: 2, height: 19)
            // The glow: a tight halo over a wider, fainter one.
            .shadow(color: AdaptiveColors.notchSurfacePrimaryText.opacity(0.85), radius: 4)
            .shadow(color: AdaptiveColors.notchSurfacePrimaryText.opacity(0.45), radius: 9)
            .opacity(isDim ? 0.35 : 1)
            .onAppear {
                // Reduce Motion keeps the caret and its glow, and drops the
                // pulse: it is the one thing on this surface that moves on its
                // own. DroppyAnimation's own presets read the same setting.
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                withAnimation(Self.pulse) { isDim = true }
            }
    }
}

/// The modifiers both search fields share: the type, the hidden caret, the
/// focus, and every key the palette answers.
private struct SearchFieldChrome: ViewModifier {
    @ObservedObject var droplet: MeuwidgetDroplet
    @FocusState.Binding var isSearchFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: CommandsSurface.searchFont))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            // Hides the field's own caret, which cannot be given a glow or a
            // pulse; TypingCaret is drawn in its place. It also hides the
            // selection highlight, which this field never shows off.
            .tint(.clear)
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
            // Tab takes the suggestion when there is one, and nothing else:
            // the command is filled in, not run. With no suggestion showing it
            // is left alone, so it still moves the focus the way the system
            // expects it to.
            .onKeyPress(.tab) {
                guard droplet.ghostCompletion != nil else { return .ignored }
                droplet.completeWithGhost()
                return .handled
            }
            // Escape reaches a focused field as the Cancel action.
            .onExitCommand {
                droplet.closePalette()
            }
    }
}

/// The caret, and the placeholder beside it, drawn over a search field.
///
/// `textBeforeCaret` in the field's own font is exactly as wide as what sits
/// to the left of the insertion point, so the bar lands on it. The placeholder
/// follows the caret rather than starting under it, and goes at the first
/// keystroke. Never takes the click that has to reach the field beneath.
private struct SearchFieldCaretOverlay: View {
    let textBeforeCaret: String
    let isEmpty: Bool
    /// The rest of the suggested command's title, or empty for no suggestion.
    /// Never both this and the placeholder: one needs typing, the other an
    /// empty field.
    let ghost: String

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: textBeforeCaret)
                .font(.system(size: CommandsSurface.searchFont))
                .opacity(0)
            TypingCaret()
            if isEmpty {
                Text("Buscar comandos")
                    .font(.system(size: CommandsSurface.searchFont))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText.opacity(0.18))
                    .padding(.leading, DroppySpacing.xsm)
            } else if !ghost.isEmpty {
                // The typed text is drawn by the field itself; this is only
                // what Tab would add to it, so it starts where the caret is.
                Text(verbatim: ghost)
                    .font(.system(size: CommandsSurface.searchFont))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText.opacity(0.32))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }
}

/// The search field: the caret rides at the end of the text, where typing
/// leaves it.
///
/// It followed the field's real insertion point for one build, through the
/// `TextSelection` binding `TextField(text:selection:)` takes on macOS 15 and
/// newer. That crashed Droppy Playground 1.0.6 on the first keystroke, every
/// time: `String.Index.utf16Offset(in:)` trapped inside the body, because the
/// index the field reports indexes the field's own copy of the string and the
/// view was drawing the copy from a render earlier. Any measurement of that
/// index against this view's text has the same hazard, so following the
/// insertion point needs the caret position in integers, from the field
/// editor's own `selectedRange`, not `String.Index` arithmetic.
///
/// That AppKit route was weighed and left alone. It means owning the field
/// itself — the focus, the placeholder, and the Return, arrow and Escape
/// handling this palette has already had to get right — to move a decorative
/// bar a few characters. The caret is a sign that the line takes typing, not a
/// readout of the insertion point, and typing lands at the end of the text.
private struct EndOfTextSearchField: View {
    @ObservedObject var droplet: MeuwidgetDroplet
    @FocusState.Binding var isSearchFocused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            // No prompt of its own: the placeholder is drawn beside the caret.
            TextField("", text: $droplet.query)
                .modifier(SearchFieldChrome(droplet: droplet, isSearchFocused: $isSearchFocused))
            SearchFieldCaretOverlay(
                textBeforeCaret: droplet.query,
                isEmpty: droplet.query.isEmpty,
                ghost: droplet.ghostCompletion?.suffix ?? ""
            )
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
