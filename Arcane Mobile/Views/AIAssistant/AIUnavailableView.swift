import SwiftUI
import UIKit

/// Explains why Arcane Assistant can't run and (where possible) offers a way out.
/// Unrestricted so it can also render on the iOS 18 code path (`osTooOld`).
struct AIUnavailableView: View {
    let state: AIAvailability
    var onRetry: (() -> Void)? = nil

    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            actions
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .aiNotEnabled:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.borderedProminent)
            if let onRetry { Button("Try Again", action: onRetry) }
        case .modelNotReady, .unknown:
            if let onRetry {
                Button("Try Again", action: onRetry).buttonStyle(.borderedProminent)
            }
        default:
            EmptyView()
        }
    }

    private var title: String {
        switch state {
        case .osTooOld:           return "Requires iOS 26"
        case .deviceNotEligible:  return "Device Not Supported"
        case .aiNotEnabled:       return "Apple Intelligence Is Off"
        case .modelNotReady:      return "Getting Ready…"
        default:                  return "Arcane Assistant Unavailable"
        }
    }

    private var icon: String {
        switch state {
        case .modelNotReady: return "arrow.down.circle"
        case .aiNotEnabled:  return "sparkles.slash"
        default:             return "sparkles"
        }
    }

    private var message: String {
        switch state {
        case .osTooOld:
            return "Arcane Assistant requires iOS 26 or later."
        case .deviceNotEligible:
            return "On-device AI requires iPhone 15 Pro or newer, or an M-series iPad."
        case .aiNotEnabled:
            return "Turn on Apple Intelligence in Settings to use Arcane Assistant."
        case .modelNotReady:
            return "Apple Intelligence is still downloading its model. Try again in a moment."
        default:
            return "The on-device model isn't available right now."
        }
    }
}
