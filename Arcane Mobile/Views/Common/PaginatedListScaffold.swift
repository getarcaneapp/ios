import SwiftUI

/// Native pagination progress and explicit retry shared by resource lists.
struct PaginatedListFooter: View {
    var hasMore: Bool
    var loadMoreError: String?
    var onRetry: () -> Void
    var onLoadMore: () -> Void

    var body: some View {
        Group {
            if hasMore {
                if loadMoreError != nil {
                    Button("Retry loading more", action: onRetry)
                        .frame(maxWidth: .infinity)
                } else {
                    ProgressView("Loading more…")
                        .frame(maxWidth: .infinity)
                        .onAppear(perform: onLoadMore)
                }
            }
        }
    }
}

/// One container for the common loading/error/empty/content branching. Use it when
/// the content is a List; the caller owns its list style.
struct ResourceListContainer<Content: View>: View {
    var isLoading: Bool
    var isEmpty: Bool
    var errorMessage: String?
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if isLoading && isEmpty {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, isEmpty {
                ContentUnavailableView(
                    "Couldn't Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                content
            }
        }
    }
}

// Convenience for search + debounce wiring documentation.
// Real search fields stay in each view (different prompts), but the
// 200ms debounce contract is documented here so new lists match the
// existing ones (see 0.1.6 release note).
enum ListUX {
    /// Debounce interval for search fields across resource lists.
    static let searchDebounce: Duration = .milliseconds(200)
    /// Auto-pagination loads the next page when the progress footer appears.
    static let pageSizeDefault = 50
}

// MARK: - Safe external link

/// Renders a `Link` only when `URL(string:)` succeeds, avoiding `!` in view bodies.
/// Falls back to no row (safer than a broken link). Use for hardcoded marketing URLs.
struct SafeExternalLink<Label: View>: View {
    let urlString: String
    @ViewBuilder var label: Label

    var body: some View {
        if let url = URL(string: urlString) {
            Link(destination: url) { label }
        }
    }
}
