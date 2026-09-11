//
//  MenuCommandScanner.swift
//  Meuwidget
//
//  Reads one app's menu bar through the Accessibility API, once, when asked.
//
//  The scope is deliberately narrow, and review reads this file against the
//  manifest's description:
//
//  - It is handed the app to read. It never decides which app that is.
//  - It reads the menu bar and nothing under it but menus: no windows, no
//    document content, no text fields, no focus.
//  - It neither checks nor requests Accessibility permission. The caller owns
//    that; here a refused call surfaces as `.accessibilityNotAuthorized`.
//  - It registers no AXObserver, runs no timer and keeps no state between
//    calls. One call is one read of one app's menu bar, and cancelling the
//    task running it stops the read.
//  - The Apple menu and the system Services submenu are skipped without
//    reading into them: neither holds the app's own commands.
//

import AppKit
import ApplicationServices

// MARK: - Target

/// The app whose menu bar to read, captured by the caller when the shortcut
/// fires.
public struct MenuScanTarget: Sendable, Equatable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let localizedName: String?
    /// Where the app lives, so a cache can key on its version.
    public let bundleURL: URL?

    public init(
        processIdentifier: pid_t,
        bundleIdentifier: String? = nil,
        localizedName: String? = nil,
        bundleURL: URL? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.bundleURL = bundleURL
    }

    public init(_ application: NSRunningApplication) {
        self.init(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName,
            bundleURL: application.bundleURL
        )
    }
}

// MARK: - Commands

/// The modifiers of a menu item's native key equivalent.
public struct MenuShortcutModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = MenuShortcutModifiers(rawValue: 1 << 0)
    public static let shift = MenuShortcutModifiers(rawValue: 1 << 1)
    public static let option = MenuShortcutModifiers(rawValue: 1 << 2)
    public static let control = MenuShortcutModifiers(rawValue: 1 << 3)

    /// Translates `AXMenuItemCmdModifiers`, where Command is implied unless
    /// `kAXMenuItemModifierNoCommand` is set.
    ///
    /// The masks are written out because Swift does not import the header's
    /// anonymous enum. Values from HIServices' AXAttributeConstants.h.
    init(accessibilityMask mask: Int) {
        let shiftMask = 1 << 0      // kAXMenuItemModifierShift
        let optionMask = 1 << 1     // kAXMenuItemModifierOption
        let controlMask = 1 << 2    // kAXMenuItemModifierControl
        let noCommandMask = 1 << 3  // kAXMenuItemModifierNoCommand

        var modifiers: MenuShortcutModifiers = []
        if mask & noCommandMask == 0 { modifiers.insert(.command) }
        if mask & shiftMask != 0 { modifiers.insert(.shift) }
        if mask & optionMask != 0 { modifiers.insert(.option) }
        if mask & controlMask != 0 { modifiers.insert(.control) }
        self = modifiers
    }
}

/// A menu item's native key equivalent, as the app reports it.
public struct MenuKeyboardShortcut: Sendable, Hashable {
    /// `AXMenuItemCmdChar`, for example `"S"` or `","`.
    public let character: String?
    /// `AXMenuItemCmdVirtualKey`, a `kVK_*` key code, when the app reports one.
    public let virtualKey: Int?
    /// `AXMenuItemCmdGlyph`, the raw Carbon menu glyph code. Kept raw because
    /// the macOS SDK no longer ships the glyph table to name it from.
    public let glyph: Int?
    public let modifiers: MenuShortcutModifiers

    /// The shortcut the way a menu draws it, for example `"⇧⌘S"`. `nil` when the
    /// key can only be named from its glyph.
    public var displayString: String? {
        guard let key = keyLabel else { return nil }
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        return label + key
    }

