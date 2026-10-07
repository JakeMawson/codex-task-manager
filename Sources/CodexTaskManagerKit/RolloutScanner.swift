import Foundation

struct PendingRolloutRequest: Sendable {
    let requestedAt: Date?
}

struct RolloutScanState: Sendable {
    var latestAssistantMessage: String?
    var latestAssistantMessageDate: Date?
    var latestUserMessageDate: Date?
    var completionDate: Date?
    var latestRecordDate: Date?
    var isDesktopManaged = false
    var pendingApprovalCalls: [String: PendingRolloutRequest] = [:]
    var pendingInputCalls: [String: PendingRolloutRequest] = [:]
    var isRunning = false
    var parsedLine = false
    var pendingLine = Data()

    var snapshot: RolloutSnapshot {
        RolloutSnapshot(
            latestAssistantMessage: latestAssistantMessage,
            latestAssistantMessageDate: latestAssistantMessageDate,
            latestUserMessageDate: latestUserMessageDate,
            attentionRequestDate: (
                pendingApprovalCalls.values.compactMap(\.requestedAt)
                    + pendingInputCalls.values.compactMap(\.requestedAt)
            ).max(),
            completionDate: completionDate,
            latestRecordDate: latestRecordDate,
            isDesktopManaged: isDesktopManaged,
            isRunning: parsedLine && isRunning,
            needsApproval: !pendingApprovalCalls.isEmpty && isRunning,
            needsResponse: !pendingInputCalls.isEmpty && isRunning
        )
    }
}

public struct RolloutScanCursor: Sendable {
    private var state: RolloutScanState
    private var offset: UInt64

    public init(fileURL: URL) throws {
        offset = try RolloutScanner.fileSize(fileURL)
        state = try RolloutScanner.scanState(fileURL: fileURL, throughOffset: offset)
    }

    public var snapshot: RolloutSnapshot { state.snapshot }
    var pendingLineForTesting: Data { state.pendingLine }
    var pendingApprovalCountForTesting: Int { state.pendingApprovalCalls.count }

    public mutating func scanAppended(fileURL: URL) throws -> RolloutSnapshot {
        let currentSize = try RolloutScanner.fileSize(fileURL)
        if currentSize > offset {
            state = try RolloutScanner.scanAppended(
                fileURL: fileURL,
                previousState: state,
                fromOffset: offset,
                throughOffset: currentSize
            )
        } else if currentSize < offset {
            state = try RolloutScanner.scanState(fileURL: fileURL)
        }
        offset = currentSize
        return state.snapshot
    }
}

public enum RolloutScanner {
    private static let initialTailBytes = 16 * 1_024
    private static let maximumTailBytes = 4 * 1_024 * 1_024

    public static func scan(fileURL: URL) throws -> RolloutSnapshot {
        try scanState(fileURL: fileURL).snapshot
    }

    static func scanState(
        fileURL: URL,
        throughOffset requestedOffset: UInt64? = nil
    ) throws -> RolloutScanState {
        let size = try requestedOffset ?? fileSize(fileURL)
        let initialData = try tailData(fileURL: fileURL, throughOffset: size, maximumBytes: initialTailBytes)
        let startsMidFile = size > UInt64(initialData.count)
        let initialState = startsMidFile
            ? try sessionMetadataState(fileURL: fileURL, throughOffset: size)
            : RolloutScanState()
        let initial = parse(initialData, startsMidFile: startsMidFile, initialState: initialState)
        if initialData.count < initialTailBytes || hasRequiredRecency(in: initial) {
            return initial
        }

        let expandedData = try tailData(fileURL: fileURL, throughOffset: size, maximumBytes: maximumTailBytes)
        return parse(expandedData, startsMidFile: size > UInt64(expandedData.count))
    }

    private static func hasRequiredRecency(in state: RolloutScanState) -> Bool {
        let snapshot = state.snapshot
        if snapshot.needsApproval || snapshot.needsResponse {
            return snapshot.attentionRequestDate != nil
        }
        if snapshot.isRunning {
            return snapshot.latestUserMessageDate != nil
        }
        return snapshot.completionDate != nil && snapshot.latestAssistantMessageDate != nil
    }

    static func scanAppended(
        fileURL: URL,
        previousState: RolloutScanState,
        fromOffset: UInt64,
        throughOffset: UInt64
    ) throws -> RolloutScanState {
        guard throughOffset >= fromOffset else {
            return try scanState(fileURL: fileURL)
        }
        let appended = try data(
            fileURL: fileURL,
            offset: fromOffset,
            count: Int(throughOffset - fromOffset)
        )
        guard appended.count == Int(throughOffset - fromOffset) else {
            throw CocoaError(.fileReadUnknown)
        }
        return parse(appended, startsMidFile: false, initialState: previousState)
    }

