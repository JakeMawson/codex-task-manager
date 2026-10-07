import Foundation
import CoreServices
import SQLite3
import Testing
@testable import CodexTaskManagerKit

private enum RecordingApprovalError: LocalizedError {
    case pauseFailed(String)

    var errorDescription: String? {
        switch self {
        case let .pauseFailed(threadID): "Pause failed for \(threadID)."
        }
    }
}

private actor RecordingApprovalController: TaskApprovalControlling {
    private let failingPauseIDs: Set<String>
    private let liveStates: [String: TaskAttentionState]
    private var pausedIDs: [String] = []
    private var liveStateRequestIDs: [String] = []

    init(
        failingPauseIDs: Set<String> = [],
        liveStates: [String: TaskAttentionState] = [:]
    ) {
        self.failingPauseIDs = failingPauseIDs
        self.liveStates = liveStates
    }

    func start() async throws {}
    func subscribe(to threadIDs: [String]) async {}
    func liveApprovalStateIsAuthoritative() async -> Bool { false }
    func liveAttentionState(for threadID: String) async -> TaskAttentionState? {
        liveStateRequestIDs.append(threadID)
        return liveStates[threadID]
    }
    func perform(_ action: TaskApprovalAction, for threadID: String) async throws {}

    func pause(threadID: String) async throws {
        pausedIDs.append(threadID)
        if failingPauseIDs.contains(threadID) {
            throw RecordingApprovalError.pauseFailed(threadID)
        }
    }

    func recordedPauseIDs() -> [String] { pausedIDs }
    func recordedLiveStateRequestIDs() -> [String] { liveStateRequestIDs }
}

private actor DelayedStartApprovalController: TaskApprovalControlling {
    private let delay: Duration

    init(delay: Duration) { self.delay = delay }

    func start() async throws { try await Task.sleep(for: delay) }
    func subscribe(to threadIDs: [String]) async {}
    func liveApprovalStateIsAuthoritative() async -> Bool { false }
    func liveAttentionState(for threadID: String) async -> TaskAttentionState? { nil }
    func perform(_ action: TaskApprovalAction, for threadID: String) async throws {}
    func pause(threadID: String) async throws {}
}

@Suite("Codex Task Manager")
struct CodexTaskManagerKitTests {
    @Test("Deep links accept exact UUID task identifiers")
    func deepLinkValidation() {
        let id = "00000000-0000-0000-0000-000000000001"
        #expect(CodexDeepLink.url(for: id)?.absoluteString == "codex://threads/\(id)")
        #expect(CodexDeepLink.url(for: "not-a-task") == nil)
    }

    @Test("Needs filtering includes approval and response states only")
    func unifiedNeedsFilter() {
        var tasks = fixtures()
        tasks.append(makeTask(6, project: "/B", state: .needsApproval))
        let result = TaskListEngine.presentation(
            tasks: tasks,
            filter: .needs,
            sort: .recent,
            searchText: "",
            groupByProject: true,
            customProjectOrder: [],
            expandedProjectPaths: []
        )
        #expect(result.totalCount == 2)
        #expect(Set(result.sections.flatMap(\.tasks).map(\.state)) == [.needsApproval, .needsResponse])
        #expect(!result.isLimited)
        #expect(TaskStatusFilter.needs.label == "Needs input")
    }

    @Test("Multiple selected statuses include each selected category")
    func multiStatusFilter() {
        let result = TaskListEngine.presentation(
            tasks: fixtures(),
            filter: Set([.needs, .running]),
            sort: .recent,
            searchText: "",
            groupByProject: true,
            customProjectOrder: [],
            expandedProjectPaths: []
        )
        #expect(result.totalCount == 2)
        #expect(Set(result.sections.flatMap(\.tasks).map(\.state)) == [.needsResponse, .running])
        #expect(!result.isLimited)
    }

    @Test("An empty status selection shows all tasks")
    func emptyMultiStatusFilter() {
        let result = TaskListEngine.presentation(
            tasks: fixtures(),
            filter: Set<TaskStatusFilter>(),
            sort: .recent,
            searchText: "",
            groupByProject: true,
            customProjectOrder: [],
            expandedProjectPaths: []
        )
        #expect(result.totalCount == fixtures().count)
        #expect(result.sections.flatMap(\.tasks).contains { $0.state == .idle })
    }

    @Test("Read filtering includes only idle tasks")
    func readFilter() {
        let result = TaskListEngine.presentation(
            tasks: fixtures(),
            filter: [.read],
            sort: .recent,
            searchText: "",
            groupByProject: true,
            customProjectOrder: [],
            expandedProjectPaths: []
        )
        #expect(result.totalCount == 2)
        #expect(result.sections.flatMap(\.tasks).allSatisfy { $0.state == .idle })
    }

