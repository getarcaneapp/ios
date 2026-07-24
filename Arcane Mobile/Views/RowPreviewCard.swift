import SwiftUI

// Forces both the SF Symbol icon and the title to render in pure red.
// `.foregroundStyle(.red)` on a plain Label isn't enough — destructive role,
// hierarchical symbol rendering, and tint inheritance can each repaint the
// icon in some other shade. Explicit Image with `.symbolRenderingMode(.monochrome)`
// + `.foregroundStyle(.red)` wins everywhere (toolbar menus, context menus,
// inline buttons). Pair with `.tint(.red)` on the enclosing Button when used
// inside `swipeActions`.
struct DestructiveLabel: View {
    let text: String
    var systemImage: String = "trash"

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.red)
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.red)
        }
    }
}

// Card used as the `preview:` content for `.contextMenu` on list rows.
// All major resource lists render this when the user long-presses a row,
// so the look stays consistent across Containers / Images / Projects / etc.
struct RowPreviewCard: View {
    let icon: String
    let iconColor: Color
    var iconUrl: String? = nil
    let title: String
    var subtitle: String? = nil
    var badges: [PreviewBadge] = []
    var details: [PreviewDetail] = []

    struct PreviewBadge: Hashable {
        let text: String
        let color: Color
    }

    struct PreviewDetail: Hashable {
        let icon: String
        let label: String
        let value: String
        var monospaced: Bool = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                CachedAsyncImage(url: iconUrl, size: 52) {
                    if #available(iOS 26, *) {
                        Image(systemName: icon)
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .glassEffect(.regular.tint(iconColor), in: .circle)
                    } else {
                        Image(systemName: icon)
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(iconColor, in: .circle)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if !badges.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(badges, id: \.self) { badge in
                                if #available(iOS 26, *) {
                                    Text(badge.text)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .foregroundStyle(.white)
                                        .glassEffect(.regular.tint(badge.color), in: .capsule)
                                } else {
                                    Text(badge.text)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .foregroundStyle(badge.color)
                                        .background(badge.color.opacity(0.15), in: .capsule)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }

            if !details.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(details, id: \.self) { detail in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(detail.label, systemImage: detail.icon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(detail.value)
                                .font(detail.monospaced
                                      ? .system(.caption, design: .monospaced)
                                      : .subheadline)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(Color(.secondarySystemGroupedBackground))
    }
}
