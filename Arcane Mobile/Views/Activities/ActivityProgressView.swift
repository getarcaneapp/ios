import SwiftUI

struct ActivityProgressView: View {
    let progress: Int?
    let isActive: Bool
    let tint: Color
    var showsPercentage = false

    var body: some View {
        if let progress {
            if showsPercentage {
                ProgressView(value: Double(progress), total: 100) {
                    Text("Progress")
                } currentValueLabel: {
                    Text(verbatim: "\(progress)%")
                }
                .progressViewStyle(.linear)
                .tint(tint)
            } else {
                ProgressView(value: Double(progress), total: 100)
                    .progressViewStyle(.linear)
                    .tint(tint)
            }
        } else if isActive {
            HStack {
                ProgressView()
                    .tint(tint)
                Text("In progress")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
