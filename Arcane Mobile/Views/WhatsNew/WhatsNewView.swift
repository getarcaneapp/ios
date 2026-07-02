import SwiftUI

struct WhatsNewView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 20) {
                    ForEach(ReleaseNotes.all) { note in
                        ReleaseNoteCard(
                            note: note,
                            isCurrent: note.id == ReleaseNotes.latest?.id
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }
}

private struct ReleaseNoteCard: View {
    let note: ReleaseNote
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.version)
                    .font(.title.bold())
                Spacer()
                if isCurrent {
                    Text("Current")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.green.opacity(0.15), in: .capsule)
                }
            }

            if !note.new.isEmpty {
                section(
                    title: "NEW",
                    icon: "sparkles",
                    tint: .mint,
                    bullets: note.new
                )
            }
            if !note.changed.isEmpty {
                section(
                    title: "Changed",
                    icon: "paintbrush.fill",
                    tint: .blue,
                    bullets: note.changed
                )
            }
            if !note.fixed.isEmpty {
                section(
                    title: "Fixed",
                    icon: "ladybug.fill",
                    tint: .red,
                    bullets: note.fixed
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: Radius.card))
    }

    @ViewBuilder
    private func section(
        title: String,
        icon: String,
        tint: Color,
        bullets: [ReleaseNote.Bullet]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title.uppercased())
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(bullets, id: \.self) { bullet in
                    BulletRow(bullet: bullet)
                }
            }
        }
    }
}

private struct BulletRow: View {
    let bullet: ReleaseNote.Bullet

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bullet.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let badge = bullet.badge {
                    Text(badge.label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(badge.color.opacity(0.15), in: .capsule)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
