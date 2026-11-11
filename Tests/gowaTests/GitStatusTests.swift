import Testing
@testable import gowa

@Test("git porcelain status parses branch, ahead/behind, renames, and the collection file")
func gitStatusParse() {
    let output = """
    ## main...origin/main [ahead 2, behind 1]
     M api/Cekat.yml
    ?? notes.txt
    R  old.yml -> "new name.yml"
    """
    let status = GitStatus.parse(output, collectionPath: "api/Cekat.yml")
    #expect(status.branch == "main")
    #expect(status.ahead == 2 && status.behind == 1)
    #expect(status.changes.map(\.path) == ["api/Cekat.yml", "notes.txt", "new name.yml"])
    #expect(status.changes.map(\.label) == ["modified", "untracked", "renamed"])
    #expect(status.collectionChange?.label == "modified")
    #expect(GitStatus.parse("## No commits yet on dev\n", collectionPath: nil).branch == "dev")
}
