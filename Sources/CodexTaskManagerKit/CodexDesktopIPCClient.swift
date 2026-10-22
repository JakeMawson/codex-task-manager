import Foundation
import Darwin

actor CodexDesktopIPCClient {
    private let socketPath: String
    private var connectedHandleForTesting: FileHandle?
    private let requestTimeout: Duration
    private let snapshotTimeout: Duration
    private var socketHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<Data>.Continuation?
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

    func attentionState(for threadID: String) async throws -> TaskAttentionState? {
        // Status discovery must not spend the action timeout on every unloaded
        // historical chat. A timeout is unknown and preserves rollout state.
        guard try await ownerClientID(for: threadID, timeout: .seconds(1)) != nil else { return .idle }
        // Observe the actual Desktop owner. Resuming the same thread on a
        // separate daemon does not report that owner's runtime state.
        let result = await withCheckedContinuation { continuation in
            snapshots.removeValue(forKey: threadID)?.resume(returning: nil)
            snapshots[threadID] = continuation
            snapshotTimeouts.removeValue(forKey: threadID)?.cancel()
            snapshotTimeouts[threadID] = Task { [weak self] in
                do { try await Task.sleep(for: self?.snapshotTimeout ?? .seconds(1)) } catch { return }
                await self?.finishSnapshot(threadID, state: nil)
            }
            do { try following(threadID, true) }
            catch { finishSnapshot(threadID, state: nil) }
        }
        return result
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
        .appending(path: ".codex/ipc/ipc.sock").path, connectedHandleForTesting: FileHandle? = nil, requestTimeout: Duration = .seconds(5), snapshotTimeout: Duration = .seconds(1)) {
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
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(128))
        inputContinuation = continuation
        // Consume frames in read order; separate unstructured tasks per chunk
        // can reorder a split frame on their way into the actor.
        readerTask = Task { [weak self] in
            for await data in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(data, generation: generation)
            }
            await self?.receive(Data(), generation: generation)
        }
        handle.readabilityHandler = { handle in
            if case .dropped = continuation.yield(handle.availableData) { continuation.finish() }
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
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: payload),
                  let message = value.objectValue
            else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: JSONValue]) {
        if message["type"]?.stringValue == "broadcast",
           message["method"]?.stringValue == "thread-stream-state-changed",
           let params = message["params"]?.objectValue,
           params["hostId"]?.stringValue == "local",
           let id = params["conversationId"]?.stringValue,
           let change = params["change"]?.objectValue,
           change["type"]?.stringValue == "snapshot",
           let state = change["conversationState"]?.objectValue {
            finishSnapshot(id, state: Self.attentionState(in: state))
        }
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
        inputContinuation?.finish()
        inputContinuation = nil
        readerTask?.cancel()
        readerTask = nil
        socketHandle?.readabilityHandler = nil
        try? socketHandle?.close()
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
