import SwiftUI

extension RunState {
    var color: Color {
        switch self {
        case .idle: return Theme.textSecondary
        case .starting: return Theme.amber
        case .running: return Theme.accent
        case .stopped: return Theme.textSecondary.opacity(0.8)
        case .failed: return Theme.danger
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .failed(let code): return "Failed (\(code))"
        }
    }
}
