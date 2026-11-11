import Foundation
import Security

struct OCProxy: Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case system = "System"
        case off = "Off"
        case custom = "Custom"
    }

    var mode: Mode = .system
    var scheme = "http"
    var hostname = ""
    var port = 8080
    var authEnabled = false
    var username = ""
    var password = ""
    var bypass = ""
}

struct OCClientCertificate: Equatable, Sendable, Identifiable {
    var id = UUID()
    var domain = ""
    var type = "pkcs12" // "pkcs12" | "pem"
    var path = ""
    var keyPath = ""
    var passphrase = ""
    var disabled = false

    static func == (a: Self, b: Self) -> Bool {
        a.domain == b.domain && a.type == b.type && a.path == b.path && a.keyPath == b.keyPath
            && a.passphrase == b.passphrase && a.disabled == b.disabled
    }
}

/// Collection network settings: `config.proxy` and `config.clientCertificates`
/// from the spec, plus Gowa's TLS and cookie switches under `extensions.gowa`.
struct OCNetworkSettings: Equatable, Sendable {
    var proxy = OCProxy()
    var clientCertificates: [OCClientCertificate] = []
    var verifyTLS = true
    var storeCookies = true
}

extension OpenCollectionDocument {
    var networkSettings: OCNetworkSettings {
        get {
            let config = root["config"] as? [String: Any] ?? [:]
            var settings = OCNetworkSettings()
            if let proxy = config["proxy"] as? [String: Any] {
                let connection = proxy["config"] as? [String: Any] ?? [:]
                let auth = connection["auth"] as? [String: Any] ?? [:]
                settings.proxy = OCProxy(
                    mode: proxy["disabled"] as? Bool == true ? .off : (proxy["inherit"] as? Bool ?? (connection["hostname"] == nil) ? .system : .custom),
                    scheme: connection["protocol"] as? String ?? "http",
                    hostname: connection["hostname"] as? String ?? "",
                    port: (connection["port"] as? NSNumber)?.intValue ?? 8080,
                    authEnabled: !(auth.isEmpty || auth["disabled"] as? Bool == true),
                    username: auth["username"] as? String ?? "",
                    password: auth["password"] as? String ?? "",
                    bypass: connection["bypassProxy"] as? String ?? ""
                )
            }
            settings.clientCertificates = (config["clientCertificates"] as? [[String: Any]] ?? []).map { entry in
                let type = entry["type"] as? String ?? "pkcs12"
                return OCClientCertificate(
                    domain: entry["domain"] as? String ?? "",
                    type: type,
                    path: (type == "pem" ? entry["certificateFilePath"] : entry["pkcs12FilePath"]) as? String ?? "",
                    keyPath: entry["privateKeyFilePath"] as? String ?? "",
                    passphrase: entry["passphrase"] as? String ?? "",
                    disabled: entry["disabled"] as? Bool ?? false
                )
            }
            let gowa = (root["extensions"] as? [String: Any])?["gowa"] as? [String: Any] ?? [:]
            settings.verifyTLS = gowa["verifyTLS"] as? Bool ?? true
            settings.storeCookies = gowa["storeCookies"] as? Bool ?? true
            return settings
        }
        set {
            var config = root["config"] as? [String: Any] ?? [:]
            switch newValue.proxy.mode {
            case .system:
                config.removeValue(forKey: "proxy")
            case .off:
                config["proxy"] = ["disabled": true]
            case .custom:
                var connection: [String: Any] = [
                    "protocol": newValue.proxy.scheme,
                    "hostname": newValue.proxy.hostname,
                    "port": newValue.proxy.port,
                ]
                if newValue.proxy.authEnabled {
                    connection["auth"] = ["username": newValue.proxy.username, "password": newValue.proxy.password]
                }
                if !newValue.proxy.bypass.isEmpty { connection["bypassProxy"] = newValue.proxy.bypass }
                config["proxy"] = ["inherit": false, "config": connection]
            }
            if newValue.clientCertificates.isEmpty {
                config.removeValue(forKey: "clientCertificates")
            } else {
                config["clientCertificates"] = newValue.clientCertificates.map { certificate -> [String: Any] in
                    var entry: [String: Any] = ["domain": certificate.domain, "type": certificate.type]
                    if certificate.type == "pem" {
                        entry["certificateFilePath"] = certificate.path
                        entry["privateKeyFilePath"] = certificate.keyPath
                    } else {
                        entry["pkcs12FilePath"] = certificate.path
                    }
                    if !certificate.passphrase.isEmpty { entry["passphrase"] = certificate.passphrase }
                    if certificate.disabled { entry["disabled"] = true }
                    return entry
                }
            }
            root["config"] = config

            var extensions = root["extensions"] as? [String: Any] ?? [:]
            var gowa = extensions["gowa"] as? [String: Any] ?? [:]
            if newValue.verifyTLS { gowa.removeValue(forKey: "verifyTLS") } else { gowa["verifyTLS"] = false }
            if newValue.storeCookies { gowa.removeValue(forKey: "storeCookies") } else { gowa["storeCookies"] = false }
            extensions["gowa"] = gowa
            root["extensions"] = extensions
        }
    }
}

