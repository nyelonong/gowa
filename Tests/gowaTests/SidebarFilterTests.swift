import Testing
@testable import gowa

private func request(_ path: NodePath, _ name: String, _ method: String, _ url: String) -> SidebarNode {
    SidebarNode(node: OCNode(path: path, name: name, isFolder: false, method: method, url: url), children: [])
}

private func folder(_ path: NodePath, _ name: String, _ children: [SidebarNode]) -> SidebarNode {
    SidebarNode(node: OCNode(path: path, name: name, isFolder: true, method: nil, url: nil), children: children)
}

private let tree = [
    request([0], "Health", "GET", "{{baseUrl}}/health"),
    folder([1], "Orders", [
        request([1, 0], "Create order", "POST", "{{baseUrl}}/orders"),
        request([1, 1], "Remove", "DELETE", "{{baseUrl}}/orders/1"),
    ]),
    folder([2], "Webhooks", [
        folder([2, 0], "Stripe", [
            request([2, 0, 0], "Callback", "GET", "{{baseUrl}}/stripe/callback"),
        ]),
    ]),
]

private func names(_ nodes: [SidebarNode]) -> [String] {
    nodes.flatMap { [$0.name] + names($0.children) }
}

@Test("blank search keeps the whole tree")
func sidebarFilterBlank() {
    #expect(names(SidebarNode.filter(tree, query: "  ")) == names(tree))
}

@Test("search matches request name, URL, and method, keeping ancestor folders")
func sidebarFilterFields() {
    #expect(names(SidebarNode.filter(tree, query: "CALLBACK")) == ["Webhooks", "Stripe", "Callback"])
    #expect(names(SidebarNode.filter(tree, query: "/health")) == ["Health"])
    #expect(names(SidebarNode.filter(tree, query: "delete")) == ["Orders", "Remove"])
}

@Test("every search word must match; a matching folder keeps its subtree")
func sidebarFilterWordsAndFolders() {
    #expect(names(SidebarNode.filter(tree, query: "post orders")) == ["Orders", "Create order"])
    #expect(names(SidebarNode.filter(tree, query: "stripe")) == ["Webhooks", "Stripe", "Callback"])
    #expect(SidebarNode.filter(tree, query: "nothing-here").isEmpty)
    #expect(SidebarNode.firstRequest(in: SidebarNode.filter(tree, query: "orders"))?.name == "Create order")
}
