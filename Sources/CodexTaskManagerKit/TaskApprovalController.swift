import Foundation
import Darwin

public enum TaskApprovalAction: String, Sendable {
    #if CODEX_TASK_MANAGER_EXPERIMENTAL_APPROVAL_ACTIONS
    // Disabled in production. Prefer Codex's native callback-owner actions.
    case allowOnce
    case allowSimilarCommands
    #endif
    case allowAllForTask
}

public enum TaskApprovalControllerError: LocalizedError, Sendable {
    case codexCLIUnavailable
    case daemonSetupFailed(String)
    case connectionClosed
    case protocolError(String)
    #if CODEX_TASK_MANAGER_EXPERIMENTAL_APPROVAL_ACTIONS
    case noPendingApproval
    case similarCommandUnavailable
    #endif

    public var errorDescription: String? {
        switch self {
        case .codexCLIUnavailable:
            "The bundled Codex CLI could not be found."
        case let .daemonSetupFailed(message):
            "The Codex companion service could not start: \(message)"
        case .connectionClosed:
            "The Codex companion connection closed unexpectedly."
        case let .protocolError(message):
            "Codex rejected the approval action: \(message)"
        #if CODEX_TASK_MANAGER_EXPERIMENTAL_APPROVAL_ACTIONS
        case .noPendingApproval:
            "This approval is not available on the shared Codex connection. Use Codex's native approval button instead."
        case .similarCommandUnavailable:
            "Codex did not provide a reusable command rule for this approval."
        #endif
        }
    }
}

public protocol TaskApprovalControlling: Sendable {
    func start() async throws
    func subscribe(to threadIDs: [String]) async
    func liveApprovalStateIsAuthoritative() async -> Bool
    func liveAttentionState(for threadID: String) async -> TaskAttentionState?
    func perform(_ action: TaskApprovalAction, for threadID: String) async throws
    func pause(threadID: String) async throws
}

enum CodexDesktopRuntimeDetector {
    static let privateAppServerExecutable = "/Applications/ChatGPT.app/Contents/Resources/codex"
    static let legacyPrivateAppServerArguments = ["-c", "features.code_mode_host=true", "app-server"]

