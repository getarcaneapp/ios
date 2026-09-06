import Arcane
import SwiftUI

struct ContainerConfigurationView: View {
  @SwiftUI.Environment(ArcaneClientManager.self) private var manager
  @SwiftUI.Environment(ResourceMutationStore.self) private var mutations
  @SwiftUI.Environment(\.dismiss) private var dismiss
  let environmentID: EnvironmentID
  var containerID: String? = nil
  let onSaved: (String) -> Void

  @State private var draft = ContainerConfigurationDraft()
  @State private var original = ContainerConfigurationDraft()
  @State private var config: ContainerEditConfig?
  @State private var loading = true
  @State private var busy = false
  @State private var error: String?
  @State private var review = false
  @State private var task: Task<Void, Never>?
  @State private var generation = -1

  private var blocked: Bool { config?.editDisabled == true || config?.isCompose == true }
  private var permission: String {
    containerID == nil ? Permission.Containers.create : "containers:edit"
  }

  var body: some View {
    NavigationStack {
      Form {
        if loading { ProgressView("Loading configuration…") }
        if let error { Section { Text(error).foregroundStyle(.red) } }
        if blocked {
          Section("Managed container") {
            Text("Edit this container through its owning project.")
            if let project = config?.composeProject,
              manager.permissions.has(Permission.Projects.list, in: environmentID),
              manager.permissions.has(Permission.Projects.read, in: environmentID)
            {
              NavigationLink("Open project: \(project)") {
                ContainerOwningProjectView(environmentID: environmentID, name: project)
              }
            }
          }
        } else if !loading {
          if review {
            Section("Review container replacement") {
              LabeledContent("Container", value: draft.name)
              LabeledContent("Image", value: draft.image)
              Text(
                "Saving recreates the container with a new ID. Running containers are interrupted. Settings outside this form are preserved."
              )
              Text("Review the fields below before choosing Recreate.")
            }
          }
          configurationSections.disabled(review)
        }
      }
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .navigationTitle(containerID == nil ? "Create Container" : "Edit Container")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(review ? "Back" : "Cancel") {
            if review { review = false } else { dismiss() }
          }.disabled(busy)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(containerID == nil ? "Create" : (review ? "Recreate" : "Review")) {
            if containerID != nil && !review {
              do {
                _ = try draft.editRequest(from: original)
                error = nil
                review = true
              } catch { self.error = error.localizedDescription }
            } else {
              task = Task { await save() }
            }
          }
          .disabled(
            loading || busy || blocked || !manager.permissions.has(permission, in: environmentID)
              || (containerID != nil && draft == original))
        }
      }
      .overlay {
        if busy {
          ProgressView("Saving container…").padding().background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: Radius.standard, style: .continuous))
        }
      }
      .interactiveDismissDisabled(busy)
      .task(id: manager.clientGeneration) { await load() }
      .onDisappear { task?.cancel() }
      .onChange(of: manager.activeEnvironmentID) { _, newID in
        if newID != environmentID {
          task?.cancel()
          dismiss()
        }
      }
      .onChange(of: manager.clientGeneration) {
        task?.cancel()
        dismiss()
      }
    }
  }

  @ViewBuilder private var configurationSections: some View {
    Section("Container") {
      TextField("Name", text: $draft.name)
      TextField("Image", text: $draft.image)
      TextField("Working directory", text: $draft.workingDir)
      TextField("User", text: $draft.user)
    }
    Section("Command") {
      multiline("Command arguments, one per line", $draft.command)
      multiline("Entrypoint arguments, one per line", $draft.entrypoint)
    }
    Section("Environment variables") {
      multiline("NAME=value, one per line", $draft.environment).privacySensitive()
    }
    Section("Ports") {
      ForEach($draft.ports) { $port in
        VStack(alignment: .leading) {
          TextField("Container port (80/tcp)", text: $port.port)
          TextField("Host address (optional)", text: $port.hostIP)
          TextField("Host port (blank for automatic)", text: $port.hostPort).keyboardType(
            .numberPad)
          Button("Remove port", role: .destructive) { draft.ports.removeAll { $0.id == port.id } }
        }
      }
      Button("Add port") { draft.ports.append(.init()) }
    }
    Section("Mounts") {
      ForEach($draft.mounts) { $mount in
        VStack(alignment: .leading) {
          Picker("Type", selection: $mount.type) {
            Text("Volume").tag("volume")
            Text("Bind mount").tag("bind")
          }
          TextField("Source volume or host path", text: $mount.source)
          TextField("Container path", text: $mount.target)
          Toggle("Read only", isOn: $mount.readOnly)
          Button("Remove mount", role: .destructive) {
            draft.mounts.removeAll { $0.id == mount.id }
          }
        }
      }
      Button("Add mount") { draft.mounts.append(.init()) }
      if !draft.binds.isEmpty { multiline("Existing volume bindings, one per line", $draft.binds) }
    }
    Section("Networks") {
      if let mode = config?.hostConfig.networkMode,
        ["host", "none"].contains(mode) || mode.hasPrefix("container:")
      {
        LabeledContent("Network mode", value: mode)
        Text("This container's network mode is preserved.").foregroundStyle(.secondary)
      } else {
        ForEach($draft.networks) { $network in
          VStack(alignment: .leading) {
            TextField("Network name", text: $network.name)
            multiline("Aliases, one per line", $network.aliases)
            TextField("Static IPv4 address (optional)", text: $network.ipv4)
            TextField("Static IPv6 address (optional)", text: $network.ipv6)
            Button("Remove network", role: .destructive) {
              draft.networks.removeAll { $0.id == network.id }
            }
          }
        }
        Button("Add network") { draft.networks.append(.init()) }
      }
    }
    Section("Restart policy") {
      Picker("Policy", selection: $draft.restartPolicy) {
        Text("Never").tag("no")
        Text("Always").tag("always")
        Text("Unless stopped").tag("unless-stopped")
        Text("On failure").tag("on-failure")
      }
      if draft.restartPolicy == "on-failure" {
        TextField("Maximum retries", text: $draft.retryCount).keyboardType(.numberPad)
      }
      Toggle("Remove when stopped", isOn: $draft.autoRemove)
    }
    Section("Health check") {
      Picker("Health check", selection: $draft.healthMode) {
        Text("Use image default").tag("inherit")
        Text("Disabled").tag("disabled")
        Text("Custom").tag("custom")
      }
      if draft.healthMode == "custom" {
        multiline("CMD or CMD-SHELL, then arguments on separate lines", $draft.healthCommand)
        number("Interval (seconds)", $draft.interval)
        number("Timeout (seconds)", $draft.timeout)
        number("Start period (seconds)", $draft.startPeriod)
        number("Start interval (seconds)", $draft.startInterval)
        number("Retries", $draft.retries)
      }
    }
    Section("Advanced runtime") {
      Toggle("Privileged", isOn: $draft.privileged)
      Toggle("Read-only root filesystem", isOn: $draft.readOnly)
      number("Memory limit (bytes, 0 for unlimited)", $draft.memory)
      number("Memory and swap (bytes, -1 for unlimited)", $draft.memorySwap)
      number("CPU allocation (billionths of a CPU)", $draft.nanoCPUs)
      number("CPU shares", $draft.cpuShares)
      multiline("Added capabilities, one per line", $draft.capAdd)
      multiline("Dropped capabilities, one per line", $draft.capDrop)
      multiline("Labels: name=value, one per line", $draft.labels)
    }
  }

  private func multiline(_ label: String, _ binding: Binding<String>) -> some View {
    TextField(label, text: binding, axis: .vertical).lineLimit(2...8).font(
      .system(.body, design: .monospaced))
  }
  private func number(_ label: String, _ binding: Binding<String>) -> some View {
    VStack(alignment: .leading) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      TextField(label, text: binding).keyboardType(.numbersAndPunctuation)
    }
  }

  private func load() async {
    let requestGeneration = manager.clientGeneration
    generation = requestGeneration
    loading = true
    error = nil
    guard let client = manager.client else {
      loading = false
      error = "Connect to a server to continue."
      return
    }
    do {
      if let containerID {
        let loaded = try await client.containers.editConfig(envID: environmentID, id: containerID)
        try Task.checkCancellation()
        guard requestGeneration == manager.clientGeneration else { return }
        config = loaded
        draft = ContainerConfigurationDraft(loaded)
        original = draft
      }
      loading = false
    } catch is CancellationError {} catch ArcaneError.notFound {
      loading = false
      self.error =
        "Container editing is unavailable on this server, or the container no longer exists."
    } catch ArcaneError.forbidden {
      loading = false
      self.error = "You do not have permission to read this container configuration."
    } catch {
      loading = false
      self.error = error.localizedDescription
    }
  }

  private func save() async {
    guard let client = manager.client, generation == manager.clientGeneration,
      manager.permissions.has(permission, in: environmentID), !blocked
    else { return }
    busy = true
    defer { busy = false }
    do {
      let id: String
      if let containerID {
        id = try await client.containers.edit(
          envID: environmentID, id: containerID, body: draft.editRequest(from: original)
        ).id
      } else {
        id = try await client.containers.create(envID: environmentID, body: draft.createRequest())
          .id
      }
      try Task.checkCancellation()
      guard generation == manager.clientGeneration else { return }
      if let cached = manager.cached {
        await cached.invalidate(
          envID: environmentID,
          paths: [
            client.rest.environmentPath(environmentID, "containers"),
            client.rest.environmentPath(environmentID, "containers/*"),
          ])
      }
      guard generation == manager.clientGeneration else { return }
      mutations.markChanged(kind: .containers, envID: environmentID)
      onSaved(id)
      dismiss()
    } catch is CancellationError {} catch {
      self.error = error.localizedDescription
      showToast(.error(error.localizedDescription))
    }
  }
}

private struct ContainerOwningProjectView: View {
  @SwiftUI.Environment(ArcaneClientManager.self) private var manager
  let environmentID: EnvironmentID
  let name: String
  @State private var project: ProjectDetails?
  @State private var error: String?

  var body: some View {
    Group {
      if let project {
        ProjectDetailView(project: project, environmentID: environmentID)
      } else if let error {
        ContentUnavailableView(
          "Project unavailable", systemImage: "folder", description: Text(error))
      } else {
        ProgressView("Loading project…")
      }
    }
    .task(id: manager.clientGeneration) {
      guard let client = manager.client else {
        error = "Connect to a server to continue."
        return
      }
      do {
        let envID = environmentID
        let pages = ArcanePaginator<ProjectDetails>(limit: 50) { start, limit in
          try await client.projects.list(envID: envID, query: .init(start: start, limit: limit))
        }
        for try await candidate in pages {
          try Task.checkCancellation()
          if candidate.name == name {
            project = candidate
            return
          }
        }
        error = "The owning project is not managed by this server."
      } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
  }
}