    /// Reads the key equivalent out of an item's attributes, or `nil` when the
    /// item has none.
    init?(attributes: [String: AnyObject]) {
        let character = (attributes[kAXMenuItemCmdCharAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let virtualKey = (attributes[kAXMenuItemCmdVirtualKeyAttribute] as? NSNumber)?.intValue
        // A glyph code of 0 is treated as no glyph.
        let glyph = ((attributes[kAXMenuItemCmdGlyphAttribute] as? NSNumber)?.intValue).flatMap { $0 == 0 ? nil : $0 }
        // A key code alone only counts when it is non-zero: 0 is also kVK_ANSI_A,
        // so it cannot tell "no shortcut" from "A".
        guard character != nil || glyph != nil || (virtualKey ?? 0) != 0 else { return nil }

        self.character = character
        self.virtualKey = virtualKey
        self.glyph = glyph
        self.modifiers = MenuShortcutModifiers(
            accessibilityMask: (attributes[kAXMenuItemCmdModifiersAttribute] as? NSNumber)?.intValue ?? 0
        )
    }

    private var keyLabel: String? {
        // Function keys arrive as private-use characters (U+F700 to U+F8FF) and
        // Return, Tab and Delete as control characters; neither reads as text.
        if let character, let scalar = character.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(scalar),
           !(0xF700...0xF8FF).contains(scalar.value) {
            return character.uppercased()
        }
        if let virtualKey, let label = Self.virtualKeyLabels[virtualKey] {
            return label
        }
        return nil
    }

    /// Layout-independent keys, by their `kVK_*` code in Carbon's Events.h.
    private static let virtualKeyLabels: [Int: String] = [
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋",
        0x73: "↖", 0x74: "⇞", 0x75: "⌦", 0x77: "↘", 0x79: "⇟",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
        0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
        0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
        0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20"
    ]
}

/// A handle on a menu item in the target app, for pressing it later.
///
/// `AXUIElement` is an immutable Core Foundation handle, so carrying it across
/// isolation domains is safe; every use of it is still a message to the target
/// app. The handle can go stale when the app rebuilds that menu.
/// ``MenuCommand/path`` is there to find the item again.
public struct MenuCommandReference: @unchecked Sendable {
    public let element: AXUIElement
    public let processIdentifier: pid_t
}

/// One command from a menu bar, flattened.
public struct MenuCommand: Sendable {
    /// Menu, submenus and command, for example `["File", "Export", "PDF…"]`.
    public let path: [String]
    /// The path joined for display: `"File > Export > PDF…"`.
    public let fullTitle: String
    /// The app's own key equivalent, when it has one.
    public let shortcut: MenuKeyboardShortcut?
    /// Whether the item and every menu above it were enabled when the scan read
    /// them. Only a snapshot: an app that is not active can report most of its
    /// items disabled. ``MenuCommandExecutor/press(_:)`` reads it again.
    public let isEnabled: Bool
    public let reference: MenuCommandReference

    init(path: [String], shortcut: MenuKeyboardShortcut?, isEnabled: Bool, reference: MenuCommandReference) {
        self.path = path
        self.fullTitle = path.joined(separator: " > ")
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.reference = reference
    }
}

/// What one scan found.
public struct MenuScanResult: Sendable {
    public let target: MenuScanTarget
    /// In menu order, the Apple menu and the Services submenu excluded.
    public let commands: [MenuCommand]
    /// True when the scan stopped at ``MenuCommandScanner/Limits/maximumCommands``
    /// or skipped menus nested deeper than ``MenuCommandScanner/Limits/maximumDepth``.
    public let isTruncated: Bool
}

/// Why a scan produced nothing.
public enum MenuScanError: Error, Equatable, Sendable {
    /// The system refused the call because this process is not trusted for
    /// Accessibility (`kAXErrorAPIDisabled`). Also thrown mid-scan, if the
    /// permission is revoked while reading.
    case accessibilityNotAuthorized
    /// No running app has this process identifier any more.
    case targetUnavailable(pid_t)
    /// The target is this process. Reading your own menu bar through AX from
    /// the main thread waits on the main thread, so it is refused outright.
    case targetIsCurrentProcess
    /// The app did not answer within ``MenuCommandScanner/Limits/messagingTimeout``.
    case targetNotResponding(pid_t)
    /// The app exposes no menu bar, as background agents do not.
    case noMenuBar(pid_t)
    /// The task running the scan was cancelled; the scan stopped before its
    /// next read.
    case cancelled
    /// Any other failure reading the menu bar, with the attribute and the raw
    /// `AXError` code.
    case accessibilityFailure(attribute: String, code: Int32)
}

// MARK: - Scanner

/// Flattens an app's menu bar into commands.
///
/// Every read is a synchronous message to the target app, and a large menu bar
/// is hundreds of them, so call ``scan(_:)`` off the main actor.
public struct MenuCommandScanner: Sendable {
    public struct Limits: Sendable {
        /// Submenu levels below a menu bar item. Deeper menus are skipped.
        public var maximumDepth: Int
        /// The scan stops once it has this many commands.
        public var maximumCommands: Int
        /// Seconds to wait for the target app on each read.
        public var messagingTimeout: Float

        public init(maximumDepth: Int, maximumCommands: Int, messagingTimeout: Float) {
            self.maximumDepth = maximumDepth
            self.maximumCommands = maximumCommands
            self.messagingTimeout = messagingTimeout
        }

        public static let standard = Limits(maximumDepth: 8, maximumCommands: 5_000, messagingTimeout: 1)
    }

    public let limits: Limits

    public init(limits: Limits = .standard) {
        self.limits = limits
    }

    /// Reads `target`'s menu bar once and returns its commands.
    ///
    /// Items that vanish while being read, and separators, are skipped. A
    /// refused permission, an app that stops answering, or cancellation of the
    /// calling task ends the scan with an error rather than a partial list.
    public func scan(_ target: MenuScanTarget) throws(MenuScanError) -> MenuScanResult {
        var session = ScanSession(target: target, limits: limits)
        return try session.run()
    }
}

/// The state of one scan. Lives for one call of ``MenuCommandScanner/scan(_:)``.
private struct ScanSession {
    let target: MenuScanTarget
    let limits: MenuCommandScanner.Limits
    private(set) var commands: [MenuCommand] = []
    private(set) var isTruncated = false

    init(target: MenuScanTarget, limits: MenuCommandScanner.Limits) {
        self.target = target
        self.limits = limits
    }

    private var pid: pid_t { target.processIdentifier }

    private static let menuItemAttributes = [
        kAXTitleAttribute, kAXEnabledAttribute, kAXChildrenAttribute,
        kAXMenuItemCmdCharAttribute, kAXMenuItemCmdVirtualKeyAttribute,
        kAXMenuItemCmdGlyphAttribute, kAXMenuItemCmdModifiersAttribute
    ]

    mutating func run() throws(MenuScanError) -> MenuScanResult {
        guard !Task.isCancelled else { throw .cancelled }
        guard pid != getpid() else { throw .targetIsCurrentProcess }
        guard isTargetRunning else { throw .targetUnavailable(pid) }

        let menuBar = try menuBar(of: AXUIElementCreateApplication(pid))
        guard let barAttributes = try read(menuBar, [kAXChildrenAttribute]),
              let barItems = Self.elements(barAttributes[kAXChildrenAttribute]) else {
            throw .noMenuBar(pid)
        }

        // The first menu bar item is the Apple menu. It is skipped without
        // reading anything from it. The second is the application menu, which
        // holds the Services submenu.
        for (index, item) in barItems.enumerated().dropFirst() {
            guard commands.count < limits.maximumCommands else {
                isTruncated = true
                break
            }
            try visitMenuBarItem(item, isApplicationMenu: index == 1)
        }

        return MenuScanResult(target: target, commands: commands, isTruncated: isTruncated)
    }

    // MARK: Walking

    private mutating func visitMenuBarItem(_ item: AXUIElement, isApplicationMenu: Bool) throws(MenuScanError) {
        guard let attributes = try read(item, [kAXTitleAttribute, kAXEnabledAttribute, kAXChildrenAttribute]),
              let title = Self.title(attributes) else { return }
        let isEnabled = attributes[kAXEnabledAttribute] as? Bool ?? true
        try visitMenus(
            in: attributes,
            path: [title],
            parentEnabled: isEnabled,
            depth: 1,
            isApplicationMenu: isApplicationMenu
        )
    }

    /// Walks every `AXMenu` among an element's children. Returns whether there
    /// was one, which is what makes an item a submenu rather than a command.
    @discardableResult
    private mutating func visitMenus(
        in attributes: [String: AnyObject],
        path: [String],
        parentEnabled: Bool,
        depth: Int,
        isApplicationMenu: Bool
    ) throws(MenuScanError) -> Bool {
        var foundMenu = false
        for child in Self.elements(attributes[kAXChildrenAttribute]) ?? [] {
            guard let menuAttributes = try read(child, [kAXRoleAttribute, kAXChildrenAttribute]),
                  menuAttributes[kAXRoleAttribute] as? String == kAXMenuRole else { continue }
            foundMenu = true

            guard depth <= limits.maximumDepth else {
                isTruncated = true
                continue
            }
            for item in Self.elements(menuAttributes[kAXChildrenAttribute]) ?? [] {
                guard commands.count < limits.maximumCommands else {
                    isTruncated = true
                    return foundMenu
                }
                try visitMenuItem(
                    item,
                    path: path,
                    parentEnabled: parentEnabled,
                    depth: depth,
                    isApplicationMenu: isApplicationMenu
                )
            }
        }
        return foundMenu
    }

    private mutating func visitMenuItem(
        _ item: AXUIElement,
        path: [String],
        parentEnabled: Bool,
        depth: Int,
        isApplicationMenu: Bool
    ) throws(MenuScanError) {
        // Separators have no title, and neither does anything that vanished.
        guard let attributes = try read(item, Self.menuItemAttributes),
              let title = Self.title(attributes) else { return }

        // Services is the system's menu, not the app's. Like the Apple menu it
        // is skipped whole, before anything inside it is read.
        if isApplicationMenu, depth == 1, Self.isServicesTitle(title) {
            return
        }

        let isEnabled = parentEnabled && (attributes[kAXEnabledAttribute] as? Bool ?? true)
        let itemPath = path + [title]

        if try visitMenus(
            in: attributes,
            path: itemPath,
            parentEnabled: isEnabled,
            depth: depth + 1,
            isApplicationMenu: false
        ) {
            return
        }

        commands.append(
            MenuCommand(
                path: itemPath,
                shortcut: MenuKeyboardShortcut(attributes: attributes),
                isEnabled: isEnabled,
                reference: MenuCommandReference(element: item, processIdentifier: pid)
            )
        )
    }

    /// Whether a top-level item of the application menu is the Services
    /// submenu, recognized by its English title alone.
    ///
    /// Nothing else in its AX attributes marks it: in TextEdit it has no
    /// subrole, and its identifiers are generated (`_NS:848` for the item,
    /// `_NS:852` for its menu). An app whose menus are in another language
    /// titles it differently, so for now that app's Services items stay in the
    /// list.
    private static func isServicesTitle(_ title: String) -> Bool {
        title.compare("Services", options: .caseInsensitive) == .orderedSame
    }

    // MARK: Reading

    private var isTargetRunning: Bool {
        guard let application = NSRunningApplication(processIdentifier: pid) else { return false }
        return !application.isTerminated
    }

    private func menuBar(of application: AXUIElement) throws(MenuScanError) -> AXUIElement {
        AXUIElementSetMessagingTimeout(application, limits.messagingTimeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &value)
        switch status {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw .noMenuBar(pid) }
            return unsafeDowncast(value, to: AXUIElement.self)
        case .apiDisabled:
            throw .accessibilityNotAuthorized
        case .cannotComplete:
            throw unansweredError()
        case .invalidUIElement:
            throw .targetUnavailable(pid)
        case .noValue, .attributeUnsupported:
            throw .noMenuBar(pid)
        default:
            throw .accessibilityFailure(attribute: kAXMenuBarAttribute, code: status.rawValue)
        }
    }

    /// Reads several attributes in one message to the app.
    ///
    /// Returns `nil` when the element cannot be read at all (it vanished, or the
    /// app does not implement it), so the caller skips it. An attribute the
    /// element does not have is simply absent from the dictionary. Checks for
    /// cancellation first, so a cancelled scan sends no further messages.
    private func read(_ element: AXUIElement, _ attributes: [String]) throws(MenuScanError) -> [String: AnyObject]? {
        guard !Task.isCancelled else { throw .cancelled }

        AXUIElementSetMessagingTimeout(element, limits.messagingTimeout)
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &raw
        )
        switch status {
        case .success:
            break
        case .apiDisabled:
            throw .accessibilityNotAuthorized
        case .cannotComplete:
            throw unansweredError()
        default:
            return nil
        }

        guard let values = raw as? [AnyObject], values.count == attributes.count else { return nil }

        var result: [String: AnyObject] = [:]
        for (name, value) in zip(attributes, values) {
            if let error = Self.accessibilityError(in: value) {
                switch error {
                case .apiDisabled: throw .accessibilityNotAuthorized
                case .cannotComplete: throw unansweredError()
                default: continue
                }
            }
            if value is NSNull { continue }
            result[name] = value
        }
        return result
    }

    /// `kAXErrorCannotComplete` means the app did not answer, or is gone.
    private func unansweredError() -> MenuScanError {
        isTargetRunning ? .targetNotResponding(pid) : .targetUnavailable(pid)
    }

    /// The error a multiple-attribute read left in place of a value, if any.
    private static func accessibilityError(in value: AnyObject) -> AXError? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .axError else { return nil }
        var code: Int32 = 0
        guard AXValueGetValue(axValue, .axError, &code) else { return nil }
        return AXError(rawValue: code)
    }

    private static func elements(_ value: AnyObject?) -> [AXUIElement]? {
        guard let array = value as? [AnyObject] else { return nil }
        return array.compactMap { element in
            CFGetTypeID(element) == AXUIElementGetTypeID() ? unsafeDowncast(element, to: AXUIElement.self) : nil
        }
    }

    private static func title(_ attributes: [String: AnyObject]) -> String? {
        guard let title = (attributes[kAXTitleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }
}