/// Resolved, ready-to-use transport options for one send.
struct NetworkOptions: @unchecked Sendable {
    var proxyDictionary: [AnyHashable: Any]?
    var proxyCredential: URLCredential?
    var identities: [(domain: String, credential: URLCredential)] = []
    var verifyTLS = true
    var cookies: CookieJar?

    static let none = NetworkOptions()

    @MainActor
    static func resolve(_ settings: OCNetworkSettings, variables: [String: String], baseDirectory: URL?, cookies: CookieJar?) throws -> NetworkOptions {
        var options = NetworkOptions(verifyTLS: settings.verifyTLS, cookies: settings.storeCookies ? cookies : nil)
        let value = { OpenCollectionDocument.interpolate($0, variables) }

        switch settings.proxy.mode {
        case .system:
            options.proxyDictionary = nil
        case .off:
            options.proxyDictionary = [:]
        case .custom:
            let host = value(settings.proxy.hostname)
            let port = settings.proxy.port
            var dictionary: [AnyHashable: Any] = [:]
            if settings.proxy.scheme.lowercased().hasPrefix("socks") {
                dictionary[kCFNetworkProxiesSOCKSEnable] = 1
                dictionary[kCFNetworkProxiesSOCKSProxy] = host
                dictionary[kCFNetworkProxiesSOCKSPort] = port
            } else {
                dictionary[kCFNetworkProxiesHTTPEnable] = 1
                dictionary[kCFNetworkProxiesHTTPProxy] = host
                dictionary[kCFNetworkProxiesHTTPPort] = port
                dictionary[kCFNetworkProxiesHTTPSEnable] = 1
                dictionary[kCFNetworkProxiesHTTPSProxy] = host
                dictionary[kCFNetworkProxiesHTTPSPort] = port
            }
            let exceptions = settings.proxy.bypass.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !exceptions.isEmpty { dictionary[kCFNetworkProxiesExceptionsList] = exceptions }
            options.proxyDictionary = dictionary
            if settings.proxy.authEnabled {
                options.proxyCredential = URLCredential(user: value(settings.proxy.username), password: value(settings.proxy.password), persistence: .forSession)
            }
        }

        for certificate in settings.clientCertificates where !certificate.disabled && !certificate.path.isEmpty {
            guard certificate.type == "pkcs12" else {
                throw NetworkError.pemUnsupported(certificate.domain)
            }
            let url = EffectiveBody.resolvePath(value(certificate.path), base: baseDirectory)
            options.identities.append((certificate.domain, try loadIdentity(url, passphrase: value(certificate.passphrase))))
        }
        return options
    }

    static func loadIdentity(_ url: URL, passphrase: String) throws -> URLCredential {
        guard let data = try? Data(contentsOf: url) else { throw NetworkError.unreadableCertificate(url.path) }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: passphrase] as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identityRef = first[kSecImportItemIdentity as String]
        else { throw NetworkError.badCertificate(url.lastPathComponent, status) }
        let identity = identityRef as! SecIdentity
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        return URLCredential(identity: identity, certificates: Array(chain.dropFirst()), persistence: .forSession)
    }

    func identity(forHost host: String, port: Int) -> URLCredential? {
        identities.first { Self.domain($0.domain, matches: host, port: port) }?.credential
    }

    /// `domain` accepts `host`, `host:port`, and a leading `*.` wildcard.
    static func domain(_ domain: String, matches host: String, port: Int) -> Bool {
        let pattern = domain.lowercased()
        let parts = pattern.split(separator: ":", maxSplits: 1).map(String.init)
        let hostPattern = parts.first ?? ""
        if parts.count > 1, Int(parts[1]) != port { return false }
        if hostPattern.hasPrefix("*.") {
            return host.lowercased().hasSuffix(String(hostPattern.dropFirst(1)))
        }
        return host.lowercased() == hostPattern
    }
}

enum NetworkError: LocalizedError, Equatable {
    case pemUnsupported(String)
    case unreadableCertificate(String)
    case badCertificate(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .pemUnsupported(let domain):
            "The client certificate for \(domain) is PEM. Gowa reads PKCS#12 (.p12) files — convert it with `openssl pkcs12 -export -in cert.pem -inkey key.pem -out cert.p12`."
        case .unreadableCertificate(let path):
            "Can't read the client certificate \(path)"
        case .badCertificate(let name, let status):
            status == errSecAuthFailed
                ? "Wrong passphrase for the client certificate \(name)"
                : "Can't load the client certificate \(name) (error \(status))"
        }
    }
}
