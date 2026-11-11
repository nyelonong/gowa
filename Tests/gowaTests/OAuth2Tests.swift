import Foundation
import Testing
@testable import gowa

@MainActor
@Test("PKCE S256 challenge matches the RFC 7636 example")
func pkceChallenge() {
    #expect(OAuth2Client.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", method: "S256")
        == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(OAuth2Client.randomURLSafe(32).count == 43)
}

@Test("oauth2 config round-trips and keeps keys Gowa doesn't edit")
func oauth2ConfigRoundTrip() throws {
    let original: [String: Any] = [
        "type": "oauth2", "flow": "authorization_code",
        "authorizationUrl": "https://id.test/authorize", "accessTokenUrl": "https://id.test/token",
        "callbackUrl": "http://127.0.0.1:9000/cb",
        "credentials": ["clientId": "app", "clientSecret": "{{secret}}", "placement": "body"],
        "scope": "read write",
        "pkce": ["disabled": false, "method": "S256"],
        "additionalParameters": ["authorizationRequest": [["name": "audience", "value": "api", "placement": "query"]]],
        "tokenConfig": ["placement": ["query": "token"], "source": "id_token"],
    ]
    let config = try #require(OCOAuth2(original))
    #expect(config.flow == .authorizationCode)
    #expect(config.credentialsPlacement == "body")
    #expect(config.tokenQuery == "token")
    #expect(config.tokenSource == "id_token")

    let written = config.dict(merging: original)
    #expect(written["additionalParameters"] != nil)
    #expect(OCOAuth2(written) == config)
    #expect(OCOAuth2(["type": "oauth2", "grantType": "client_credentials"]) == nil)
}

@MainActor
@Test("client credentials token request uses Basic auth or body credentials")
func tokenRequestShape() throws {
    var config = OCOAuth2()
    config.accessTokenUrl = "https://id.test/token"
    config.clientId = "app id"
    config.clientSecret = "s3cret"
    config.scope = "read"

    let basic = try OAuth2Client.tokenRequest(config, fields: ["grant_type": "client_credentials"])
    #expect(basic.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("app%20id:s3cret".utf8).base64EncodedString())
    #expect(String(data: basic.httpBody!, encoding: .utf8) == "grant_type=client_credentials&scope=read")

    config.credentialsPlacement = "body"
    let body = try OAuth2Client.tokenRequest(config, fields: ["grant_type": "client_credentials"])
    #expect(body.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(String(data: body.httpBody!, encoding: .utf8) == "client_id=app%20id&client_secret=s3cret&grant_type=client_credentials&scope=read")
}

@MainActor
@Test("authorization URL carries client, redirect, state, and PKCE challenge")
func authorizationURLShape() throws {
    var config = OCOAuth2()
    config.flow = .authorizationCode
    config.authorizationUrl = "https://id.test/authorize?prompt=login"
    config.clientId = "app"
    config.scope = "openid"
    let url = try OAuth2Client.authorizationURL(config, responseType: "code", state: "xyz", challenge: "abc")
    let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    #expect(items == [
        "prompt": "login", "response_type": "code", "client_id": "app",
        "redirect_uri": "http://127.0.0.1:8765/callback", "scope": "openid", "state": "xyz",
        "code_challenge": "abc", "code_challenge_method": "S256",
    ])
}

@Test("token responses parse JSON or form bodies and surface server errors")
func tokenResponseParsing() throws {
    let now = Date(timeIntervalSince1970: 1000)
    let token = try OAuth2Token.parse(Data(#"{"access_token":"a","expires_in":3600,"refresh_token":"r","token_type":"Bearer"}"#.utf8), now: now)
    #expect(token.accessToken == "a")
    #expect(token.expiresAt == Date(timeIntervalSince1970: 4600))
    #expect(token.isExpired(at: Date(timeIntervalSince1970: 4580)))
    #expect(!token.isExpired(at: Date(timeIntervalSince1970: 4000)))
    #expect(try OAuth2Token.parse(Data("access_token=f&token_type=bearer".utf8)).accessToken == "f")
    #expect { try OAuth2Token.parse(Data(#"{"error":"invalid_client"}"#.utf8)) } throws: {
        ($0 as? OAuth2Error) == .server("invalid_client", nil)
    }
}

@MainActor
@Test("callback fields read both query and fragment")
func callbackFields() {
    let fields = OAuth2Client.callbackFields(URL(string: "myapp://cb?state=s#access_token=t&expires_in=60")!)
    #expect(fields == ["state": "s", "access_token": "t", "expires_in": "60"])
    #expect(BrowserCallback.isLoopback("http://localhost:8000/cb"))
    #expect(!BrowserCallback.isLoopback("https://localhost/cb"))
}

@MainActor
@Test("requests with oauth2 auth save as spec oauth2 blocks")
func oauth2RequestSaves() {
    let doc = OpenCollectionDocument(root: ["items": []])
    var config = OCOAuth2()
    config.accessTokenUrl = "https://id.test/token"
    let snapshot = OCRequestSnapshot(
        name: "Secure", method: "GET", url: "https://api.test", params: [], headers: [],
        bodyType: nil, bodyData: "", authKind: .oauth2(config),
        settings: OCSettings(followRedirects: nil, timeout: nil), docs: nil
    )
    let path = doc.addRequest(under: nil, snapshot: snapshot)
    #expect(doc.requestSnapshot(at: path)?.authKind == .oauth2(config))
}
