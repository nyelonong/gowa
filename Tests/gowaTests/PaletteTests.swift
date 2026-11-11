import Testing
@testable import gowa

@MainActor
@Test("palette ranking prefers contiguous and word-start matches and drops non-matches")
func paletteRanking() {
    let items = ["Create order", "Get product", "Get products by category", "Manage Environments…"].map { title in
        PaletteItem(id: title, kind: .action, title: title, subtitle: "", badge: nil) {}
    }
    #expect(PaletteSearch.rank(items, query: "getprod").map(\.title).prefix(2) == ["Get product", "Get products by category"])
    #expect(PaletteSearch.rank(items, query: "env").first?.title == "Manage Environments…")
    #expect(PaletteSearch.rank(items, query: "zzz").isEmpty)
    #expect(PaletteSearch.score("co", "Create order")! < PaletteSearch.score("co", "Collection")!)
    #expect(PaletteSearch.rank(items, query: " ").count == 4)
}
