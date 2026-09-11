//
//  MenuCommandExecutor.swift
//  Meuwidget
//
//  Presses the one menu item the user chose, through the Accessibility API.
//
//  It only presses a live reference that a scan in the current session
//  produced. It never walks the menu bar to find an item again, never presses
//  anything the user did not pick, and never synthesizes key or mouse events:
//  it reads the item's enabled state and presses the item, both through AX.
//

import ApplicationServices

/// Why a press did not go through. Every case is recoverable: the caller
/// closes the palette and carries on.
public enum MenuCommandPressError: Error, Equatable, Sendable {
    /// The system refused the call: Accessibility was revoked since the scan.
    case accessibilityNotAuthorized
    /// The item is gone. The app rebuilt or closed that menu, or quit.
    case itemUnavailable
    /// The app reports the item disabled at the moment of the press, so it was
    /// not pressed.
    case disabled
    /// The app did not answer in time. The command may still have run, for
    /// example one that opened a modal panel.
    case targetNotResponding
    /// The item no longer accepts a press.
    case actionUnsupported
    /// Any other failure, with the raw `AXError` code.
    case accessibilityFailure(code: Int32)
}

/// Presses menu items.
public struct MenuCommandExecutor: Sendable {
    /// Seconds to wait for the app to answer each message.
    public let messagingTimeout: Float

    public init(messagingTimeout: Float = 1) {
        self.messagingTimeout = messagingTimeout
    }

    /// Whether the app reports the item enabled right now, read from the live
    /// reference in one message, or `nil` when it does not report it.
    ///
    /// ``MenuCommand/isEnabled`` is only what the scan saw, and an app that is
    /// not active can report most of its items disabled: TextEdit, read from
    /// the background, reported 150 of its 177 commands disabled, and 23 of 189
    /// once it was active.
    public func currentEnabledState(of command: MenuCommand) throws(MenuCommandPressError) -> Bool? {
        let element = command.reference.element
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value)
        switch status {
        case .success:
            return value as? Bool
        case .noValue, .attributeUnsupported:
            return nil
        default:
            throw Self.failure(for: status)
        }
    }

    /// Presses `command`'s menu item once, if the app reports it enabled at
    /// this moment.
    ///
    /// The enabled state is read again first, and the press is refused with
    /// ``MenuCommandPressError/disabled`` only when the app still reports the
    /// item disabled; the scan's state is not consulted. Call it once the
    /// target app is active, since that is what its enabled state depends on.
    ///
    /// Synchronous messages to the app, so call it off the main actor. A stale
    /// reference is not repaired. The system accepting the press is not proof
    /// the app ran the command.
    public func press(_ command: MenuCommand) throws(MenuCommandPressError) {
        guard try currentEnabledState(of: command) != false else { throw .disabled }

        let status = AXUIElementPerformAction(command.reference.element, kAXPressAction as CFString)
        guard status == .success else { throw Self.failure(for: status) }
    }

    private static func failure(for status: AXError) -> MenuCommandPressError {
        switch status {
        case .apiDisabled: .accessibilityNotAuthorized
        case .invalidUIElement: .itemUnavailable
        case .cannotComplete: .targetNotResponding
        case .actionUnsupported: .actionUnsupported
        default: .accessibilityFailure(code: status.rawValue)
        }
    }
}
