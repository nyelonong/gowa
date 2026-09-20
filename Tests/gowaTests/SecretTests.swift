import Foundation
import Testing
@testable import gowa

@MainActor
@Test("secret variables are stripped from YAML and stored in the Keychain")
func secretRoundTrip() throws {
    let doc = OpenCollectionDocument.sample()
    doc.environments = [
        OCEnvironmentSnapshot(name: "Production", variables: [
            OCVariable(name: "baseUrl", value: "https://echo.usebruno.com", secret: false, disabled: false),
            OCVariable(name: "token", value: "super-secret-value", secret: true, disabled: false),
            OCVariable(name: "plain", value: "hello", secret: false, disabled: false),
        ])
    ]

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gowa-secret-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("collection.yml")
    try doc.save(to: file)

    let written = try String(contentsOf: file, encoding: .utf8)
    #expect(!written.contains("super-secret-value"))
    #expect(written.contains("token"))
    #expect(written.contains("https://echo.usebruno.com"))

    // The keychain now holds it.
    let account = doc.secretAccount(env: "Production", variable: "token")
    #expect(Keychain.value(account: account) == "super-secret-value")

    // Reload: YAML value is empty, resolution reads the keychain.
    let loaded = try OpenCollectionDocument.load(from: file)
    let resolution = loaded.resolveVariables(in: "Production")
    #expect(resolution.values["token"] == "super-secret-value")
    #expect(resolution.values["plain"] == "hello")
    #expect(resolution.missingSecrets.isEmpty)

    Keychain.removeValue(account: account)
}

@MainActor
@Test("unset secrets are reported as missing and block sends")
func missingSecret() throws {
    let doc = OpenCollectionDocument.sample()
    doc.environments = [
        OCEnvironmentSnapshot(name: "Production", variables: [
            OCVariable(name: "token", value: "", secret: true, disabled: false),
        ])
    ]
    let resolution = doc.resolveVariables(in: "Production")
    #expect(resolution.missingSecrets == ["token"])
    #expect(resolution.values["token"] == nil)

    // Disabled secret variables are ignored entirely.
    var envs = doc.environments
    envs[0].variables[0].disabled = true
    doc.environments = envs
    let quiet = doc.resolveVariables(in: "Production")
    #expect(quiet.missingSecrets.isEmpty)
}

@MainActor
@Test("document ID is stable and preserves other extensions")
func documentID() {
    let doc = OpenCollectionDocument(root: [
        "info": ["name": "x"],
        "extensions": ["custom": "keep"],
    ])
    let first = doc.documentID
    #expect(doc.documentID == first)
    let extensions = doc.root["extensions"] as? [String: Any]
    #expect((extensions?["custom"] as? String) == "keep")
    let gowa = extensions?["gowa"] as? [String: Any]
    #expect((gowa?["id"] as? String) == first)
}
