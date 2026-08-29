import Foundation

/// Which face the app shows. Simple is the app as it shipped: drop, name, convert on defaults.
enum Mode: String, CaseIterable, Identifiable, Sendable {
    case simple
    case advanced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .simple: return "Simple"
        case .advanced: return "Advanced"
        }
    }
}
