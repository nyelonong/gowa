import Foundation
import Testing
@testable import gowa

@MainActor
private func folderDocument() -> OpenCollectionDocument {
    OpenCollectionDocument(root: [
        "info": ["name": "Defaults"],
        "request": [
            "variables": [["name": "region", "value": "collection"], ["name": "onlyCollection", "value": "c"]],
            "auth": ["type": "bearer", "token": "collection-token"],
        ],
        "items": [
            [
                "info": ["name": "API", "type": "folder"],
                "request": [
                    "variables": [["name": "region", "value": ["type": "string", "data": "folder"]]],
                ],
                "items": [
                    [
                        "info": ["name": "Get", "type": "http"],
                        "http": ["method": "GET", "url": "https://x.test/{{region}}", "auth": ["type": "inherit"]],
                        "runtime": ["variables": [["name": "requestOnly", "value": "r"]]],
                    ],
                ],
            ],
        ],
    ])
}

@MainActor
@Test("variables layer collection < environment < folder < request")
func layeredVariablePrecedence() {
    let doc = folderDocument()
    let values = doc.layeredVariables(at: [0, 0], environment: ["region": "env", "onlyEnv": "e"])
    #expect(values["region"] == "folder")
    #expect(values["onlyCollection"] == "c")
    #expect(values["onlyEnv"] == "e")
    #expect(values["requestOnly"] == "r")
    #expect(doc.layeredVariables(at: nil, environment: ["region": "env"])["region"] == "env")
}

@MainActor
@Test("folder defaults round-trip and keep unknown request keys")
func folderDefaultsRoundTrip() {
    let doc = folderDocument()
    var defaults = doc.defaults(at: [0])
    #expect(defaults.variables.map(\.value) == ["folder"])
    #expect(defaults.auth == .inherit)

    defaults.headers = [OCHeader(name: "X-Team", value: "{{region}}", disabled: false)]
    defaults.docs = "# API"
    doc.updateDefaults(at: [0], defaults)

    let reread = doc.defaults(at: [0])
    #expect(reread.headers == defaults.headers)
    #expect(reread.docs == "# API")
    #expect(doc.resolvedHeaders(at: [0, 0], requestHeaders: []).map(\.name) == ["X-Team"])
}

@MainActor
@Test("an explicit folder auth of none stops inheriting the collection auth")
func folderNoneAuthStopsInheritance() {
    let doc = folderDocument()
    #expect(doc.resolvedAuth(at: [0, 0]) == .bearer(token: "collection-token"))

    var defaults = doc.defaults(at: [0])
    defaults.auth = .none
    doc.updateDefaults(at: [0], defaults)
    #expect(doc.resolvedAuth(at: [0, 0]) == OAuthKind.none)
}

@Test("bulk edit text round-trips rows, keeps colons in values, and disables with //")
func bulkEditRoundTrip() {
    let rows = [
        KVRow(name: "Accept", value: "application/json", disabled: false),
        KVRow(name: "X-Time", value: "12:30:00", disabled: true),
    ]
    let text = KVRow.bulkText(rows)
    #expect(text == "Accept: application/json\n//X-Time: 12:30:00")
    #expect(KVRow.parseBulk(text) == rows)
    #expect(KVRow.parseBulk("\n flag \n// a:b\n") == [
        KVRow(name: "flag", value: "", disabled: false),
        KVRow(name: "a", value: "b", disabled: true),
    ])
}

@Test("bulk replace keeps each param's location by name")
func bulkReplaceKeepsParamKind() {
    var params = [OCParam(name: "id", value: "1", kind: "path", disabled: false)]
    params.apply(.replaceAll([KVRow(name: "id", value: "2", disabled: false), KVRow(name: "q", value: "x", disabled: false)]))
    #expect(params.map(\.kind) == ["path", "query"])
    #expect(params.map(\.value) == ["2", "x"])
}