    @Test("Legacy response selection migrates to unified needs")
    @MainActor
    func needsSelectionMigration() {
        let suiteName = "CodexTaskManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyPreferences = """
        {
          "selectedStatusFilters": ["needsResponse"],
          "sort": "recent",
          "groupByProject": true,
          "showProjectNames": true,
          "customProjectOrder": []
        }
        """
        defaults.set(Data(legacyPreferences.utf8), forKey: "CodexTaskManager.preferences.v1")

        let model = TaskManagerModel(defaults: defaults, fixtureName: "all")
        #expect(model.selectedStatusFilters == [.needs])
    }

    @Test("Every legacy attention selection decodes as one unified needs category")
    @MainActor
    func allNeedsSelectionMigrations() {
        for legacySelection in [
            #"["needsApproval"]"#,
            #"["needsResponse"]"#,
            #"["needsApproval","needsResponse"]"#,
        ] {
            let suiteName = "CodexTaskManagerTests.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                Issue.record("Unable to create isolated UserDefaults suite")
                continue
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let preferences = """
            {
              "selectedStatusFilters": \(legacySelection),
              "statusFilterSchemaVersion": 2,
              "sort": "recent",
              "groupByProject": true,
              "showProjectNames": true,
              "customProjectOrder": []
            }
            """
            defaults.set(Data(preferences.utf8), forKey: "CodexTaskManager.preferences.v1")

            let model = TaskManagerModel(defaults: defaults, fixtureName: "all")
            #expect(model.selectedStatusFilters == [.needs])
        }
    }

    @Test("Status menu categories and top shortcuts share one selection set")
    @MainActor
    func statusSelectionSynchronization() {
        let suiteName = "CodexTaskManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = TaskManagerModel(defaults: defaults, fixtureName: "all")
        #expect(TaskStatusFilter.selectableCases == [.needs, .running, .complete, .read])
        #expect(model.selectedStatusFilters.isEmpty)

        model.toggleStatusFilter(.needs)
        model.toggleStatusFilter(.running)
        model.toggleStatusFilter(.complete)
        model.toggleStatusFilter(.read)
        #expect(model.selectedStatusFilters == [.needs, .running, .complete, .read])
        #expect(model.isAttentionFilterSelected)
        #expect(model.isStatusFilterSelected(.running))
        #expect(model.isStatusFilterSelected(.complete))
        #expect(model.isStatusFilterSelected(.read))

        #expect(model.presentation.totalCount == model.tasks.count)

        model.selectOnlyStatusFilter(.read)
        #expect(model.selectedStatusFilters == [.read])
        #expect(!model.isAttentionFilterSelected)
        #expect(!model.isStatusFilterSelected(.running))
        #expect(!model.isStatusFilterSelected(.complete))
        #expect(model.isStatusFilterSelected(.read))
        #expect(model.presentation.sections.flatMap(\.tasks).allSatisfy { $0.state == .idle })

        model.selectOnlyAttentionFilters()
        #expect(model.selectedStatusFilters == [.needs])
        #expect(model.isAttentionFilterSelected)
        #expect(!model.isStatusFilterSelected(.running))
        #expect(!model.isStatusFilterSelected(.complete))
        #expect(!model.isStatusFilterSelected(.read))

        model.selectOnlyStatusFilter(.running)
        #expect(model.selectedStatusFilters == [.running])
        #expect(!model.isAttentionFilterSelected)
        #expect(model.isStatusFilterSelected(.running))

        model.selectOnlyStatusFilter(.complete)
        #expect(model.selectedStatusFilters == [.complete])
        #expect(!model.isAttentionFilterSelected)
        #expect(!model.isStatusFilterSelected(.running))
        #expect(model.isStatusFilterSelected(.complete))
        #expect(!model.isStatusFilterSelected(.read))
    }

    @Test("Read selection persists across model instances")
    @MainActor
    func readSelectionPersistence() {
        let suiteName = "CodexTaskManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstModel = TaskManagerModel(defaults: defaults, fixtureName: "all")
        firstModel.selectOnlyStatusFilter(.read)

        let restoredModel = TaskManagerModel(defaults: defaults, fixtureName: "all")
        #expect(restoredModel.selectedStatusFilters == [.read])
    }

    @Test("Sort mode remains mutually exclusive")
    @MainActor
    func singleSortSelection() {
        let suiteName = "CodexTaskManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = TaskManagerModel(defaults: defaults, fixtureName: "all")
        for sort in TaskSortMode.allCases {
            model.sort = sort
            #expect(model.sort == sort)
        }
    }

    @Test("Priority is needs approval, response, complete, running, then idle")
    func priorityOrder() {
        var tasks = fixtures()
        tasks.append(makeTask(6, project: "/A", state: .needsApproval))
        let result = TaskListEngine.sorted(tasks, mode: .priority, customProjectOrder: [])
        #expect(result.map(\.state) == [.needsApproval, .needsResponse, .complete, .running, .idle, .idle])
    }

    @Test("Grouping uses the first matching project occurrence and gathers later matches")
    func groupingFirstOccurrence() {
        let tasks = fixtures()
        let result = TaskListEngine.presentation(
            tasks: tasks,
            filter: .all,
            sort: .recent,
            searchText: "",
            groupByProject: true,
            customProjectOrder: [],
            expandedProjectPaths: []
        )
        #expect(result.sections.map(\.projectPath) == ["/A", "/B", "/C"])
        #expect(result.sections[0].tasks.map(\.id) == [tasks[0].id, tasks[2].id, tasks[4].id])
    }

    @Test("Each project limits independently after project gathering")
    func disclosureLimitsEachProject() {
        let tasks = disclosureFixtures()
        let result = TaskListEngine.presentation(
            tasks: tasks,
            filter: .all,
            sort: .recent,
            searchText: "",
            groupByProject: true,
            customProjectOrder: [],
            expandedProjectPaths: []
        )
        #expect(result.totalCount == 12)
        #expect(result.displayedCount == 9)
        #expect(result.isLimited)
        #expect(result.sections.map(\.projectPath) == ["/A", "/B", "/C"])
        #expect(result.sections.map(\.tasks.count) == [4, 4, 1])
        #expect(result.sections.map(\.totalCount) == [6, 5, 1])
        #expect(result.sections.map(\.isLimited) == [true, true, false])

        let expandedA = TaskListEngine.presentation(
            tasks: tasks,
            filter: .all,
            sort: .recent,
            searchText: "",
            groupByProject: true,
            customProjectOrder: [],
            expandedProjectPaths: ["/A"]
        )
        #expect(expandedA.sections.map(\.tasks.count) == [6, 4, 1])
        #expect(expandedA.sections.map(\.totalCount) == [6, 5, 1])
        #expect(expandedA.sections.map(\.isLimited) == [false, true, false])
        #expect(expandedA.isLimited)

        let expandedBoth = TaskListEngine.presentation(
            tasks: tasks,
            filter: .all,
            sort: .recent,
            searchText: "",
            groupByProject: true,
            customProjectOrder: [],
            expandedProjectPaths: ["/A", "/B"]
        )
        #expect(expandedBoth.displayedCount == 12)
        #expect(!expandedBoth.isLimited)
    }

    @Test("Search results are never capped at four")
    func searchIsNotCapped() {
        let result = TaskListEngine.presentation(
            tasks: fixtures(),
            filter: .all,
            sort: .recent,
            searchText: "message",
            groupByProject: false,
            customProjectOrder: [],
            expandedProjectPaths: []
        )
        #expect(result.totalCount == 5)
        #expect(result.displayedCount == 5)
        #expect(!result.isLimited)
    }

    @Test("Search keeps pin metadata but uses ordinary task ordering")
    func searchDoesNotPromotePinnedTasks() {
        let newer = makeTask(1, project: "/A", state: .idle)
        var olderPinned = makeTask(2, project: "/B", state: .idle, pinned: true)
        olderPinned = CodexTask(
            id: olderPinned.id,
            title: olderPinned.title,
            projectPath: olderPinned.projectPath,
            latestAssistantMessage: olderPinned.latestAssistantMessage,
            recency: Date(timeIntervalSince1970: 1),
            isPinned: true,
            state: olderPinned.state
        )
        let result = TaskListEngine.presentation(
            tasks: [olderPinned, newer],
            filter: .all,
            sort: .recent,
            searchText: "task",
            groupByProject: false,
            customProjectOrder: [],
            pinnedTaskOrder: [olderPinned.id],
            expandedProjectPaths: []
        )

        #expect(result.sections.count == 1)
        #expect(result.sections[0].isPinnedSection == false)
        #expect(result.sections[0].tasks.map(\.id) == [newer.id, olderPinned.id])
        #expect(result.sections[0].tasks.last?.isPinned == true)
    }

    @Test("Search does not promote or force grouping for pinned projects")
    func searchDoesNotPromotePinnedProjects() {
        let tasks = [
            makeTask(1, project: "/A", state: .idle),
            makeTask(2, project: "/B", state: .idle),
        ]
        let result = TaskListEngine.presentation(
            tasks: tasks,
            filter: .all,
            sort: .recent,
            searchText: "task",
            groupByProject: false,
            customProjectOrder: ["/A", "/B"],
            pinnedProjectPaths: ["/B"],
            pinnedProjectOrder: ["/B"],
            expandedProjectPaths: []
        )

        #expect(result.sections.count == 1)
        #expect(result.sections[0].projectPath == nil)
        #expect(result.sections[0].tasks.map(\.projectPath) == ["/A", "/B"])

        let groupedResult = TaskListEngine.presentation(
            tasks: tasks,
            filter: .all,
            sort: .recent,
            searchText: "task",
            groupByProject: true,
            customProjectOrder: ["/A", "/B"],
            pinnedProjectPaths: ["/B"],
            pinnedProjectOrder: ["/B"],
            expandedProjectPaths: []
        )
        #expect(groupedResult.sections.map(\.projectPath) == ["/A", "/B"])
    }

    @Test("Whitespace and cleared searches restore pin-first ordering")
    func normalViewsStillPromotePins() {
        let ordinary = makeTask(1, project: "/A", state: .idle)
        let pinned = makeTask(2, project: "/B", state: .idle, pinned: true)
        for searchText in ["", "   \n"] {
            let result = TaskListEngine.presentation(
                tasks: [ordinary, pinned],
                filter: .all,
                sort: .recent,
                searchText: searchText,
                groupByProject: false,
                customProjectOrder: [],
                pinnedTaskOrder: [pinned.id],
                expandedProjectPaths: []
            )
            #expect(result.sections.first?.isPinnedSection == true)
            #expect(result.sections.first?.tasks.map(\.id) == [pinned.id])
        }
    }

    @Test("Alphabetical mode sorts projects and forces grouped presentation")
    func alphabeticalForcesGrouping() {
        let result = TaskListEngine.presentation(
            tasks: fixtures(),
            filter: .all,
            sort: .alphabetical,
            searchText: "",
            groupByProject: false,
            customProjectOrder: [],
            expandedProjectPaths: []
        )
        #expect(result.sections.map(\.projectPath) == ["/A", "/B", "/C"])
    }

    @Test("Codex worktrees inherit their canonical repository project identity")
    func worktreeProjectIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let codexHome = directory.appending(path: ".codex", directoryHint: .isDirectory)
        let canonicalProject = directory.appending(path: "Projects/ProstheticSimulator", directoryHint: .isDirectory)
        let liveWorktree = codexHome.appending(path: "worktrees/1764/ProstheticSimulator", directoryHint: .isDirectory)
        let missingWorktree = codexHome.appending(path: "worktrees/1c66/ProstheticSimulator", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: canonicalProject.appending(path: ".git", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: liveWorktree, withIntermediateDirectories: true)
        try "gitdir: \(canonicalProject.path)/.git/worktrees/ProstheticSimulator1\n".write(
            to: liveWorktree.appending(path: ".git"),
            atomically: true,
            encoding: .utf8
        )

        let canonical = CodexTaskRepository.canonicalProjectPaths(
            for: [canonicalProject.path, liveWorktree.path, missingWorktree.path],
            codexHome: codexHome
        )
        #expect(canonical[canonicalProject.path] == canonicalProject.path)
        #expect(canonical[liveWorktree.path] == canonicalProject.path)
        #expect(canonical[missingWorktree.path] == canonicalProject.path)

        let ambiguousProject = directory.appending(path: "Other/ProstheticSimulator", directoryHint: .isDirectory)
        let ambiguous = CodexTaskRepository.canonicalProjectPaths(
            for: [canonicalProject.path, ambiguousProject.path, missingWorktree.path],
            codexHome: codexHome
        )
        #expect(ambiguous[missingWorktree.path] == missingWorktree.path)
    }

    @Test("Ungrouped all-task views have no global disclosure cap")
    func ungroupedIsNotCapped() {
        let result = TaskListEngine.presentation(
            tasks: disclosureFixtures(),
            filter: .all,
            sort: .recent,
            searchText: "",
            groupByProject: false,
            customProjectOrder: [],
            expandedProjectPaths: []
        )
        #expect(result.sections.count == 1)
        #expect(result.displayedCount == 12)
        #expect(!result.isLimited)
    }

    @Test("Filtered project results have no disclosure cap")
    func filteredProjectsAreNotCapped() {
        let tasks = (1...6).map { makeTask($0, project: "/A", state: .complete) }
        let result = TaskListEngine.presentation(
            tasks: tasks,
            filter: .complete,
            sort: .recent,
            searchText: "",
            groupByProject: true,
            customProjectOrder: [],
            expandedProjectPaths: []
        )
        #expect(result.sections[0].tasks.count == 6)
        #expect(result.sections[0].totalCount == 6)
        #expect(!result.isLimited)
    }

    @Test("Every sort keeps pins first and respects the saved pin order")
    func universalPinnedOrder() {
        var tasks = fixtures()
        tasks[0] = tasks[0].replacingPinned(true)
        tasks.append(makeTask(6, project: "/B", state: .idle, pinned: true))
        let pins = tasks.filter(\.isPinned).map(\.id).reversed()
        for mode in TaskSortMode.allCases {
            let result = TaskListEngine.sorted(
                tasks,
                mode: mode,
                customProjectOrder: ["/C", "/B", "/A"],
                pinnedTaskOrder: Array(pins)
            )
            #expect(Array(result.prefix(2)).allSatisfy { $0.isPinned })
            #expect(Array(result.prefix(2)).map(\.id) == Array(pins))
            #expect(result.dropFirst(2).allSatisfy { !$0.isPinned })
        }
    }

    @Test("Grouped lists keep all matching pins in one leading section")
    func groupedPinnedSection() {
        var tasks = fixtures()
        tasks[0] = tasks[0].replacingPinned(true)
        tasks.append(makeTask(6, project: "/B", state: .idle, pinned: true))
        let result = TaskListEngine.presentation(
            tasks: tasks,
            filter: [],
            sort: .recent,
            searchText: "",
            groupByProject: true,
            customProjectOrder: [],
            pinnedTaskOrder: Array(tasks.filter(\.isPinned).map(\.id).reversed()),
            expandedProjectPaths: []
        )
        #expect(result.sections.first?.isPinnedSection == true)
        #expect(result.sections.first?.tasks.count == 2)
        #expect(result.sections.dropFirst().flatMap(\.tasks).allSatisfy { !$0.isPinned })
    }

    @Test("Priority first reorders only inside project groups and keeps task pins first")
    func priorityFirstWithinProjectGroups() {
        var tasks = [
            makeTask(1, project: "/A", state: .idle, pinned: true),
            makeTask(2, project: "/A", state: .running),
            makeTask(3, project: "/A", state: .needsApproval),
            makeTask(4, project: "/B", state: .idle),
            makeTask(5, project: "/B", state: .complete),
        ]
        tasks[0] = CodexTask(
            id: tasks[0].id,
            title: tasks[0].title,
            projectPath: tasks[0].projectPath,
            latestAssistantMessage: tasks[0].latestAssistantMessage,
            recency: Date(timeIntervalSince1970: 200),
            isPinned: true,
            state: tasks[0].state
        )
        let result = TaskListEngine.presentation(
            tasks: tasks,
            filter: .all,
            sort: .recent,
            searchText: "",
            groupByProject: true,
            customProjectOrder: ["/B", "/A"],
            priorityFirstWithinProjects: true,
            pinnedProjectPaths: ["/A"],
            pinnedTaskOrder: [tasks[0].id],
            expandedProjectPaths: []
        )
        #expect(result.totalCount == tasks.count)
        #expect(result.sections.map(\.projectPath) == ["/A", "/B"])
        #expect(result.sections[0].tasks.map(\.id) == [tasks[0].id, tasks[2].id, tasks[1].id])
        #expect(result.sections[1].tasks.map(\.id) == [tasks[4].id, tasks[3].id])
    }

    @Test("Pinned projects stay grouped first when ordinary grouping is off")
    func pinnedProjectsForceLeadingGroups() {
        let tasks = fixtures()
        let result = TaskListEngine.presentation(
            tasks: tasks,
            filter: .all,
            sort: .recent,
            searchText: "",
            groupByProject: false,
            customProjectOrder: ["/C", "/B", "/A"],
            pinnedProjectPaths: ["/B"],
            expandedProjectPaths: []
        )
        #expect(result.sections.first?.projectPath == "/B")
        #expect(result.sections.first?.tasks.allSatisfy { $0.projectPath == "/B" } == true)
        #expect(result.sections.last?.projectPath == nil)
        #expect(result.sections.last?.tasks.allSatisfy { $0.projectPath != "/B" } == true)
        #expect(result.displayedCount == tasks.count)
    }

    @Test("Pinned projects obey active filtering and custom project order")
    func pinnedProjectFilteringAndOrder() {
        let tasks = fixtures()
        let result = TaskListEngine.presentation(
            tasks: tasks,
            filter: .running,
            sort: .recent,
            searchText: "",
            groupByProject: true,
            customProjectOrder: ["/C", "/B", "/A"],
            pinnedProjectPaths: ["/B", "/C"],
            expandedProjectPaths: []
        )
        #expect(result.totalCount == 1)
        #expect(result.sections.map(\.projectPath) == ["/A"])
    }

    @Test("Custom project order governs Recent groups while A–Z stays alphabetical")
    func customProjectOrderVersusAlphabetical() {
        let tasks = fixtures()
        let recent = TaskListEngine.presentation(
            tasks: tasks,
            filter: .all,
            sort: .recent,
            searchText: "",
            groupByProject: true,
            customProjectOrder: ["/C", "/B", "/A"],
            expandedProjectPaths: []
        )
        #expect(recent.sections.map(\.projectPath) == ["/C", "/B", "/A"])

        let alphabetical = TaskListEngine.presentation(
            tasks: tasks,
            filter: .all,
            sort: .alphabetical,
            searchText: "",
            groupByProject: true,
            customProjectOrder: ["/C", "/B", "/A"],
            expandedProjectPaths: []
        )
        #expect(alphabetical.sections.map(\.projectPath) == ["/A", "/B", "/C"])
    }

    @Test("Project pins and arbitrary project moves persist across model instances")
    @MainActor
    func projectPinAndOrderPersistence() {
        let suiteName = "CodexTaskManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = TaskManagerModel(defaults: defaults, fixtureName: "all")
        let last = model.projectPaths.last!
        model.toggleProjectPin(last)
        model.moveProject(from: model.projectPaths.count - 1, to: 0)
        model.priorityFirstWithinProjects = true

        let restored = TaskManagerModel(defaults: defaults, fixtureName: "all")
        #expect(restored.isProjectPinned(last))
        #expect(restored.projectPaths.first == last)
        #expect(restored.priorityFirstWithinProjects)
        restored.toggleProjectPin(last)
        #expect(!restored.isProjectPinned(last))
    }

    @Test("Project groups default expanded and remember collapsed state")
    @MainActor
    func projectCollapsePersistence() {
        let suiteName = "CodexTaskManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = TaskManagerModel(defaults: defaults, fixtureName: "all")
        let project = model.projectPaths[1]
        #expect(model.collapsedProjectPaths.isEmpty)
        #expect(!model.isProjectCollapsed(project))

        model.toggleProjectCollapsed(project)
        #expect(model.isProjectCollapsed(project))
        model.searchText = "Beer"
        model.selectOnlyStatusFilter(.complete)
        model.sort = .alphabetical
        model.groupByProject = false
        model.toggleProjectPin(project)
        #expect(model.isProjectCollapsed(project))

        let restoredCollapsed = TaskManagerModel(defaults: defaults, fixtureName: "all")
        #expect(restoredCollapsed.isProjectCollapsed(project))
        restoredCollapsed.toggleProjectCollapsed(project)

        let restoredExpanded = TaskManagerModel(defaults: defaults, fixtureName: "all")
        #expect(!restoredExpanded.isProjectCollapsed(project))
    }

    @Test("Project batch actions target only eligible tasks and preserve partial failures")
    @MainActor
    func projectBatchActions() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeUnreadState(to: directory.appending(path: ".codex-global-state.json"))

        let repository = CodexTaskRepository(codexHome: directory)
        let controller = RecordingApprovalController(failingPauseIDs: [makeTask(6, project: "/A", state: .running).id])
        let suiteName = "CodexTaskManagerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = TaskManagerModel(
            repository: repository,
            defaults: defaults,
            approvalController: controller
        )
        model.tasks = [
            makeTask(1, project: "/A", state: .complete),
            makeTask(2, project: "/A", state: .complete),
            makeTask(3, project: "/A", state: .idle),
            makeTask(4, project: "/B", state: .complete),
            makeTask(5, project: "/A", state: .running),
            makeTask(6, project: "/A", state: .running),
            makeTask(7, project: "/A", state: .needsResponse),
            makeTask(8, project: "/B", state: .running),
        ]
        for id in [model.tasks[0].id, model.tasks[1].id, model.tasks[3].id] {
            try await repository.setTaskUnread(id, unread: true)
        }

        #expect(model.projectUnreadCount("/A") == 2)
        #expect(model.projectRunningCount("/A") == 2)
        #expect(model.projectUnreadCount("/Missing") == 0)
        #expect(model.projectRunningCount("/Missing") == 0)

        await model.markAllAsRead(in: "/A")
        #expect(model.tasks[0].state == .idle)
        #expect(model.tasks[1].state == .idle)
        #expect(model.tasks[2].state == .idle)
        #expect(model.tasks[3].state == .complete)
        #expect(try await repository.readStateOverride(for: model.tasks[0].id)?.unread == false)
        #expect(try await repository.readStateOverride(for: model.tasks[1].id)?.unread == false)
        #expect(try await repository.readStateOverride(for: model.tasks[3].id)?.unread == true)
        #expect(model.projectUnreadCount("/A") == 0)
        #expect(model.projectUnreadCount("/B") == 1)
        #expect(model.approvalMessage == "MARKED AS READ — 2 TASKS IN A")
        #expect(model.errorMessage == nil)

        await model.pauseAllTasks(in: "/A")
        #expect(await controller.recordedPauseIDs() == [model.tasks[4].id, model.tasks[5].id])
        #expect(model.tasks[4].state == .complete)
        #expect(model.tasks[5].state == .running)
        #expect(model.tasks[6].state == .needsResponse)
        #expect(model.tasks[7].state == .running)
        #expect(try await repository.readStateOverride(for: model.tasks[4].id)?.unread == true)
        #expect(model.projectRunningCount("/A") == 1)
        #expect(model.projectRunningCount("/B") == 1)
        #expect(model.approvalMessage == "PAUSED — 1 TASK IN A")
        #expect(model.errorMessage?.contains("1 of 2 project tasks failed") == true)
        #expect(model.approvalActionsInFlight.isEmpty)
    }

    @Test("Project pins append in pin-time order, repin last, and drag only within pins")
    @MainActor
    func projectPinAppendAndDragOrder() {
        let suiteName = "CodexTaskManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = TaskManagerModel(defaults: defaults, fixtureName: "all")
        let projects = model.projectPaths
        let firstPin = projects.last!
        let secondPin = projects[1]
        let thirdPin = projects[2]
        model.toggleProjectPin(firstPin)
        model.toggleProjectPin(secondPin)
        model.toggleProjectPin(thirdPin)
        #expect(model.pinnedProjectOrder == [firstPin, secondPin, thirdPin])

        let presentation = model.presentation
        #expect(presentation.sections.compactMap(\.projectPath).prefix(3) == [firstPin, secondPin, thirdPin])

        model.movePinnedProject(thirdPin, relativeTo: firstPin)
        #expect(model.pinnedProjectOrder == [thirdPin, firstPin, secondPin])
        model.movePinnedProject(secondPin, by: -2)
        #expect(model.pinnedProjectOrder == [secondPin, thirdPin, firstPin])
        model.movePinnedProject(secondPin, by: -1)
        #expect(model.pinnedProjectOrder == [secondPin, thirdPin, firstPin])
        model.toggleProjectPin(firstPin)
        model.toggleProjectPin(firstPin)
        #expect(model.pinnedProjectOrder == [secondPin, thirdPin, firstPin])

        let restored = TaskManagerModel(defaults: defaults, fixtureName: "all")
        #expect(restored.pinnedProjectOrder == model.pinnedProjectOrder)
    }

    @Test("Legacy project-pin sets migrate deterministically through saved project order")
    @MainActor
    func legacyProjectPinOrderMigration() {
        let suiteName = "CodexTaskManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyPreferences = """
        {
          "sort": "recent",
          "groupByProject": true,
          "showProjectNames": true,
          "customProjectOrder": ["/Users/demo/HandScanner", "/Users/demo/beersimpl"],
          "pinnedProjectPaths": ["/Users/demo/beersimpl", "/Users/demo/HandScanner"]
        }
        """
        defaults.set(Data(legacyPreferences.utf8), forKey: "CodexTaskManager.preferences.v1")
        let model = TaskManagerModel(defaults: defaults, fixtureName: "all")
        #expect(model.pinnedProjectOrder == [
            "/Users/demo/HandScanner",
            "/Users/demo/beersimpl",
        ])
    }

    @Test("Legacy Custom + pinned sort migrates to Recent without resetting preferences")
    @MainActor
    func customPinnedSortMigration() {
        let suiteName = "CodexTaskManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyPreferences = """
        {
          "selectedStatusFilters": ["running"],
          "sort": "customPinned",
          "groupByProject": false,
          "showProjectNames": false,
          "customProjectOrder": ["/B", "/A"]
        }
        """
        defaults.set(Data(legacyPreferences.utf8), forKey: "CodexTaskManager.preferences.v1")
        let model = TaskManagerModel(defaults: defaults, fixtureName: "all")
        #expect(model.sort == .recent)
        #expect(model.selectedStatusFilters == [.running])
        #expect(!model.groupByProject)
        #expect(!model.showProjectNames)
    }

    @Test("Pin toggles persist and drag reorder stays inside the pinned subset")
    @MainActor
    func pinPersistenceAndReorder() {
        let suiteName = "CodexTaskManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = TaskManagerModel(defaults: defaults, fixtureName: "all")
        let initiallyPinned = model.tasks.filter(\.isPinned)
        #expect(initiallyPinned.count == 2)
        model.movePinnedTask(initiallyPinned[0].id, relativeTo: initiallyPinned[1].id)
        #expect(model.pinnedTaskOrder == [initiallyPinned[1].id, initiallyPinned[0].id])
        model.movePinnedTask(initiallyPinned[0].id, by: -1)
        #expect(model.pinnedTaskOrder == [initiallyPinned[0].id, initiallyPinned[1].id])
        model.movePinnedTask(initiallyPinned[0].id, by: -1)
        #expect(model.pinnedTaskOrder == [initiallyPinned[0].id, initiallyPinned[1].id])

        guard let unpinned = model.tasks.first(where: { !$0.isPinned }) else {
            Issue.record("Fixture needs an unpinned task")
            return
        }
        model.togglePin(unpinned)
        #expect(model.tasks.first(where: { $0.id == unpinned.id })?.isPinned == true)
        #expect(model.pinnedTaskOrder.last == unpinned.id)

        let restored = TaskManagerModel(defaults: defaults, fixtureName: "all")
        #expect(restored.tasks.first(where: { $0.id == unpinned.id })?.isPinned == true)
        #expect(restored.pinnedTaskOrder == model.pinnedTaskOrder)

        restored.togglePin(unpinned.replacingPinned(true))
        #expect(restored.tasks.first(where: { $0.id == unpinned.id })?.isPinned == false)
        #expect(!restored.pinnedTaskOrder.contains(unpinned.id))
        restored.togglePin(unpinned)
        #expect(restored.pinnedTaskOrder.last == unpinned.id)
    }

    @Test("Rollout parser distinguishes running, pending input, and completion")
    func rolloutStates() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "rollout.jsonl")

        try write([
            line(type: "event_msg", payload: ["type": "task_started"]),
            line(type: "event_msg", payload: ["type": "agent_message", "message": "Still   working\nnow.", "phase": "commentary"]),
            line(type: "response_item", payload: ["type": "function_call", "name": "request_user_input", "call_id": "call-1"]),
        ], to: url)

        let pending = try RolloutScanner.scan(fileURL: url)
        #expect(pending.isRunning)
        #expect(!pending.needsApproval)
        #expect(pending.needsResponse)
        #expect(pending.latestAssistantMessage == "Still working now.")

        try write([
            line(type: "event_msg", payload: ["type": "task_started"]),
            line(type: "response_item", payload: ["type": "function_call", "name": "request_user_input", "call_id": "call-1"]),
            line(type: "response_item", payload: ["type": "function_call_output", "call_id": "call-1"]),
            line(type: "event_msg", payload: ["type": "agent_message", "message": "Finished.", "phase": "final_answer"]),
            line(type: "event_msg", payload: ["type": "task_complete"]),
        ], to: url)

        let complete = try RolloutScanner.scan(fileURL: url)
        #expect(!complete.isRunning)
        #expect(!complete.needsApproval)
        #expect(!complete.needsResponse)
        #expect(complete.latestAssistantMessage == "Finished.")
    }

    @Test("Settings metadata cannot revive a completed rollout")
    func settingsMetadataPreservesTerminalState() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "rollout.jsonl")

        try write([
            line(timestamp: "2026-08-13T10:30:00.000Z", type: "response_item", payload: ["type": "message", "role": "user"]),
            line(timestamp: "2026-08-13T10:30:01.000Z", type: "event_msg", payload: ["type": "task_started"]),
            line(timestamp: "2026-08-13T10:30:02.000Z", type: "event_msg", payload: ["type": "agent_message", "message": "Finished.", "phase": "final_answer"]),
            line(timestamp: "2026-08-13T10:30:03.000Z", type: "event_msg", payload: ["type": "task_complete"]),
            line(timestamp: "2026-08-13T10:30:04.000Z", type: "event_msg", payload: ["type": "thread_settings_applied"]),
        ], to: url)

        let fullScan = try RolloutScanner.scan(fileURL: url)
        #expect(!fullScan.isRunning)
        #expect(fullScan.completionDate == isoDate("2026-08-13T10:30:03.000Z"))

        try write([
            line(timestamp: "2026-08-13T10:30:00.000Z", type: "response_item", payload: ["type": "message", "role": "user"]),
            line(timestamp: "2026-08-13T10:30:01.000Z", type: "event_msg", payload: ["type": "task_started"]),
            line(timestamp: "2026-08-13T10:30:02.000Z", type: "event_msg", payload: ["type": "agent_message", "message": "Finished.", "phase": "final_answer"]),
            line(timestamp: "2026-08-13T10:30:03.000Z", type: "event_msg", payload: ["type": "task_complete"]),
        ], to: url)
        var cursor = try RolloutScanCursor(fileURL: url)
        #expect(!cursor.snapshot.isRunning)

        try append([
            line(timestamp: "2026-08-13T10:30:04.000Z", type: "event_msg", payload: ["type": "thread_settings_applied"]),
        ], to: url)
        let incremental = try cursor.scanAppended(fileURL: url)
        #expect(!incremental.isRunning)
        #expect(incremental.completionDate == isoDate("2026-08-13T10:30:03.000Z"))

        try append([
            line(timestamp: "2026-08-13T10:30:05.000Z", type: "event_msg", payload: ["type": "task_started"]),
        ], to: url)
        let restarted = try cursor.scanAppended(fileURL: url)
        #expect(restarted.isRunning)
        #expect(restarted.completionDate == nil)
    }

    @Test("Rollout recency follows the current task state")
    func stateAwareRolloutRecency() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "rollout.jsonl")
        let fallback = Date(timeIntervalSince1970: 1)

        try write([
            line(timestamp: "2026-08-13T10:00:00.000Z", type: "response_item", payload: ["type": "message", "role": "user"]),
            line(timestamp: "2026-08-13T10:00:01.000Z", type: "event_msg", payload: ["type": "task_started"]),
            line(timestamp: "2026-08-13T10:00:02.000Z", type: "event_msg", payload: ["type": "agent_message", "message": "Working."]),
        ], to: url)

        var snapshot = try RolloutScanner.scan(fileURL: url)
        #expect(snapshot.recencyDate(for: .running, fallback: fallback) == isoDate("2026-08-13T10:00:00.000Z"))

        try append([
            line(timestamp: "2026-08-13T10:00:03.000Z", type: "response_item", payload: ["type": "function_call", "name": "request_user_input", "call_id": "input-1"]),
        ], to: url)
        snapshot = try RolloutScanner.scan(fileURL: url)
        #expect(snapshot.recencyDate(for: .needsResponse, fallback: fallback) == isoDate("2026-08-13T10:00:03.000Z"))

        try append([
            line(timestamp: "2026-08-13T10:00:04.000Z", type: "response_item", payload: ["type": "function_call_output", "call_id": "input-1"]),
            line(timestamp: "2026-08-13T10:00:05.000Z", type: "event_msg", payload: ["type": "agent_message", "message": "Finished."]),
            line(timestamp: "2026-08-13T10:00:06.000Z", type: "event_msg", payload: ["type": "task_complete"]),
        ], to: url)
        snapshot = try RolloutScanner.scan(fileURL: url)
        #expect(snapshot.recencyDate(for: .complete, fallback: fallback) == isoDate("2026-08-13T10:00:06.000Z"))
        #expect(snapshot.recencyDate(for: .idle, fallback: fallback) == isoDate("2026-08-13T10:00:05.000Z"))
    }

    @Test("Recent ordering uses each state's selected timestamp")
    func stateAwareRecentOrdering() {
        let fallback = Date(timeIntervalSince1970: 1)
        let runningSnapshot = RolloutSnapshot(
            latestAssistantMessage: "Still working",
            latestAssistantMessageDate: isoDate("2026-08-13T10:09:00.000Z"),
            latestUserMessageDate: isoDate("2026-08-13T10:00:00.000Z"),
            isRunning: true,
            needsResponse: false
        )
        let needsSnapshot = RolloutSnapshot(
            latestAssistantMessage: "Question",
            attentionRequestDate: isoDate("2026-08-13T10:08:00.000Z"),
            isRunning: true,
            needsResponse: true
        )
        let completeSnapshot = RolloutSnapshot(
            latestAssistantMessage: "Done",
            completionDate: isoDate("2026-08-13T10:07:00.000Z"),
            isRunning: false,
            needsResponse: false
        )
        let readSnapshot = RolloutSnapshot(
            latestAssistantMessage: "Earlier answer",
            latestAssistantMessageDate: isoDate("2026-08-13T10:06:00.000Z"),
            isRunning: false,
            needsResponse: false
        )
        let inputs: [(String, TaskAttentionState, RolloutSnapshot)] = [
            ("running", .running, runningSnapshot),
            ("needs", .needsResponse, needsSnapshot),
            ("complete", .complete, completeSnapshot),
            ("read", .idle, readSnapshot),
        ]
        let tasks = inputs.map { id, state, snapshot in
            CodexTask(
                id: id,
                title: id,
                projectPath: "/Fixture",
                latestAssistantMessage: snapshot.latestAssistantMessage ?? "",
                recency: snapshot.recencyDate(for: state, fallback: fallback),
                isPinned: false,
                state: state
            )
        }

        #expect(TaskListEngine.sorted(tasks, mode: .recent, customProjectOrder: []).map(\.id) == [
            "needs", "complete", "read", "running",
        ])
    }

    @Test("Pending needs recency tracks the newest unresolved request incrementally")
    func incrementalAttentionRecency() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "rollout.jsonl")
        try write([
            line(timestamp: "2026-08-13T11:00:00.000Z", type: "event_msg", payload: ["type": "task_started"]),
            line(timestamp: "2026-08-13T11:00:01.000Z", type: "response_item", payload: ["type": "function_call", "name": "request_user_input", "call_id": "input-1"]),
        ], to: url)
        var cursor = try RolloutScanCursor(fileURL: url)

        try append([
            line(timestamp: "2026-08-13T11:00:02.000Z", type: "response_item", payload: [
                "type": "custom_tool_call",
                "name": "exec",
                "call_id": "approval-1",
                "input": #"{\"sandbox_permissions\":\"require_escalated\"}"#,
            ]),
        ], to: url)
        var incremental = try cursor.scanAppended(fileURL: url)
        #expect(incremental.attentionRequestDate == isoDate("2026-08-13T11:00:02.000Z"))
        #expect(incremental == (try RolloutScanner.scan(fileURL: url)))

        try append([
            line(timestamp: "2026-08-13T11:00:03.000Z", type: "response_item", payload: ["type": "custom_tool_call_output", "call_id": "approval-1"]),
        ], to: url)
        incremental = try cursor.scanAppended(fileURL: url)
        #expect(incremental.attentionRequestDate == isoDate("2026-08-13T11:00:01.000Z"))
        #expect(incremental == (try RolloutScanner.scan(fileURL: url)))
    }

    @Test("Rollout parser recognizes a pending direct approval request")
    func rolloutNeedsApproval() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "rollout.jsonl")

        try write([
            line(type: "event_msg", payload: ["type": "task_started"]),
            line(type: "response_item", payload: [
                "type": "custom_tool_call",
                "name": "exec",
                "call_id": "approval-1",
                "input": #"{\"cmd\":\"echo ready\",\"sandbox_permissions\":\"require_escalated\"}"#,
            ]),
        ], to: url)

        let pending = try RolloutScanner.scan(fileURL: url)
        #expect(pending.isRunning)
        #expect(pending.needsApproval)
        #expect(!pending.needsResponse)

        try write([
            line(type: "event_msg", payload: ["type": "task_started"]),
            line(type: "response_item", payload: [
                "type": "custom_tool_call",
                "name": "exec",
                "call_id": "approval-1",
                "input": #"{ sandbox_permissions: "require_escalated" }"#,
            ]),
            line(type: "response_item", payload: ["type": "custom_tool_call_output", "call_id": "approval-1"]),
        ], to: url)

        let resolved = try RolloutScanner.scan(fileURL: url)
        #expect(!resolved.needsApproval)
    }

    @Test("A later turn preserves unresolved approvals until a real terminal event")
    func rolloutApprovalTurnBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "rollout.jsonl")

        let unresolvedApproval = try line(type: "response_item", payload: [
            "type": "custom_tool_call",
            "name": "exec",
            "call_id": "old-approval",
            "input": #"{\"sandbox_permissions\":\"require_escalated\"}"#,
        ])
        try write([
            line(type: "event_msg", payload: ["type": "task_started"]),
            unresolvedApproval,
            line(type: "event_msg", payload: ["type": "task_started"]),
            line(type: "event_msg", payload: ["type": "agent_message", "message": "A later turn is running."]),
        ], to: url)
        var snapshot = try RolloutScanner.scan(fileURL: url)
        #expect(snapshot.isRunning)
        #expect(snapshot.needsApproval)

        try write([
            line(type: "event_msg", payload: ["type": "task_started"]),
            unresolvedApproval,
            line(type: "event_msg", payload: ["type": "turn_aborted"]),
        ], to: url)
        snapshot = try RolloutScanner.scan(fileURL: url)
        #expect(!snapshot.isRunning)
        #expect(!snapshot.needsApproval)
    }

    @Test("Incremental rollout parsing waits for a complete JSONL record")
    func incrementalPartialLine() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "rollout.jsonl")
        try write([line(type: "event_msg", payload: ["type": "task_started"])], to: url)
        var cursor = try RolloutScanCursor(fileURL: url)

        let approval = try line(type: "response_item", payload: [
            "type": "custom_tool_call",
            "name": "exec",
            "call_id": "partial-approval",
            "input": #"{\"sandbox_permissions\":\"require_escalated\"}"#,
        ])
        let midpoint = approval.index(approval.startIndex, offsetBy: approval.count / 2)
        try appendText(String(approval[..<midpoint]), to: url)
        var snapshot = try cursor.scanAppended(fileURL: url)
        #expect(snapshot.isRunning)
        #expect(!snapshot.needsApproval)
        #expect(String(decoding: cursor.pendingLineForTesting, as: UTF8.self) == String(approval[..<midpoint]))

        try appendText(String(approval[midpoint...]) + "\n", to: url)
        snapshot = try cursor.scanAppended(fileURL: url)
        #expect(cursor.pendingLineForTesting.isEmpty)
        #expect(cursor.pendingApprovalCountForTesting == 1)
        #expect(snapshot.needsApproval)
    }

    @Test("Optional live catalog smoke test (CTM_TEST_LOCAL_CATALOG=1)")
    func liveRepositoryRead() async throws {
        guard ProcessInfo.processInfo.environment["CTM_TEST_LOCAL_CATALOG"] == "1" else { return }
        let database = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/state_5.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { return }
        let tasks = try await CodexTaskRepository().loadTasks()
        #expect(tasks.allSatisfy { !$0.id.isEmpty && !$0.title.isEmpty && !$0.projectPath.isEmpty })
    }

    @Test("Session index titles override prompt-like catalog titles and refresh independently")
    func sessionIndexTitleOverlay() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rollout = directory.appending(path: "sessions/rollout.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write([
            line(type: "event_msg", payload: ["type": "task_started"]),
            line(type: "event_msg", payload: ["type": "agent_message", "message": "Secondary line remains unchanged."]),
            line(type: "event_msg", payload: ["type": "task_complete"]),
        ], to: rollout)
        try makeCatalog(at: directory.appending(path: "state_5.sqlite"), rolloutPath: rollout.path)
        try writeUnreadState(to: directory.appending(path: ".codex-global-state.json"))
        let titleIndex = directory.appending(path: "session_index.jsonl")
        try write([
            #"{"id":"00000000-0000-0000-0000-000000000001","thread_name":"Older sidebar title"}"#,
            #"{"id":"00000000-0000-0000-0000-000000000001","thread_name":"Codex sidebar title"}"#,
        ], to: titleIndex)

        let repository = CodexTaskRepository(codexHome: directory)
        var tasks = try await repository.loadTasks()
        #expect(tasks[0].title == "Codex sidebar title")
        #expect(tasks[0].latestAssistantMessage == "Secondary line remains unchanged.")
        var metrics = await repository.lastLoadMetrics()
        #expect(metrics.catalogReloaded)
        #expect(metrics.titleIndexReloaded)

        _ = try await repository.loadTasks(refresh: .none)
        metrics = await repository.lastLoadMetrics()
        #expect(!metrics.catalogReloaded)
        #expect(!metrics.titleIndexReloaded)

        try write([
            #"{"id":"00000000-0000-0000-0000-000000000001","thread_name":"Updated Codex title"}"#,
        ], to: titleIndex)
        tasks = try await repository.loadTasks(refresh: TaskRefreshHint(titleIndexChanged: true))
        #expect(tasks[0].title == "Updated Codex title")
        #expect(tasks[0].latestAssistantMessage == "Secondary line remains unchanged.")
        metrics = await repository.lastLoadMetrics()
        #expect(!metrics.catalogReloaded)
        #expect(metrics.titleIndexReloaded)
        #expect(metrics.rolloutScans == 0)

        try write([
            #"{"id":"00000000-0000-0000-0000-000000000001","thread_name":"   "}"#,
        ], to: titleIndex)
        tasks = try await repository.loadTasks(refresh: TaskRefreshHint(titleIndexChanged: true))
        #expect(tasks[0].title == "Fixture task")
    }

    @Test("Refresh hints merge without dropping paths or safety flags")
    func refreshHintMerge() {
        var hint = TaskRefreshHint(changedRolloutPaths: ["/a.jsonl"])
        hint.merge(TaskRefreshHint(catalogChanged: true, changedRolloutPaths: ["/b.jsonl"]))
        hint.merge(TaskRefreshHint(requiresFullReconciliation: true, titleIndexChanged: true, unreadStateChanged: true))
        #expect(hint.requiresFullReconciliation)
        #expect(hint.catalogChanged)
        #expect(hint.titleIndexChanged)
        #expect(hint.unreadStateChanged)
        #expect(hint.changedRolloutPaths == ["/a.jsonl", "/b.jsonl"])
    }

    @Test("FSEvent classification targets Codex sources and fails safe on dropped events")
    func fseventClassification() {
        let home = URL(fileURLWithPath: "/tmp/codex-observer-fixture", isDirectory: true)
        let rollout = home.appending(path: "sessions/2026/08/11/rollout.jsonl").path
        let hint = CodexDataChangeClassifier.classify(
            paths: [
                rollout,
                home.appending(path: "state_5.sqlite-wal").path,
                home.appending(path: "session_index.jsonl").path,
                home.appending(path: ".codex-global-state.json").path,
            ],
            flags: [
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),
            ],
            codexHome: home
        )
        #expect(hint.changedRolloutPaths == [rollout])
        #expect(hint.catalogChanged)
        #expect(hint.titleIndexChanged)
        #expect(hint.unreadStateChanged)
        #expect(!hint.requiresFullReconciliation)

        let dropped = CodexDataChangeClassifier.classify(
            paths: [home.path],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped)],
            codexHome: home
        )
        #expect(dropped.requiresFullReconciliation)

        let renamed = CodexDataChangeClassifier.classify(
            paths: [rollout],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile)],
            codexHome: home
        )
        #expect(renamed.changedRolloutPaths == [rollout])
        #expect(renamed.catalogChanged)
    }

    @Test("Incremental refresh scans only an appended rollout and reconciliation catches a missed event")
    func incrementalRepositoryRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rollout = directory.appending(path: "sessions/2026/08/11/rollout.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write([
            line(timestamp: "2026-08-13T12:00:00.000Z", type: "response_item", payload: ["type": "message", "role": "user"]),
            line(timestamp: "2026-08-13T12:00:01.000Z", type: "event_msg", payload: ["type": "task_started"]),
            line(timestamp: "2026-08-13T12:00:02.000Z", type: "event_msg", payload: ["type": "agent_message", "message": "Waiting for input."]),
            line(timestamp: "2026-08-13T12:00:03.000Z", type: "response_item", payload: ["type": "function_call", "name": "request_user_input", "call_id": "input-1"]),
        ], to: rollout)
        try makeCatalog(at: directory.appending(path: "state_5.sqlite"), rolloutPath: rollout.path)
        try writeUnreadState(to: directory.appending(path: ".codex-global-state.json"))

        let repository = CodexTaskRepository(
            codexHome: directory,
            desktopRuntimeStartDateProvider: { nil }
        )
        let initial = try await repository.loadTasks()
        #expect(initial.count == 1)
        #expect(initial[0].state == .needsResponse)
        #expect(initial[0].recency == isoDate("2026-08-13T12:00:03.000Z"))
        var metrics = await repository.lastLoadMetrics()
        #expect(metrics.catalogReloaded)
        #expect(metrics.unreadStateReloaded)
        #expect(metrics.rolloutFullScans == 1)

        _ = try await repository.loadTasks(refresh: .none)
        metrics = await repository.lastLoadMetrics()
        #expect(metrics.rolloutMetadataChecks == 0)
        #expect(metrics.rolloutScans == 0)
        #expect(!metrics.catalogReloaded)
        #expect(!metrics.unreadStateReloaded)

        try append([
            line(timestamp: "2026-08-13T12:00:04.000Z", type: "response_item", payload: ["type": "function_call_output", "call_id": "input-1"]),
            line(timestamp: "2026-08-13T12:00:05.000Z", type: "event_msg", payload: ["type": "agent_message", "message": "Finished response."]),
            line(timestamp: "2026-08-13T12:00:06.000Z", type: "event_msg", payload: ["type": "task_complete"]),
        ], to: rollout)
        try writeUnreadState(
            to: directory.appending(path: ".codex-global-state.json"),
            taskIDs: ["00000000-0000-0000-0000-000000000001"]
        )

        let reconciled = try await repository.loadTasks(
            refresh: TaskRefreshHint(
                requiresFullReconciliation: true,
                unreadStateChanged: true
            )
        )
        #expect(reconciled[0].state == .complete)
        #expect(reconciled[0].recency == isoDate("2026-08-13T12:00:06.000Z"))
        metrics = await repository.lastLoadMetrics()
        #expect(metrics.rolloutMetadataChecks == 1)
        #expect(metrics.rolloutIncrementalScans == 1)
        #expect(metrics.rolloutFullScans == 0)

        try append([
            line(timestamp: "2026-08-13T12:00:07.000Z", type: "event_msg", payload: ["type": "thread_settings_applied"]),
        ], to: rollout)
        let settingsOnly = try await repository.loadTasks(
            refresh: TaskRefreshHint(changedRolloutPaths: [rollout.path])
        )
        #expect(settingsOnly[0].state == .complete)
        #expect(settingsOnly[0].recency == isoDate("2026-08-13T12:00:06.000Z"))
        metrics = await repository.lastLoadMetrics()
        #expect(metrics.rolloutIncrementalScans == 1)
        #expect(metrics.rolloutFullScans == 0)

        try await repository.setTaskUnread("00000000-0000-0000-0000-000000000001", unread: false)
        let read = try await repository.loadTasks(refresh: .none)
        #expect(read[0].state == .idle)
        #expect(read[0].recency == isoDate("2026-08-13T12:00:05.000Z"))
        let reopenedRepository = CodexTaskRepository(codexHome: directory)
        let readAfterReopen = try await reopenedRepository.loadTasks()
        #expect(readAfterReopen[0].state == .idle)
        #expect(readAfterReopen[0].recency == isoDate("2026-08-13T12:00:05.000Z"))

        try append([
            line(timestamp: "2026-08-13T12:00:10.000Z", type: "response_item", payload: ["type": "message", "role": "user"]),
            line(timestamp: "2026-08-13T12:00:11.000Z", type: "event_msg", payload: ["type": "task_started"]),
            line(timestamp: "2026-08-13T12:00:12.000Z", type: "event_msg", payload: ["type": "agent_message", "message": "Running after the prompt."]),
        ], to: rollout)
        let running = try await repository.loadTasks(
            refresh: TaskRefreshHint(changedRolloutPaths: [rollout.path])
        )
        #expect(running[0].state == .running)
        #expect(running[0].recency == isoDate("2026-08-13T12:00:10.000Z"))

        try write([
            line(timestamp: "2026-08-13T12:01:00.000Z", type: "event_msg", payload: ["type": "task_started"]),
            line(timestamp: "2026-08-13T12:01:01.000Z", type: "event_msg", payload: ["type": "agent_message", "message": "Replacement completed."]),
            line(timestamp: "2026-08-13T12:01:02.000Z", type: "event_msg", payload: ["type": "task_complete"]),
        ], to: rollout)
        try writeUnreadState(
            to: directory.appending(path: ".codex-global-state.json"),
            taskIDs: ["00000000-0000-0000-0000-000000000001"]
        )
        let replaced = try await repository.loadTasks(
            refresh: TaskRefreshHint(
                unreadStateChanged: true,
                changedRolloutPaths: [rollout.path]
            )
        )
        #expect(replaced[0].state == .complete)
        #expect(replaced[0].latestAssistantMessage == "Replacement completed.")
        #expect(replaced[0].recency == isoDate("2026-08-13T12:01:02.000Z"))
        metrics = await repository.lastLoadMetrics()
        #expect(metrics.rolloutIncrementalScans == 0)
        #expect(metrics.rolloutFullScans == 1)

        try append([
            line(timestamp: "2026-08-13T12:02:00.000Z", type: "response_item", payload: ["type": "message", "role": "user"]),
            line(timestamp: "2026-08-13T12:02:01.000Z", type: "event_msg", payload: ["type": "task_started"]),
            line(timestamp: "2026-08-13T12:02:02.000Z", type: "response_item", payload: [
                "type": "custom_tool_call",
                "name": "exec",
                "call_id": "approval-2",
                "input": #"{\"sandbox_permissions\":\"require_escalated\"}"#,
            ]),
        ], to: rollout)
        let changed = try await repository.loadTasks(
            refresh: TaskRefreshHint(changedRolloutPaths: [rollout.path])
        )
        #expect(changed[0].state == .needsApproval)
        #expect(changed[0].recency == isoDate("2026-08-13T12:02:02.000Z"))
        metrics = await repository.lastLoadMetrics()
        #expect(metrics.rolloutMetadataChecks == 1)
        #expect(metrics.rolloutIncrementalScans == 1)
        #expect(metrics.rolloutFullScans == 0)
    }

    @Test("Fallback reconciliation remains bounded to thirty seconds")
    @MainActor
    func reconciliationCadence() {
        #expect(TaskManagerModel.reconciliationInterval <= .seconds(30))
        #expect(TaskManagerModel.observerFallbackPollingInterval <= .seconds(2.5))
    }

    @Test("Approval JSON preserves response and task-settings protocol shapes")
    func approvalProtocolJSON() throws {
        let response = JSONValue.object([
            "id": .int(7),
            "result": .object(["decision": .string("accept")]),
        ])
        let responseObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
        #expect(responseObject?["id"] as? Int == 7)
        #expect((responseObject?["result"] as? [String: Any])?["decision"] as? String == "accept")

        let settings = JSONValue.object([
            "threadId": .string("thread-1"),
            "approvalPolicy": .string("never"),
            "approvalsReviewer": .string("auto_review"),
            "sandboxPolicy": .object(["type": .string("dangerFullAccess")]),
        ])
        let settingsObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        #expect(settingsObject?["threadId"] as? String == "thread-1")
        #expect(settingsObject?["approvalPolicy"] as? String == "never")
        #expect(settingsObject?["approvalsReviewer"] as? String == "auto_review")
        #expect((settingsObject?["sandboxPolicy"] as? [String: Any])?["type"] as? String == "dangerFullAccess")
    }

    @Test("Pause selects only the newest in-progress turn")
    func pauseTurnSelection() {
        let response = JSONValue.object([
            "thread": .object([
                "turns": .array([
                    .object(["id": .string("completed"), "status": .string("completed")]),
                    .object(["id": .string("active"), "status": .string("inProgress")]),
                ]),
            ]),
        ])
        #expect(CodexTaskApprovalController.inProgressTurnID(in: response) == "active")
        #expect(CodexTaskApprovalController.inProgressTurnID(in: .object([:])) == nil)
    }

    @Test("Desktop pause uses owner-side user-stop semantics")
    func desktopPauseRequest() {
        let request = CodexDesktopIPCClient.userStopRequest(threadID: "thread-123")
        #expect(request.version == 4)
        #expect(request.params.objectValue?["conversationId"]?.stringValue == "thread-123")
        #expect(request.params.objectValue?["mode"]?.stringValue == "user-stop")
    }

    @Test("Task Manager read overrides persist without mutating Codex global state")
    func unreadStateMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appending(path: ".codex-global-state.json")
        let initial: [String: Any] = [
            "unrelated": ["preserved": true],
            "electron-persisted-atom-state": [
                "another-key": "keep-me",
                "unread-thread-ids-by-host-v1": [
                    "local": ["existing"],
                    "remote-host": ["remote"],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: initial).write(to: stateURL)
        let repository = CodexTaskRepository(codexHome: directory)

        let originalData = try Data(contentsOf: stateURL)
        let marker = isoDate("2026-08-14T07:00:00.000Z")
        try await repository.setTaskUnread("target", unread: true, observedMarker: marker)
        #expect(try await repository.loadUnreadTaskIDs() == ["existing"])
        #expect(try await repository.readStateOverride(for: "target")?.unread == true)
        #expect(try await repository.readStateOverride(for: "target")?.marker == marker)
        try await repository.setTaskUnread("target", unread: false, observedMarker: marker)
        #expect(try await repository.loadUnreadTaskIDs() == ["existing"])
        #expect(try await repository.readStateOverride(for: "target")?.unread == false)
        #expect(try Data(contentsOf: stateURL) == originalData)

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        let unrelated = saved?["unrelated"] as? [String: Any]
        let persisted = saved?["electron-persisted-atom-state"] as? [String: Any]
        let byHost = persisted?["unread-thread-ids-by-host-v1"] as? [String: Any]
        #expect(unrelated?["preserved"] as? Bool == true)
        #expect(persisted?["another-key"] as? String == "keep-me")
        #expect(byHost?["remote-host"] as? [String] == ["remote"])
    }

    @Test("Task-scoped allow-all crosses a live approval when explicitly enabled")
    func liveTaskScopedAllowAll() async throws {
        guard let threadID = ProcessInfo.processInfo.environment["CODEX_TASK_MANAGER_ALLOW_ALL_TEST_THREAD_ID"],
              !threadID.isEmpty
        else { return }

        let suiteName = "CodexTaskManagerKitTests.allowAll.\(UUID().uuidString)"
        let controller = CodexTaskApprovalController(
            defaults: try #require(UserDefaults(suiteName: suiteName))
        )
        try await controller.perform(.allowAllForTask, for: threadID)
    }

    @Test("Pause interrupts a live task when explicitly enabled")
    func liveTaskPause() async throws {
        guard let threadID = ProcessInfo.processInfo.environment["CODEX_TASK_MANAGER_PAUSE_TEST_THREAD_ID"],
              !threadID.isEmpty
        else { return }
        let controller = CodexTaskApprovalController(
            defaults: try #require(UserDefaults(suiteName: "CodexTaskManagerKitTests.pause.\(UUID().uuidString)"))
        )
        try await controller.pause(threadID: threadID)
    }

    @Test("Task-scoped allow-all suppresses immediate duplicate recovery")
    func taskScopedAllowAllDebounce() {
        #expect(!CodexTaskApprovalController.shouldSuppressAllowAllRecovery(elapsed: nil))
        #expect(CodexTaskApprovalController.shouldSuppressAllowAllRecovery(elapsed: .zero))
        #expect(CodexTaskApprovalController.shouldSuppressAllowAllRecovery(elapsed: .seconds(9.999)))
        #expect(!CodexTaskApprovalController.shouldSuppressAllowAllRecovery(elapsed: .seconds(10)))
        #expect(!CodexTaskApprovalController.shouldSuppressAllowAllRecovery(elapsed: .seconds(30)))
    }

    #if CODEX_TASK_MANAGER_EXPERIMENTAL_APPROVAL_ACTIONS
    @Test("Dormant similar-command rules remain task-local and prefix-based")
    func dormantSimilarCommandMatching() {
        let taskARules = [["pwd"], ["git", "status"]]
        let taskBRules = [["swift", "test"]]
        #expect(CodexTaskApprovalController.matchesSimilarCommand(proposedPrefix: ["pwd"], storedPrefixes: taskARules))
        #expect(CodexTaskApprovalController.matchesSimilarCommand(proposedPrefix: ["pwd", "-P"], storedPrefixes: taskARules))
        #expect(CodexTaskApprovalController.matchesSimilarCommand(proposedPrefix: ["git", "status", "--short"], storedPrefixes: taskARules))
        #expect(!CodexTaskApprovalController.matchesSimilarCommand(proposedPrefix: ["git", "diff"], storedPrefixes: taskARules))
        #expect(!CodexTaskApprovalController.matchesSimilarCommand(proposedPrefix: ["pwd"], storedPrefixes: taskBRules))
    }
    #endif

    @Test("Resolved callbacks and completed turns clear only their matching pending approval")
    func approvalLifecycleResolutionMatching() {
        let requestID = JSONValue.int(42)
        let resolvedParams: [String: JSONValue] = [
            "threadId": .string("thread-a"),
            "requestId": requestID,
        ]
        #expect(CodexTaskApprovalController.lifecycleNotificationResolvesPendingApproval(
            method: "serverRequest/resolved",
            params: resolvedParams,
            pendingThreadID: "thread-a",
            pendingTurnID: "turn-a",
            pendingRequestID: requestID
        ))
        #expect(!CodexTaskApprovalController.lifecycleNotificationResolvesPendingApproval(
            method: "serverRequest/resolved",
            params: resolvedParams,
            pendingThreadID: "thread-b",
            pendingTurnID: "turn-a",
            pendingRequestID: requestID
        ))
        #expect(!CodexTaskApprovalController.lifecycleNotificationResolvesPendingApproval(
            method: "serverRequest/resolved",
            params: resolvedParams,
            pendingThreadID: "thread-a",
            pendingTurnID: "turn-a",
            pendingRequestID: .int(43)
        ))

        let completedParams: [String: JSONValue] = [
            "threadId": .string("thread-a"),
            "turn": .object(["id": .string("turn-a")]),
        ]
        #expect(CodexTaskApprovalController.lifecycleNotificationResolvesPendingApproval(
            method: "turn/completed",
            params: completedParams,
            pendingThreadID: "thread-a",
            pendingTurnID: "turn-a",
            pendingRequestID: requestID
        ))
        #expect(!CodexTaskApprovalController.lifecycleNotificationResolvesPendingApproval(
            method: "turn/completed",
            params: completedParams,
            pendingThreadID: "thread-a",
            pendingTurnID: "turn-b",
            pendingRequestID: requestID
        ))
    }

    @Test("Private Codex desktop App Server detection is exact")
    func privateDesktopAppServerDetection() {
        #expect(CodexDesktopRuntimeDetector.isPrivateDesktopAppServerCommand([
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "-c",
            "features.code_mode_host=true",
            "app-server",
            "--analytics-default-enabled",
        ]))
        #expect(!CodexDesktopRuntimeDetector.isPrivateDesktopAppServerCommand([
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "app-server",
            "daemon",
            "run",
        ]))
        #expect(CodexDesktopRuntimeDetector.isPrivateDesktopAppServerCommand([
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "app-server",
            "--listen",
            "stdio://",
        ]))
        #expect(CodexDesktopRuntimeDetector.privateDesktopAppServerIsPresent(in: """
          /usr/bin/something --flag
          /Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled
          /Users/demo/.codex/packages/standalone/current/codex app-server --remote-control --listen unix://
        """))
        #expect(CodexDesktopRuntimeDetector.privateDesktopAppServerIsPresent(in: """
          /Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://
          /Users/demo/.codex/packages/standalone/current/codex app-server --remote-control --listen unix://
        """))

        let utc = TimeZone(secondsFromGMT: 0)!
        let earliest = CodexDesktopRuntimeDetector.earliestPrivateDesktopAppServerStartDate(
            in: """
            Wed Aug 12 23:11:28 2026 /Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled
            Thu Aug 13 01:00:00 2026 /Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://
            Thu Aug 13 02:00:00 2026 /Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled
            """,
            timeZone: utc
        )
        #expect(earliest == isoDate("2026-08-12T23:11:28.000Z"))
    }

    @Test("A desktop rollout from a previous App Server cannot remain running")
    func priorDesktopRuntimeCannotRemainRunning() {
        let rolloutDate = isoDate("2026-07-17T13:17:57.000Z")
        let laterRuntime = isoDate("2026-08-12T23:11:28.000Z")
        let earlierRuntime = isoDate("2026-07-17T12:00:00.000Z")

        #expect(CodexTaskRepository.isStaleDesktopRunningState(
            rowIsDesktopManaged: true,
            rolloutLatestRecordDate: rolloutDate,
            desktopRuntimeStartDate: laterRuntime
        ))
        #expect(!CodexTaskRepository.isStaleDesktopRunningState(
            rowIsDesktopManaged: true,
            rolloutLatestRecordDate: rolloutDate,
            desktopRuntimeStartDate: earlierRuntime
        ))
        #expect(!CodexTaskRepository.isStaleDesktopRunningState(
            rowIsDesktopManaged: false,
            rolloutLatestRecordDate: rolloutDate,
            desktopRuntimeStartDate: laterRuntime
        ))
        #expect(!CodexTaskRepository.isStaleDesktopRunningState(
            rowIsDesktopManaged: true,
            rolloutLatestRecordDate: nil,
            desktopRuntimeStartDate: laterRuntime
        ))
    }

    @Test("Current and legacy desktop App Server commands are recognized")
    func desktopAppServerCommandRecognition() {
        let executable = "/Applications/ChatGPT.app/Contents/Resources/codex"
        #expect(CodexDesktopRuntimeDetector.isPrivateDesktopAppServerCommand([
            executable, "app-server", "--listen", "stdio://",
        ]))
        #expect(CodexDesktopRuntimeDetector.isPrivateDesktopAppServerCommand([
            executable, "-c", "features.code_mode_host=true", "app-server", "--analytics-default-enabled",
        ]))
        #expect(!CodexDesktopRuntimeDetector.isPrivateDesktopAppServerCommand([
            executable, "exec", "--json",
        ]))
        #expect(!CodexDesktopRuntimeDetector.isPrivateDesktopAppServerCommand([
            "/Users/example/codex", "app-server", "--listen", "stdio://",
        ]))
    }

    @Test("Repository clears only running rollouts from an older desktop runtime")
    func repositoryDesktopRuntimeBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rollout = directory.appending(path: "sessions/rollout.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write([
            line(timestamp: "2026-07-17T13:17:57.000Z", type: "event_msg", payload: ["type": "task_started"]),
            line(timestamp: "2026-07-17T13:18:00.000Z", type: "event_msg", payload: [
                "type": "agent_message",
                "message": "This interrupted turn never wrote a terminal event.",
            ]),
        ], to: rollout)
        try makeCatalog(at: directory.appending(path: "state_5.sqlite"), rolloutPath: rollout.path)
        try writeUnreadState(to: directory.appending(path: ".codex-global-state.json"))

        let newerRuntimeDate = isoDate("2026-08-12T23:11:28.000Z")
        let newerRuntimeRepository = CodexTaskRepository(
            codexHome: directory,
            desktopRuntimeStartDateProvider: { newerRuntimeDate }
        )
        let staleTask = try #require(try await newerRuntimeRepository.loadTasks().first)
        #expect(staleTask.state == .idle)

        let olderRuntimeDate = isoDate("2026-07-17T12:00:00.000Z")
        let olderRuntimeRepository = CodexTaskRepository(
            codexHome: directory,
            desktopRuntimeStartDateProvider: { olderRuntimeDate }
        )
        let currentTask = try #require(try await olderRuntimeRepository.loadTasks().first)
        #expect(currentTask.state == .running)
    }

    @Test("Legacy desktop provenance is recovered from rollout metadata")
    func repositoryLegacyDesktopRuntimeBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rollout = directory.appending(path: "sessions/rollout.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write([
            line(timestamp: "2026-07-17T13:17:56.000Z", type: "session_meta", payload: [
                "originator": "Codex Desktop",
            ]),
            line(timestamp: "2026-07-17T13:17:57.000Z", type: "event_msg", payload: ["type": "task_started"]),
            line(timestamp: "2026-07-17T13:18:00.000Z", type: "event_msg", payload: [
                "type": "agent_message",
                "message": "This legacy desktop turn omitted its terminal event.",
            ]),
        ], to: rollout)
        try makeCatalog(
            at: directory.appending(path: "state_5.sqlite"),
            rolloutPath: rollout.path,
            threadSource: ""
        )
        try writeUnreadState(to: directory.appending(path: ".codex-global-state.json"))

        let repository = CodexTaskRepository(
            codexHome: directory,
            desktopRuntimeStartDateProvider: { self.isoDate("2026-08-12T23:11:28.000Z") }
        )
        let task = try #require(try await repository.loadTasks().first)
        #expect(task.isDesktopManaged)
        #expect(task.state == .idle)
    }

    @Test("Non-desktop running rollouts reconcile against live App Server state")
    @MainActor
    func nonDesktopRunningLiveReconciliation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rollout = directory.appending(path: "sessions/rollout.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write([
            line(timestamp: "2025-12-02T06:15:43.000Z", type: "session_meta", payload: [
                "originator": "codex_vscode",
            ]),
            line(timestamp: "2025-12-02T06:15:44.000Z", type: "event_msg", payload: ["type": "task_started"]),
            line(timestamp: "2025-12-02T06:16:37.000Z", type: "event_msg", payload: [
                "type": "agent_message",
                "message": "Legacy extension response without a terminal event.",
            ]),
        ], to: rollout)
        try makeCatalog(
            at: directory.appending(path: "state_5.sqlite"),
            rolloutPath: rollout.path,
            threadSource: ""
        )
        try writeUnreadState(to: directory.appending(path: ".codex-global-state.json"))

        let threadID = "00000000-0000-0000-0000-000000000001"
        let controller = RecordingApprovalController(liveStates: [threadID: .idle])
        let model = TaskManagerModel(
            repository: CodexTaskRepository(
                codexHome: directory,
                desktopRuntimeStartDateProvider: { nil }
            ),
            defaults: try #require(UserDefaults(suiteName: "CodexTaskManagerKitTests.live-running.\(UUID().uuidString)")),
            approvalController: controller
        )
        await model.refresh()

        #expect(model.tasks.first?.state == .idle)
        #expect(await controller.recordedLiveStateRequestIDs() == [threadID])
    }

    @Test("Background refresh is not gated by companion startup")
    @MainActor
    func backgroundRefreshDoesNotWaitForCompanion() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rollout = directory.appending(path: "sessions/rollout.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write([
            line(timestamp: "2026-08-21T09:00:00.000Z", type: "event_msg", payload: ["type": "task_started"]),
            line(timestamp: "2026-08-21T09:00:01.000Z", type: "event_msg", payload: ["type": "task_complete"]),
        ], to: rollout)
        try makeCatalog(at: directory.appending(path: "state_5.sqlite"), rolloutPath: rollout.path)
        try writeUnreadState(to: directory.appending(path: ".codex-global-state.json"))

        let model = TaskManagerModel(
            repository: CodexTaskRepository(codexHome: directory, desktopRuntimeStartDateProvider: { nil }),
            defaults: try #require(UserDefaults(suiteName: "CodexTaskManagerKitTests.background-refresh.\(UUID().uuidString)")),
            approvalController: DelayedStartApprovalController(delay: .seconds(2))
        )
        model.startBackgroundRefresh()
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.tasks.count == 1)
        #expect(model.tasks.first?.state != .running)
        model.stopBackgroundRefreshForTesting()
    }

    @Test("Companion requests have a bounded timeout and retry cooldown")
    func companionTimeoutBounds() {
        #expect(CodexTaskApprovalController.companionRequestTimeout <= .seconds(5))
        #expect(CodexTaskApprovalController.companionStartRetryDelay <= .seconds(5))
    }

    private func fixtures() -> [CodexTask] {
        [
            makeTask(1, project: "/A", state: .running),
            makeTask(2, project: "/B", state: .needsResponse),
            makeTask(3, project: "/A", state: .idle),
            makeTask(4, project: "/C", state: .complete),
            makeTask(5, project: "/A", state: .idle),
        ]
    }

    private func disclosureFixtures() -> [CodexTask] {
        [
            makeTask(1, project: "/A", state: .idle),
            makeTask(2, project: "/B", state: .idle),
            makeTask(3, project: "/A", state: .idle),
            makeTask(4, project: "/B", state: .idle),
            makeTask(5, project: "/A", state: .idle),
            makeTask(6, project: "/B", state: .idle),
            makeTask(7, project: "/A", state: .idle),
            makeTask(8, project: "/B", state: .idle),
            makeTask(9, project: "/A", state: .idle),
            makeTask(10, project: "/B", state: .idle),
            makeTask(11, project: "/A", state: .idle),
            makeTask(12, project: "/C", state: .idle),
        ]
    }

    private func makeTask(
        _ index: Int,
        project: String,
        state: TaskAttentionState,
        pinned: Bool = false
    ) -> CodexTask {
        CodexTask(
            id: String(format: "00000000-0000-0000-0000-%012d", index),
            title: "Task \(index)",
            projectPath: project,
            latestAssistantMessage: "Message \(index)",
            recency: Date(timeIntervalSince1970: Double(100 - index)),
            isPinned: pinned,
            state: state
        )
    }

    private func line(timestamp: String? = nil, type: String, payload: [String: Any]) throws -> String {
        var root: [String: Any] = ["type": type, "payload": payload]
        root["timestamp"] = timestamp
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func isoDate(_ value: String) -> Date {
        try! Date(value, strategy: .iso8601)
    }

    private func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func appendText(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func makeCatalog(at url: URL, rolloutPath: String, threadSource: String = "user") throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        let escapedPath = rolloutPath.replacingOccurrences(of: "'", with: "''")
        let escapedThreadSource = threadSource.replacingOccurrences(of: "'", with: "''")
        let sql = """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            name TEXT,
            title TEXT,
            preview TEXT,
            cwd TEXT,
            recency_at_ms INTEGER,
            recency_at INTEGER,
            rollout_path TEXT,
            is_pinned INTEGER,
            archived INTEGER,
            thread_source TEXT
        );
        INSERT INTO threads VALUES (
            '00000000-0000-0000-0000-000000000001',
            'Fixture task',
            'Fixture task',
            'Fixture preview',
            '/Fixture',
            1000,
            1,
            '\(escapedPath)',
            0,
            0,
            '\(escapedThreadSource)'
        );
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func writeUnreadState(to url: URL, taskIDs: [String] = []) throws {
        let root: [String: Any] = [
            "electron-persisted-atom-state": [
                "unread-thread-ids-by-host-v1": ["local": taskIDs],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try data.write(to: url)
    }
}
