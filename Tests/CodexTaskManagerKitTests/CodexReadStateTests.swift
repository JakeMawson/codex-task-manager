import Foundation
import Testing
@testable import CodexTaskManagerKit

@Suite("Native unread synchronization")
struct CodexReadStateTests {
    private func fixture() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "task-manager-unread-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try auth(home, account: "account")
        try save(home, ids: ["unread"])
        return home
    }
    private func auth(_ home: URL, account: String) throws {
        let claims = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_user_id": "user"]])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["access_token": "header." + payload + ".signature"]]).write(to: home.appending(path: "auth.json"), options: .atomic)
    }
    private func save(_ home: URL, ids: [String], host: String? = nil) throws {
        let context = try CodexReadContext.local(codexHome: home)
        let store: [String: Any] = ["version": 1, "unreadByIdentity": [
            context.identityKey: [host ?? context.executionHostKey: ids, "remote:fixture": ["remote-unread"]],
            "another-account": [context.executionHostKey: ["other-account-unread"]],
        ]]
        try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": store]).write(to: home.appending(path: ".codex-global-state.json"), options: .atomic)
    }
    @Test func accountAndHostIsolation() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try CodexUnreadState.read(codexHome: home).ids == ["unread"])
        try auth(home, account: "different-account")
        #expect(try CodexUnreadState.read(codexHome: home).ids.isEmpty)
        try save(home, ids: ["unread"], host: "local:unknown-websocket-host")
        #expect(throws: (any Error).self) { try CodexUnreadState.read(codexHome: home) }
        try Data("{}".utf8).write(to: home.appending(path: "auth.json"))
        #expect(throws: (any Error).self) { try CodexUnreadState.read(codexHome: home) }
    }
    @Test func malformedModernStateDoesNotFallBackToLegacy() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": ["version": 2], "electron-persisted-atom-state": ["unread-thread-ids-by-host-v1": ["local": ["stale"]]]]).write(to: home.appending(path: ".codex-global-state.json"))
        #expect(throws: (any Error).self) { try CodexUnreadState.read(codexHome: home) }
    }
    @Test func liveUnreadParityReadOnly() async throws {
        guard let output = ProcessInfo.processInfo.environment["CODEX_TASK_MANAGER_UNREAD_REPORT"] else { return }
        let repository = CodexTaskRepository()
        let tasks = try await repository.loadTasks()
        let ids = try await repository.loadUnreadTaskIDs()
        let report: [String: Any] = [
            "catalogue_count": tasks.count,
            "native_local_unread_count": ids.count,
            "tasks": tasks.filter(\.isUnread).map { ["id": $0.id, "state": $0.state.rawValue] },
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        #expect(tasks.filter(\.isUnread).allSatisfy { ids.contains($0.id) })
    }
    @Test func readStateClearsModelUnreadFlag() {
        let task = CodexTask(id: "a", title: "A", projectPath: "/fixture", latestAssistantMessage: "Done", recency: Date(), isPinned: false, isUnread: true, state: .complete)
        #expect(!task.markingRead().isUnread)
        #expect(task.markingRead().state == .idle)
    }
}
