import Foundation
import Testing
@testable import gowa

@Test("copy as cURL renders a runnable command")
func curlCommand() {
    let command = CurlBuilder.command(from: AppState.EffectiveRequest(
        method: "POST",
        url: "https://api.test/users?active=1",
        headers: [("Content-Type", "application/json"), ("Authorization", "Bearer tok")],
        body: "{\"name\": \"it's fine\"}",
        followRedirects: true,
        timeout: 30
    ))

    #expect(command.hasPrefix("curl"))
    #expect(command.contains("-X POST"))
    #expect(command.contains("'https://api.test/users?active=1'"))
    #expect(command.contains("-H 'Content-Type: application/json'"))
    #expect(command.contains("-H 'Authorization: Bearer tok'"))
    #expect(command.contains("-d '{\"name\": \"it'\\''s fine\"}'"))
    #expect(command.contains("--max-time 30"))
    #expect(command.contains("-L"))
    #expect(!command.contains("it's fine'"))
}

@Test("GET omits -X and keeps redirects explicit")
func getCommand() {
    let command = CurlBuilder.command(from: AppState.EffectiveRequest(
        method: "GET",
        url: "https://api.test",
        headers: [],
        body: "",
        followRedirects: false,
        timeout: nil
    ))
    #expect(command.hasPrefix("curl"))
    #expect(command.contains("'https://api.test'"))
    #expect(!command.contains("-X"))
    #expect(!command.contains("-d "))
    #expect(!command.contains("-L"))
}
