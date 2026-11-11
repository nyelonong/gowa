import Foundation
import Testing
@testable import gowa

private func response(_ url: String, setCookie: String) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Set-Cookie": setCookie])!
}

@Test("cookies go back only to matching host, path, and scheme")
func cookieMatching() {
    let jar = CookieJar(fileURL: nil)
    jar.store(from: response("https://api.example.com/auth/login", setCookie: "sid=abc; Path=/; Secure"), for: URL(string: "https://api.example.com/auth/login")!)
    jar.store(from: response("https://api.example.com/", setCookie: "pref=dark; Domain=example.com; Path=/app"), for: URL(string: "https://api.example.com/")!)

    #expect(jar.header(for: URL(string: "https://api.example.com/users")!) == "sid=abc")
    #expect(jar.header(for: URL(string: "http://api.example.com/users")!) == nil)
    #expect(jar.header(for: URL(string: "https://www.example.com/app/x")!) == "pref=dark")
    #expect(jar.header(for: URL(string: "https://www.example.com/apple")!) == nil)
    #expect(jar.header(for: URL(string: "https://other.test/")!) == nil)
}

@Test("a Set-Cookie with a past expiry deletes the cookie")
func cookieExpiryDeletes() {
    let jar = CookieJar(fileURL: nil)
    let url = URL(string: "https://x.test/")!
    jar.store(from: response("https://x.test/", setCookie: "sid=1; Path=/"), for: url)
    jar.store(from: response("https://x.test/", setCookie: "sid=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"), for: url)
    #expect(jar.all.isEmpty)
}

@Test("only cookies with an expiry date persist between launches")
func cookiePersistence() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("gowa-cookies-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let url = URL(string: "https://x.test/")!
    let jar = CookieJar(fileURL: file)
    jar.store(from: response("https://x.test/", setCookie: "session=1; Path=/"), for: url)
    jar.store(from: response("https://x.test/", setCookie: "keep=2; Path=/; Max-Age=3600"), for: url)

    let reloaded = CookieJar(fileURL: file)
    #expect(reloaded.all.map(\.name) == ["keep"])
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@MainActor
@Test("network settings round-trip through spec config and Gowa extensions")
func networkSettingsRoundTrip() {
    let doc = OpenCollectionDocument(root: ["items": []])
    var settings = OCNetworkSettings()
    settings.proxy = OCProxy(mode: .custom, scheme: "http", hostname: "proxy.local", port: 3128, authEnabled: true, username: "u", password: "{{proxyPass}}", bypass: "localhost")
    settings.clientCertificates = [OCClientCertificate(domain: "*.corp.test", type: "pkcs12", path: "certs/me.p12", passphrase: "{{p12}}")]
    settings.verifyTLS = false
    settings.storeCookies = false
    doc.networkSettings = settings
    #expect(doc.networkSettings == settings)
    #expect(((doc.root["config"] as? [String: Any])?["proxy"] as? [String: Any])?["inherit"] as? Bool == false)

    settings.proxy.mode = .off
    doc.networkSettings = settings
    #expect(doc.networkSettings.proxy.mode == .off)
    settings.proxy.mode = .system
    doc.networkSettings = settings
    #expect((doc.root["config"] as? [String: Any])?["proxy"] == nil)
}

@MainActor
@Test("proxy settings resolve variables into a CFNetwork proxy dictionary")
func proxyResolution() throws {
    var settings = OCNetworkSettings()
    settings.proxy = OCProxy(mode: .custom, scheme: "socks5", hostname: "{{host}}", port: 1080, bypass: "localhost, *.local")
    let options = try NetworkOptions.resolve(settings, variables: ["host": "10.0.0.2"], baseDirectory: nil, cookies: nil)
    #expect(options.proxyDictionary?[kCFNetworkProxiesSOCKSProxy] as? String == "10.0.0.2")
    #expect(options.proxyDictionary?[kCFNetworkProxiesExceptionsList] as? [String] == ["localhost", "*.local"])

    settings.proxy.mode = .off
    #expect(try NetworkOptions.resolve(settings, variables: [:], baseDirectory: nil, cookies: nil).proxyDictionary?.isEmpty == true)
}

@MainActor
@Test("PEM client certificates fail with a conversion hint; missing files name their path")
func clientCertificateErrors() {
    var settings = OCNetworkSettings()
    settings.clientCertificates = [OCClientCertificate(domain: "api.test", type: "pem", path: "cert.pem")]
    #expect { try NetworkOptions.resolve(settings, variables: [:], baseDirectory: nil, cookies: nil) } throws: {
        ($0 as? NetworkError) == .pemUnsupported("api.test")
    }
    settings.clientCertificates = [OCClientCertificate(domain: "api.test", type: "pkcs12", path: "/nonexistent/me.p12")]
    #expect { try NetworkOptions.resolve(settings, variables: [:], baseDirectory: nil, cookies: nil) } throws: {
        ($0 as? NetworkError) == .unreadableCertificate("/nonexistent/me.p12")
    }
}

@Test("client certificates match by host, port, and wildcard")
func clientCertificateDomainMatch() {
    let wildcard = URLCredential(user: "wild", password: "", persistence: .none)
    let exact = URLCredential(user: "exact", password: "", persistence: .none)
    var options = NetworkOptions()
    options.identities = [("api.test:8443", exact), ("*.corp.test", wildcard)]
    #expect(options.identity(forHost: "api.test", port: 8443)?.user == "exact")
    #expect(options.identity(forHost: "api.test", port: 443) == nil)
    #expect(options.identity(forHost: "svc.corp.test", port: 443)?.user == "wild")
    #expect(options.identity(forHost: "corp.test.evil", port: 443) == nil)
}
