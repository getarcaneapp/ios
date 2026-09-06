import Arcane
import Foundation

struct ContainerPortDraft: Identifiable, Equatable {
  var id = UUID()
  var port = "80/tcp"
  var hostIP = ""
  var hostPort = ""
}

struct ContainerMountDraft: Identifiable, Equatable {
  var id = UUID()
  var type = "volume"
  var source = ""
  var target = ""
  var readOnly = false
}

struct ContainerNetworkDraft: Identifiable, Equatable {
  var id = UUID()
  var name = ""
  var aliases = ""
  var ipv4 = ""
  var ipv6 = ""
}

struct ContainerConfigurationDraft: Equatable {
  private var sourceConfig: ContainerEditConfig?
  var name = ""
  var image = ""
  var command = ""
  var entrypoint = ""
  var workingDir = ""
  var user = ""
  var environment = ""
  var labels = ""
  var binds = ""
  var ports: [ContainerPortDraft] = []
  var mounts: [ContainerMountDraft] = []
  var networks: [ContainerNetworkDraft] = []
  var restartPolicy = "no"
  var retryCount = "0"
  var privileged = false
  var autoRemove = false
  var readOnly = false
  var capAdd = ""
  var capDrop = ""
  var memory = "0"
  var memorySwap = "0"
  var nanoCPUs = "0"
  var cpuShares = "0"
  var healthMode = "inherit"
  var healthCommand = ""
  var interval = "0"
  var timeout = "0"
  var startPeriod = "0"
  var startInterval = "0"
  var retries = "0"

  init() {}

  init(_ config: ContainerEditConfig) {
    sourceConfig = config
    name = config.name
    image = config.image
    command = (config.command ?? []).joined(separator: "\n")
    entrypoint = (config.entrypoint ?? []).joined(separator: "\n")
    workingDir = config.workingDir ?? ""
    user = config.user ?? ""
    environment = (config.environment ?? []).joined(separator: "\n")
    labels = (config.labels ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
      .joined(separator: "\n")
    let host = config.hostConfig
    binds = (host.binds ?? []).joined(separator: "\n")
    ports = (host.portBindings ?? [:]).sorted { $0.key < $1.key }.flatMap { key, values in
      values.map {
        ContainerPortDraft(port: key, hostIP: $0.hostIp ?? "", hostPort: $0.hostPort ?? "")
      }
    }
    mounts = (host.mounts ?? []).map {
      .init(type: $0.type, source: $0.source, target: $0.target, readOnly: $0.readOnly ?? false)
    }
    networks = (config.networks ?? [:]).sorted { $0.key < $1.key }.map { key, value in
      .init(
        name: key, aliases: (value.aliases ?? []).joined(separator: "\n"),
        ipv4: value.ipv4Address ?? "", ipv6: value.ipv6Address ?? "")
    }
    restartPolicy = host.restartPolicy?.name ?? "no"
    retryCount = String(host.restartPolicy?.maximumRetryCount ?? 0)
    privileged = host.privileged ?? false
    autoRemove = host.autoRemove ?? false
    readOnly = host.readonlyRootfs ?? false
    capAdd = (host.capAdd ?? []).joined(separator: "\n")
    capDrop = (host.capDrop ?? []).joined(separator: "\n")
    memory = String(host.memory ?? 0)
    memorySwap = String(host.memorySwap ?? 0)
    nanoCPUs = String(host.nanoCpus ?? 0)
    cpuShares = String(host.cpuShares ?? 0)
    if let health = config.healthcheck {
      healthMode = health.test == ["NONE"] ? "disabled" : "custom"
      healthCommand = (health.test ?? []).joined(separator: "\n")
      interval = String(health.interval ?? 0)
      timeout = String(health.timeout ?? 0)
      startPeriod = String(health.startPeriod ?? 0)
      startInterval = String(health.startInterval ?? 0)
      retries = String(health.retries ?? 0)
    }
  }

  func lines(_ value: String) -> [String] {
    value.components(separatedBy: .newlines).filter { !$0.isEmpty }
  }

  private func preservedLines(_ value: String, original: [String]?) -> [String] {
    if let original, original.joined(separator: "\n") == value { return original }
    return lines(value)
  }

  private func integer(_ value: String, _ label: String, allowMinusOne: Bool = false) throws
    -> Int64
  {
    guard let number = Int64(value), number >= (allowMinusOne ? -1 : 0) else {
      throw DraftError(
        "\(label) must be a whole number \(allowMinusOne ? "of -1 or greater" : "of zero or greater")."
      )
    }
    return number
  }

  func createRequest() throws -> ContainerCreate {
    guard name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil else {
      throw DraftError(
        "Enter a container name using letters, digits, dots, underscores, or hyphens.")
    }
    guard !image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DraftError("Enter an image reference.")
    }
    var labelMap: [String: String] = [:]
    let originalLabels = sourceConfig?.labels ?? [:]
    let originalLabelText = originalLabels.sorted { $0.key < $1.key }.map {
      "\($0.key)=\($0.value)"
    }.joined(separator: "\n")
    let labelsUnchanged = sourceConfig != nil && labels == originalLabelText
    if labelsUnchanged { labelMap = originalLabels }
    for line in labelsUnchanged ? [] : lines(labels) {
      guard let separator = line.firstIndex(of: "="), separator != line.startIndex else {
        throw DraftError("Enter each label as name=value.")
      }
      let key = String(line[..<separator])
      guard labelMap[key] == nil else { throw DraftError("Label names must be unique.") }
      labelMap[key] = String(line[line.index(after: separator)...])
    }
    var portMap: [String: [PortBindingCreate]] = [:]
    for port in ports {
      let components = port.port.split(separator: "/")
      guard components.count == 2, let number = Int(components[0]), (1...65535).contains(number),
        ["tcp", "udp", "sctp"].contains(String(components[1]))
      else { throw DraftError("Use a container port such as 80/tcp or 53/udp.") }
      if !port.hostPort.isEmpty {
        guard let number = Int(port.hostPort), (1...65535).contains(number) else {
          throw DraftError(
            "Host ports must be between 1 and 65535, or blank for automatic assignment.")
        }
      }
      portMap[port.port, default: []].append(.init(hostIp: port.hostIP, hostPort: port.hostPort))
    }
    for mount in mounts {
      guard !mount.source.isEmpty, mount.target.hasPrefix("/") else {
        throw DraftError("Mounts need a source and an absolute container path.")
      }
    }
    var endpoints: [String: EndpointSettingsCreate] = [:]
    for network in networks {
      guard !network.name.isEmpty, endpoints[network.name] == nil else {
        throw DraftError("Network names must be nonempty and unique.")
      }
      endpoints[network.name] = .init(
        aliases: lines(network.aliases), ipv4Address: network.ipv4, ipv6Address: network.ipv6)
    }
    let health: ContainerHealthcheckCreate?
    switch healthMode {
    case "disabled": health = .init(test: ["NONE"])
    case "custom":
      let test = lines(healthCommand)
      guard let kind = test.first, ["CMD", "CMD-SHELL"].contains(kind), test.count > 1 else {
        throw DraftError(
          "Start the health command with CMD or CMD-SHELL on its own line, followed by its arguments."
        )
      }
      health = .init(
        test: test, interval: try integer(interval, "Interval"),
        timeout: try integer(timeout, "Timeout"),
        startPeriod: try integer(startPeriod, "Start period"),
        startInterval: try integer(startInterval, "Start interval"),
        retries: Int(try integer(retries, "Retries")))
    default: health = nil
    }
    return ContainerCreate(
      name: name, image: image, command: preservedLines(command, original: sourceConfig?.command),
      entrypoint: preservedLines(entrypoint, original: sourceConfig?.entrypoint),
      workingDir: workingDir, user: user,
      environment: preservedLines(environment, original: sourceConfig?.environment),
      labels: labelMap,
      healthcheck: health,
      hostConfig: .init(
        binds: lines(binds), portBindings: portMap,
        restartPolicy: .init(
          name: restartPolicy, maximumRetryCount: Int(try integer(retryCount, "Retry count"))),
        privileged: privileged, autoRemove: autoRemove, memory: try integer(memory, "Memory"),
        memorySwap: try integer(memorySwap, "Memory and swap", allowMinusOne: true),
        nanoCpus: try integer(nanoCPUs, "CPU allocation"),
        cpuShares: try integer(cpuShares, "CPU shares"), readonlyRootfs: readOnly,
        capAdd: lines(capAdd), capDrop: lines(capDrop),
        mounts: mounts.map {
          .init(type: $0.type, source: $0.source, target: $0.target, readOnly: $0.readOnly)
        }),
      networkingConfig: .init(endpointsConfig: endpoints))
  }

