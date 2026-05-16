import SwiftUI
import Arcane
import UniformTypeIdentifiers

struct UploadImageView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let onComplete: () async -> Void

    @State private var pickedURL: URL?
    @State private var pickedSize: Int64 = 0
    @State private var pickedName: String = ""
    @State private var showImporter = false
    @State private var isUploading = false
    @State private var progress: Double = 0
    @State private var output: String?
    @State private var errorMessage: String?
    @State private var uploadTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let pickedURL {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pickedName).font(.subheadline)
                            Text(pickedSize.byteString).font(.caption).foregroundStyle(.secondary)
                            Text(pickedURL.path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Button("Change file…") { showImporter = true }
                            .disabled(isUploading)
                    } else {
                        Button {
                            showImporter = true
                        } label: {
                            Label("Choose tarball…", systemImage: "doc.zipper")
                        }
                    }
                } header: {
                    Text("File")
                } footer: {
                    Text("Accepts .tar, .tar.gz, .tgz, .tar.xz. Server enforces a max size (default 500 MB).")
                }

                if isUploading {
                    Section("Progress") {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: progress, total: 1.0)
                            Text("\(Int(progress * 100))%")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let output, !output.isEmpty {
                    Section("Result") {
                        ScrollView {
                            Text(output)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 200)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Upload Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isUploading ? "Stop" : "Cancel") {
                        if isUploading {
                            uploadTask?.cancel()
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if output != nil {
                        Button("Done") { dismiss() }
                    } else {
                        Button {
                            Task { await startUpload() }
                        } label: {
                            if isUploading { ProgressView().scaleEffect(0.8) }
                            else { Text("Upload") }
                        }
                        .disabled(pickedURL == nil || isUploading)
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handlePicked(result)
            }
        }
    }

    private var allowedContentTypes: [UTType] {
        var types: [UTType] = [.gzip, .data]
        if let tar = UTType("public.tar-archive") {
            types.append(tar)
        }
        return types
    }

    private func handlePicked(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // Document picker URLs need security-scoped access.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                pickedSize = (attrs[.size] as? Int64) ?? Int64((attrs[.size] as? Int) ?? 0)
            } catch {
                pickedSize = 0
            }
            pickedURL = url
            pickedName = url.lastPathComponent
            output = nil
            errorMessage = nil
        case .failure(let error):
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func startUpload() async {
        guard let client = manager.client,
              let url = pickedURL else {
            errorMessage = "Invalid configuration"
            return
        }
        isUploading = true
        progress = 0
        errorMessage = nil
        output = nil
        let cached = manager.cached
        let filename = pickedName
        let onComplete = onComplete
        let envID = environmentID

        uploadTask = Task {
            defer {
                isUploading = false
                uploadTask = nil
            }
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            do {
                // The SDK's uploadStream emits progress + load events as NDJSON.
                // We aggregate the human-readable status string for the final output.
                let stream = client.images.uploadStream(envID: envID, fileURL: url, filename: filename)
                var aggregated: [String] = []
                for try await event in stream {
                    if Task.isCancelled { break }
                    if let err = event.error, !err.isEmpty {
                        errorMessage = err
                        continue
                    }
                    if let detail = event.progressDetail,
                       let total = detail.total, total > 0,
                       let current = detail.current {
                        progress = Double(min(current, total)) / Double(total)
                    }
                    if let status = event.status, !status.isEmpty {
                        aggregated.append(status)
                    }
                }
                guard !Task.isCancelled else {
                    errorMessage = "Cancelled"
                    return
                }
                progress = 1.0
                output = aggregated.isEmpty ? "Upload complete." : aggregated.joined(separator: "\n")
                if let cached {
                    await cached.invalidate(envID: envID, paths: [
                        client.rest.environmentPath(envID, "images") + "*",
                        client.rest.environmentPath(envID, "images/*")
                    ])
                }
                mutationStore.markChanged(kind: .images, envID: envID)
                await onComplete()
            } catch is CancellationError {
                errorMessage = "Cancelled"
            } catch {
                errorMessage = friendlyErrorMessage(error)
            }
        }
    }
}
