import Foundation
import Testing
@testable import CodexTaskManagerKit

struct ProjectSearchTests {
    @Test("Search finds all project chats across categories and ranks names before projects and previews")
    func projectSearchAndRanking() throws {
        let tasks = [
            task("preview", title: "Unrelated work", project: "/Fixture/Other", message: "FamilySimpl reference", time: 100, state: .complete),
            task("project-running", title: "Review changes", project: "/Fixture/FamilySimpl", time: 90, state: .running),
            task("project-read", title: "Check tree joins", project: "/Fixture/FamilySimpl", time: 80, state: .idle),
            task("name", title: "FamilySimpl documentation", project: "/Fixture/Docs", time: 1, state: .idle),
            task("unrelated", title: "Other work", project: "/Fixture/Elsewhere", time: 200, state: .complete),
        ]
        for sort in [TaskSortMode.recent, .priority, .alphabetical] {
            let result = TaskListEngine.presentation(
                tasks: tasks, filter: .complete, sort: sort, searchText: "  FAMILYSIMPL\n",
                groupByProject: false, customProjectOrder: ["/Fixture/Other", "/Fixture/FamilySimpl", "/Fixture/Docs"],
                expandedProjectPaths: []
            )
            #expect(result.totalCount == 4)
            #expect(result.sections.map(\.projectPath) == ["/Fixture/Docs", "/Fixture/FamilySimpl", "/Fixture/Other"])
            try #require(result.sections.count == 3)
            #expect(Set(result.sections[1].tasks.map(\.id)) == ["project-running", "project-read"])
            #expect(result.displayedCount == 4)
            #expect(!result.isLimited)
        }
    }

    @Test("Name relevance wins within a matching project even with priority ordering")
    func groupedRelevance() {
        let result = TaskListEngine.presentation(
            tasks: [
                task("project", title: "Approval", project: "/Fixture/FamilySimpl", time: 100, state: .needsApproval),
                task("name", title: "FamilySimpl layout", project: "/Fixture/FamilySimpl", time: 1, state: .idle),
            ], filter: .running, sort: .priority, searchText: "familysimpl",
            groupByProject: true, customProjectOrder: [], priorityFirstWithinProjects: true,
            expandedProjectPaths: []
        )
        #expect(result.sections.count == 1)
        #expect(result.sections.first?.tasks.map(\.id) == ["name", "project"])
    }

    @Test("Search temporarily reveals collapsed projects and preserves saved category and collapse choices")
    @MainActor
    func searchRestoresPreferences() throws {
        let defaults = try #require(UserDefaults(suiteName: "ProjectSearchTests.\(UUID().uuidString)"))
        let model = TaskManagerModel(defaults: defaults, fixtureName: "all")
        let project = "/Fixture/FamilySimpl"
        model.tasks = [task("read", title: "Check tree joins", project: project, time: 1, state: .idle)]
        model.selectOnlyStatusFilter(.complete)
        model.toggleProjectCollapsed(project)
        #expect(model.isProjectCollapsed(project))
        #expect(model.presentation.totalCount == 0)
        model.searchText = "familysimpl"
        #expect(model.presentation.sections.first?.projectPath == project)
        #expect(model.presentation.displayedCount == 1)
        #expect(!model.isProjectCollapsed(project))
        #expect(model.selectedStatusFilters == [.complete])
        #expect(model.collapsedProjectPaths.contains(project))
        model.searchText = " \n"
        #expect(model.isProjectCollapsed(project))
        #expect(model.presentation.totalCount == 0)
        let restored = TaskManagerModel(defaults: defaults, fixtureName: "all")
        #expect(restored.selectedStatusFilters == [.complete])
        #expect(restored.isProjectCollapsed(project))
    }

    @Test("Optional live project search preserves exact membership (CTM_TEST_SEARCH_PROJECT)")
    func liveProjectMembership() async throws {
        guard let query = ProcessInfo.processInfo.environment["CTM_TEST_SEARCH_PROJECT"], !query.isEmpty else { return }
        let tasks = try await CodexTaskRepository().loadTasks()
        let expected = Set(tasks.filter { $0.projectName.localizedCaseInsensitiveContains(query) }.map(\.id))
        try #require(!expected.isEmpty)
        let result = TaskListEngine.presentation(
            tasks: tasks, filter: .complete, sort: .recent, searchText: query,
            groupByProject: false, customProjectOrder: [], expandedProjectPaths: []
        )
        let actual = Set(result.sections.flatMap(\.tasks).map(\.id))
        #expect(expected.isSubset(of: actual))
        #expect(result.sections.filter { $0.projectPath?.localizedCaseInsensitiveContains(query) == true }.flatMap(\.tasks).count == expected.count)
        print("Live project search: all \(expected.count) ordinary project chats retained across statuses.")
    }

    private func task(_ id: String, title: String, project: String, message: String = "", time: Double, state: TaskAttentionState) -> CodexTask {
        CodexTask(id: id, title: title, projectPath: project, latestAssistantMessage: message,
                  recency: Date(timeIntervalSince1970: time), isPinned: false, state: state)
    }
}