    static func isPrivateDesktopAppServerCommand(_ arguments: [String]) -> Bool {
        guard arguments.first == privateAppServerExecutable else { return false }
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
    static let allowAllRecoveryDebounceInterval: Duration = .seconds(10)

    private struct StoredPolicy: Codable, Sendable {
        var allowAll = false
        var similarCommandPrefixes: [[String]] = []
    }

    private struct PendingApproval: Sendable {
        let requestID: JSONValue
        let threadID: String
        let turnID: String
        let method: String
        let proposedCommandPrefix: [String]?
    }

    private static let policyDefaultsKey = "CodexTaskManager.taskApprovalPolicies.v1"

    private let defaults: UserDefaults
    private let cliPathOverride: String?
    private let desktopIPC = CodexDesktopIPCClient()
    private var policies: [String: StoredPolicy]
    private var socketHandle: FileHandle?
    private var incomingBuffer = Data()
    private var fragmentedMessage = Data()
    private var isWebSocketUpgraded = false
    private var nextRequestID = 1_000_000
    private var pendingRequests: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var pendingRequestTimeouts: [Int: Task<Void, Never>] = [:]
    private var pendingApprovals: [String: PendingApproval] = [:]
    private var archivedThreadIDs = Set<String>()
    private var unarchivedThreadIDs = Set<String>()
    private var allowAllRecoveriesInFlight = Set<String>()
    private var lastAllowAllContinuationAt: [String: ContinuousClock.Instant] = [:]
    private var isStarted = false
    private var isStarting = false
    private var lastStartFailureAt: ContinuousClock.Instant?
    private var authorityCache: (checkedAt: ContinuousClock.Instant, isAuthoritative: Bool)?

    static let companionRequestTimeout: Duration = .seconds(5)
    static let companionStartRetryDelay: Duration = .seconds(5)

    static func lifecycleNotificationResolvesPendingApproval(
        method: String,
        params: [String: JSONValue],
        pendingThreadID: String,
        pendingTurnID: String,
        pendingRequestID: JSONValue
    ) -> Bool {
        guard params["threadId"]?.stringValue == pendingThreadID else { return false }
        switch method {
        case "serverRequest/resolved":
            return params["requestId"] == pendingRequestID
        case "turn/completed":
            return params["turn"]?.objectValue?["id"]?.stringValue == pendingTurnID
        default:
            return false
        }
    }

    static func shouldSuppressAllowAllRecovery(elapsed: Duration?) -> Bool {
        guard let elapsed else { return false }
        return elapsed < allowAllRecoveryDebounceInterval
    }

    static func inProgressTurnID(in response: JSONValue) -> String? {
        response.objectValue?["thread"]?.objectValue?["turns"]?.arrayValue?
            .reversed()
            .first(where: { $0.objectValue?["status"]?.stringValue == "inProgress" })?
            .objectValue?["id"]?.stringValue
    }

    #if CODEX_TASK_MANAGER_EXPERIMENTAL_APPROVAL_ACTIONS
    // Reference implementation only. These operations work when the approval
    // callback is replayed on this shared connection, but Codex's native UI is
    // more reliable because it always owns its private desktop callback.
    static func matchesSimilarCommand(
        proposedPrefix: [String]?,
        storedPrefixes: [[String]]
    ) -> Bool {
        guard let proposedPrefix, !proposedPrefix.isEmpty else { return false }
        return storedPrefixes.contains { storedPrefix in
            !storedPrefix.isEmpty
                && storedPrefix.count <= proposedPrefix.count
                && Array(proposedPrefix.prefix(storedPrefix.count)) == storedPrefix
        }
    }
    #endif

    public init(defaults: UserDefaults = .standard, cliPath: String? = nil) {
        self.defaults = defaults
        self.cliPathOverride = cliPath
        if let data = defaults.data(forKey: Self.policyDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: StoredPolicy].self, from: data) {
            self.policies = decoded
        } else {
            self.policies = [:]
        }
    }

    public func start() async throws {
        guard !isStarted else { return }
        let clock = ContinuousClock()
        if let lastStartFailureAt,
           clock.now - lastStartFailureAt < Self.companionStartRetryDelay {
            throw TaskApprovalControllerError.connectionClosed
        }
        guard !isStarting else { throw TaskApprovalControllerError.connectionClosed }
        isStarting = true
        defer { isStarting = false }
        let cliPath = try resolveCLIPath()
        do {
            try runShortCommand("/bin/launchctl", arguments: ["setenv", "CODEX_APP_SERVER_USE_LOCAL_DAEMON", "1"])
            try runShortCommand(cliPath, arguments: ["app-server", "daemon", "start"])
            try runShortCommand(cliPath, arguments: ["app-server", "daemon", "enable-remote-control"])
            let socketPath = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".codex/app-server-control/app-server-control.sock").path
            let handle = try connectUnixSocket(path: socketPath)
            handle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                Task {
                    if data.isEmpty {
                        await self?.connectionDidClose()
                    } else {
                        await self?.ingest(data)
                    }
                }
            }
            socketHandle = handle

            let keyBytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
            let key = Data(keyBytes).base64EncodedString()
            let handshake = [
                "GET /rpc HTTP/1.1",
                "Host: localhost",
                "Upgrade: websocket",
                "Connection: Upgrade",
                "Sec-WebSocket-Key: \(key)",
                "Sec-WebSocket-Version: 13",
                "",
                "",
            ].joined(separator: "\r\n")
            try handle.write(contentsOf: Data(handshake.utf8))
            try await waitForWebSocketUpgrade()

