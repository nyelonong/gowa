import Foundation
import Testing
@testable import gowa

private var document: Any { try! JSONSerialization.jsonObject(with: Data("""
{"store": {"book": [
  {"title": "A", "price": 8, "tags": ["x"]},
  {"title": "B", "price": 12},
  {"title": "C", "price": 5}
], "owner": {"name": "Zed", "title": "boss"}}}
""".utf8)) }

private func values(_ path: String) throws -> [String] {
    try JSONPath.evaluate(path, on: document).map { "\($0)" }
}

@Test("JSONPath keys, indexes, wildcards, slices, and recursive descent")
func jsonPathSelectors() throws {
    #expect(try values("$.store.book[0].title") == ["A"])
    #expect(try values("$.store.book[-1].title") == ["C"])
    #expect(try values("$.store.book[*].price") == ["8", "12", "5"])
    #expect(try values("$.store.book[1:].title") == ["B", "C"])
    #expect(try values("$['store']['owner'].name") == ["Zed"])
    #expect(try values("$..title") == ["A", "B", "C", "boss"])
    #expect(try values("$.store.owner.*") == ["Zed", "boss"])
    #expect(try values("$.missing.path").isEmpty)
    #expect(throws: JSONPath.ParseError.self) { try JSONPath.parse("store.book") }
    #expect(throws: JSONPath.ParseError.self) { try JSONPath.parse("$.a[?(@.x)]") }
}

@Test("JSONPath renders one match alone and several as an array")
func jsonPathRender() throws {
    #expect(JSONPath.render(try JSONPath.evaluate("$.store.book[0].title", on: document)) == #""A""#)
    #expect(JSONPath.render(try JSONPath.evaluate("$.store.book[*].price", on: document)) == "[\n  8,\n  12,\n  5\n]")
}

@Test("XPath filters XML responses")
func xpathFilter() throws {
    let xml = Data("<r><item id=\"1\">a</item><item id=\"2\">b</item></r>".utf8)
    #expect(try XPathFilter.evaluate("//item[@id='2']", xml: xml) == #"<item id="2">b</item>"#)
}

@Test("filter results keep short number spelling and escape strings")
func renderNumbers() throws {
    let document = try JSONSerialization.jsonObject(with: Data(#"{"items":[{"rating":4.7,"price":129.5,"qty":3,"big":12345678901234,"ok":true,"none":null,"note":"a \"b\" / é"}]}"#.utf8))
    #expect(JSONPath.render(try JSONPath.evaluate("$.items[0].rating", on: document)) == "4.7")
    let rendered = JSONPath.render(try JSONPath.evaluate("$.items[0]", on: document))
    #expect(rendered == """
    {
      "big": 12345678901234,
      "none": null,
      "note": "a \\"b\\" / é",
      "ok": true,
      "price": 129.5,
      "qty": 3,
      "rating": 4.7
    }
    """)
    #expect(JSONPath.render([4.7, 1, "x"]) == "[\n  4.7,\n  1,\n  \"x\"\n]")
}
