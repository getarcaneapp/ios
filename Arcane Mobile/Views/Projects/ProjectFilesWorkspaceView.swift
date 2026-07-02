import SwiftUI
import Arcane

enum ProjectFilesWorkspaceDestination: Hashable {
    case compose
    case env
    case files
    case folder(String)
    case managedFile(String)
}

struct ProjectFilesWorkspaceView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let projectID: String
    let initialProjectName: String
    let environmentID: EnvironmentID
    let initialSelection: ProjectFilesWorkspaceDestination
    let initialReadOnlyReason: String?

    @State private var selected: ProjectFilesWorkspaceDestination
    @State private var projectName: String
    @State private var composeFileName = "compose.yml"
    @State private var composeContent = ""
    @State private var envContent = ""
    @State private var originalComposeContent = ""
    @State private var originalEnvContent = ""
    @State private var projectFiles: [ProjectFile] = []
    @State private var fileTreeRevision: String?
    @State private var stagedChanges: [ProjectFileChange] = []
    @State private var managedFileContents: [String: String] = [:]
    @State private var originalManagedFileContents: [String: String] = [:]
    @State private var managedFileLoadErrors: [String: String] = [:]
    @State private var managedFileLoading: Set<String> = []
    @State private var readOnlyReason: String?
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showRender = false
    @State private var fileDialog: ProjectFileDialog?
    @State private var pendingDelete: ManagedProjectFileEntry?

    init(
        project: ProjectDetails,
        environmentID: EnvironmentID,
        initialSelection: ProjectFilesWorkspaceDestination
    ) {
        self.projectID = project.id
        self.initialProjectName = project.displayName
        self.environmentID = environmentID
        self.initialSelection = initialSelection
        if project.isArchived {
            self.initialReadOnlyReason = "Archived projects are read-only."
        } else if project.gitOpsManagedBy != nil {
            self.initialReadOnlyReason = "GitOps-managed project files are read-only."
        } else {
            self.initialReadOnlyReason = nil
        }
        _selected = State(initialValue: initialSelection)
        _projectName = State(initialValue: project.displayName)
        _readOnlyReason = State(initialValue: initialReadOnlyReason)
    }

    private var canEdit: Bool { readOnlyReason == nil }

    private var hasCoreChanges: Bool {
        composeContent != originalComposeContent || envContent != originalEnvContent
    }

    private var changedManagedFilePaths: [String] {
        managedFileContents.keys
            .filter { managedFileContents[$0] != originalManagedFileContents[$0] }
            .sorted()
    }

    private var hasManagedChanges: Bool {
        !stagedChanges.isEmpty || !changedManagedFilePaths.isEmpty
    }

    private var hasChanges: Bool {
        hasCoreChanges || hasManagedChanges
    }

    private var displayedFiles: [ManagedProjectFileEntry] {
        ProjectFileWorkspaceHelpers.apply(projectFiles: projectFiles, changes: stagedChanges)
    }

    private var displayedPathSet: Set<String> {
        Set(displayedFiles.map(\.relativePath))
    }

    var body: some View {
        Group {
            if isLoading && !hasLoaded {
                ProgressView("Loading files...")
                    .navigationTitle("Project Files")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                workspaceContent(for: selected)
            }
        }
        .navigationDestination(for: ProjectFilesWorkspaceDestination.self) { destination in
            workspaceContent(for: destination)
        }
        // Presented as a sheet, so the root needs an explicit dismiss. Pushed
        // drill-downs keep the NavigationStack's automatic back button; this
        // leading item shows only on the workspace root.
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showRender) {
            RenderComposeView(
                initialCompose: composeContent,
                initialEnv: envContent,
                environmentID: environmentID
            ) { resolved in
                composeContent = resolved
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $fileDialog) { dialog in
            ProjectFileDialogView(
                dialog: dialog,
                folders: displayedFiles.filter(\.isDirectory),
                existingPaths: displayedPathSet,
                composeFileName: composeFileName
            ) { result in
                submitFileDialog(result)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .deleteConfirmation(item: $pendingDelete) { entry in
            DeleteConfirmationConfig(
                title: entry.isDirectory ? "Delete Folder" : "Delete File",
                message: entry.isDirectory
                    ? "Delete \(entry.relativePath) and all files inside it."
                    : "Delete \(entry.relativePath).",
                icon: "trash",
                actions: [
                    DeleteConfirmationAction(title: "Delete") {
                        stageDelete(entry)
                    }
                ]
            )
        }
        .task {
            if !hasLoaded {
                await loadFiles()
            }
        }
    }

    @ViewBuilder
    private func workspaceContent(for destination: ProjectFilesWorkspaceDestination) -> some View {
        switch destination {
        case .compose:
            composeEditor
                .navigationTitle(composeFileName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { editorToolbar(folderPath: "") }
        case .env:
            envEditor
                .navigationTitle(".env")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { editorToolbar(folderPath: "") }
        case .files:
            filesBrowser(folderPath: "")
                .navigationTitle("Project Files")
                .navigationBarTitleDisplayMode(.large)
                .toolbar { browserToolbar(folderPath: "") }
        case .folder(let path):
            filesBrowser(folderPath: path)
                .navigationTitle(ProjectFileWorkspaceHelpers.basename(path))
                .navigationBarTitleDisplayMode(.large)
                .toolbar { browserToolbar(folderPath: path) }
        case .managedFile(let path):
            managedFileEditor(path: path)
                .navigationTitle(ProjectFileWorkspaceHelpers.basename(path))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { editorToolbar(folderPath: ProjectFileWorkspaceHelpers.parentPath(path)) }
        }
    }

    private var composeEditor: some View {
        ProjectTextFileEditorView(
            text: $composeContent,
            language: .yaml,
            readOnly: !canEdit,
            readOnlyMessage: readOnlyReason,
            isLoading: false,
            errorMessage: errorMessage,
            allowsResolveVariables: true,
            onResolveVariables: { showRender = true }
        )
    }

    private var envEditor: some View {
        ProjectTextFileEditorView(
            text: $envContent,
            language: .env,
            readOnly: !canEdit,
            readOnlyMessage: readOnlyReason,
            isLoading: false,
            errorMessage: errorMessage
        )
    }

    @ToolbarContentBuilder
    private func browserToolbar(folderPath: String) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            projectFileMenu(folderPath: folderPath)
            saveButton
        }
    }

    @ToolbarContentBuilder
    private func editorToolbar(folderPath: String) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            projectFileMenu(folderPath: folderPath)
            saveButton
        }
    }

    private func projectFileMenu(folderPath: String) -> some View {
        Menu {
            Button {
                Task { await loadFiles(refresh: true) }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            Divider()
            Button {
                fileDialog = .createFile(parentPath: folderPath)
            } label: {
                Label("New File", systemImage: "doc.badge.plus")
            }
            .disabled(!canEdit)
            Button {
                fileDialog = .createFolder(parentPath: folderPath)
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(!canEdit)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Project file options")
    }

    private var saveButton: some View {
        Button {
            Task { await saveChanges() }
        } label: {
            if isSaving {
                ProgressView().scaleEffect(0.8)
            } else {
                Text("Save")
            }
        }
        .disabled(!canEdit || !hasChanges || isSaving)
    }

    private func filesBrowser(folderPath: String) -> some View {
        List {
            if let readOnlyReason {
                Section {
                    Label(readOnlyReason, systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if folderPath.isEmpty {
                Section("Project") {
                    NavigationLink(value: ProjectFilesWorkspaceDestination.compose) {
                        ProjectCoreFileRow(
                            title: composeFileName,
                            systemImage: "doc.text",
                            hasChanges: composeContent != originalComposeContent
                        )
                    }
                    NavigationLink(value: ProjectFilesWorkspaceDestination.env) {
                        ProjectCoreFileRow(
                            title: ".env",
                            systemImage: "key.horizontal",
                            hasChanges: envContent != originalEnvContent
                        )
                    }
                }
            }

            Section(folderPath.isEmpty ? "Files" : "Contents") {
                let children = childEntries(in: folderPath)
                if children.isEmpty {
                    ContentUnavailableView(
                        folderPath.isEmpty ? "No Custom Files" : "Empty Folder",
                        systemImage: "folder",
                        description: Text(folderPath.isEmpty
                            ? "Add project files used by compose includes, configs, secrets, or runtime configuration."
                            : "Add files or folders here from the menu.")
                    )
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                } else {
                    ForEach(children) { entry in
                        if entry.isDirectory {
                            NavigationLink(value: ProjectFilesWorkspaceDestination.folder(entry.relativePath)) {
                                ProjectFileBrowserRow(
                                    entry: entry,
                                    hasChanges: fileHasUnsavedContent(entry.relativePath),
                                    isLoading: managedFileLoading.contains(entry.relativePath),
                                    showsDisclosure: false,
                                    showsDetailPath: false
                                )
                            }
                            .contextMenu { managedFileContextMenu(for: entry) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                managedFileSwipeActions(for: entry)
                            }
                        } else {
                            NavigationLink(value: ProjectFilesWorkspaceDestination.managedFile(entry.relativePath)) {
                                ProjectFileBrowserRow(
                                    entry: entry,
                                    hasChanges: fileHasUnsavedContent(entry.relativePath),
                                    isLoading: managedFileLoading.contains(entry.relativePath),
                                    showsDisclosure: false,
                                    showsDetailPath: false
                                )
                            }
                            .contextMenu { managedFileContextMenu(for: entry) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                managedFileSwipeActions(for: entry)
                            }
                        }
                    }
                }
            }

            if hasChanges {
                Section {
                    Label("Unsaved changes", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await loadFiles(refresh: true)
        }
    }

    private func childEntries(in folderPath: String) -> [ManagedProjectFileEntry] {
        displayedFiles.filter { entry in
            ProjectFileWorkspaceHelpers.parentPath(entry.relativePath) == folderPath
        }
    }

    @ViewBuilder
    private func managedFileEditor(path: String) -> some View {
        if let entry = displayedFiles.first(where: { $0.relativePath == path }), entry.isDirectory {
            ContentUnavailableView("Folder", systemImage: "folder", description: Text(path))
        } else {
            ProjectTextFileEditorView(
                text: bindingForManagedFile(path),
                language: ProjectFileWorkspaceHelpers.language(for: path),
                readOnly: !canEdit || (displayedFiles.first(where: { $0.relativePath == path })?.isProtected == true),
                readOnlyMessage: readOnlyReason,
                isLoading: managedFileLoading.contains(path),
                errorMessage: managedFileLoadErrors[path],
                onRetry: {
                    Task { await loadManagedFileContent(path, force: true) }
                }
            )
            .task(id: path) {
                await loadManagedFileContent(path)
            }
        }
    }

    @ViewBuilder
    private func managedFileContextMenu(for entry: ManagedProjectFileEntry) -> some View {
        if canEdit && !entry.isProtected {
            if entry.isDirectory {
                Button {
                    fileDialog = .createFile(parentPath: entry.relativePath)
                } label: {
                    Label("New File", systemImage: "doc.badge.plus")
                }
                Button {
                    fileDialog = .createFolder(parentPath: entry.relativePath)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
            Button {
                fileDialog = .rename(path: entry.relativePath, currentName: entry.name)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                fileDialog = .move(path: entry.relativePath)
            } label: {
                Label("Move", systemImage: "folder")
            }
            Button(role: .destructive) {
                pendingDelete = entry
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } else {
            Label("Read Only", systemImage: "lock")
        }
    }

    @ViewBuilder
    private func managedFileSwipeActions(for entry: ManagedProjectFileEntry) -> some View {
        if canEdit && !entry.isProtected {
            Button(role: .destructive) {
                pendingDelete = entry
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    private func loadFiles(refresh: Bool = false) async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            async let composeDetails = client.projects.compose(envID: environmentID, projectID: projectID)
            async let filesDetails = client.projects.files(envID: environmentID, projectID: projectID)
            let (compose, files) = try await (composeDetails, filesDetails)
            projectName = compose.displayName
            composeFileName = compose.composeFileName?.isEmpty == false ? (compose.composeFileName ?? "compose.yml") : "compose.yml"
            composeContent = compose.composeContent ?? ""
            envContent = compose.envContent ?? ""
            originalComposeContent = composeContent
            originalEnvContent = envContent
            projectFiles = files.projectFiles ?? compose.projectFiles ?? []
            fileTreeRevision = files.fileTreeRevision ?? compose.fileTreeRevision
            stagedChanges = []
            managedFileContents = [:]
            originalManagedFileContents = [:]
            managedFileLoadErrors = [:]
            managedFileLoading = []
            readOnlyReason = compose.isArchived ? "Archived projects are read-only." :
                (compose.gitOpsManagedBy != nil ? "GitOps-managed project files are read-only." : nil)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func loadManagedFileContent(_ path: String, force: Bool = false) async {
        guard force || managedFileContents[path] == nil else { return }
        guard displayedFiles.first(where: { $0.relativePath == path })?.isDirectory != true else { return }
        guard let client = manager.client else { return }
        managedFileLoading.insert(path)
        managedFileLoadErrors[path] = nil
        defer { managedFileLoading.remove(path) }
        do {
            let file = try await client.projects.file(envID: environmentID, projectID: projectID, relativePath: path)
            let content = file.content ?? ""
            managedFileContents[path] = content
            originalManagedFileContents[path] = content
        } catch {
            managedFileLoadErrors[path] = friendlyErrorMessage(error)
        }
    }

    private func bindingForManagedFile(_ path: String) -> Binding<String> {
        Binding(
            get: { managedFileContents[path] ?? "" },
            set: { managedFileContents[path] = $0 }
        )
    }

    private func saveChanges() async {
        guard canEdit, hasChanges, let client = manager.client else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let fileChanges = buildProjectFileSaveChanges()
        let request = UpdateProject(
            name: nil,
            composeContent: composeContent != originalComposeContent ? composeContent : nil,
            envContent: envContent != originalEnvContent ? envContent : nil,
            fileTreeRevision: fileChanges.isEmpty ? nil : fileTreeRevision,
            fileChanges: fileChanges.isEmpty ? nil : fileChanges
        )

        do {
            _ = try await client.projects.update(envID: environmentID, projectID: projectID, request: request)
            showToast(.success("Saved"))
            await invalidateProjectCaches()
            mutationStore.markChanged(kind: .projects, envID: environmentID)
            await loadFiles(refresh: true)
        } catch {
            errorMessage = friendlyErrorMessage(error)
            showToast(.error("Couldn't save"))
        }
    }

    private func buildProjectFileSaveChanges() -> [ProjectFileChange] {
        var changes = stagedChanges
        var contentChanges: [String: String] = [:]
        for path in changedManagedFilePaths {
            if let content = managedFileContents[path] {
                contentChanges[path] = content
            }
        }

        var createFilePaths = Set<String>()
        for index in changes.indices where changes[index].operation == .createFile {
            let path = changes[index].relativePath
            createFilePaths.insert(path)
            if let content = contentChanges[path] {
                changes[index].content = content
            } else if changes[index].content == nil {
                changes[index].content = ""
            }
        }

        for (path, content) in contentChanges.sorted(by: { $0.key < $1.key }) {
            if createFilePaths.contains(path) || isDeleted(path, by: changes) {
                continue
            }
            changes.append(ProjectFileChange(operation: .updateFile, relativePath: path, content: content))
        }
        return changes
    }

    private func isDeleted(_ path: String, by changes: [ProjectFileChange]) -> Bool {
        changes.contains { change in
            change.operation == .delete && ProjectFileWorkspaceHelpers.pathMatches(path, root: change.relativePath)
        }
    }

    private func submitFileDialog(_ result: ProjectFileDialogResult) -> String? {
        switch result {
        case .createFile(let parentPath, let name):
            guard let path = ProjectFileWorkspaceHelpers.planCreate(
                existingPaths: displayedPathSet,
                parentPath: parentPath,
                name: name,
                composeFileName: composeFileName
            ) else {
                return "Use a unique file name that is not reserved by Arcane."
            }
            stagedChanges.append(ProjectFileChange(operation: .createFile, relativePath: path, content: ""))
            managedFileContents[path] = ""
            selected = .managedFile(path)
            return nil
        case .createFolder(let parentPath, let name):
            guard let path = ProjectFileWorkspaceHelpers.planCreate(
                existingPaths: displayedPathSet,
                parentPath: parentPath,
                name: name,
                composeFileName: composeFileName
            ) else {
                return "Use a unique folder name that is not reserved by Arcane."
            }
            stagedChanges.append(ProjectFileChange(operation: .createFolder, relativePath: path))
            return nil
        case .rename(let path, let newName):
            guard let plan = ProjectFileWorkspaceHelpers.planRename(
                existingPaths: displayedPathSet,
                relativePath: path,
                newName: newName,
                composeFileName: composeFileName
            ) else {
                return "Use a unique file name that is not reserved by Arcane."
            }
            stagedChanges.append(ProjectFileChange(operation: .rename, relativePath: path, newName: plan.newName))
            remapManagedState(from: path, to: plan.newPath)
            if selected == .managedFile(path) {
                selected = .managedFile(plan.newPath)
            }
            return nil
        case .move(let path, let newParentPath):
            guard let entry = displayedFiles.first(where: { $0.relativePath == path }),
                  let newPath = ProjectFileWorkspaceHelpers.planMove(
                    entry: entry,
                    existingPaths: displayedPathSet,
                    relativePath: path,
                    newParentPath: newParentPath
                  ) else {
                return "Choose a different destination folder."
            }
            stagedChanges.append(ProjectFileChange(operation: .move, relativePath: path, newParentPath: newParentPath))
            remapManagedState(from: path, to: newPath)
            if selected == .managedFile(path) {
                selected = .managedFile(newPath)
            }
            return nil
        }
    }

    private func stageDelete(_ entry: ManagedProjectFileEntry) {
        stagedChanges.append(ProjectFileChange(
            operation: .delete,
            relativePath: entry.relativePath,
            recursive: entry.isDirectory ? true : nil
        ))
        removeManagedState(root: entry.relativePath)
        if case .managedFile(let path) = selected,
           ProjectFileWorkspaceHelpers.pathMatches(path, root: entry.relativePath) {
            selected = .files
        }
    }

    private func fileHasUnsavedContent(_ path: String) -> Bool {
        managedFileContents[path] != nil && managedFileContents[path] != originalManagedFileContents[path]
    }

    private func remapManagedState(from oldPath: String, to newPath: String) {
        managedFileContents = ProjectFileWorkspaceHelpers.remapRecord(managedFileContents, from: oldPath, to: newPath)
        originalManagedFileContents = ProjectFileWorkspaceHelpers.remapRecord(originalManagedFileContents, from: oldPath, to: newPath)
        managedFileLoadErrors = ProjectFileWorkspaceHelpers.remapRecord(managedFileLoadErrors, from: oldPath, to: newPath)
        managedFileLoading = Set(managedFileLoading.map { path in
            ProjectFileWorkspaceHelpers.pathMatches(path, root: oldPath)
                ? "\(newPath)\(path.dropFirst(oldPath.count))"
                : path
        })
    }

    private func removeManagedState(root: String) {
        managedFileContents = ProjectFileWorkspaceHelpers.removeRecord(managedFileContents, root: root)
        originalManagedFileContents = ProjectFileWorkspaceHelpers.removeRecord(originalManagedFileContents, root: root)
        managedFileLoadErrors = ProjectFileWorkspaceHelpers.removeRecord(managedFileLoadErrors, root: root)
        managedFileLoading = managedFileLoading.filter { !ProjectFileWorkspaceHelpers.pathMatches($0, root: root) }
    }

    private func invalidateProjectCaches() async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(envID: environmentID, paths: [
            client.rest.environmentPath(environmentID, "projects") + "*",
            client.rest.environmentPath(environmentID, "projects/*")
        ])
    }
}

private struct ProjectTextFileEditorView: View {
    @Binding var text: String
    let language: EditorLanguage
    let readOnly: Bool
    let readOnlyMessage: String?
    let isLoading: Bool
    let errorMessage: String?
    var allowsResolveVariables = false
    var onResolveVariables: (() -> Void)?
    var onRetry: (() -> Void)?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CodeEditorView(text: $text, language: language, readOnly: readOnly)
                .ignoresSafeArea(.keyboard, edges: .bottom)

            if isLoading {
                ProgressView("Loading file...")
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 8, style: .continuous))
            }

            if allowsResolveVariables && !readOnly && !text.isEmpty {
                Button {
                    onResolveVariables?()
                } label: {
                    Image(systemName: "curlybraces")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.indigo)
                        .frame(width: 52, height: 52)
                        .glassEffectCompat(in: .circle)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 16)
                .accessibilityLabel("Resolve Variables")
            }
        }
        .safeAreaInset(edge: .top) {
            editorBanner
        }
    }

    @ViewBuilder
    private var editorBanner: some View {
        if let errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
                if let onRetry {
                    Button("Retry") { onRetry() }
                        .font(.caption.weight(.semibold))
                }
            }
            .padding(10)
            .background(.red.opacity(0.1))
        } else if readOnly, let readOnlyMessage {
            Label(readOnlyMessage, systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.regularMaterial)
        }
    }
}

private struct ProjectCoreFileRow: View {
    let title: String
    let systemImage: String
    let hasChanges: Bool

    var body: some View {
        ProjectFileBrowserRow(
            name: title,
            detail: nil,
            systemImage: systemImage,
            isDirectory: false,
            isProtected: false,
            hasChanges: hasChanges,
            depth: 0,
            showsDisclosure: true
        )
    }
}

struct ProjectFileBrowserRow: View {
    let name: String
    let detail: String?
    let systemImage: String
    let isDirectory: Bool
    let isProtected: Bool
    let hasChanges: Bool
    let depth: Int
    let isLoading: Bool
    let showsDisclosure: Bool
    let showsDetailPath: Bool

    init(
        name: String,
        detail: String?,
        systemImage: String,
        isDirectory: Bool,
        isProtected: Bool = false,
        hasChanges: Bool = false,
        depth: Int = 0,
        isLoading: Bool = false,
        showsDisclosure: Bool = true,
        showsDetailPath: Bool = true
    ) {
        self.name = name
        self.detail = detail
        self.systemImage = systemImage
        self.isDirectory = isDirectory
        self.isProtected = isProtected
        self.hasChanges = hasChanges
        self.depth = depth
        self.isLoading = isLoading
        self.showsDisclosure = showsDisclosure
        self.showsDetailPath = showsDetailPath
    }

    init(
        entry: ManagedProjectFileEntry,
        hasChanges: Bool = false,
        isLoading: Bool = false,
        showsDisclosure: Bool = true,
        showsDetailPath: Bool = true
    ) {
        self.init(
            name: entry.name,
            detail: showsDetailPath ? entry.relativePath : nil,
            systemImage: entry.isDirectory ? "folder.fill" : "doc.text",
            isDirectory: entry.isDirectory,
            isProtected: entry.isProtected,
            hasChanges: entry.pending || hasChanges,
            depth: entry.depth,
            isLoading: isLoading,
            showsDisclosure: showsDisclosure,
            showsDetailPath: showsDetailPath
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(name)
                        .font(.body)
                        .lineLimit(1)
                    if isProtected {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if hasChanges {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.orange)
                    }
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isLoading {
                ProgressView().scaleEffect(0.75)
            } else if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, CGFloat(depth) * 16)
        .contentShape(.rect)
    }
}

private struct ProjectFileDialogView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let dialog: ProjectFileDialog
    let folders: [ManagedProjectFileEntry]
    let existingPaths: Set<String>
    let composeFileName: String
    let onSubmit: (ProjectFileDialogResult) -> String?

    @State private var name: String
    @State private var destinationPath: String
    @State private var errorMessage: String?

    init(
        dialog: ProjectFileDialog,
        folders: [ManagedProjectFileEntry],
        existingPaths: Set<String>,
        composeFileName: String,
        onSubmit: @escaping (ProjectFileDialogResult) -> String?
    ) {
        self.dialog = dialog
        self.folders = folders
        self.existingPaths = existingPaths
        self.composeFileName = composeFileName
        self.onSubmit = onSubmit
        _name = State(initialValue: dialog.initialName)
        _destinationPath = State(initialValue: dialog.initialDestination)
    }

    var body: some View {
        NavigationStack {
            Form {
                if dialog.needsName {
                    Section(dialog.nameSectionTitle) {
                        FormTextField(
                            title: "Name",
                            placeholder: dialog.namePlaceholder,
                            text: $name,
                            autocapitalization: .never,
                            autocorrectionDisabled: true,
                            monospaced: true
                        )
                    }
                }

                if dialog.needsDestination {
                    Section("Destination") {
                        Picker("Folder", selection: $destinationPath) {
                            Text("Project root").tag("")
                            ForEach(moveDestinationFolders) { folder in
                                Text(folder.relativePath).tag(folder.relativePath)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(dialog.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(dialog.actionTitle) {
                        submit()
                    }
                }
            }
        }
    }

    private var moveDestinationFolders: [ManagedProjectFileEntry] {
        folders.filter { folder in
            guard case .move(let path) = dialog else { return true }
            let entry = folders.first { $0.relativePath == path }
            if entry?.isDirectory == true && ProjectFileWorkspaceHelpers.pathMatches(folder.relativePath, root: path) {
                return false
            }
            return folder.relativePath != path
        }
    }

    private func submit() {
        let result: ProjectFileDialogResult
        switch dialog {
        case .createFile:
            result = .createFile(parentPath: destinationPath, name: name)
        case .createFolder:
            result = .createFolder(parentPath: destinationPath, name: name)
        case .rename(let path, _):
            result = .rename(path: path, newName: name)
        case .move(let path):
            result = .move(path: path, newParentPath: destinationPath)
        }

        if let message = onSubmit(result) {
            errorMessage = message
        } else {
            dismiss()
        }
    }
}

private enum ProjectFileDialog: Identifiable {
    case createFile(parentPath: String)
    case createFolder(parentPath: String)
    case rename(path: String, currentName: String)
    case move(path: String)

    var id: String {
        switch self {
        case .createFile(let parentPath):
            return "create-file:\(parentPath)"
        case .createFolder(let parentPath):
            return "create-folder:\(parentPath)"
        case .rename(let path, _):
            return "rename:\(path)"
        case .move(let path):
            return "move:\(path)"
        }
    }

    var title: String {
        switch self {
        case .createFile:
            return "New File"
        case .createFolder:
            return "New Folder"
        case .rename:
            return "Rename"
        case .move:
            return "Move"
        }
    }

    var actionTitle: String {
        switch self {
        case .createFile, .createFolder:
            return "Create"
        case .rename:
            return "Rename"
        case .move:
            return "Move"
        }
    }

    var initialName: String {
        switch self {
        case .rename(_, let currentName):
            return currentName
        default:
            return ""
        }
    }

    var initialDestination: String {
        switch self {
        case .createFile(let parentPath), .createFolder(let parentPath):
            return parentPath
        case .move(let path):
            return ProjectFileWorkspaceHelpers.parentPath(path)
        case .rename:
            return ""
        }
    }

    var needsName: Bool {
        switch self {
        case .createFile, .createFolder, .rename:
            return true
        case .move:
            return false
        }
    }

    var needsDestination: Bool {
        switch self {
        case .createFile, .createFolder, .move:
            return true
        case .rename:
            return false
        }
    }

    var nameSectionTitle: String {
        switch self {
        case .createFile:
            return "File Name"
        case .createFolder:
            return "Folder Name"
        case .rename:
            return "New Name"
        case .move:
            return ""
        }
    }

    var namePlaceholder: String {
        switch self {
        case .createFile:
            return "config.yaml"
        case .createFolder:
            return "config"
        case .rename:
            return "name"
        case .move:
            return ""
        }
    }
}

private enum ProjectFileDialogResult {
    case createFile(parentPath: String, name: String)
    case createFolder(parentPath: String, name: String)
    case rename(path: String, newName: String)
    case move(path: String, newParentPath: String)
}

struct ManagedProjectFileEntry: Identifiable, Hashable {
    var id: String { relativePath }
    var path: String
    var relativePath: String
    var name: String
    var isDirectory: Bool
    var size: Int64
    var protected: Bool?
    var pending: Bool
    var depth: Int

    var isProtected: Bool { protected == true }
}

enum ProjectFileWorkspaceHelpers {
    private static let reservedRootNames: Set<String> = [
        ".env",
        ".env.git",
        "project.env",
        "compose.yaml",
        "compose.yml",
        "docker-compose.yaml",
        "docker-compose.yml"
    ]

    static func apply(projectFiles: [ProjectFile], changes: [ProjectFileChange]) -> [ManagedProjectFileEntry] {
        var entries = Dictionary(uniqueKeysWithValues: projectFiles.map { file in
            (file.relativePath, ManagedProjectFileEntry(
                path: file.path,
                relativePath: file.relativePath,
                name: file.name.isEmpty ? basename(file.relativePath) : file.name,
                isDirectory: file.isDirectory,
                size: file.size,
                protected: file.protected,
                pending: false,
                depth: depth(file.relativePath)
            ))
        })

        for change in changes {
            let relativePath = normalize(change.relativePath)
            switch change.operation {
            case .createFile:
                entries[relativePath] = ManagedProjectFileEntry(
                    path: relativePath,
                    relativePath: relativePath,
                    name: basename(relativePath),
                    isDirectory: false,
                    size: Int64(change.content?.count ?? 0),
                    protected: false,
                    pending: true,
                    depth: depth(relativePath)
                )
            case .createFolder:
                entries[relativePath] = ManagedProjectFileEntry(
                    path: relativePath,
                    relativePath: relativePath,
                    name: basename(relativePath),
                    isDirectory: true,
                    size: 0,
                    protected: false,
                    pending: true,
                    depth: depth(relativePath)
                )
            case .updateFile:
                if var entry = entries[relativePath] {
                    entry.pending = true
                    entries[relativePath] = entry
                }
            case .rename:
                guard let newName = change.newName else { continue }
                let parent = parentPath(relativePath)
                remapEntries(&entries, from: relativePath, to: join(parent: parent, name: newName))
            case .move:
                let parent = normalize(change.newParentPath ?? "")
                remapEntries(&entries, from: relativePath, to: join(parent: parent, name: basename(relativePath)))
            case .delete:
                for path in entries.keys where pathMatches(path, root: relativePath) {
                    entries.removeValue(forKey: path)
                }
            }
        }

        return entries.values.sorted { lhs, rhs in
            browserSort(lhs, rhs, entries: entries)
        }
    }

    static func language(for relativePath: String) -> EditorLanguage {
        let lower = relativePath.lowercased()
        let base = basename(lower)
        if lower.hasSuffix(".env") || base.hasPrefix(".env") {
            return .env
        }
        if lower.hasSuffix(".yaml") || lower.hasSuffix(".yml") {
            return .yaml
        }
        return .plaintext
    }

    static func planCreate(
        existingPaths: Set<String>,
        parentPath: String,
        name: String,
        composeFileName: String
    ) -> String? {
        guard let validName = validateFileName(name, parentPath: parentPath, composeFileName: composeFileName) else {
            return nil
        }
        let relativePath = join(parent: parentPath, name: validName)
        return existingPaths.contains(relativePath) ? nil : relativePath
    }

    static func planRename(
        existingPaths: Set<String>,
        relativePath: String,
        newName: String,
        composeFileName: String
    ) -> (newName: String, newPath: String)? {
        let parent = parentPath(relativePath)
        guard let validName = validateFileName(newName, parentPath: parent, composeFileName: composeFileName) else {
            return nil
        }
        let newPath = join(parent: parent, name: validName)
        guard newPath == relativePath || !existingPaths.contains(newPath) else { return nil }
        return (validName, newPath)
    }

    static func planMove(
        entry: ManagedProjectFileEntry,
        existingPaths: Set<String>,
        relativePath: String,
        newParentPath: String
    ) -> String? {
        let parent = normalize(newParentPath)
        guard parent != parentPath(relativePath) else { return nil }
        if entry.isDirectory, !parent.isEmpty, pathMatches(parent, root: relativePath) {
            return nil
        }
        let newPath = join(parent: parent, name: basename(relativePath))
        guard newPath == relativePath || !existingPaths.contains(newPath) else { return nil }
        return newPath
    }

    static func basename(_ relativePath: String) -> String {
        let normalized = normalize(relativePath)
        guard let slash = normalized.lastIndex(of: "/") else { return normalized }
        return String(normalized[normalized.index(after: slash)...])
    }

    static func parentPath(_ relativePath: String) -> String {
        let normalized = normalize(relativePath)
        guard let slash = normalized.lastIndex(of: "/") else { return "" }
        return String(normalized[..<slash])
    }

    static func pathMatches(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix("\(root)/")
    }

    static func remapRecord<T>(_ record: [String: T], from oldPath: String, to newPath: String) -> [String: T] {
        Dictionary(uniqueKeysWithValues: record.map { path, value in
            if pathMatches(path, root: oldPath) {
                return ("\(newPath)\(path.dropFirst(oldPath.count))", value)
            }
            return (path, value)
        })
    }

    static func removeRecord<T>(_ record: [String: T], root: String) -> [String: T] {
        record.filter { path, _ in !pathMatches(path, root: root) }
    }

    private static func normalize(_ relativePath: String) -> String {
        relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    private static func join(parent: String, name: String) -> String {
        let parent = normalize(parent)
        return parent.isEmpty ? name : "\(parent)/\(name)"
    }

    private static func validateFileName(_ name: String, parentPath: String, composeFileName: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
        guard !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("\0") else { return nil }
        let lower = trimmed.lowercased()
        if parentPath.isEmpty, lower == composeFileName.lowercased() || reservedRootNames.contains(lower) {
            return nil
        }
        return trimmed
    }

    private static func depth(_ relativePath: String) -> Int {
        let normalized = normalize(relativePath)
        guard !normalized.isEmpty else { return 0 }
        return max(0, normalized.split(separator: "/").count - 1)
    }

    private static func browserSort(
        _ lhs: ManagedProjectFileEntry,
        _ rhs: ManagedProjectFileEntry,
        entries: [String: ManagedProjectFileEntry]
    ) -> Bool {
        if pathMatches(rhs.relativePath, root: lhs.relativePath) {
            return true
        }
        if pathMatches(lhs.relativePath, root: rhs.relativePath) {
            return false
        }

        let lhsParts = lhs.relativePath.split(separator: "/").map(String.init)
        let rhsParts = rhs.relativePath.split(separator: "/").map(String.init)
        let sharedCount = min(lhsParts.count, rhsParts.count)

        for index in 0..<sharedCount where lhsParts[index] != rhsParts[index] {
            let lhsPath = lhsParts.prefix(index + 1).joined(separator: "/")
            let rhsPath = rhsParts.prefix(index + 1).joined(separator: "/")
            let lhsIsDirectory = entries[lhsPath]?.isDirectory == true
            let rhsIsDirectory = entries[rhsPath]?.isDirectory == true
            if lhsIsDirectory != rhsIsDirectory {
                return lhsIsDirectory
            }
            return lhsParts[index].localizedStandardCompare(rhsParts[index]) == .orderedAscending
        }

        return lhsParts.count < rhsParts.count
    }

    private static func remapEntries(
        _ entries: inout [String: ManagedProjectFileEntry],
        from oldPath: String,
        to newPath: String
    ) {
        var remapped: [String: ManagedProjectFileEntry] = [:]
        for (path, entry) in entries {
            if pathMatches(path, root: oldPath) {
                let movedPath = "\(newPath)\(path.dropFirst(oldPath.count))"
                remapped[movedPath] = ManagedProjectFileEntry(
                    path: movedPath,
                    relativePath: movedPath,
                    name: basename(movedPath),
                    isDirectory: entry.isDirectory,
                    size: entry.size,
                    protected: entry.protected,
                    pending: true,
                    depth: depth(movedPath)
                )
            } else {
                remapped[path] = entry
            }
        }
        entries = remapped
    }
}
