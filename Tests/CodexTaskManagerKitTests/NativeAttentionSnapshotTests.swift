import Foundation
import Testing
@testable import CodexTaskManagerKit

@Suite("Live attention patches")
struct NativeAttentionSnapshotTests {
    static func question(_ id: String = "question") -> [String: Any] {
        ["type": "agentMessage", "id": id, "delivery": "async", "questions": [["title": "Choose"]]]
    }
    static func reply(status: String = "accepted") throws -> [String: Any] {
        let id = String(decoding: try JSONSerialization.data(withJSONObject: ["request_user_input_async", "question", 0]), as: UTF8.self)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: [["questionItemId": id, "question": "Choose", "answer": "Done"]]), as: UTF8.self)
        return ["type": "steeringUserMessage", "status": status, "input": [["type": "text", "text": "<send_user_message_question_reply>\n\(json)\n</send_user_message_question_reply>"]]]
    }
    static func state(paginated: Bool = false) -> [String: Any] {
        let turn: [String: Any] = ["turnId": "current", "status": "inProgress", "items": [question()]]
        let old: [String: Any] = ["turnId": "old", "status": "interrupted", "items": [question("historical-unanswered")]]
        var state: [String: Any] = ["threadRuntimeStatus": ["type": "active", "activeFlags": []]]
        if paginated { state["turnHistory"] = ["history": ["entitiesByKey": ["current": turn, "old": old]]] }
        else { state["turns"] = [old, turn] }
        return state
    }
    @Test(arguments: [false, true])
    func acceptedReplyAndNewQuestion(_ paginated: Bool) throws {
        var mirror = try NativeAttentionSnapshot(state: Self.state(paginated: paginated), revision: 10)
        let path: [Any] = paginated ? ["turnHistory", "history", "entitiesByKey", "current"] : ["turns", 1]
        #expect(mirror.attention == .needsResponse)
        try mirror.apply(["baseRevision": 10, "revision": 11, "patches": [["op": "add", "path": path + ["items", 1], "value": try Self.reply(status: "pending")]]])
        #expect(mirror.attention == .needsResponse)
        try mirror.apply(["baseRevision": 11, "revision": 12, "patches": [["op": "replace", "path": path + ["items", 1, "status"], "value": "accepted"]]])
        #expect(mirror.attention == .running)
        try mirror.apply(["baseRevision": 12, "revision": 13, "patches": [["op": "add", "path": path + ["items", 2], "value": Self.question("new-question")]]])
        #expect(mirror.attention == .needsResponse)
        try mirror.apply(["baseRevision": 13, "revision": 14, "patches": [["op": "replace", "path": path + ["status"], "value": "completed"], ["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]]]])
        #expect(mirror.attention == .idle)
    }
    @Test func revisionGapAndAtomicFailure() throws {
        var mirror = try NativeAttentionSnapshot(state: Self.state(), revision: 10)
        #expect(throws: (any Error).self) { try mirror.apply(["baseRevision": 9, "revision": 12, "patches": []]) }
        #expect(mirror.revision == 10)
        #expect(throws: (any Error).self) { try mirror.apply(["baseRevision": 10, "revision": 11, "patches": [["op": "replace", "path": ["turns", 1, "status"], "value": "completed"], ["op": "remove", "path": ["turns", 20]]]]) }
        #expect(mirror.revision == 10)
        #expect(mirror.attention == .needsResponse)
    }
    @Test func sparseMirrorPreservesIndexesWithoutToolOutput() throws {
        var state = Self.state()
        var turns = state["turns"] as! [[String: Any]]
        turns[1]["items"] = [Self.question(), ["type": "commandExecution", "aggregatedOutput": String(repeating: "x", count: 4_000_000)], ["type": "reasoning", "content": [String(repeating: "y", count: 4_000_000)]]]
        state["turns"] = turns
        var mirror = try NativeAttentionSnapshot(state: state, revision: 0)
        #expect(try JSONEncoder().encode(mirror.state).count < 1000)
        try mirror.apply(["baseRevision": 0, "revision": 1, "patches": [["op": "replace", "path": ["turns", 1, "items", 1, "aggregatedOutput"], "value": String(repeating: "z", count: 4_000_000)], ["op": "replace", "path": ["turns", 1, "items", 2, "content"], "value": ["more reasoning"]], ["op": "remove", "path": ["turns", 1, "items", 1]], ["op": "add", "path": ["turns", 1, "items", 2], "value": try Self.reply()]]])
        #expect(mirror.attention == .running)
        #expect(try JSONEncoder().encode(mirror.state).count < 1500)
    }
}
