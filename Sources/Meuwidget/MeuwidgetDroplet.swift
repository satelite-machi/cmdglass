//
//  MeuwidgetDroplet.swift
//  Meuwidget
//

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
    private var permissionTask: Task<Void, Never>?
    private var presentation: ExpandedSurfacePresentation?

    /// The search field's text. Cleared every time the surface opens.
    @Published var query = ""

    public func activate(host: DropletHost) throws {
        self.host = host
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
        if presentation != nil {
            host?.notchSurface.dismissExpandedSurface(Self.commandsSurfaceID)
        }
        presentation = nil
        host?.shortcuts.unregister(id: Self.shortcutID)
        host = nil
    }

    // MARK: Shortcut

    /// The shortcut's handler, and the only place in the droplet that checks or
    /// requests Accessibility: the permission is asked for when the user reaches
    /// for the feature, never at activation.
    private func shortcutPressed() {
        guard let host else { return }
        let status = host.permissions.status(for: .accessibility)
        switch status {
        case .granted:
            presentCommands()
        case .notDetermined:
            permissionTask?.cancel()
            permissionTask = Task { [weak self] in
                guard let self, let host = self.host else { return }
                let resolved = await host.permissions.request(.accessibility)
                guard !Task.isCancelled else { return }
                host.log.info("accessibility request resolved to \(resolved)")
                self.presentCommands()
            }
        default:
            // Denied or unavailable. The SDK says not to re-ask after a denial;
            // the surface still opens, and has nothing to list yet anyway.
            host.log.notice("accessibility is \(status); opening the surface without it")
            presentCommands()
        }
    }

    private func presentCommands() {
        guard let host else { return }
        query = ""
        presentation = host.notchSurface.presentExpandedSurface(
            ExpandedSurfacePresentationRequest(surfaceID: Self.commandsSurfaceID, opensShelf: true)
        )
        if presentation == nil {
            host.log.notice("host refused to present the commands surface")
        }
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

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
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
        query = ""
    }
}

extension MeuwidgetDroplet: ExpandedSurfaceHosting {
    public var expandedSurfaceProvider: (any ExpandedSurfaceProviding)? { self }
}

/// The commands surface: a search field and, until the scanner exists, an
/// empty state.
private struct CommandsSurface: View {
    @ObservedObject var droplet: MeuwidgetDroplet
    let context: ExpandedSurfaceContext
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.lg) {
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
            }
            .padding(.horizontal, DroppySpacing.md)
            .padding(.vertical, DroppySpacing.smd)
            .background(
                RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                    .fill(AdaptiveColors.notchSurfaceCardFill)
            )

            Spacer(minLength: 0)

            Text("Nenhum comando carregado ainda")
                .font(.system(size: 13))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .padding(DroppySpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if !context.isPreview { isSearchFocused = true }
        }
    }
}
