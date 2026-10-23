import Foundation

/// A sparse, revisioned mirror of Codex's attention fields. Array positions are
/// retained so native Immer patches apply without retaining tool output/media.
struct NativeAttentionSnapshot {
    private enum Shape {
        case root, turns, turn, historyContainer, history, entities, items, item, content, contentItem, leaf
        func child(_ key: String) -> Shape? {
            switch self {
            case .root:
                return ["threadRuntimeStatus": .leaf, "turns": .turns, "turnHistory": .historyContainer][key]
            case .historyContainer: return key == "history" ? .history : nil
            case .history: return key == "entitiesByKey" ? .entities : nil
            case .entities: return .turn
            case .turns: return key == "length" ? .leaf : Int(key) != nil ? .turn : nil
            case .turn: return key == "items" ? .items : ["status", "turnId"].contains(key) ? .leaf : nil
            case .items: return key == "length" ? .leaf : Int(key) != nil ? .item : nil
            case .item:
                return ["content", "input"].contains(key) ? .content : ["type", "id", "delivery", "questions", "status"].contains(key) ? .leaf : nil
            case .content: return key == "length" ? .leaf : Int(key) != nil ? .contentItem : nil
            case .contentItem: return ["type", "text"].contains(key) ? .leaf : nil
            case .leaf: return .leaf
            }
        }
    }
    private(set) var revision: Int
    private(set) var state: JSONValue
    var attention: TaskAttentionState? { CodexDesktopIPCClient.attentionState(in: state.objectValue ?? [:]) }

    init(state: [String: Any], revision: Int) throws {
        self.revision = revision
        self.state = try Self.project(state, shape: .root)
    }

    mutating func apply(_ change: [String: Any]) throws {
        guard let base = change["baseRevision"] as? Int, base == revision,
              let next = change["revision"] as? Int, next > base,
              let patches = change["patches"] as? [[String: Any]] else { throw InvalidPatch() }
        var updated = state
        for patch in patches {
            guard let rawPath = patch["path"] as? [Any], let op = patch["op"] as? String,
                  ["add", "remove", "replace"].contains(op) else { throw InvalidPatch() }
            let path = try rawPath.map { part -> String in
                if let key = part as? String { return key }
                if let index = part as? Int { return String(index) }
                throw InvalidPatch()
            }
            var shape = Shape.root
            var relevant = true
            for key in path {
                guard let child = shape.child(key) else { relevant = false; break }
                shape = child
            }
            guard relevant else { continue }
            // Text/content patches for reasoning and tool items are irrelevant.
            if let items = path.firstIndex(of: "items"), path.count > items + 2,
               ["content", "input"].contains(path[items + 2]),
               let item = Self.value(in: updated, path: Array(path.prefix(items + 2)))?.objectValue,
               !["userMessage", "steeringUserMessage"].contains(item["type"]?.stringValue ?? "") { continue }
            let value = op == "remove" ? JSONValue.null : try Self.project(patch["value"] ?? NSNull(), shape: shape)
            try Self.mutate(&updated, path: ArraySlice(path), op: op, value: value)
        }
        state = updated
        revision = next
    }

    private static func project(_ raw: Any, shape: Shape) throws -> JSONValue {
        if case .leaf = shape {
            if let text = raw as? String { return .string(text) }
            if let number = raw as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
                return ["d", "f"].contains(String(cString: number.objCType)) ? .double(number.doubleValue) : .int(number.intValue)
            }
            if let array = raw as? [Any] { return .array(try array.map { try project($0, shape: .leaf) }) }
            if let object = raw as? [String: Any] { return .object(try object.mapValues { try project($0, shape: .leaf) }) }
            if raw is NSNull { return .null }
            throw InvalidPatch()
        }
        if let array = raw as? [Any] {
            return .array(try array.enumerated().map { index, value in
                guard let child = shape.child(String(index)) else { return .null }
                return try project(value, shape: child)
            })
        }
        guard let object = raw as? [String: Any] else { return .null }
        var projected: [String: JSONValue] = [:]
        for (key, value) in object {
            guard let child = shape.child(key) else { continue }
            if case .item = shape, ["content", "input"].contains(key),
               !["userMessage", "steeringUserMessage"].contains(object["type"] as? String ?? "") { continue }
            projected[key] = try project(value, shape: child)
        }
        return .object(projected)
    }

    private static func value(in root: JSONValue, path: [String]) -> JSONValue? {
        var node = root
        for key in path {
            if let object = node.objectValue, let next = object[key] { node = next }
            else if let array = node.arrayValue, let index = Int(key), array.indices.contains(index) { node = array[index] }
            else { return nil }
        }
        return node
    }

    private static func mutate(_ node: inout JSONValue, path: ArraySlice<String>, op: String, value: JSONValue) throws {
        guard let key = path.first else { node = op == "remove" ? .null : value; return }
        if var object = node.objectValue {
            if path.count == 1 {
                if op == "remove" { object.removeValue(forKey: key) } else { object[key] = value }
            } else {
                guard var child = object[key] else { throw InvalidPatch() }
                try mutate(&child, path: path.dropFirst(), op: op, value: value)
                object[key] = child
            }
            node = .object(object)
        } else if var array = node.arrayValue, key == "length", path.count == 1, op == "replace", let length = value.intValue, (0...array.count).contains(length) {
            array = Array(array.prefix(length))
            node = .array(array)
        } else if var array = node.arrayValue, let index = Int(key), index >= 0 {
            if path.count == 1 {
                if op == "add", index <= array.count { array.insert(value, at: index) }
                else if array.indices.contains(index) {
                    if op == "remove" { array.remove(at: index) } else { array[index] = value }
                } else { throw InvalidPatch() }
            } else {
                guard array.indices.contains(index) else { throw InvalidPatch() }
                try mutate(&array[index], path: path.dropFirst(), op: op, value: value)
            }
            node = .array(array)
        } else { throw InvalidPatch() }
    }
    private struct InvalidPatch: Error {}
}
