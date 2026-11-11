import Testing
@testable import gowa

@MainActor
@Test("markdown splits into headings, lists, quotes, code, and paragraphs")
func markdownBlocks() {
    let text = """
    # Orders API
    Creates an **order**
    for the user.

    - needs `token`
    2. retry once
    > deprecated soon
    ```
    {"a": 1}
    ```
    ---
    #nospace
    """
    #expect(MarkdownView.blocks(text) == [
        .heading(1, "Orders API"),
        .paragraph("Creates an **order** for the user."),
        .bullet("needs `token`"),
        .numbered("2", "retry once"),
        .quote("deprecated soon"),
        .code(#"{"a": 1}"#),
        .rule,
        .paragraph("#nospace"),
    ])
}
