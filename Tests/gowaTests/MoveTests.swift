import Foundation
import Testing
@testable import gowa

@MainActor
private func tree() -> OpenCollectionDocument {
    func request(_ name: String) -> [String: Any] {
        ["info": ["name": name, "type": "http"], "http": ["method": "GET", "url": "https://x.test/\(name)"]]
    }
    func folder(_ name: String, _ items: [[String: Any]]) -> [String: Any] {
        ["info": ["name": name, "type": "folder"], "items": items]
    }
    return OpenCollectionDocument(root: ["items": [
        request("a"),
        folder("F", [request("f1"), request("f2")]),
        request("b"),
        folder("G", [folder("H", [request("h1")])]),
    ]])
}

@MainActor
private func names(_ doc: OpenCollectionDocument) -> [String] {
    doc.enumerate().map { String(repeating: ".", count: $0.path.count - 1) + $0.name }
}

@MainActor
@Test("reorder within the same parent, both directions")
func moveReorder() {
    let doc = tree()
    #expect(doc.move(from: [0], toParent: nil, index: 3) == [2])
    #expect(names(doc) == ["F", ".f1", ".f2", "b", "a", "G", ".H", "..h1"])
    #expect(doc.move(from: [1], toParent: nil, index: 0) == [0])
    #expect(names(doc) == ["b", "F", ".f1", ".f2", "a", "G", ".H", "..h1"])
}

@MainActor
@Test("move into a folder, out to the top level, and to the end")
func moveAcrossFolders() {
    let doc = tree()
    #expect(doc.move(from: [0], toParent: [1], index: nil) == [0, 2])
    #expect(names(doc) == ["F", ".f1", ".f2", ".a", "b", "G", ".H", "..h1"])
    #expect(doc.move(from: [2, 0, 0], toParent: nil, index: 0) == [0])
    #expect(names(doc) == ["h1", "F", ".f1", ".f2", ".a", "b", "G", ".H"])
}

@MainActor
@Test("a folder can't move into itself or its descendants, or into a request")
func moveRejectsCycles() {
    let doc = tree()
    #expect(doc.move(from: [3], toParent: [3, 0], index: nil) == nil)
    #expect(doc.move(from: [3], toParent: [3], index: nil) == nil)
    #expect(doc.move(from: [1], toParent: [0], index: nil) == nil)
    #expect(names(doc) == names(tree()))
}

@MainActor
@Test("selection paths follow the moved item and its shifted siblings")
func moveRemapsSelection() {
    let doc = tree()
    let result = doc.move(from: [1], toParent: [3], index: 0)!
    #expect(result == [2, 0])
    #expect(OpenCollectionDocument.remap([1, 1], from: [1], toParent: [3], index: 0, result: result) == [2, 0, 1])
    #expect(OpenCollectionDocument.remap([2], from: [1], toParent: [3], index: 0, result: result) == [1])
    #expect(OpenCollectionDocument.remap([3, 0, 0], from: [1], toParent: [3], index: 0, result: result) == [2, 1, 0])
    #expect(doc.enumerate().first { $0.path == [2, 1, 0] }?.name == "h1")
    #expect(doc.enumerate().first { $0.path == [2, 0, 1] }?.name == "f2")
}

@MainActor
@Test("deleting or duplicating an earlier item keeps the selection on the same request")
func selectionFollowsDeleteAndDuplicate() {
    let app = AppState(restoringLastCollection: false)
    let doc = tree()
    app.document = doc
    app.select(path: [2])
    #expect(app.draft?.name == "b")

    app.delete([0])
    #expect(app.selectedRequestPath == [1])
    #expect(app.document?.requestSnapshot(at: app.selectedRequestPath!)?.name == "b")

    app.duplicate([0])
    #expect(app.selectedRequestPath == [2])
    #expect(app.document?.requestSnapshot(at: app.selectedRequestPath!)?.name == "b")
}

@MainActor
@Test("the folder runner only picks HTTP and GraphQL requests")
func runnerSkipsStreamingItems() {
    let app = AppState(restoringLastCollection: false)
    app.document = OpenCollectionDocument(root: ["items": [
        ["info": ["name": "h", "type": "http"], "http": ["method": "GET", "url": "https://x.test"]],
        ["info": ["name": "g", "type": "graphql"], "graphql": ["url": "https://x.test/gql"]],
        ["info": ["name": "w", "type": "websocket"], "websocket": ["url": "wss://x.test"]],
        ["info": ["name": "r", "type": "grpc"], "grpc": ["url": "x.test:443"]],
    ]])
    #expect(app.runnerRequests(under: nil) == [[0], [1]])
}
