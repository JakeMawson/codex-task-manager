import Foundation
import SQLite3
import Testing
@testable import CodexTaskManagerKit

struct SessionVisibilityTests {
    @Test("Optional live catalog preserves every non-subagent chat (CTM_TEST_LOCAL_CATALOG=1)")
    func liveCatalogMembership() async throws {
        guard ProcessInfo.processInfo.environment["CTM_TEST_LOCAL_CATALOG"] == "1" else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        var database: OpaquePointer?
        try #require(sqlite3_open_v2(home.appending(path: "state_5.sqlite").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        let db = try #require(database)
        defer { sqlite3_close(db) }
        let sql = #"""
        SELECT id FROM threads WHERE archived = 0
          AND COALESCE(thread_source, '') <> 'subagent'
          AND NOT (COALESCE(thread_source, '') = '' AND
            CASE WHEN json_valid(source) THEN json_type(source, '$.subagent') IS NOT NULL ELSE 0 END);
        """#
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var expected: Set<String> = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            expected.insert(String(cString: sqlite3_column_text(statement, 0)))
            result = sqlite3_step(statement)
        }
        try #require(result == SQLITE_DONE)
        let tasks = try await CodexTaskRepository().loadTasks()
        #expect(Set(tasks.map(\.id)) == expected)
        print("Live catalog: \(tasks.count) ordinary chats retained; exact SQL membership matched.")
    }

    @Test("Internal subagents stay hidden while ordinary and agent-created chats remain visible")
    func mixedSessionOrigins() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "ctm-visibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var database: OpaquePointer?
        #expect(sqlite3_open(home.appending(path: "state_5.sqlite").path, &database) == SQLITE_OK)
        let db = try #require(database)
        defer { sqlite3_close(db) }
        let sql = #"""
        CREATE TABLE threads (
            id TEXT PRIMARY KEY, name TEXT, title TEXT, preview TEXT, cwd TEXT,
            recency_at_ms INTEGER, recency_at INTEGER, rollout_path TEXT,
            is_pinned INTEGER, archived INTEGER, thread_source TEXT, source TEXT
        );
        INSERT INTO threads VALUES
          ('user', 'User chat', '', '', '/Fixture', 1000, 1, '', 0, 0, 'user', 'vscode'),
          ('agent-created', 'Managed chat', '', '', '/Fixture', 1000, 1, '', 1, 0, 'agent_created_thread', 'vscode'),
          ('cli', 'CLI chat', '', '', '/Fixture', 1000, 1, '', 0, 0, NULL, 'cli'),
          ('legacy-user', 'Legacy chat', '', '', '/Fixture', 1000, 1, '', 0, 0, NULL, 'vscode'),
          ('unknown', 'Future source', '', '', '/Fixture', 1000, 1, '', 0, 0, 'future_source', 'future'),
          ('malformed', 'Unknown metadata', '', '', '/Fixture', 1000, 1, '', 0, 0, '', '{invalid'),
          ('unrelated-json', 'Other metadata', '', '', '/Fixture', 1000, 1, '', 0, 0, NULL, '{"note":"subagent"}'),
          ('agent-created-origin', 'Managed fork', '', '', '/Fixture', 1000, 1, '', 0, 0, 'agent_created_thread', '{"subagent":{"thread_spawn":{}}}'),
          ('explicit-user', 'Visible fork', '', '', '/Fixture', 1000, 1, '', 0, 0, 'user', '{"subagent":{"thread_spawn":{}}}'),
          ('subagent', '', '', 'Worker completed', '/Fixture', 1000, 1, '', 0, 0, 'subagent', '{"subagent":{"thread_spawn":{"parent_thread_id":"user","depth":1}}}'),
          ('subagent-vscode', '', '', 'Internal handoff', '/Fixture', 1000, 1, '', 1, 0, 'subagent', 'vscode'),
          ('legacy-subagent', '', '', 'Legacy internal worker', '/Fixture', 1000, 1, '', 0, 0, NULL, '{"subagent":{"thread_spawn":{"parent_thread_id":"user","depth":2}}}'),
          ('empty-source-subagent', '', '', 'Internal review', '/Fixture', 1000, 1, '', 0, 0, '', '{"subagent":"review"}'),
          ('archived', 'Archived', '', '', '/Fixture', 1000, 1, '', 0, 1, 'user', 'vscode');
        """#
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)

        let repository = CodexTaskRepository(codexHome: home, desktopRuntimeStartDateProvider: { nil })
        let expected: Set<String> = ["user", "agent-created", "agent-created-origin", "cli", "legacy-user", "unknown", "malformed", "unrelated-json", "explicit-user"]
        let initial = try await repository.loadTasks()
        #expect(Set(initial.map(\.id)) == expected)
        #expect(initial.first(where: { $0.id == "agent-created" })?.isPinned == true)
        #expect(await repository.lastLoadMetrics().taskCount == expected.count)
        let cached = try await repository.loadTasks(refresh: .none)
        #expect(Set(cached.map(\.id)) == expected)

        // Catalog invalidation must remove a newly classified internal session.
        try #require(sqlite3_exec(db, "UPDATE threads SET thread_source = 'subagent' WHERE id = 'unknown'", nil, nil, nil) == SQLITE_OK)
        let refreshed = try await repository.loadTasks(refresh: TaskRefreshHint(catalogChanged: true))
        #expect(Set(refreshed.map(\.id)) == expected.subtracting(["unknown"]))
    }
}
