import Foundation
import Darwin

actor CodexDesktopIPCClient {
    private let socketPath: String
    private var connectedHandleForTesting: FileHandle?
    private let requestTimeout: Duration
    private let snapshotTimeout: Duration
    private var socketHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private let readQueue = DispatchQueue(label: "com.jakemawson.codex-task-manager.ipc-read")
    private var connectionID = UUID()
    private var incomingBuffer = Data()
    private var clientID = "initializing-client"
    private var pendingRequests: [String: CheckedContinuation<[String: JSONValue], Error>] = [:]
    private var requestTimeouts: [String: Task<Void, Never>] = [:]
    private var starting: Task<Void, Error>?
    private var snapshots: [String: CheckedContinuation<TaskAttentionState?, Never>] = [:]
    private var snapshotTimeouts: [String: Task<Void, Never>] = [:]

    static func attentionState(in state: [String: JSONValue]) -> TaskAttentionState? {
        guard let runtime = state["threadRuntimeStatus"]?.objectValue,
              let type = runtime["type"]?.stringValue else { return nil }
        let flags = Set(runtime["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        if type == "active", flags.contains("waitingOnApproval") { return .needsApproval }
        if NativeAsyncQuestions.hasPending(in: state) { return .needsResponse }
        guard type == "active" else { return ["idle", "notLoaded", "systemError"].contains(type) ? .idle : nil }
        if flags.contains("waitingOnUserInput") { return .needsResponse }
        return .running
    }

    // Native histories contain large tool outputs and reasoning that cannot
    // affect attention. Project the wire snapshot before generic Codable
    // decoding, so another chat cannot consume this chat's snapshot deadline.
    static func attentionState(inNativeState state: [String: Any]) -> TaskAttentionState? {
        var turns = state["turns"] as? [[String: Any]] ?? []
        if let history = state["turnHistory"] as? [String: Any],
           let entries = history["history"] as? [String: Any],
           let entities = entries["entitiesByKey"] as? [String: Any] {
            turns.append(contentsOf: entities.values.compactMap { $0 as? [String: Any] })
        }
        let items = turns.flatMap { $0["items"] as? [[String: Any]] ?? [] }.compactMap { item -> [String: Any]? in
            guard let type = item["type"] as? String else { return nil }
            switch type {
            case "agentMessage" where item["delivery"] as? String == "async":
                return item.filter { ["type", "id", "delivery", "questions"].contains($0.key) }
            case "userMessage", "steeringUserMessage":
                return item.filter { ["type", "status", "content", "input"].contains($0.key) }
            default: return nil
            }
        }
        let minimal: [String: Any] = [
            "threadRuntimeStatus": state["threadRuntimeStatus"] ?? NSNull(),
            "turns": [["items": items]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: minimal),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
        return attentionState(in: decoded)
    }

    func attentionState(for threadID: String) async throws -> TaskAttentionState? {
        // A busy Desktop may take over one second to answer. A timeout is
        // unknown and preserves rollout state; batch discovery amortizes waits.
        guard try await ownerClientID(for: threadID, timeout: .seconds(5)) != nil else { return .idle }
        return await snapshot(for: threadID)
    }

    private func snapshot(for threadID: String) async -> TaskAttentionState? {
        // Observe the actual Desktop owner; a separate daemon cannot report it.
        let result = await withCheckedContinuation { continuation in
            snapshots.removeValue(forKey: threadID)?.resume(returning: nil)
            snapshots[threadID] = continuation
            snapshotTimeouts.removeValue(forKey: threadID)?.cancel()
            snapshotTimeouts[threadID] = Task { [weak self] in
                do { try await Task.sleep(for: self?.snapshotTimeout ?? .seconds(5)) } catch { return }
                await self?.finishSnapshot(threadID, state: nil)
            }
            do { try following(threadID, true) }
            catch { finishSnapshot(threadID, state: nil) }
        }
        return result
    }

    private enum Ownership: Sendable {
        case present, absent, unavailable
    }

    func attentionStates(for threadIDs: [String]) async -> [String: TaskAttentionState] {
        // Discovery responses are tiny. Complete them before following any
        // large histories, so absent owners share one bounded wait rather than
        // occupying every snapshot slot for successive five-second waves.
        var ownership: [String: Ownership] = [:]
        await withTaskGroup(of: (String, Ownership).self) { group in
            var iterator = threadIDs.makeIterator()
            for _ in 0..<min(64, threadIDs.count) {
                if let id = iterator.next() {
                    group.addTask { await self.discoverOwnership(for: id) }
                }
            }
            while let (id, owner) = await group.next() {
                ownership[id] = owner
                if let id = iterator.next() {
                    group.addTask { await self.discoverOwnership(for: id) }
                }
            }
        }
        var states: [String: TaskAttentionState] = [:]
        for (id, owner) in ownership where owner == .absent { states[id] = .idle }
        let owned = threadIDs.filter { ownership[$0] == .present }
        await withTaskGroup(of: (String, TaskAttentionState?).self) { group in
            var iterator = owned.makeIterator()
            for _ in 0..<min(8, owned.count) {
                if let id = iterator.next() { group.addTask { (id, await self.snapshot(for: id)) } }
            }
            while let (id, state) = await group.next() {
                if let state { states[id] = state }
                if let id = iterator.next() { group.addTask { (id, await self.snapshot(for: id)) } }
            }
        }
        return states
    }

    private func discoverOwnership(for id: String) async -> (String, Ownership) {
        do { return (id, try await ownerClientID(for: id) == nil ? .absent : .present) }
        catch { return (id, .unavailable) }
    }

    private func following(_ threadID: String, _ enabled: Bool) throws {
        try send(.object([
            "type": .string("broadcast"), "sourceClientId": .string(clientID),
            "version": .int(1), "method": .string("thread-stream-following-changed"),
            "params": .object(["conversationId": .string(threadID), "hostId": .string("local"), "following": .bool(enabled)]),
        ]))
    }

    private func finishSnapshot(_ id: String, state: TaskAttentionState?) {
        guard let continuation = snapshots.removeValue(forKey: id) else { return }
        snapshotTimeouts.removeValue(forKey: id)?.cancel()
        try? following(id, false)
        continuation.resume(returning: state)
    }

    init(socketPath: String = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".codex/ipc/ipc.sock").path, connectedHandleForTesting: FileHandle? = nil, requestTimeout: Duration = .seconds(5), snapshotTimeout: Duration = .seconds(5)) {
        self.socketPath = socketPath
        self.connectedHandleForTesting = connectedHandleForTesting
        self.requestTimeout = requestTimeout
        self.snapshotTimeout = snapshotTimeout
    }

    func ownerClientID(for threadID: String, timeout: Duration? = nil) async throws -> String? {
        try await start()
        let response = try await request(
            method: "thread-owner-discovery",
            params: .object([
                "hostId": .string("local"),
                "conversationId": .string(threadID),
            ]),
            version: 1,
            timeout: timeout
        )
        guard response["resultType"]?.stringValue == "success" else {
            if response["error"]?.stringValue == "no-client-found" { return nil }
            throw TaskApprovalControllerError.protocolError(
                response["error"]?.stringValue ?? "Desktop task owner discovery failed."
            )
        }
        guard let owner = response["handledByClientId"]?.stringValue, !owner.isEmpty else {
            throw TaskApprovalControllerError.protocolError("Codex returned an invalid task owner.")
        }
        return owner
    }

    static func userStopRequest(threadID: String) -> (params: JSONValue, version: Int) {
        (
            params: .object([
                "conversationId": .string(threadID),
                "mode": .string("user-stop"),
            ]),
            version: 3
        )
    }

    func pause(threadID: String, ownerClientID: String) async throws {
        let request = Self.userStopRequest(threadID: threadID)
        let response = try await self.request(
            method: "thread-follower-interrupt-turn",
            params: request.params,
            version: request.version,
            targetClientID: ownerClientID
        )
        try requireSuccess(response)
        if let goalPauseError = response["result"]?.objectValue?["goalPauseError"]?.stringValue {
            throw TaskApprovalControllerError.protocolError(goalPauseError)
        }
    }

    private func start() async throws {
        if let starting { return try await starting.value }
        guard socketHandle == nil else { return }
        let task = Task { try await self.connectAndInitialize() }
        starting = task
        defer { starting = nil }
        do { try await task.value }
        catch { connectionDidClose(); throw error }
    }

    private func connectAndInitialize() async throws {
        let handle = try connectedHandleForTesting ?? connectUnixSocket(path: socketPath)
        connectedHandleForTesting = nil
        let generation = UUID()
        connectionID = generation
        let readQueue = self.readQueue
        // Apply backpressure at the socket. A bounded queue of small chunks can
        // overflow while another chat's large snapshot is decoded, discarding
        // the pending-question frame and silently falling back to Running.
        // One awaited read retains frame order and bounds queued data to 64 KiB;
        // blocking I/O lives on its own queue, outside the cooperative executor.
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                let data: Data = await withCheckedContinuation { continuation in
                    readQueue.async {
                        var data = Data(count: 64 * 1024)
                        let count = data.withUnsafeMutableBytes { bytes in
                            var count: Int
                            repeat { count = Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count) }
                            while count < 0 && errno == EINTR
                            return count
                        }
                        if count > 0 { data.count = count }
                        else { data = Data() }
                        continuation.resume(returning: data)
                    }
                }
                guard !Task.isCancelled else { return }
                await self?.receive(data, generation: generation)
                if data.isEmpty { return }
            }
        }
        socketHandle = handle

        let initialized = try await request(
            method: "initialize",
            params: .object(["clientType": .string("codex-task-manager")]),
            version: 0,
            permitsUninitializedClient: true
        )
        guard initialized["resultType"]?.stringValue == "success",
              let assignedClientID = initialized["result"]?.objectValue?["clientId"]?.stringValue
        else {
            throw TaskApprovalControllerError.protocolError(
                initialized["error"]?.stringValue ?? "Desktop IPC initialization failed."
            )
        }
        clientID = assignedClientID
    }

    private func request(
        method: String,
        params: JSONValue,
        version: Int,
        targetClientID: String? = nil,
        permitsUninitializedClient: Bool = false,
        timeout: Duration? = nil
    ) async throws -> [String: JSONValue] {
        guard permitsUninitializedClient || clientID != "initializing-client" else {
            throw TaskApprovalControllerError.connectionClosed
        }
        let requestID = UUID().uuidString.lowercased()
        var message: [String: JSONValue] = [
            "type": .string("request"),
            "requestId": .string(requestID),
            "sourceClientId": .string(clientID),
            "version": .int(version),
            "method": .string(method),
            "params": params,
            "timeoutMs": .int(5_000),
        ]
        if let targetClientID {
            message["targetClientId"] = .string(targetClientID)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
            requestTimeouts[requestID] = Task { [weak self] in
                do { try await Task.sleep(for: min(self?.requestTimeout ?? .seconds(5), timeout ?? .seconds(5))) } catch { return }
                await self?.expireRequest(requestID)
            }
            do {
                try send(.object(message))
            } catch {
                pendingRequests[requestID] = nil
                requestTimeouts.removeValue(forKey: requestID)?.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func expireRequest(_ id: String) {
        requestTimeouts[id] = nil
        pendingRequests.removeValue(forKey: id)?.resume(throwing: TaskApprovalControllerError.protocolError("Desktop request timed out. Try again in Codex."))
    }

    private func requireSuccess(_ response: [String: JSONValue]) throws {
        guard response["resultType"]?.stringValue == "success" else {
            throw TaskApprovalControllerError.protocolError(
                response["error"]?.stringValue ?? "Codex Desktop rejected the task action."
            )
        }
    }

    private func receive(_ data: Data, generation: UUID) {
        guard generation == connectionID else { return }
        if data.isEmpty { connectionDidClose() } else { ingest(data) }
    }

    private func ingest(_ data: Data) {
        guard incomingBuffer.count + data.count <= 65 * 1024 * 1024 else { connectionDidClose(); return }
        incomingBuffer.append(data)
        while incomingBuffer.count >= 4 {
            let payloadLength = Int(incomingBuffer.withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            })
            guard payloadLength > 0, payloadLength <= 64 * 1024 * 1024 else {
                connectionDidClose()
                return
            }
            guard incomingBuffer.count >= 4 + payloadLength else { return }
            let payload = Data(incomingBuffer[4..<(4 + payloadLength)])
            incomingBuffer.removeSubrange(..<(4 + payloadLength))
            guard let native = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
            if native["type"] as? String == "broadcast" {
                // Ignore unrelated broadcasts before recursively decoding any
                // history, including frames arriving after we unfollowed it.
                if native["method"] as? String == "thread-stream-state-changed",
                   let params = native["params"] as? [String: Any], params["hostId"] as? String == "local",
                   let id = params["conversationId"] as? String, snapshots[id] != nil,
                   let change = params["change"] as? [String: Any], change["type"] as? String == "snapshot",
                   let state = change["conversationState"] as? [String: Any] {
                    finishSnapshot(id, state: Self.attentionState(inNativeState: state))
                }
                continue
            }
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: payload),
                  let message = value.objectValue else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: JSONValue]) {
        if message["type"]?.stringValue == "response",
           let requestID = message["requestId"]?.stringValue,
           let continuation = pendingRequests.removeValue(forKey: requestID) {
            requestTimeouts.removeValue(forKey: requestID)?.cancel()
            continuation.resume(returning: message)
            return
        }
        if message["type"]?.stringValue == "client-discovery-request",
           let requestID = message["requestId"]?.stringValue {
            try? send(.object([
                "type": .string("client-discovery-response"),
                "requestId": .string(requestID),
                "response": .object(["canHandle": .bool(false)]),
            ]))
        }
    }

    private func send(_ value: JSONValue) throws {
        guard let socketHandle else { throw TaskApprovalControllerError.connectionClosed }
        let payload = try JSONEncoder().encode(value)
        var length = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        try socketHandle.write(contentsOf: frame)
    }

    private func connectionDidClose() {
        connectionID = UUID()
        readerTask?.cancel()
        readerTask = nil
        if let handle = socketHandle {
            Darwin.shutdown(handle.fileDescriptor, SHUT_RDWR)
            // Serialize close after the in-flight read, before any next read.
            readQueue.async { try? handle.close() }
        }
        socketHandle = nil
        incomingBuffer.removeAll()
        clientID = "initializing-client"
        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        for task in requestTimeouts.values { task.cancel() }
        requestTimeouts.removeAll()
        let observers = Array(snapshots.values)
        snapshots.removeAll()
        for task in snapshotTimeouts.values { task.cancel() }
        snapshotTimeouts.removeAll()
        for observer in observers { observer.resume(returning: nil) }
        for continuation in continuations {
            continuation.resume(throwing: TaskApprovalControllerError.connectionClosed)
        }
    }

    private func connectUnixSocket(path: String) throws -> FileHandle {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TaskApprovalControllerError.connectionClosed }
        var noSignal: Int32 = 1
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(descriptor); throw TaskApprovalControllerError.connectionClosed
        }
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
        var peerUID: uid_t = 0, peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            Darwin.close(descriptor); throw TaskApprovalControllerError.connectionClosed
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
