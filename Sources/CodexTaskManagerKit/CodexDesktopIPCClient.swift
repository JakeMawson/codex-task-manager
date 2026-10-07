import Foundation
import Darwin

actor CodexDesktopIPCClient {
    private let socketPath: String
    private var socketHandle: FileHandle?
    private var incomingBuffer = Data()
    private var clientID = "initializing-client"
    private var pendingRequests: [String: CheckedContinuation<[String: JSONValue], Error>] = [:]

    init(socketPath: String = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".codex/ipc/ipc.sock").path) {
        self.socketPath = socketPath
    }

    func ownerClientID(for threadID: String) async throws -> String? {
        try await start()
        let response = try await request(
            method: "thread-owner-discovery",
            params: .object([
                "hostId": .string("local"),
                "conversationId": .string(threadID),
            ]),
            version: 1
        )
        guard response["resultType"]?.stringValue == "success" else {
            if response["error"]?.stringValue == "no-client-found" { return nil }
            throw TaskApprovalControllerError.protocolError(
                response["error"]?.stringValue ?? "Desktop task owner discovery failed."
            )
        }
        return response["handledByClientId"]?.stringValue
    }

    func applyAllowAllSettings(threadID: String, ownerClientID: String) async throws {
        try requireSuccess(try await request(
            method: "thread-follower-update-thread-settings",
            params: .object([
                "conversationId": .string(threadID),
                "threadSettings": Self.allowAllSettings,
            ]),
            version: 1,
            targetClientID: ownerClientID
        ))
    }

    func interruptAndContinue(threadID: String, ownerClientID: String) async throws {
        // Version 3 is Codex's backwards-compatible interrupt request when no
        // expected turn id is supplied. The live owner resolves the approval
        // card and interrupts exactly its current turn.
        try requireSuccess(try await request(
            method: "thread-follower-interrupt-turn",
            params: .object([
                "conversationId": .string(threadID),
                "mode": .string("user"),
            ]),
            version: 3,
            targetClientID: ownerClientID
        ))

        // Reapply after interruption so both the persisted next-turn settings
        // and the explicit recovery turn use task-scoped full access.
        try await applyAllowAllSettings(threadID: threadID, ownerClientID: ownerClientID)
        try requireSuccess(try await request(
            method: "thread-follower-start-turn",
            params: .object([
                "conversationId": .string(threadID),
                "turnStartParams": .object([
                    "input": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("Apologies for the interruption - all commands are auto-accepted now. Continue on where you were"),
                        ]),
                    ]),
                    "approvalPolicy": .string("never"),
                    "approvalsReviewer": .string("auto_review"),
                    "sandboxPolicy": .object(["type": .string("dangerFullAccess")]),
                ]),
            ]),
            version: 1,
            targetClientID: ownerClientID
        ))
    }

    static func userStopRequest(threadID: String) -> (params: JSONValue, version: Int) {
        (
            params: .object([
                "conversationId": .string(threadID),
                "mode": .string("user-stop"),
            ]),
            version: 4
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

    private static let allowAllSettings: JSONValue = .object([
        "approvalPolicy": .string("never"),
        "approvalsReviewer": .string("auto_review"),
        "sandboxPolicy": .object(["type": .string("dangerFullAccess")]),
    ])

    private func start() async throws {
        guard socketHandle == nil else { return }
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
        permitsUninitializedClient: Bool = false
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
            "timeoutMs": .int(10_000),
        ]
        if let targetClientID {
            message["targetClientId"] = .string(targetClientID)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
            do {
                try send(.object(message))
            } catch {
                pendingRequests[requestID] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func requireSuccess(_ response: [String: JSONValue]) throws {
        guard response["resultType"]?.stringValue == "success" else {
            throw TaskApprovalControllerError.protocolError(
                response["error"]?.stringValue ?? "Codex Desktop rejected the task action."
            )
        }
    }

    private func ingest(_ data: Data) {
        incomingBuffer.append(data)
        while incomingBuffer.count >= 4 {
            let payloadLength = Int(incomingBuffer.withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            })
            guard payloadLength > 0, payloadLength <= 256 * 1024 * 1024 else {
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
        if message["type"]?.stringValue == "response",
           let requestID = message["requestId"]?.stringValue,
           let continuation = pendingRequests.removeValue(forKey: requestID) {
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
        socketHandle?.readabilityHandler = nil
        try? socketHandle?.close()
        socketHandle = nil
        incomingBuffer.removeAll()
        clientID = "initializing-client"
        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: TaskApprovalControllerError.connectionClosed)
        }
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
}
