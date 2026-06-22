import Foundation

/// The semantic category of a ``RegattaToast``, driving its icon, color, and
/// auto-dismiss timing.
enum RegattaToastKind: String, Sendable, Equatable, CaseIterable {
    /// A user action completed successfully (green, checkmark).
    case success
    /// A user action failed (red, exclamation); lingers longer than the others.
    case error
    /// A neutral, informational notice (blue, info).
    case info

    /// The SF Symbol shown in the toast's leading badge.
    var symbolName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    /// How long a toast of this kind stays on screen before auto-dismissing.
    ///
    /// Errors linger longer so the user has time to read the failure reason.
    var autoDismiss: Duration {
        switch self {
        case .success: return .seconds(4)
        case .info: return .seconds(4)
        case .error: return .seconds(7)
        }
    }
}