            _ = try await request(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("codex_task_manager"),
                        "title": .string("Codex Task Manager"),
                        "version": .string("1.0.0"),
                    ]),
                    "capabilities": .object(["experimentalApi": .bool(true)]),
                ])
            )
            try send(.object(["method": .string("initialized"), "params": .object([:])]))
            isStarted = true
            lastStartFailureAt = nil
            await subscribe(to: Array(policies.keys))
        } catch {
            lastStartFailureAt = clock.now
            connectionDidClose()
            if case TaskApprovalControllerError.daemonSetupFailed = error { throw error }
            throw error
        }
    }

    public func subscribe(to threadIDs: [String]) async {
        guard isStarted else { return }
        for threadID in Set(threadIDs) {
            do {
                _ = try await request(
                    method: "thread/resume",
                    params: .object(["threadId": .string(threadID)])
                )
                if policies[threadID]?.allowAll == true {
                    try await applyAllowAllSettings(threadID: threadID)
                }
            } catch {
                // A freshly-created thread may not have a rollout yet. The next refresh retries it.
            }
        }
    }

    public func liveApprovalStateIsAuthoritative() async -> Bool {
        let clock = ContinuousClock()
        if let authorityCache,
           clock.now - authorityCache.checkedAt < .seconds(30) {
            return authorityCache.isAuthoritative
        }
        let isAuthoritative = !CodexDesktopRuntimeDetector.privateDesktopAppServerIsRunning()
        authorityCache = (clock.now, isAuthoritative)
        return isAuthoritative
    }

    public func liveAttentionState(for threadID: String) async -> TaskAttentionState? {
        do {
            try await start()
            let response = try await request(
                method: "thread/resume",
                params: .object(["threadId": .string(threadID)])
            )
            guard let status = response.objectValue?["thread"]?.objectValue?["status"]?.objectValue,
                  let type = status["type"]?.stringValue
            else { return nil }
            let flags = Set(status["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            if flags.contains("waitingOnApproval") { return .needsApproval }
            if flags.contains("waitingOnUserInput") { return .needsResponse }
            return type == "active" ? .running : .idle
        } catch {
            return nil
        }
    }

    public func perform(_ action: TaskApprovalAction, for threadID: String) async throws {
        #if CODEX_TASK_MANAGER_EXPERIMENTAL_APPROVAL_ACTIONS
        switch action {
        case .allowOnce:
            try await performExperimentalAllowOnce(for: threadID)
            return
        case .allowSimilarCommands:
            try await performExperimentalAllowSimilarCommands(for: threadID)
            return
        case .allowAllForTask:
            break
        }
        #endif

        let clock = ContinuousClock()
        guard !allowAllRecoveriesInFlight.contains(threadID) else { return }
        if let lastStartedAt = lastAllowAllContinuationAt[threadID],
           Self.shouldSuppressAllowAllRecovery(elapsed: clock.now - lastStartedAt) {
            return
        }
        allowAllRecoveriesInFlight.insert(threadID)
        defer { allowAllRecoveriesInFlight.remove(threadID) }

        // Codex Desktop normally owns the live approval callback on its private
        // App Server. Route the recovery through the app's separate local IPC
        // follower API so the prompt is cleared in the owning process without
        // modifying or restarting Codex itself.
        if let ownerClientID = try? await desktopIPC.ownerClientID(for: threadID) {
            try await start()
            let activeGoalMustBeRestored = try await taskHasActiveGoal(threadID: threadID)
            try await desktopIPC.applyAllowAllSettings(
                threadID: threadID,
                ownerClientID: ownerClientID
            )
            var policy = policies[threadID] ?? StoredPolicy()
            policy.allowAll = true
            policies[threadID] = policy
            persistPolicies()
            try await desktopIPC.interruptAndContinue(
                threadID: threadID,
                ownerClientID: ownerClientID
            )
            if activeGoalMustBeRestored {
                try await restoreActiveGoal(threadID: threadID)
            }
            lastAllowAllContinuationAt[threadID] = clock.now
            return
        }

        try await start()
        let resumed = try await request(
            method: "thread/resume",
            params: .object(["threadId": .string(threadID)])
        )

        var policy = policies[threadID] ?? StoredPolicy()
        policy.allowAll = true
        policies[threadID] = policy
        persistPolicies()
        try await applyAllowAllSettings(threadID: threadID)

        if let approval = pendingApprovals[threadID] {
            // A callback owned by the shared connection can be ended directly.
            _ = try await request(
                method: "turn/interrupt",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(approval.turnID),
                ])
            )
        } else {
            // A desktop-owned approval callback is not replayed to this
            // companion connection. Archiving and immediately restoring the
            // same persisted thread unloads that blocked turn without
            // restarting Codex or changing any other task.
            try await unloadDesktopOwnedTurn(threadID: threadID)
        }
        try await applyAllowAllSettings(threadID: threadID)
        pendingApprovals[threadID] = nil

        var turnParams: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Apologies for the interruption - all commands are auto-accepted now. Continue on where you were"),
                ]),
            ]),
            "approvalPolicy": .string("never"),
            "approvalsReviewer": .string("auto_review"),
            "sandboxPolicy": .object(["type": .string("dangerFullAccess")]),
        ]
        if let cwd = resumed.objectValue?["cwd"]?.stringValue {
            turnParams["cwd"] = .string(cwd)
        }
        _ = try await request(method: "turn/start", params: .object(turnParams))
        lastAllowAllContinuationAt[threadID] = clock.now
    }

    public func pause(threadID: String) async throws {
        if let ownerClientID = try? await desktopIPC.ownerClientID(for: threadID) {
            try await desktopIPC.pause(threadID: threadID, ownerClientID: ownerClientID)
            return
        }

        try await start()
        let resumed = try await request(
            method: "thread/resume",
            params: .object(["threadId": .string(threadID)])
        )
        let liveType = resumed.objectValue?["thread"]?.objectValue?["status"]?.objectValue?["type"]?.stringValue
        let turnID = Self.inProgressTurnID(in: resumed)
        let goal = try? await request(
            method: "thread/goal/get",
            params: .object(["threadId": .string(threadID)])
        )
        let goalObject = goal?.objectValue?["goal"]?.objectValue ?? goal?.objectValue
        let hasActiveGoal = goalObject?["status"]?.stringValue == "active"

        if hasActiveGoal {
            _ = try await request(
                method: "thread/goal/set",
                params: .object([
                    "threadId": .string(threadID),
                    "status": .string("paused"),
                ])
            )
        }

        if liveType == "active", let turnID {
            do {
                _ = try await request(
                    method: "turn/interrupt",
                    params: .object([
                        "threadId": .string(threadID),
                        "turnId": .string(turnID),
                    ])
                )
            } catch {
                try await unloadDesktopOwnedTurn(threadID: threadID)
            }
        } else {
            // Desktop-private turns can appear idle on the companion daemon.
            // Archive/restore unloads the same persisted task without creating
            // a continuation, which is the desired pause behavior.
            try await unloadDesktopOwnedTurn(threadID: threadID)
        }

    }

    private func applyAllowAllSettings(threadID: String) async throws {
        _ = try await request(
            method: "thread/settings/update",
            params: .object([
                "threadId": .string(threadID),
                "approvalPolicy": .string("never"),
                "approvalsReviewer": .string("auto_review"),
                "sandboxPolicy": .object(["type": .string("dangerFullAccess")]),
            ])
        )
    }

    private func taskHasActiveGoal(threadID: String) async throws -> Bool {
        let response = try await request(
            method: "thread/goal/get",
            params: .object(["threadId": .string(threadID)])
        )
        return response.objectValue?["goal"]?.objectValue?["status"]?.stringValue == "active"
    }

    private func restoreActiveGoal(threadID: String) async throws {
        _ = try await request(
            method: "thread/goal/set",
            params: .object([
                "threadId": .string(threadID),
                "status": .string("active"),
            ])
        )
    }

    private func unloadDesktopOwnedTurn(threadID: String) async throws {
        archivedThreadIDs.remove(threadID)
        _ = try await request(
            method: "thread/archive",
            params: .object(["threadId": .string(threadID)])
        )
        await waitForThreadLifecycleNotification(threadID, archived: true)
        unarchivedThreadIDs.remove(threadID)
        _ = try await request(
            method: "thread/unarchive",
            params: .object(["threadId": .string(threadID)])
        )
        await waitForThreadLifecycleNotification(threadID, archived: false)
    }

    #if CODEX_TASK_MANAGER_EXPERIMENTAL_APPROVAL_ACTIONS
    private func performExperimentalAllowOnce(for threadID: String) async throws {
        let approval = try await sharedPendingApproval(for: threadID)
        try respond(to: approval.requestID, result: approvalResult(decision: "accept"))
        pendingApprovals[threadID] = nil
    }

    private func performExperimentalAllowSimilarCommands(for threadID: String) async throws {
        let approval = try await sharedPendingApproval(for: threadID)
        guard approval.method == "item/commandExecution/requestApproval",
              let prefix = approval.proposedCommandPrefix,
              !prefix.isEmpty
        else {
            throw TaskApprovalControllerError.similarCommandUnavailable
        }
        var policy = policies[threadID] ?? StoredPolicy()
        if !policy.similarCommandPrefixes.contains(prefix) {
            policy.similarCommandPrefixes.append(prefix)
        }
        policies[threadID] = policy
        persistPolicies()
        try respond(to: approval.requestID, result: approvalResult(decision: "accept"))
        pendingApprovals[threadID] = nil
    }

    private func sharedPendingApproval(for threadID: String) async throws -> PendingApproval {
        try await start()
        await subscribe(to: [threadID])
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1.5)
        while clock.now < deadline {
            if let approval = pendingApprovals[threadID] { return approval }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TaskApprovalControllerError.noPendingApproval
    }

    private func approvalResult(decision: String) -> JSONValue {
        .object(["decision": .string(decision)])
    }
    #endif

    private func waitForThreadLifecycleNotification(_ threadID: String, archived: Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline {
            let observed = archived
                ? archivedThreadIDs.contains(threadID)
                : unarchivedThreadIDs.contains(threadID)
            if observed { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func ingest(_ data: Data) {
        incomingBuffer.append(data)
        if !isWebSocketUpgraded {
            let delimiter = Data("\r\n\r\n".utf8)
            guard let range = incomingBuffer.range(of: delimiter) else { return }
            let header = String(decoding: incomingBuffer[..<range.upperBound], as: UTF8.self)
            guard header.hasPrefix("HTTP/1.1 101") else {
                connectionDidClose()
                return
            }
            incomingBuffer.removeSubrange(..<range.upperBound)
            isWebSocketUpgraded = true
        }
        parseWebSocketFrames()
    }

    private func parseWebSocketFrames() {
        while incomingBuffer.count >= 2 {
            let first = incomingBuffer[incomingBuffer.startIndex]
            let second = incomingBuffer[incomingBuffer.index(after: incomingBuffer.startIndex)]
            let isFinal = first & 0x80 != 0
            let opcode = first & 0x0F
            let isMasked = second & 0x80 != 0
            var payloadLength = Int(second & 0x7F)
            var offset = 2

            if payloadLength == 126 {
                guard incomingBuffer.count >= 4 else { return }
                payloadLength = Int(incomingBuffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self).bigEndian })
                offset = 4
            } else if payloadLength == 127 {
                guard incomingBuffer.count >= 10 else { return }
                let length = incomingBuffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt64.self).bigEndian }
                guard length <= UInt64(Int.max) else {
                    connectionDidClose()
                    return
                }
                payloadLength = Int(length)
                offset = 10
            }

            let maskLength = isMasked ? 4 : 0
            guard incomingBuffer.count >= offset + maskLength + payloadLength else { return }
            let mask = isMasked ? Array(incomingBuffer[offset..<(offset + 4)]) : []
            offset += maskLength
            var payload = Data(incomingBuffer[offset..<(offset + payloadLength)])
            incomingBuffer.removeSubrange(..<(offset + payloadLength))
            if isMasked {
                payload.withUnsafeMutableBytes { bytes in
                    for index in bytes.indices {
                        bytes[index] ^= mask[index % 4]
                    }
                }
            }

            switch opcode {
            case 0x0:
                fragmentedMessage.append(payload)
                if isFinal {
                    handleWebSocketMessage(fragmentedMessage)
                    fragmentedMessage.removeAll(keepingCapacity: true)
                }
            case 0x1:
                if isFinal {
                    handleWebSocketMessage(payload)
                } else {
                    fragmentedMessage = payload
                }
            case 0x8:
                connectionDidClose()
                return
            case 0x9:
                try? writeWebSocketFrame(payload, opcode: 0xA)
            default:
                continue
            }
        }
    }

    private func handleWebSocketMessage(_ data: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(message) = value
        else { return }
        handle(message)
    }

    private func handle(_ message: [String: JSONValue]) {
        if let id = message["id"]?.intValue,
           message["method"] == nil,
           let continuation = pendingRequests.removeValue(forKey: id) {
            pendingRequestTimeouts.removeValue(forKey: id)?.cancel()
            if let error = message["error"]?.objectValue,
               let errorMessage = error["message"]?.stringValue {
                continuation.resume(throwing: TaskApprovalControllerError.protocolError(errorMessage))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }

        if let method = message["method"]?.stringValue,
           let params = message["params"]?.objectValue,
           method == "serverRequest/resolved" || method == "turn/completed" {
            for (threadID, approval) in pendingApprovals where Self.lifecycleNotificationResolvesPendingApproval(
                method: method,
                params: params,
                pendingThreadID: approval.threadID,
                pendingTurnID: approval.turnID,
                pendingRequestID: approval.requestID
            ) {
                pendingApprovals[threadID] = nil
            }
            return
        }

        if let method = message["method"]?.stringValue,
           let threadID = message["params"]?.objectValue?["threadId"]?.stringValue {
            if method == "thread/archived" {
                archivedThreadIDs.insert(threadID)
                return
            }
            if method == "thread/unarchived" {
                unarchivedThreadIDs.insert(threadID)
                return
            }
        }

        guard let method = message["method"]?.stringValue,
              let requestID = message["id"],
              let params = message["params"]?.objectValue,
              let threadID = params["threadId"]?.stringValue,
              let turnID = params["turnId"]?.stringValue,
              params["itemId"]?.stringValue != nil,
              method == "item/commandExecution/requestApproval"
                || method == "item/fileChange/requestApproval"
        else { return }

        let approval = PendingApproval(
            requestID: requestID,
            threadID: threadID,
            turnID: turnID,
            method: method,
            proposedCommandPrefix: params["proposedExecpolicyAmendment"]?.arrayValue?.compactMap(\.stringValue)
        )
        pendingApprovals[threadID] = approval

        #if CODEX_TASK_MANAGER_EXPERIMENTAL_APPROVAL_ACTIONS
        if method == "item/commandExecution/requestApproval",
           Self.matchesSimilarCommand(
               proposedPrefix: approval.proposedCommandPrefix,
               storedPrefixes: policies[threadID]?.similarCommandPrefixes ?? []
           ) {
            do {
                try respond(to: requestID, result: approvalResult(decision: "accept"))
                pendingApprovals[threadID] = nil
            } catch {
                // Keep it pending so Codex's native UI can still resolve it.
            }
        }
        #endif
    }

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        let id = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            pendingRequestTimeouts[id] = Task { [weak self] in
                do {
                    try await Task.sleep(for: Self.companionRequestTimeout)
                } catch {
                    return
                }
                await self?.expirePendingRequest(id: id, method: method)
            }
            do {
                try send(.object([
                    "method": .string(method),
                    "id": .int(id),
                    "params": params,
                ]))
            } catch {
                pendingRequests[id] = nil
                pendingRequestTimeouts.removeValue(forKey: id)?.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func expirePendingRequest(id: Int, method: String) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        pendingRequestTimeouts[id] = nil
        continuation.resume(throwing: TaskApprovalControllerError.protocolError(
            "The Codex companion did not respond to \(method)."
        ))
    }

    private func send(_ value: JSONValue) throws {
        try writeWebSocketFrame(JSONEncoder().encode(value), opcode: 0x1)
    }

    #if CODEX_TASK_MANAGER_EXPERIMENTAL_APPROVAL_ACTIONS
    private func respond(to requestID: JSONValue, result: JSONValue) throws {
        try send(.object(["id": requestID, "result": result]))
    }
    #endif

    private func writeWebSocketFrame(_ payload: Data, opcode: UInt8) throws {
        guard let socketHandle else { throw TaskApprovalControllerError.connectionClosed }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        var frame = Data([0x80 | opcode])
        switch payload.count {
        case 0..<126:
            frame.append(0x80 | UInt8(payload.count))
        case 126..<65_536:
            frame.append(0x80 | 126)
            var length = UInt16(payload.count).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        default:
            frame.append(0x80 | 127)
            var length = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        }
        frame.append(contentsOf: mask)
        var maskedPayload = payload
        maskedPayload.withUnsafeMutableBytes { bytes in
            for index in bytes.indices {
                bytes[index] ^= mask[index % 4]
            }
        }
        frame.append(maskedPayload)
        try socketHandle.write(contentsOf: frame)
    }

    private func connectionDidClose() {
        isStarted = false
        socketHandle?.readabilityHandler = nil
        try? socketHandle?.close()
        socketHandle = nil
        isWebSocketUpgraded = false
        incomingBuffer.removeAll()
        fragmentedMessage.removeAll()
        pendingApprovals.removeAll()
        archivedThreadIDs.removeAll()
        unarchivedThreadIDs.removeAll()
        allowAllRecoveriesInFlight.removeAll()
        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        let timeoutTasks = pendingRequestTimeouts.values
        pendingRequestTimeouts.removeAll()
        for task in timeoutTasks { task.cancel() }
        for continuation in continuations {
            continuation.resume(throwing: TaskApprovalControllerError.connectionClosed)
        }
    }

    private func waitForWebSocketUpgrade() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline {
            if isWebSocketUpgraded { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TaskApprovalControllerError.connectionClosed
    }

    private func connectUnixSocket(path: String) throws -> FileHandle {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TaskApprovalControllerError.connectionClosed }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maximumPathLength else {
            Darwin.close(descriptor)
            throw TaskApprovalControllerError.connectionClosed
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maximumPathLength) { destination in
                _ = path.withCString { source in strncpy(destination, source, maximumPathLength - 1) }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw TaskApprovalControllerError.connectionClosed
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func resolveCLIPath() throws -> String {
        let candidates = [
            cliPathOverride,
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/codex").path,
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TaskApprovalControllerError.codexCLIUnavailable
        }
        return path
    }

    private func runShortCommand(_ executable: String, arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw TaskApprovalControllerError.daemonSetupFailed(message.isEmpty ? "command exited \(process.terminationStatus)" : message)
        }
    }

    private func persistPolicies() {
        guard let data = try? JSONEncoder().encode(policies) else { return }
        defaults.set(data, forKey: Self.policyDefaultsKey)
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
