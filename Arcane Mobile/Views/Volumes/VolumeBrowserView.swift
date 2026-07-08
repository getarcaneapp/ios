import SwiftUI
import Arcane

struct VolumeBrowserView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    let environmentID: EnvironmentID
    let volumeName: String

    @State private var segments: [String] = []
    @State private var entries: [FileEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var showPathAlert = false
    @State private var pathInput = "/"
    @State private var loadGeneration = 0

    private var currentPath: String {
        segments.isEmpty ? "/" : "/" + segments.joined(separator: "/")
    }

    private var displayedEntries: [FileEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? entries
            : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return filtered.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if isLoading && entries.isEmpty {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, entries.isEmpty {
                ContentUnavailableView(
                    "Couldn't Load Folder",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if displayedEntries.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("Empty Folder", systemImage: "folder")
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                List {
                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    ForEach(displayedEntries, id: \.path) { entry in
                        if entry.isDirectory {
                            Button {
                                openDirectory(entry)
                            } label: {
                                VolumeBrowserRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink(value: entry) {
                                VolumeBrowserRow(entry: entry)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(currentPath == "/" ? volumeName : currentPath)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search folder")
        .safeAreaInset(edge: .top, spacing: 0) {
            breadcrumbBar
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        pathInput = currentPath
                        showPathAlert = true
                    } label: {
                        Label("Go to Path", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    }
                    Button {
                        Task { await loadEntries() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More options")
            }
        }
        .navigationDestination(for: FileEntry.self) { entry in
            VolumeFileDetailView(entry: entry)
        }
        .alert("Go to Path", isPresented: $showPathAlert) {
            TextField("Path", text: $pathInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Go") {
                applyPathInput()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a path inside this volume.")
        }
        .task(id: currentPath) { await loadEntries() }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 8) {
            if !segments.isEmpty {
                Button {
                    segments.removeLast()
                } label: {
                    Image(systemName: "arrow.turn.left.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.pressable)
                .foregroundStyle(Color.accentColor)
                .glassEffectCompat(interactive: true, in: .capsule)
                .accessibilityLabel("Up one level")
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        breadcrumbChip(title: "/", id: "root", isCurrent: segments.isEmpty) {
                            segments = []
                        }
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                            let id = "segment-\(index)"
                            breadcrumbChip(title: segment, id: id, isCurrent: index == segments.count - 1) {
                                segments = Array(segments.prefix(index + 1))
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .onAppear {
                    proxy.scrollTo(currentBreadcrumbID, anchor: .trailing)
                }
                .onChange(of: currentBreadcrumbID) { _, id in
                    withAnimation(Motion.reduced(Motion.reflow, reduceMotion: reduceMotion)) {
                        proxy.scrollTo(id, anchor: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var currentBreadcrumbID: String {
        segments.isEmpty ? "root" : "segment-\(segments.count - 1)"
    }

    private func breadcrumbChip(
        title: String,
        id: String,
        isCurrent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 34)
        }
        .id(id)
        .buttonStyle(.pressable)
        .foregroundStyle(isCurrent ? .white : .primary)
        .modifier(VolumeBreadcrumbChrome(isCurrent: isCurrent))
        .accessibilityLabel(title == "/" ? "Root folder" : title)
    }

    private func openDirectory(_ entry: FileEntry) {
        segments.append(entry.name)
    }

    private func applyPathInput() {
        segments = Self.segments(from: pathInput)
    }

    private func loadEntries() async {
        guard let client = manager.client else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let requestedPath = currentPath
        if entries.isEmpty { isLoading = true }
        errorMessage = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }
        do {
            let nextEntries = try await client.volumes.browse(
                envID: environmentID,
                name: volumeName,
                path: requestedPath
            )
            guard loadGeneration == generation, !Task.isCancelled, requestedPath == currentPath else { return }
            entries = nextEntries
        } catch {
            guard loadGeneration == generation, !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = friendlyErrorMessage(error)
            entries = []
        }
    }

    private static func segments(from path: String) -> [String] {
        path.split(separator: "/")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private struct VolumeBreadcrumbChrome: ViewModifier {
    let isCurrent: Bool

    func body(content: Content) -> some View {
        if isCurrent {
            content.glassChipCompat(tint: .accentColor, interactive: true, in: .capsule)
        } else {
            content.glassEffectCompat(interactive: true, in: .capsule)
        }
    }
}

private struct VolumeBrowserRow: View {
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .font(.title3)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if entry.isDirectory {
                        Text("Folder")
                    } else {
                        Text(entry.size.byteString)
                    }
                    Text("•")
                    Text(entry.modTime, format: .relative(presentation: .named))
                    if entry.isSymlink {
                        Text("•")
                        Text("Symlink")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct VolumeFileDetailView: View {
    let entry: FileEntry

    var body: some View {
        List {
            Section {
                LabeledContent("Path", value: entry.path)
                LabeledContent("Size", value: entry.size.byteString)
                LabeledContent("Modified", value: entry.modTime.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Mode", value: entry.mode)
                LabeledContent("Symlink", value: entry.isSymlink ? "Yes" : "No")
                if let target = entry.linkTarget, !target.isEmpty {
                    LabeledContent("Link Target", value: target)
                }
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
