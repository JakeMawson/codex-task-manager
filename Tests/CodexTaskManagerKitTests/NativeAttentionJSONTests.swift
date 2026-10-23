import Foundation
import Testing
@testable import CodexTaskManagerKit

@Suite("Streaming attention JSON") struct NativeAttentionJSONTests {
    private func wire(_ state: [String: Any]) -> [String: Any] {
        ["type": "broadcast", "method": "thread-stream-state-changed", "params": ["hostId": "local", "conversationId": "fixture", "change": ["type": "snapshot", "revision": 12, "conversationState": state]]]
    }
    private func project(_ raw: Data, chunkSize: Int) throws -> [String: Any] {
        let projector = NativeAttentionJSON()
        for offset in stride(from: 0, to: raw.count, by: chunkSize) {
            try projector.consume(raw.subdata(in: offset..<min(raw.count, offset + chunkSize)))
        }
        return try JSONSerialization.jsonObject(with: projector.finish()) as! [String: Any]
    }
    @Test(arguments: [1, 2, 3, 7, 31, 65536], [false, true])
    func arbitraryReadBoundaries(_ chunkSize: Int, _ paginated: Bool) throws {
        var state = NativeAttentionSnapshotTests.state(paginated: paginated)
        state["ignored"] = ["escaped": "quote\" slash\\ newline\n 🦈", "array": [true, false, NSNull(), 1.25]]
        let raw = try JSONSerialization.data(withJSONObject: wire(state), options: .sortedKeys)
        let result = try project(raw, chunkSize: chunkSize)
        let change = (result["params"] as! [String: Any])["change"] as! [String: Any]
        let projected = change["conversationState"] as! [String: Any]
        #expect(projected["ignored"] == nil)
        #expect(try NativeAttentionSnapshot(state: projected, revision: 12).state == NativeAttentionSnapshot(state: state, revision: 12).state)
        #expect(CodexDesktopIPCClient.attentionState(inNativeState: projected) == .needsResponse)
    }
    @Test func responsesPatchesUnicodeAndEscapedKeys() throws {
        let response: [String: Any] = ["type": "response", "requestId": "id", "resultType": "success", "handledByClientId": "owner", "result": ["clientId": "client", "goalPauseError": "quote\" slash\\ 🦈\n"]]
        let raw = try JSONSerialization.data(withJSONObject: response, options: .sortedKeys)
        #expect(try NSDictionary(dictionary: project(raw, chunkSize: 1)) == NSDictionary(dictionary: response))
        let patch: [String: Any] = ["type": "patches", "baseRevision": 1, "revision": 2, "patches": [["op": "add", "path": ["turns", 1, "items", 1], "value": try NativeAttentionSnapshotTests.reply()]]]
        var message = wire(NativeAttentionSnapshotTests.state())
        var params = message["params"] as! [String: Any]; params["change"] = patch; message["params"] = params
        let projected = try project(JSONSerialization.data(withJSONObject: message), chunkSize: 7)
        let result = (projected["params"] as! [String: Any])["change"] as! [String: Any]
        var mirror = try NativeAttentionSnapshot(state: NativeAttentionSnapshotTests.state(), revision: 1)
        try mirror.apply(result)
        #expect(mirror.attention == .running)
        let escaped = Data(#"{"t\u0079pe":"client-discovery-request","requestId":"quote\"\\🦈"}"#.utf8)
        #expect(try project(escaped, chunkSize: 1)["type"] as? String == "client-discovery-request")
    }
    @Test func discardedTextIsBoundedAndRetainedTextHasALimit() throws {
        let projector = NativeAttentionJSON(retainedLimit: 128)
        try projector.consume(Data(#"{"padding":""#.utf8))
        let chunk = Data(repeating: 120, count: 65536)
        for _ in 0..<64 { try projector.consume(chunk) }
        try projector.consume(Data(#"","type":"broadcast"}"#.utf8))
        #expect(try projector.finish().count < 128)
        let bounded = NativeAttentionJSON(retainedLimit: 128)
        #expect(throws: (any Error).self) { try bounded.consume(Data((#"{"result":""# + String(repeating: "x", count: 129)).utf8)) }
    }
    @Test(arguments: ["", "{", "{}{}", "{\"type\":}", "{\"type\":\"broken", "{\"type\":1,}", "{\"params\":[1,]}", "[}"])
    func malformedStructureIsRejected(_ text: String) {
        #expect(throws: (any Error).self) {
            let projector = NativeAttentionJSON()
            try projector.consume(Data(text.utf8))
            _ = try JSONSerialization.jsonObject(with: projector.finish())
        }
    }
}
