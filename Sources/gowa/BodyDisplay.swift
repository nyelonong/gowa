import Foundation

/// Precomputed response-body presentation, built once per response on a
/// background task so the main thread only assigns views.
struct BodyDisplay: Sendable {
    let isJSON: Bool
    let plain: String
    let pretty: String?
    let plainRuns: [JSONHighlighter.Run]
    let prettyRuns: [JSONHighlighter.Run]

    /// The text currently shown for a given Format toggle state.
    func text(prettyPrinted: Bool) -> String {
        prettyPrinted ? (pretty ?? plain) : plain
    }

    /// Color runs matching `text(prettyPrinted:)`.
    func runs(prettyPrinted: Bool) -> [JSONHighlighter.Run] {
        prettyPrinted ? prettyRuns : plainRuns
    }

    static func build(_ result: HTTPResult, bodyText: String) -> BodyDisplay {
        let json = JSONHighlighter.isJSON(bodyText, contentType: contentType(of: result))
        let prettyText = json ? JSONHighlighter.prettyPrint(bodyText) : nil
        return BodyDisplay(
            isJSON: json,
            plain: bodyText,
            pretty: prettyText,
            plainRuns: json ? JSONHighlighter.runs(bodyText) : [],
            prettyRuns: json ? (prettyText.map(JSONHighlighter.runs) ?? []) : []
        )
    }

    static func contentType(of result: HTTPResult) -> String? {
        result.headers.first { $0.name.lowercased() == "content-type" }?.value
    }
}
