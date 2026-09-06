import Foundation
import Arcane

struct FederatedCredentialForm {
    var name = ""
    var description = ""
    var enabled = true
    var issuerUrl = ""
    var audiences = ""
    var subjectClaim = "sub"
    var subjectMatch = ""
    var matchType = "exact"
    var roleId = ""
    var environmentId = ""
    var tokenTtlSeconds = 300
    var expires = false
    var expiresAt = Date().addingTimeInterval(86400 * 30)

    init(credential: FederatedCredential? = nil) {
        guard let credential else { return }
        name = credential.name
        description = credential.description ?? ""
        enabled = credential.enabled
        issuerUrl = credential.issuerUrl
        audiences = credential.audiences.joined(separator: "\n")
        subjectClaim = credential.subjectClaim
        subjectMatch = credential.subjectMatch
        matchType = credential.matchType
        roleId = credential.roleId
        environmentId = credential.environmentId ?? ""
        tokenTtlSeconds = credential.tokenTtlSeconds
        expires = credential.expiresAt != nil
        expiresAt = credential.expiresAt ?? expiresAt
    }

    var audienceValues: [String] { audiences.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    var validationMessage: String? {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 255 else { return "Enter a name of up to 255 characters." }
        guard let url = URL(string: issuerUrl), url.scheme == "https", url.host != nil else { return "Enter an HTTPS issuer URL." }
        guard !audienceValues.isEmpty, !subjectClaim.isEmpty, !subjectMatch.isEmpty, !roleId.isEmpty else { return "Enter audiences and a subject rule, and choose a role." }
        guard (60...3600).contains(tokenTtlSeconds) else { return "Token lifetime must be 60–3600 seconds." }
        guard description.count <= 1000 else { return "Description must be at most 1000 characters." }
        guard !expires || expiresAt > Date() else { return "Choose a future expiration date." }
        return nil
    }

    var createRequest: CreateFederatedCredential {
        .init(name: name, description: description, enabled: enabled, issuerUrl: issuerUrl,
              audiences: audienceValues, subjectClaim: subjectClaim, subjectMatch: subjectMatch,
              matchType: matchType, roleId: roleId, environmentId: environmentId.isEmpty ? nil : environmentId,
              tokenTtlSeconds: tokenTtlSeconds, expiresAt: expires ? expiresAt : nil)
    }

    var updateRequest: UpdateFederatedCredential {
        .init(name: name, description: description, enabled: enabled, issuerUrl: issuerUrl,
              audiences: audienceValues, subjectClaim: subjectClaim, subjectMatch: subjectMatch,
              matchType: matchType, roleId: roleId, environmentId: environmentId,
              tokenTtlSeconds: tokenTtlSeconds, expiresAt: expires ? expiresAt : nil)
    }
}
