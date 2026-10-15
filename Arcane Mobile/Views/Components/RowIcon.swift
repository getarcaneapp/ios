import SwiftUI

/// Leading symbol for list rows: a tinted glyph on a soft rounded-square well.
/// Restrained — the tint sits at low opacity behind the glyph, and the well is
/// static rather than glass so dense lists don't pay an offscreen pass per row.
struct RowIcon: View {
    @Environment(\.appAccentColor) private var appAccentColor

    let systemImage: String
    /// Nil follows the app accent color.
    var tint: Color? = nil
    var size: CGFloat = 36
    /// The glyph bounces whenever this changes (e.g. a dashboard tile's value).
    var changeToken: String = ""

    var body: some View {
        let tint = tint ?? appAccentColor
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .symbolEffect(.bounce, value: changeToken)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: .rect(cornerRadius: Radius.small, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// An image reference with its namespace dimmed so the image's own name leads,
/// e.g. "ghcr.io/org/" in secondary, then "app". The tag is left to `TagChip`.
struct ImageReferenceName: View {
    let reference: ImageReferenceParts
    var font: Font = .body

    var body: some View {
        Text("\(Text(verbatim: reference.namespace).foregroundStyle(.secondary))\(Text(verbatim: reference.name))")
            .font(font)
    }
}

/// Secondary line naming a row's image: the reference at caption size with its
/// tag as a chip, for service and container rows that mention their image.
struct ImageReferenceLine: View {
    let reference: String

    var body: some View {
        let parts = ImageReferenceParts(reference)
        HStack(spacing: 6) {
            ImageReferenceName(reference: parts, font: .caption)
                .lineLimit(1)
                .truncationMode(.head)
            if let tag = parts.tag { TagChip(text: tag) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reference)
    }
}

/// Small monospaced chip for tags, versions, and other literal identifiers.
struct TagChip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: Radius.small, style: .continuous))
    }
}

/// Splits "ghcr.io/org/app:1.2" into "ghcr.io/org/", "app", and "1.2" so a row
/// can lead with the image's own name. Digest pins keep a short digest as the tag.
nonisolated struct ImageReferenceParts: Equatable, Sendable {
    let namespace: String
    let name: String
    let tag: String?

    init(namespace: String, name: String, tag: String?) {
        self.namespace = namespace
        self.name = name
        self.tag = tag
    }

    init(_ reference: String) {
        var path = Substring(reference)
        var tag: String?
        if let at = path.lastIndex(of: "@") {
            let digest = path[path.index(after: at)...]
            tag = String((digest.split(separator: ":").last ?? digest).prefix(12))
            path = path[..<at]
        }
        let slash = path.lastIndex(of: "/")
        let nameStart = slash.map { path.index(after: $0) } ?? path.startIndex
        // A colon before the last slash is a registry port, not a tag.
        if let colon = path[nameStart...].lastIndex(of: ":") {
            if tag == nil { tag = String(path[path.index(after: colon)...]) }
            path = path[..<colon]
        }
        namespace = String(path[..<nameStart])
        name = String(path[nameStart...])
        self.tag = tag?.isEmpty == true ? nil : tag
    }
}
