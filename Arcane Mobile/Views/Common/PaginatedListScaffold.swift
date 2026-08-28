import SwiftUI

// MARK: - PaginatedListScaffold
//
// Reusable list chrome for resource lists (Containers, Images, Networks, Volumes,
// Projects, Ports, Jobs, Variables...). Consolidates the repeated pattern:
//
//   Group { if isLoading && items.isEmpty { skeleton } else if error { … } else if empty { … } else { List { rows + pagination footer } } }
//
// Extracted so future lists import one component instead of copy-pasted `pagination.hasMore`
// + `SkeletonListRow` + retry + `loadMore` wiring.

/// Footer for paginated Lists. Handles the three states the pagination loop cycles
/// through: more to load (shimmer), retry, or done.
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
                    SkeletonListRow()
                        .skeletonShimmer()
                        .onAppear(perform: onLoadMore)
                }
            }
        }
    }
}

/// One container for the common loading/error/empty/content branching. Use it when
/// the content is a List; it owns the `insetGrouped` style choice.
struct ResourceListContainer<Content: View>: View {
    var isLoading: Bool
    var isEmpty: Bool
    var errorMessage: String?
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if isLoading && isEmpty {
                SkeletonListLoadingView()
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
    /// Auto-pagination trigger — next page loads when the skeleton footer appears.
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
