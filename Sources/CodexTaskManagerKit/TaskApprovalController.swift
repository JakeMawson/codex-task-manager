import Foundation
import Darwin

public enum TaskApprovalControllerError: LocalizedError, Sendable {
    case connectionClosed
    case protocolError(String)
    public var errorDescription: String? {
        switch self {
        case .connectionClosed: "The Codex Desktop connection closed. Try again or open the chat in Codex."
        case .protocolError(let message): message
        }
    }
}

public protocol TaskApprovalControlling: Sendable {
    func liveAttentionState(for threadID: String) async -> TaskAttentionState?
    func liveAttentionState(for threadID: String, isDesktopManaged: Bool) async -> TaskAttentionState?
    func liveAttentionStates(for tasks: [CodexTask]) async -> [String: TaskAttentionState]
    func pause(threadID: String) async throws
    func pause(threadID: String, isDesktopManaged: Bool) async throws
}

extension TaskApprovalControlling {
    public func liveAttentionStates(for tasks: [CodexTask]) async -> [String: TaskAttentionState] {
        var states: [String: TaskAttentionState] = [:]
        await withTaskGroup(of: (String, TaskAttentionState?).self) { group in
            var iterator = tasks.makeIterator()
            for _ in 0..<min(8, tasks.count) {
                if let task = iterator.next() { group.addTask { (task.id, await self.liveAttentionState(for: task.id, isDesktopManaged: task.isDesktopManaged)) } }
            }
            while let (id, state) = await group.next() {
                if let state { states[id] = state }
                if let task = iterator.next() { group.addTask { (task.id, await self.liveAttentionState(for: task.id, isDesktopManaged: task.isDesktopManaged)) } }
            }
        }
        return states
    }
    public func pause(threadID: String, isDesktopManaged: Bool) async throws { try await pause(threadID: threadID) }
    public func liveAttentionState(for threadID: String, isDesktopManaged: Bool) async -> TaskAttentionState? {
        await liveAttentionState(for: threadID)
    }
}

enum CodexDesktopRuntimeDetector {
    static let privateAppServerExecutable = "/Applications/ChatGPT.app/Contents/Resources/codex"
    static let legacyPrivateAppServerArguments = ["-c", "features.code_mode_host=true", "app-server"]

    static func isPrivateDesktopAppServerCommand(_ arguments: [String]) -> Bool {
        guard [privateAppServerExecutable, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"].contains(arguments.first ?? "") else { return false }
        let appServerArguments = Array(arguments.dropFirst())
        return appServerArguments.starts(with: ["app-server", "--listen", "stdio://"])
            || appServerArguments.starts(with: legacyPrivateAppServerArguments)
    }

    static func privateDesktopAppServerIsPresent(in processTable: String) -> Bool {
        processTable.split(separator: "\n").contains { line in
            isPrivateDesktopAppServerCommand(
                line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).map(String.init)
            )
        }
    }

    static func privateDesktopAppServerIsRunning() -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return true }
            return privateDesktopAppServerIsPresent(in: String(decoding: data, as: UTF8.self))
        } catch {
            // Failing closed retains rollout-positive approvals rather than
            // hiding a real callback owned by an unobservable desktop runtime.
            return true
        }
    }

    static func earliestPrivateDesktopAppServerStartDate(
        in processTable: String,
        timeZone: TimeZone = .current
    ) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        formatter.isLenient = true

        return processTable.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard line.count > 24 else { return nil }
            let startText = String(line.prefix(24)).trimmingCharacters(in: .whitespaces)
            let command = String(line.dropFirst(24)).trimmingCharacters(in: .whitespaces)
            guard isPrivateDesktopAppServerCommand(command.split(whereSeparator: \.isWhitespace).map(String.init)) else {
                return nil
            }
            return formatter.date(from: startText)
        }.min()
    }

    static func privateDesktopAppServerStartDate() -> Date? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "lstart=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return earliestPrivateDesktopAppServerStartDate(in: String(decoding: data, as: UTF8.self))
        } catch {
            // Unknown runtime age must preserve rollout-positive state.
            return nil
        }
    }
}

public actor CodexTaskApprovalController: TaskApprovalControlling {
    private let desktopIPC = CodexDesktopIPCClient()
    public init(defaults: UserDefaults = .standard, cliPath: String? = nil) {}

    public func liveAttentionState(for threadID: String) async -> TaskAttentionState? {
        do { return try await desktopIPC.attentionState(for: threadID) }
        catch { return nil }
    }
    public func liveAttentionState(for threadID: String, isDesktopManaged: Bool) async -> TaskAttentionState? {
        // A missing Desktop owner says nothing about CLI/extension processes.
        guard isDesktopManaged else { return nil }
        return await liveAttentionState(for: threadID)
    }
    public func liveAttentionStates(for tasks: [CodexTask]) async -> [String: TaskAttentionState] {
        await desktopIPC.attentionStates(for: tasks.filter(\.isDesktopManaged).map(\.id))
    }
    public func pause(threadID: String, isDesktopManaged: Bool) async throws {
        guard isDesktopManaged else { throw TaskApprovalControllerError.protocolError("Stop this CLI or extension task in the app that owns it.") }
        try await pause(threadID: threadID)
    }
    public func pause(threadID: String) async throws {
        if let owner = try await desktopIPC.ownerClientID(for: threadID) {
            try await desktopIPC.pause(threadID: threadID, ownerClientID: owner)
        }
        // A successful owner discovery with no client establishes that this
        // Desktop task is already stopped. Transport failure must still throw.
        // Never resume, archive, rewrite goals, or alter permissions to Stop.
    }
}

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case let .int(value) = self else { return nil }
        return value
    }
}
