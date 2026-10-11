import SwiftUI

// MARK: - Connection State

enum ConnectionPhase {
    case searching, connecting, connected

    var title: String {
        switch self {
        case .searching:  return "Searching"
        case .connecting: return "Connecting"
        case .connected:  return "Connected"
        }
    }

    var subtitle: String {
        switch self {
        case .searching:  return "Looking for your device"
        case .connecting: return "Verifying secure tunnel"
        case .connected:  return "Tunnel active"
        }
    }
}
