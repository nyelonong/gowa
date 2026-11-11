import Testing
@testable import gowa

private let json = """
{
  "a": [
    1,
    2
  ],
  "s": "has { and [ inside",
  "o": {
    "k": true
  }
}
"""

@Test("fold ranges match brackets across lines and ignore brackets in strings")
func foldRanges() {
    let lines = json.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(CodeFolding.foldRanges(lines) == [0: 9, 1: 4, 6: 8])
}

@Test("folding collapses a block and keeps original line numbers")
func foldRender() {
    let lines = json.split(separator: "\n", omittingEmptySubsequences: false)
    let rendered = CodeFolding.render(lines, folded: [1], ranges: CodeFolding.foldRanges(lines))
    #expect(rendered.text.split(separator: "\n")[1] == #"  "a": [ … ],"#)
    #expect(rendered.lineNumbers == [0, 1, 5, 6, 7, 8, 9])
}

@Test("line lookup maps character offsets to lines")
func lineLookup() {
    let starts = CodeViewer.lineStarts("ab\ncd\n\nef")
    #expect(starts == [0, 3, 6, 7])
    #expect([0, 2, 3, 6, 8].map { offset in starts.lastIndex { $0 <= offset }! } == [0, 0, 1, 2, 3])
}
