import Foundation
import Darwin
import Testing
@testable import CodexTaskManagerKit

@Suite("Desktop IPC transport") struct DesktopIPCIntegrationTests {
    private func pair() throws -> (FileHandle, FileHandle) {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw CocoaError(.fileReadUnknown) }
        for fd in descriptors { var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4) }
        return (FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true), FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true))
    }
    private func read(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            let part = try handle.read(upToCount: count - data.count) ?? Data()
            guard !part.isEmpty else { throw CocoaError(.fileReadUnknown) }
            data.append(part)
        }
        return data
    }
    private func readMessage(_ handle: FileHandle) throws -> [String: JSONValue] {
        let length = try read(handle, count: 4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
        guard length > 0 && length < 100_000 else { throw CocoaError(.fileReadUnknown) }
        return try JSONDecoder().decode(JSONValue.self, from: read(handle, count: length)).objectValue ?? [:]
    }
    private func send(_ handle: FileHandle, _ value: [String: JSONValue], fragmented: Bool = false) throws {
        let payload = try JSONEncoder().encode(JSONValue.object(value))
        var length = UInt32(payload.count).littleEndian
        var data = Data(bytes: &length, count: 4); data.append(payload)
        if fragmented { for byte in data { try handle.write(contentsOf: Data([byte])) } }
        else { try handle.write(contentsOf: data) }
    }
    private func response(_ request: [String: JSONValue], result: JSONValue = .object([:])) -> [String: JSONValue] {
        ["type": .string("response"), "requestId": request["requestId"]!, "resultType": .string("success"), "handledByClientId": .string("owner"), "result": result]
    }

    @Test func fragmentedSnapshotsConcurrentDiscoveryAndStop() async throws {
        let (client, server) = try pair()
        let ipc = CodexDesktopIPCClient(connectedHandleForTesting: client)
        let worker = Task.detached {
            defer { try? server.close() }
            var initializeCount = 0, followingCount = 0, stopSeen = false
            while !stopSeen || followingCount < 2 {
                let message = try readMessage(server)
                switch message["method"]?.stringValue {
                case "initialize":
                    initializeCount += 1
                    try send(server, response(message, result: .object(["clientId": .string("test-client")])), fragmented: true)
                case "thread-owner-discovery": try send(server, response(message), fragmented: true)
                case "thread-stream-following-changed":
                    let params = message["params"]!.objectValue!
                    if params["following"] == .bool(true) {
                        try send(server, ["type": .string("broadcast"), "method": .string("thread-stream-state-changed"), "params": .object([
                            "hostId": .string("local"), "conversationId": params["conversationId"]!,
                            "change": .object(["type": .string("snapshot"), "conversationState": .object(["threadRuntimeStatus": .object(["type": .string("idle")])])]),
                        ])], fragmented: true)
                    } else { followingCount += 1 }
                case "thread-follower-interrupt-turn":
                    #expect(message["version"] == .int(3))
                    #expect(message["params"]?.objectValue?["mode"] == .string("user-stop"))
                    #expect(message["targetClientId"] == .string("owner"))
                    try send(server, response(message), fragmented: true); stopSeen = true
                default: Issue.record("Unexpected mutation or request: \(message["method"]?.stringValue ?? "unknown")")
                }
            }
            #expect(initializeCount == 1)
        }
        async let first = ipc.attentionState(for: "a")
        async let second = ipc.attentionState(for: "b")
        #expect(try await first == .idle); #expect(try await second == .idle)
        try await ipc.pause(threadID: "a", ownerClientID: "owner")
        try await worker.value
    }
    @Test func missingResponseTimesOut() async throws {
        let (client, server) = try pair()
        defer { try? server.close() }
        let ipc = CodexDesktopIPCClient(connectedHandleForTesting: client, requestTimeout: .milliseconds(50))
        await #expect(throws: (any Error).self) { try await ipc.ownerClientID(for: "no-reply") }
    }
    @Test func oversizedFrameFailsClosed() async throws {
        let (client, server) = try pair()
        let ipc = CodexDesktopIPCClient(connectedHandleForTesting: client)
        let worker = Task.detached {
            defer { try? server.close() }
            _ = try readMessage(server)
            var length = UInt32(64 * 1024 * 1024 + 1).littleEndian
            try server.write(contentsOf: Data(bytes: &length, count: 4))
        }
        await #expect(throws: (any Error).self) { try await ipc.ownerClientID(for: "oversized") }
        try await worker.value
    }
}