  func editRequest(from original: ContainerConfigurationDraft) throws -> ContainerEdit {
    let desired = try createRequest()
    let previous = try original.createRequest()
    let host = desired.hostConfig!
    let oldHost = previous.hostConfig!
    var edit = ContainerEdit()
    if desired.name != previous.name { edit.name = desired.name }
    if desired.image != previous.image { edit.image = desired.image }
    if desired.command != previous.command { edit.command = desired.command }
    if desired.entrypoint != previous.entrypoint { edit.entrypoint = desired.entrypoint }
    if desired.workingDir != previous.workingDir { edit.workingDir = desired.workingDir }
    if desired.user != previous.user { edit.user = desired.user }
    if desired.environment != previous.environment { edit.environment = desired.environment }
    if desired.labels != previous.labels { edit.labels = desired.labels }
    if desired.healthcheck != previous.healthcheck || healthMode != original.healthMode {
      edit.healthcheck = desired.healthcheck
      edit.clearHealthcheck = healthMode == "inherit"
    }
    if desired.networkingConfig != previous.networkingConfig {
      edit.networkingConfig = desired.networkingConfig
    }
    if host != oldHost {
      var change = HostConfigEdit()
      if host.binds != oldHost.binds { change.binds = host.binds }
      if host.mounts != oldHost.mounts { change.mounts = host.mounts }
      if host.portBindings != oldHost.portBindings { change.portBindings = host.portBindings }
      if host.restartPolicy != oldHost.restartPolicy { change.restartPolicy = host.restartPolicy }
      if host.privileged != oldHost.privileged { change.privileged = host.privileged }
      if host.autoRemove != oldHost.autoRemove { change.autoRemove = host.autoRemove }
      if host.readonlyRootfs != oldHost.readonlyRootfs {
        change.readonlyRootfs = host.readonlyRootfs
      }
      if host.memory != oldHost.memory { change.memory = host.memory }
      if host.memorySwap != oldHost.memorySwap { change.memorySwap = host.memorySwap }
      if host.nanoCpus != oldHost.nanoCpus { change.nanoCpus = host.nanoCpus }
      if host.cpuShares != oldHost.cpuShares { change.cpuShares = host.cpuShares }
      if host.capAdd != oldHost.capAdd { change.capAdd = host.capAdd }
      if host.capDrop != oldHost.capDrop { change.capDrop = host.capDrop }
      edit.hostConfig = change
    }
    return edit
  }

  struct DraftError: LocalizedError {
    var errorDescription: String? { message }
    let message: String
    init(_ message: String) { self.message = message }
  }
}
