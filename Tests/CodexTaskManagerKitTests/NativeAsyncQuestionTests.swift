import Foundation
import Testing
@testable import CodexTaskManagerKit

@Suite("Native asynchronous questions")
struct NativeAsyncQuestionTests {
    // Sanitized equivalent of the reported Desktop snapshot: async delivery
    // does not set waitingOnUserInput, and its accepted acknowledgement only
    // confirms presentation. The agent can continue working independently.
    @Test("An acknowledged asynchronous question still needs an answer")
    func reportedQuestion() throws {
        let state = try snapshot(items: [question("call-question", count: 1)])
        #expect(CodexDesktopIPCClient.attentionState(in: state) == .needsResponse)
    }

    @Test(arguments: ["answered", "skipped", "singleObjectReply", "partial", "allAnswered", "wrongCall", "ordinaryMessage", "quotedReply", "toolOutput", "pendingSteer", "rejectedSteer", "acceptedSteer", "noQuestions", "idlePending", "idleAnswered", "approvalPriority", "blockingInput", "duplicateHistory", "laterTurn", "unrelatedLaterTurn", "malformedReply", "negativeIndex", "wrongTool", "withdrawn"])
    func questionLifecycle(_ scenario: String) throws {
        var items = [question("call-question", count: 1)]
        var runtime = "active", flags: [String] = []
        var expected = TaskAttentionState.needsResponse
        var laterItems: [[String: Any]] = []
        switch scenario {
        case "answered", "skipped", "singleObjectReply":
            items.append(try reply("call-question", index: 0, answer: scenario == "skipped" ? "" : "Chosen", single: scenario == "singleObjectReply"))
            expected = .running
        case "partial", "allAnswered":
            items = [question("call-question", count: 2), try reply("call-question", index: 0)]
            if scenario == "allAnswered" { items.append(try reply("call-question", index: 1)); expected = .running }
        case "wrongCall": items.append(try reply("other-call", index: 0))
        case "ordinaryMessage": items.append(["type": "userMessage", "content": [["type": "text", "text": "Keep working."]]])
        case "quotedReply":
            var item = try reply("call-question", index: 0)
            let content = item["content"] as! [[String: Any]]
            item["content"] = [["type": "text", "text": "Quoted example: " + (content[0]["text"] as! String)]]
            items.append(item)
        case "toolOutput":
            var item = try reply("call-question", index: 0); item["type"] = "mcpToolCall"; items.append(item)
        case "pendingSteer", "rejectedSteer", "acceptedSteer":
            var item = try reply("call-question", index: 0)
            item["type"] = "steeringUserMessage"; item["input"] = item.removeValue(forKey: "content")
            item["status"] = scenario == "acceptedSteer" ? "accepted" : scenario == "pendingSteer" ? "pending" : "rejected"
            items.append(item)
            if scenario == "acceptedSteer" { expected = .running }
        case "noQuestions":
            items = [["type": "agentMessage", "id": "call-question", "delivery": "async", "text": "FYI"]]; expected = .running
        case "idlePending": runtime = "idle"
        case "idleAnswered": runtime = "idle"; items.append(try reply("call-question", index: 0)); expected = .idle
        case "approvalPriority": flags = ["waitingOnApproval"]; expected = .needsApproval
        case "blockingInput": items = []; flags = ["waitingOnUserInput"]
        case "duplicateHistory": items += items; items.append(try reply("call-question", index: 0)); expected = .running
        case "laterTurn": laterItems = [try reply("call-question", index: 0)]; expected = .running
        case "unrelatedLaterTurn": laterItems = [["type": "userMessage", "content": [["type": "text", "text": "Continue."]]]]
        case "malformedReply": items.append(["type": "userMessage", "content": [["type": "text", "text": "<send_user_message_question_reply>broken</send_user_message_question_reply>"]]])
        case "negativeIndex": items.append(try reply("call-question", index: -1))
        case "wrongTool": items.append(try reply("call-question", index: 0, tool: "unrelated_tool"))
        case "withdrawn": items = []; expected = .running
        default: Issue.record("Unknown test scenario")
        }
        // Both Desktop history representations must give the same answer.
        for paginated in [false, true] {
            var state = try snapshot(items: items, runtime: runtime, flags: flags)
            if !paginated {
                state["turns"] = state["turnHistory"]?.objectValue?["history"]?.objectValue?["entitiesByKey"]?.objectValue.map { .array(Array($0.values)) }
                state["turnHistory"] = nil
            }
            if !laterItems.isEmpty {
                let extra = try snapshot(items: laterItems)["turnHistory"]!.objectValue!["history"]!.objectValue!["entitiesByKey"]!.objectValue!.values.first!
                state["turns"] = .array((state["turns"]?.arrayValue ?? []) + [extra])
            }
            #expect(CodexDesktopIPCClient.attentionState(in: state) == expected, "\(scenario), paginated=\(paginated)")
        }
    }

    @Test("Many question IDs resolve independently without title or call collisions")
    func manyQuestions() throws {
        var items = (0..<100).map { question("call-\($0)", count: 2) }
        for call in 0..<100 {
            items.append(try reply("call-\(call)", index: 0))
            if call != 99 { items.append(try reply("call-\(call)", index: 1)) }
        }
        #expect(CodexDesktopIPCClient.attentionState(in: try snapshot(items: items)) == .needsResponse)
        items.append(try reply("call-99", index: 1))
        #expect(CodexDesktopIPCClient.attentionState(in: try snapshot(items: items)) == .running)
    }

    private func reply(_ callID: String, index: Int, answer: String = "Chosen", single: Bool = false, tool: String = "request_user_input_async") throws -> [String: Any] {
        let id = String(decoding: try JSONSerialization.data(withJSONObject: [tool, callID, index]), as: UTF8.self)
        let object = ["questionItemId": id, "question": "Please choose.", "answer": answer]
        let data = try JSONSerialization.data(withJSONObject: single ? object : [object])
        let text = "<send_user_message_question_reply>\n" + String(decoding: data, as: UTF8.self) + "\n</send_user_message_question_reply>"
        return ["type": "userMessage", "content": [["type": "text", "text": text]]]
    }

    private func question(_ id: String, count: Int) -> [String: Any] {
        ["type": "agentMessage", "id": id, "delivery": "async", "phase": "final_answer",
         "text": "Please choose.", "questions": (0..<count).map { _ in ["title": "Please choose."] }]
    }

    private func snapshot(items: [[String: Any]], runtime: String = "active", flags: [String] = []) throws -> [String: JSONValue] {
        let value: [String: Any] = [
            "threadRuntimeStatus": ["type": runtime, "activeFlags": flags],
            "turns": [],
            "turnHistory": ["kind": "paginated", "history": [
                "entitiesByKey": ["turn:fixture": ["turnId": "fixture", "status": "inProgress", "items": items]],
                "isComplete": false,
            ]],
        ]
        return try JSONDecoder().decode([String: JSONValue].self, from: JSONSerialization.data(withJSONObject: value))
    }
}
