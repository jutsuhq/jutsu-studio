import Foundation
import JutsuCore

extension Mode {
    public var title: String {
        switch self {
        case .motionTransfer: String(localized: "Motion transfer", bundle: .module)
        case .restyle: String(localized: "Restyle", bundle: .module)
        case .objectSwap: String(localized: "Object swap", bundle: .module)
        case .edit: String(localized: "Edit", bundle: .module)
        case .extend: String(localized: "Extend", bundle: .module)
        }
    }
}

/// One entry of a mode picker: every mode is listed, the ones the connection can't run say why.
public struct ModeOption: Sendable, Hashable, Identifiable {
    public var mode: Mode
    /// `nil` when the mode can run.
    public var unavailableReason: String?

    public var id: Mode { mode }
    public var isAvailable: Bool { unavailableReason == nil }

    /// - Parameter capabilities: `nil` while they are still loading.
    public static func all(for state: ConnectionState, capabilities: Capabilities?) -> [ModeOption] {
        Mode.allCases.map { mode in
            ModeOption(mode: mode, unavailableReason: reason(mode, state: state, capabilities: capabilities))
        }
    }

    private static func reason(_ mode: Mode, state: ConnectionState, capabilities: Capabilities?) -> String? {
        guard state.isConnected else { return String(localized: "Connect Higgsfield first", bundle: .module) }
        guard let capabilities else {
            return String(localized: "Checking what this connection can run…", bundle: .module)
        }
        if capabilities.modes.contains(mode) { return nil }
        // The connection decides only the wording.
        return state.kind == .account
            ? String(localized: "Not available for this account", bundle: .module)
            : String(localized: "Not available with this API key", bundle: .module)
    }
}
