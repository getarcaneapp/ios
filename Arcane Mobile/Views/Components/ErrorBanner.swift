import SwiftUI

struct ErrorBanner: View {
    enum Severity {
        case error
        case warning
    }

    let message: String
    var severity: Severity = .error
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tintColor)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(tintColor)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if let retry {
                Button("Retry", action: retry)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tintColor.opacity(0.12), in: .rect(cornerRadius: Radius.nested))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.nested, style: .continuous)
                .stroke(tintColor.opacity(0.18), lineWidth: 1)
        }
        .transition(.scale(scale: 0.95).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityPrefix + message))
    }

    private var tintColor: Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        }
    }

    private var accessibilityPrefix: String {
        switch severity {
        case .error: return "Error: "
        case .warning: return "Warning: "
        }
    }
}
