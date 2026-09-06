import Arcane
import Foundation
import Testing

@testable import Arcane_Mobile

@MainActor
@Suite struct ContainerConfigurationDraftTests {
  private func snapshot() -> ContainerEditConfig {
    .init(
      id: "old", name: "web", image: "nginx:latest",
      hostConfig: .init(binds: ["/host:/data"], privileged: true, memory: 512), running: true,
      command: ["nginx", "-g", "daemon off;"], environment: ["SECRET=a=b"],
      healthcheck: .init(test: ["CMD", "true"], interval: 30),
      networks: ["private": .init(aliases: ["web"], ipv4Address: "172.20.0.2")])
  }

  @Test func unchangedEditOmitsEveryField() throws {
    let original = ContainerConfigurationDraft(snapshot())
    let body = try original.editRequest(from: original)
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    #expect(object.isEmpty)
  }

  @Test func explicitClearsDoNotReplaceUneditedSettings() throws {
    let original = ContainerConfigurationDraft(snapshot())
    var draft = original
    draft.command = ""
    draft.environment = ""
    draft.binds = ""
    draft.privileged = false
    draft.memory = "0"
    let edit = try draft.editRequest(from: original)
    #expect(edit.command == [])
    #expect(edit.environment == [])
    #expect(edit.hostConfig?.binds == [])
    #expect(edit.hostConfig?.privileged == false)
    #expect(edit.hostConfig?.memory == 0)
    #expect(edit.hostConfig?.restartPolicy == nil)
    #expect(edit.networkingConfig == nil)
    #expect(edit.healthcheck == nil)
  }

  @Test func uneditedMultilineValuesRemainIntact() throws {
    var config = snapshot()
    config.labels = ["description": "first line\nsecond line"]
    config.environment = ["MULTILINE=first\nsecond"]
    config.command = ["sh", "-c", "echo first\necho second"]
    let original = ContainerConfigurationDraft(config)
    var draft = original
    draft.name = "renamed"
    let edit = try draft.editRequest(from: original)
    #expect(edit.name == "renamed")
    #expect(edit.labels == nil && edit.command == nil && edit.environment == nil)
  }

  @Test func revertingHealthcheckSetsExplicitClear() throws {
    let original = ContainerConfigurationDraft(snapshot())
    var draft = original
    draft.healthMode = "inherit"
    let edit = try draft.editRequest(from: original)
    #expect(edit.clearHealthcheck == true)
    #expect(edit.healthcheck == nil)
  }

  @Test func invalidPortsAndDuplicateNetworksAreRejected() throws {
    var draft = ContainerConfigurationDraft(snapshot())
    draft.ports = [.init(port: "70000/tcp", hostPort: "80")]
    #expect(throws: (any Error).self) { try draft.createRequest() }
    draft.ports = []
    draft.networks.append(.init(name: "private"))
    #expect(throws: (any Error).self) { try draft.createRequest() }
  }
}
