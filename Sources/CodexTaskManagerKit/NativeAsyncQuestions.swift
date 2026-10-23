import Foundation

/// Async questions are durable message items, not blocking runtime requests.
/// Their immediate tool acknowledgement and the agent's subsequent work do
/// not answer them. Match only accepted, structured user replies by identity.
enum NativeAsyncQuestions {
    private struct QuestionID: Hashable {
        let callID: String
        let index: Int

        init(callID: String, index: Int) {
            self.callID = callID
            self.index = index
        }

        init?(_ raw: String) {
            guard let values = try? JSONDecoder().decode([JSONValue].self, from: Data(raw.utf8)),
                  values.count == 3,
                  values[0].stringValue == "request_user_input_async",
                  let callID = values[1].stringValue, !callID.isEmpty,
                  let index = values[2].intValue, index >= 0 else { return nil }
            self.init(callID: callID, index: index)
        }
    }

    static func hasPending(in state: [String: JSONValue]) -> Bool {
        var turns = state["turns"]?.arrayValue ?? []
        if let entities = state["turnHistory"]?.objectValue?["history"]?.objectValue?["entitiesByKey"]?.objectValue {
            turns.append(contentsOf: entities.values)
        }
        // Codex retires async cards when their owning turn ends. Old questions
        // remain in history after interruption; they are not current requests.
        let items = turns.filter { $0.objectValue?["status"]?.stringValue == "inProgress" }
            .flatMap { $0.objectValue?["items"]?.arrayValue ?? [] }.compactMap(\.objectValue)
        var questions: Set<QuestionID> = []
        var answered: Set<QuestionID> = []
        for item in items {
            if item["type"]?.stringValue == "agentMessage",
               item["delivery"]?.stringValue == "async",
               let callID = item["id"]?.stringValue, !callID.isEmpty,
               let entries = item["questions"]?.arrayValue {
                for (index, entry) in entries.enumerated() where entry.objectValue?["title"]?.stringValue != nil {
                    questions.insert(QuestionID(callID: callID, index: index))
                }
            }
            let content: [JSONValue]?
            switch item["type"]?.stringValue {
            case "userMessage": content = item["content"]?.arrayValue
            case "steeringUserMessage" where item["status"]?.stringValue == "accepted":
                content = item["input"]?.arrayValue
            default: content = nil
            }
            guard let content, content.count == 1,
                  content[0].objectValue?["type"]?.stringValue == "text",
                  let text = content[0].objectValue?["text"]?.stringValue else { continue }
            answered.formUnion(replyIDs(in: text))
        }
        return !questions.subtracting(answered).isEmpty
    }

    private static func replyIDs(in text: String) -> Set<QuestionID> {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = "<send_user_message_question_reply>"
        let end = "</send_user_message_question_reply>"
        guard text.hasPrefix(start), text.hasSuffix(end),
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.dropFirst(start.count).dropLast(end.count).utf8)) else { return [] }
        let replies = value.arrayValue ?? (value.objectValue == nil ? [] : [value])
        return Set(replies.compactMap { reply in
            guard let object = reply.objectValue,
                  object["answer"]?.stringValue != nil,
                  let raw = object["questionItemId"]?.stringValue else { return nil }
            return QuestionID(raw)
        })
    }
}
