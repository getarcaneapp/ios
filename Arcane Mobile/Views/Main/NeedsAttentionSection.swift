import SwiftUI

/// One triage item. Built by DashboardView from data it already holds (stream
/// states, folded action items, failed activities) — these views stay dumb and
/// do no fetching.
struct NeedsAttentionItem: Identifiable {
    enum Severity {
        case critical
        case warning

        var tint: Color {
            switch self {
            case .critical: return .red
            case .warning: return .orange
            }
        }

        var title: String {
            switch self {
            case .critical: return "Critical"
            case .warning: return "Warnings"
            }
        }
    }

    let id: String
    /// One-line explanation shown in the Attention Center.
    let detail: String
    let severity: Severity
    let icon: String
    let title: String
    let count: Int
    let action: () -> Void
}

/// Top-left toolbar entry point. The badge carries the item count and the
/// glyph tint follows the highest severity. Tap expands a compact summary
/// popover from the button; a long press opens the full Attention Center.
struct AttentionToolbarButton: View {
    let items: [NeedsAttentionItem]
    @Binding var isPresented: Bool
    let onSelect: (NeedsAttentionItem) -> Void
    let onOpenCenter: () -> Void

    /// Set by the long press so the button's tap (which also fires on release)
    /// is swallowed instead of opening the popover over the center.
    @State private var didLongPress = false
    @State private var longPressPulse = false

    private var tint: Color {
        if items.contains(where: { $0.severity == .critical }) { return .red }
        return items.isEmpty ? .green : .orange
    }

    private var symbol: String {
        items.isEmpty ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
    }

    var body: some View {
        if #available(iOS 26, *) {
            popoverButton.badge(items.count)
        } else {
            popoverButton
        }
    }

    private var popoverButton: some View {
        Button {
            if didLongPress {
                didLongPress = false
                return
            }
            isPresented = true
        } label: {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: items.count)
                .motionAwareAnimation(Motion.state, value: items.isEmpty)
                .frame(width: 32, height: 32)
                .overlay(alignment: .topTrailing) {
                    if #unavailable(iOS 26), !items.isEmpty {
                        Text(verbatim: "\(items.count)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(.red, in: .capsule)
                    }
                }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                didLongPress = true
                longPressPulse.toggle()
                isPresented = false
                onOpenCenter()
            }
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: longPressPulse)
        .accessibilityLabel(items.isEmpty
            ? "Attention Center, all clear"
            : "Attention Center, \(items.count) items")
        .accessibilityHint("Tap for a summary. Hold to open the Attention Center.")
        .accessibilityAction(named: "Open Attention Center") { onOpenCenter() }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            AttentionSummaryPopover(items: items, onSelect: onSelect)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// Compact summary that expands out of the toolbar button: the first few
/// items, each tappable. The full center is a long press away on the button.
struct AttentionSummaryPopover: View {
    let items: [NeedsAttentionItem]
    let onSelect: (NeedsAttentionItem) -> Void

    private static let maximumRows = 4

    private var visibleItems: [NeedsAttentionItem] {
        Array(items.prefix(Self.maximumRows))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Needs Attention")
                    .font(.headline)
                Spacer()
                Text(items.isEmpty ? "All clear" : "\(items.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if items.isEmpty {
                Label("Everything looks healthy.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    Button {
                        onSelect(item)
                    } label: {
                        AttentionItemRow(item: item)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .contentShape(.rect)
                    }
                    .cardRowLinkStyle()
                    .staggeredReveal(index: index)
                    if index < visibleItems.count - 1 {
                        Divider().padding(.leading, 58)
                    }
                }
                if items.count > visibleItems.count {
                    Text("\(items.count - visibleItems.count) more in the Attention Center")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
        }
        .padding(.bottom, 6)
        .frame(idealWidth: 320, maxWidth: 340, alignment: .leading)
    }
}

/// Icon disc, title (+ optional detail), count pill, chevron.
struct AttentionItemRow: View {
    let item: NeedsAttentionItem
    var showsDetail = false

    var body: some View {
        HStack(spacing: 12) {
            DashboardRowIcon(systemImage: item.icon, tint: item.severity.tint, changeToken: String(item.count))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if showsDetail {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: "\(item.count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(item.severity.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(item.severity.tint.opacity(0.14), in: Capsule())
                .contentTransition(.numericText())
                .motionAwareAnimation(Motion.state, value: item.count)
            DashboardRowChevron()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title): \(item.count)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Full Attention Center: every item grouped by severity, with its detail.
struct AttentionCenterView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let items: [NeedsAttentionItem]
    let onSelect: (NeedsAttentionItem) -> Void

    private var critical: [NeedsAttentionItem] { items.filter { $0.severity == .critical } }
    private var warnings: [NeedsAttentionItem] { items.filter { $0.severity == .warning } }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("All Clear", systemImage: "checkmark.shield.fill")
                    } description: {
                        Text("Nothing needs your attention right now.")
                    }
                } else {
                    List {
                        if !critical.isEmpty {
                            Section(NeedsAttentionItem.Severity.critical.title) {
                                ForEach(critical) { row($0) }
                            }
                        }
                        if !warnings.isEmpty {
                            Section(NeedsAttentionItem.Severity.warning.title) {
                                ForEach(warnings) { row($0) }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Attention Center")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ item: NeedsAttentionItem) -> some View {
        Button {
            onSelect(item)
        } label: {
            AttentionItemRow(item: item, showsDetail: true)
                .padding(.vertical, 2)
        }
    }
}
