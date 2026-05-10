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
              let serverURL = URL(string: manager.serverURL),
              let url = pickedURL else {
            errorMessage = "Invalid configuration"
            return
        }
        isUploading = true
        progress = 0
        errorMessage = nil
        output = nil

        uploadTask = Task {
            defer { isUploading = false; uploadTask = nil }
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            do {
                let multipartFile = try buildMultipartTempFile(fileURL: url, fieldName: "file", filename: pickedName)
                defer { try? FileManager.default.removeItem(at: multipartFile.tempURL) }

                let api = NDJSONStream.apiURL(serverURL: serverURL, path: client.rest.environmentPath(environmentID, "images/upload"))
                var request = URLRequest(url: api)
                request.httpMethod = "POST"
                request.setValue("multipart/form-data; boundary=\(multipartFile.boundary)", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                for (key, value) in try await client.authManager.authenticationHeaders() {
                    request.setValue(value, forHTTPHeaderField: key)
                }

                let delegate = UploadProgressDelegate { fraction in
                    Task { @MainActor in
                        self.progress = fraction
                    }
                }
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let (data, response) = try await session.upload(for: request, fromFile: multipartFile.tempURL)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard (200..<300).contains(http.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                    throw NDJSONError(statusCode: http.statusCode, message: body)
                }
                progress = 1.0
                let parsed = try? JSONDecoder().decode(APIResponseEnvelope<LoadResult>.self, from: data)
                output = parsed?.data?.stream ?? "Upload complete."
                if let cached = manager.cached {
                    await cached.invalidate(envID: environmentID, paths: [
                        client.rest.environmentPath(environmentID, "images") + "*",
                        client.rest.environmentPath(environmentID, "images/*")
                    ])
                }
                mutationStore.markChanged(kind: .images, envID: environmentID)
                await onComplete()
            } catch is CancellationError {
                errorMessage = "Cancelled"
            } catch {
                errorMessage = friendlyErrorMessage(error)
            }
        }
    }

    private struct MultipartFile {
        let tempURL: URL
        let boundary: String
    }

    private func buildMultipartTempFile(fileURL: URL, fieldName: String, filename: String) throws -> MultipartFile {
        let boundary = "----ArcaneMobileBoundary\(UUID().uuidString)"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        try handle.write(contentsOf: Data(header.utf8))

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while autoreleasepool(invoking: { () -> Bool in
            let chunk = input.availableData
            if chunk.isEmpty { return false }
            try? handle.write(contentsOf: chunk)
            return true
        }) {}

        let footer = "\r\n--\(boundary)--\r\n"
        try handle.write(contentsOf: Data(footer.utf8))
        return MultipartFile(tempURL: tempURL, boundary: boundary)
    }
}

nonisolated private struct LoadResult: Decodable, Sendable {
    let stream: String?
}

nonisolated private struct APIResponseEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let success: Bool?
    let data: T?
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
