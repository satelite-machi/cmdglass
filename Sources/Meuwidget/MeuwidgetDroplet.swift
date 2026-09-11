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

    private var host: DropletHost?

    public func activate(host: DropletHost) throws {
        self.host = host
        host.log.info("Meu Widget activated")
    }

    public func deactivate() {
        // Everything activate() started is torn down here. Swift cannot unload
        // code, so anything left running keeps running until Droppy relaunches.
        host = nil
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