    private static func parse(
        _ data: Data,
        startsMidFile: Bool,
        initialState: RolloutScanState = RolloutScanState()
    ) -> RolloutScanState {
        var state = initialState
        var parseData = Data()
        if !state.pendingLine.isEmpty {
            parseData.append(state.pendingLine)
            state.pendingLine.removeAll(keepingCapacity: true)
        }
        parseData.append(data)

        var text = String(decoding: parseData, as: UTF8.self)
        if startsMidFile, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if !text.isEmpty, text.last != "\n", let partial = lines.popLast() {
            state.pendingLine = Data(partial.utf8)
        }

        for line in lines {
            guard
                let lineData = line.data(using: .utf8),
                let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let type = root["type"] as? String,
                let payload = root["payload"] as? [String: Any]
            else { continue }

            state.parsedLine = true
            let payloadType = payload["type"] as? String
            let recordDate = timestamp(in: root)
            if let recordDate {
                state.latestRecordDate = max(state.latestRecordDate ?? recordDate, recordDate)
            }

            if type == "event_msg" {
                switch payloadType {
                case "agent_message":
                    state.isRunning = true
                    if let message = payload["message"] as? String {
                        state.latestAssistantMessage = compact(message)
                        state.latestAssistantMessageDate = recordDate
                    }
                case "task_started":
                    state.isRunning = true
                    state.pendingInputCalls.removeAll()
                    state.completionDate = nil
                case "task_complete", "turn_aborted":
                    state.isRunning = false
                    state.completionDate = recordDate
                    state.pendingApprovalCalls.removeAll()
                    state.pendingInputCalls.removeAll()
                case "token_count", "agent_reasoning", "thread_settings_applied":
                    break
                default:
                    state.isRunning = true
                }
            }

            if type == "session_meta",
               payload["originator"] as? String == "Codex Desktop" {
                state.isDesktopManaged = true
            }

            if type == "response_item" {
                state.isRunning = true

                if payloadType == "message",
                   payload["role"] as? String == "user" {
                    state.latestUserMessageDate = recordDate
                }

                if payloadType == "custom_tool_call",
                   payload["name"] as? String == "exec",
                   let input = payload["input"] as? String,
                   isDirectEscalationRequest(input),
                   let callID = payload["call_id"] as? String {
                    state.pendingApprovalCalls[callID] = PendingRolloutRequest(requestedAt: recordDate)
                }

                if payloadType == "function_call",
                   payload["name"] as? String == "request_user_input",
                   let callID = payload["call_id"] as? String {
                    state.pendingInputCalls[callID] = PendingRolloutRequest(requestedAt: recordDate)
                }

                if payloadType == "function_call_output",
                   let callID = payload["call_id"] as? String {
                    state.pendingInputCalls.removeValue(forKey: callID)
                }

                if payloadType == "custom_tool_call_output",
                   let callID = payload["call_id"] as? String {
                    state.pendingApprovalCalls.removeValue(forKey: callID)
                }
            }
        }

        return state
    }

    private static func sessionMetadataState(
        fileURL: URL,
        throughOffset: UInt64
    ) throws -> RolloutScanState {
        var state = RolloutScanState()
        let prefixCount = min(Int(throughOffset), maximumTailBytes)
        let prefix = try data(fileURL: fileURL, offset: 0, count: prefixCount)
        let firstLine = prefix.firstRange(of: Data([0x0A])).map { prefix[..<$0.lowerBound] }
            ?? prefix[...]
        guard
            let root = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
            root["type"] as? String == "session_meta",
            let payload = root["payload"] as? [String: Any],
            payload["originator"] as? String == "Codex Desktop"
        else { return state }
        state.isDesktopManaged = true
        return state
    }

    /// A direct tool call persists its JSON-RPC input as either JSON-escaped
    /// text or Swift/JavaScript-like source. Only the explicit elevated-command
    /// form represents an approval request; an ordinary outstanding command
    /// remains a running task.
    private static func isDirectEscalationRequest(_ input: String) -> Bool {
        let normalized = input.replacingOccurrences(of: "\\\"", with: "\"")
        return normalized.range(
            of: #"(?:[\"']sandbox_permissions[\"']|sandbox_permissions)\s*:\s*[\"']require_escalated[\"']"#,
            options: .regularExpression
        ) != nil
    }

    private static func tailData(
        fileURL: URL,
        throughOffset: UInt64,
        maximumBytes: Int
    ) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let count = min(Int(throughOffset), maximumBytes)
        try handle.seek(toOffset: throughOffset - UInt64(count))
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else {
            throw CocoaError(.fileReadUnknown)
        }
        return data
    }

    private static func data(fileURL: URL, offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    static func fileSize(_ fileURL: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return size.uint64Value
    }

    private static func compact(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timestamp(in root: [String: Any]) -> Date? {
        guard let raw = root["timestamp"] as? String else { return nil }
        return try? Date(raw, strategy: .iso8601)
    }
}
