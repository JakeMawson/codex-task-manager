import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class TaskManagerModel {
    static let reconciliationInterval: Duration = .seconds(30)
    static let observerFallbackPollingInterval: Duration = .seconds(2.5)

    private struct Preferences: Codable {
        private static let currentStatusFilterSchemaVersion = 3

        var selectedStatusFilters: Set<TaskStatusFilter>
        var statusFilterSchemaVersion: Int
        var sort: TaskSortMode
        var groupByProject: Bool
        var priorityFirstWithinProjects: Bool
        var showProjectNames: Bool
        var customProjectOrder: [String]
        var collapsedProjectPaths: Set<String>
        var pinnedProjectPaths: Set<String>
        var pinnedProjectOrder: [String]
        var pinnedTaskOrder: [String]
        var pinOverrides: [String: Bool]

        private enum CodingKeys: String, CodingKey {
            case selectedStatusFilters
            case statusFilterSchemaVersion
            case filter
            case sort
            case groupByProject
            case priorityFirstWithinProjects
            case showProjectNames
            case customProjectOrder
            case collapsedProjectPaths
            case pinnedProjectPaths
            case pinnedProjectOrder
            case pinnedTaskOrder
            case pinOverrides
        }

        init(
            selectedStatusFilters: Set<TaskStatusFilter> = [],
            statusFilterSchemaVersion: Int = currentStatusFilterSchemaVersion,
            sort: TaskSortMode = .recent,
            groupByProject: Bool = true,
            priorityFirstWithinProjects: Bool = false,
            showProjectNames: Bool = true,
            customProjectOrder: [String] = [],
            collapsedProjectPaths: Set<String> = [],
            pinnedProjectPaths: Set<String> = [],
            pinnedProjectOrder: [String] = [],
            pinnedTaskOrder: [String] = [],
            pinOverrides: [String: Bool] = [:]
        ) {
            self.selectedStatusFilters = Set(selectedStatusFilters.filter(\.isSelectableCategory))
            self.statusFilterSchemaVersion = statusFilterSchemaVersion
            self.sort = sort
            self.groupByProject = groupByProject
            self.priorityFirstWithinProjects = priorityFirstWithinProjects
            self.showProjectNames = showProjectNames
            self.customProjectOrder = customProjectOrder
            self.collapsedProjectPaths = collapsedProjectPaths
            self.pinnedProjectPaths = pinnedProjectPaths
            self.pinnedProjectOrder = pinnedProjectOrder
            self.pinnedTaskOrder = pinnedTaskOrder
            self.pinOverrides = pinOverrides
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let savedSelection = try container.decodeIfPresent(Set<TaskStatusFilter>.self, forKey: .selectedStatusFilters)
            let legacyFilter = try container.decodeIfPresent(TaskStatusFilter.self, forKey: .filter)
            let rawSelection = savedSelection
                ?? legacyFilter.map { $0.isSelectableCategory ? [$0] : [] }
                ?? []
            self.init(
                selectedStatusFilters: rawSelection,
                statusFilterSchemaVersion: Self.currentStatusFilterSchemaVersion,
                sort: try container.decodeIfPresent(TaskSortMode.self, forKey: .sort) ?? .recent,
                groupByProject: try container.decodeIfPresent(Bool.self, forKey: .groupByProject) ?? true,
                priorityFirstWithinProjects: try container.decodeIfPresent(Bool.self, forKey: .priorityFirstWithinProjects) ?? false,
                showProjectNames: try container.decodeIfPresent(Bool.self, forKey: .showProjectNames) ?? true,
                customProjectOrder: try container.decodeIfPresent([String].self, forKey: .customProjectOrder) ?? [],
                collapsedProjectPaths: try container.decodeIfPresent(Set<String>.self, forKey: .collapsedProjectPaths) ?? [],
                pinnedProjectPaths: try container.decodeIfPresent(Set<String>.self, forKey: .pinnedProjectPaths) ?? [],
                pinnedProjectOrder: try container.decodeIfPresent([String].self, forKey: .pinnedProjectOrder) ?? [],
                pinnedTaskOrder: try container.decodeIfPresent([String].self, forKey: .pinnedTaskOrder) ?? [],
                pinOverrides: try container.decodeIfPresent([String: Bool].self, forKey: .pinOverrides) ?? [:]
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(selectedStatusFilters, forKey: .selectedStatusFilters)
            try container.encode(statusFilterSchemaVersion, forKey: .statusFilterSchemaVersion)
            try container.encode(sort, forKey: .sort)
            try container.encode(groupByProject, forKey: .groupByProject)
            try container.encode(priorityFirstWithinProjects, forKey: .priorityFirstWithinProjects)
            try container.encode(showProjectNames, forKey: .showProjectNames)
            try container.encode(customProjectOrder, forKey: .customProjectOrder)
            try container.encode(collapsedProjectPaths, forKey: .collapsedProjectPaths)
            try container.encode(pinnedProjectPaths, forKey: .pinnedProjectPaths)
            try container.encode(pinnedProjectOrder, forKey: .pinnedProjectOrder)
            try container.encode(pinnedTaskOrder, forKey: .pinnedTaskOrder)
            try container.encode(pinOverrides, forKey: .pinOverrides)
        }
    }

    private static let preferencesKey = "CodexTaskManager.preferences.v1"

    private let repository: CodexTaskRepository?
    private let approvalController: (any TaskApprovalControlling)?
    private let defaults: UserDefaults
    private let fixtureName: String?
    private var isRefreshing = false
    private var pendingRefreshHint = TaskRefreshHint.none
    private var refreshLoopTask: Task<Void, Never>?
    private var approvalCompanionStartTask: Task<Void, Never>?
    private var pausedStateOverrideUntil: [String: Date] = [:]
    private var pinOverrides: [String: Bool]
    private var sourcePinStates: [String: Bool] = [:]

    public var tasks: [CodexTask] = []
    public var searchText = "" {
        didSet { resetProjectDisclosure() }
    }
    public private(set) var selectedStatusFilters: Set<TaskStatusFilter> {
        didSet {
            resetProjectDisclosure()
            persistPreferences()
        }
    }
    public var sort: TaskSortMode {
        didSet {
            resetProjectDisclosure()
            persistPreferences()
        }
    }
    public var groupByProject: Bool {
        didSet {
            resetProjectDisclosure()
            persistPreferences()
        }
    }
    public var priorityFirstWithinProjects: Bool {
        didSet { persistPreferences() }
    }
    public var showProjectNames: Bool {
        didSet { persistPreferences() }
    }
    public var customProjectOrder: [String] {
        didSet { persistPreferences() }
    }
    public private(set) var collapsedProjectPaths: Set<String> {
        didSet { persistPreferences() }
    }
    public private(set) var pinnedProjectPaths: Set<String> {
        didSet { persistPreferences() }
    }
    public private(set) var pinnedProjectOrder: [String] {
        didSet { persistPreferences() }
    }
    public private(set) var pinnedTaskOrder: [String] {
        didSet { persistPreferences() }
    }
    public var expandedProjectPaths = Set<String>()
    public var isLoading = false
    public var errorMessage: String?
    public var approvalMessage: String?
    public private(set) var approvalActionsInFlight = Set<String>()
    public var lastRefresh: Date?

    public init(
        repository: CodexTaskRepository = CodexTaskRepository(),
        defaults: UserDefaults = .standard,
        fixtureName: String? = nil,
        approvalController: (any TaskApprovalControlling)? = CodexTaskApprovalController()
    ) {
        let argumentFixtureName: String?
        if CommandLine.arguments.contains("--qa-no-response") {
            argumentFixtureName = "no-response"
        } else if CommandLine.arguments.contains("--qa-fixture") {
            argumentFixtureName = "all"
        } else {
            argumentFixtureName = nil
        }
        let resolvedFixtureName = fixtureName
            ?? ProcessInfo.processInfo.environment["CODEX_TASK_MANAGER_FIXTURE"]
            ?? argumentFixtureName
        let usesCommandLineFixture = fixtureName == nil
            && ProcessInfo.processInfo.environment["CODEX_TASK_MANAGER_FIXTURE"] == nil
            && argumentFixtureName != nil
        let resolvedDefaults = usesCommandLineFixture
            ? (UserDefaults(suiteName: "com.jakemawson.codex-task-manager.qa-fixture") ?? defaults)
            : defaults
        self.defaults = resolvedDefaults
        self.fixtureName = resolvedFixtureName
        let preferences = Self.loadPreferences(defaults: resolvedDefaults)
        self.selectedStatusFilters = preferences.selectedStatusFilters
        self.sort = preferences.sort
        self.groupByProject = preferences.groupByProject
        self.priorityFirstWithinProjects = preferences.priorityFirstWithinProjects
        self.showProjectNames = preferences.showProjectNames
        self.customProjectOrder = preferences.customProjectOrder
        self.collapsedProjectPaths = preferences.collapsedProjectPaths
        self.pinnedProjectPaths = preferences.pinnedProjectPaths
        self.pinnedProjectOrder = preferences.pinnedProjectOrder
        self.pinnedTaskOrder = preferences.pinnedTaskOrder
        self.pinOverrides = preferences.pinOverrides

        if let fixtureName = resolvedFixtureName {
            self.repository = nil
            self.approvalController = nil
            let fixtureTasks = Self.fixtureTasks(named: fixtureName)
            self.sourcePinStates = Dictionary(uniqueKeysWithValues: fixtureTasks.map { ($0.id, $0.isPinned) })
            self.tasks = applyPinOverrides(to: fixtureTasks)
            reconcileProjectOrder()
            reconcilePinnedProjectOrder()
            reconcilePinnedTaskOrder()
            lastRefresh = Date()
        } else {
            self.repository = repository
            self.approvalController = approvalController
        }
    }

    public var effectiveGroupByProject: Bool {
        groupByProject || sort.forcesGrouping
    }

    public var presentation: TaskListPresentation {
        TaskListEngine.presentation(
            tasks: tasks,
            filter: selectedStatusFilters,
            sort: sort,
            searchText: searchText,
            groupByProject: groupByProject,
            customProjectOrder: customProjectOrder,
            priorityFirstWithinProjects: priorityFirstWithinProjects,
            pinnedProjectPaths: pinnedProjectPaths,
            pinnedProjectOrder: pinnedProjectOrder,
            pinnedTaskOrder: pinnedTaskOrder,
            expandedProjectPaths: expandedProjectPaths
        )
    }

    public var usesProjectDisclosure: Bool {
        selectedStatusFilters.isEmpty
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && effectiveGroupByProject
    }

    public var statusFilterLabel: String {
        switch selectedStatusFilters.count {
        case 0:
            return TaskStatusFilter.all.label
        case 1:
            return TaskStatusFilter.selectableCases.first(where: selectedStatusFilters.contains)?.label
                ?? TaskStatusFilter.all.label
        default:
            return "\(selectedStatusFilters.count) categories"
        }
    }

    public var showsOnlyNeedsAttention: Bool {
        selectedStatusFilters == [.needs]
    }

    public var attentionCount: Int {
        stateCount(.needsApproval) + stateCount(.needsResponse)
    }

    public var isAttentionFilterSelected: Bool {
        selectedStatusFilters.contains(.needs)
    }

    public var projectPaths: [String] {
        let recent = TaskListEngine.firstProjectOrder(tasks.sorted { $0.recency > $1.recency })
        let known = Set(recent)
        return customProjectOrder.filter(known.contains) + recent.filter { !customProjectOrder.contains($0) }
    }

    public func stateCount(_ state: TaskAttentionState) -> Int {
        tasks.lazy.filter { $0.state == state }.count
    }

    public func isStatusFilterSelected(_ filter: TaskStatusFilter) -> Bool {
        selectedStatusFilters.contains(filter)
    }

    public func toggleStatusFilter(_ filter: TaskStatusFilter) {
        guard filter.isSelectableCategory else {
            clearStatusFilters()
            return
        }
        if selectedStatusFilters.contains(filter) {
            selectedStatusFilters.remove(filter)
        } else {
            selectedStatusFilters.insert(filter)
        }
    }

    public func selectOnlyStatusFilter(_ filter: TaskStatusFilter) {
        guard filter.isSelectableCategory else {
            clearStatusFilters()
            return
        }
        selectedStatusFilters = [filter]
    }

    public func selectOnlyAttentionFilters() {
        selectedStatusFilters = [.needs]
    }

    public func clearStatusFilters() {
        selectedStatusFilters = []
    }

    public func refresh(silent: Bool = false) async {
        await enqueueRefresh(.reconciliation, silent: silent)
    }

    public func startBackgroundRefresh() {
        guard fixtureName == nil, refreshLoopTask == nil else { return }
        if approvalCompanionStartTask == nil {
            approvalCompanionStartTask = Task { [weak self] in
                await self?.startApprovalCompanion()
                self?.approvalCompanionStartTask = nil
            }
        }
        refreshLoopTask = Task { [weak self] in
            await self?.runRefreshLoop()
        }
    }

    func stopBackgroundRefreshForTesting() {
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
        approvalCompanionStartTask?.cancel()
        approvalCompanionStartTask = nil
    }

    private func startApprovalCompanion() async {
        guard let approvalController else { return }
        do {
            try await approvalController.start()
            approvalMessage = "CODEX APPROVAL COMPANION READY"
        } catch {
            approvalMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func runRefreshLoop() async {
        defer { refreshLoopTask = nil }

        do {
            let observer = try CodexDataChangeObserver()
            await refresh()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await hint in observer.events {
                        guard !Task.isCancelled else { break }
                        await self?.enqueueRefresh(hint, silent: true)
                    }
                }
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: Self.reconciliationInterval)
                        } catch {
                            break
                        }
                        guard !Task.isCancelled else { break }
                        await self?.enqueueRefresh(.reconciliation, silent: true)
                    }
                }
                await group.next()
                group.cancelAll()
            }
        } catch {
            await runPollingFallback()
        }
    }

    private func runPollingFallback() async {
        await refresh()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.observerFallbackPollingInterval)
            } catch {
                break
            }
            guard !Task.isCancelled else { break }
            await refresh(silent: true)
        }
    }

    private func enqueueRefresh(_ hint: TaskRefreshHint, silent: Bool) async {
        guard fixtureName == nil, let repository else { return }
        pendingRefreshHint.merge(hint)
        if !silent && tasks.isEmpty { isLoading = true }
        guard !isRefreshing else { return }

        isRefreshing = true
        defer {
            isRefreshing = false
            isLoading = false
        }

        while !pendingRefreshHint.isEmpty {
            let nextHint = pendingRefreshHint
            pendingRefreshHint = .none
            do {
                let scannedTasks = try await repository.loadTasks(refresh: nextHint)
                let reconciledTasks = await reconcileLiveApprovalStates(in: scannedTasks)
                sourcePinStates = Dictionary(uniqueKeysWithValues: reconciledTasks.map { ($0.id, $0.isPinned) })
                let refreshedTasks = applyPinOverrides(to: reconciledTasks)
                if refreshedTasks != tasks {
                    tasks = refreshedTasks
                    reconcileProjectOrder()
                    reconcilePinnedProjectOrder()
                    reconcilePinnedTaskOrder()
                }
                await approvalController?.subscribe(
                    to: refreshedTasks.lazy.filter { $0.state == .needsApproval }.map(\.id)
                )
                errorMessage = nil
                lastRefresh = Date()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reconcileLiveApprovalStates(in scannedTasks: [CodexTask]) async -> [CodexTask] {
        guard let approvalController else { return scannedTasks }
        let sharedRuntimeIsAuthoritative = await approvalController.liveApprovalStateIsAuthoritative()
        var reconciled = scannedTasks
        for index in reconciled.indices where reconciled[index].state == .needsApproval
            || (reconciled[index].state == .running && !reconciled[index].isDesktopManaged) {
            guard sharedRuntimeIsAuthoritative || !reconciled[index].isDesktopManaged else {
                continue
            }
            guard let liveState = await approvalController.liveAttentionState(for: reconciled[index].id),
                  liveState != .needsApproval
            else { continue }
            let task = reconciled[index]
            reconciled[index] = CodexTask(
                id: task.id,
                title: task.title,
                projectPath: task.projectPath,
                latestAssistantMessage: task.latestAssistantMessage,
                recency: task.recency,
                isPinned: task.isPinned,
                isDesktopManaged: task.isDesktopManaged,
                state: liveState
            )
        }
        let now = Date()
        for index in reconciled.indices {
            let task = reconciled[index]
            guard let overrideUntil = pausedStateOverrideUntil[task.id] else { continue }
            if task.state == .running, now < overrideUntil {
                reconciled[index] = task.replacingState(.complete)
            } else {
                pausedStateOverrideUntil[task.id] = nil
            }
        }
        return reconciled
    }

    public func toggleDisclosure(for projectPath: String) {
        if expandedProjectPaths.contains(projectPath) {
            expandedProjectPaths.remove(projectPath)
        } else {
            expandedProjectPaths.insert(projectPath)
        }
    }

    public func isProjectCollapsed(_ projectPath: String) -> Bool {
        collapsedProjectPaths.contains(projectPath)
    }

    public func toggleProjectCollapsed(_ projectPath: String) {
        if collapsedProjectPaths.contains(projectPath) {
            collapsedProjectPaths.remove(projectPath)
        } else {
            collapsedProjectPaths.insert(projectPath)
        }
    }

    public func open(_ task: CodexTask) {
        guard let url = CodexDeepLink.url(for: task.id) else {
            errorMessage = "This task has an invalid Codex identifier."
            return
        }
        guard NSWorkspace.shared.open(url) else {
            errorMessage = "Codex could not open this task."
            return
        }
    }

    public func performApprovalAction(_ action: TaskApprovalAction, for task: CodexTask) async {
        guard task.state == .needsApproval, let approvalController else { return }
        guard !approvalActionsInFlight.contains(task.id) else { return }
        approvalActionsInFlight.insert(task.id)
        defer { approvalActionsInFlight.remove(task.id) }

        do {
            try await approvalController.perform(action, for: task.id)
            errorMessage = nil
            #if CODEX_TASK_MANAGER_EXPERIMENTAL_APPROVAL_ACTIONS
            approvalMessage = switch action {
            case .allowOnce: "ALLOWED ONCE — \(task.title)"
            case .allowSimilarCommands: "SIMILAR COMMANDS ALLOWED — \(task.title)"
            case .allowAllForTask: "TASK-SCOPED ACCESS ENABLED — \(task.title)"
            }
            #else
            approvalMessage = "TASK-SCOPED ACCESS ENABLED — \(task.title)"
            #endif
            await refresh(silent: true)
        } catch {
            approvalMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    public func pause(_ task: CodexTask) async {
        guard task.state == .running,
              let approvalController,
              let repository
        else { return }

        do {
            try await pauseTask(task, approvalController: approvalController, repository: repository)
            errorMessage = nil
            approvalMessage = "TASK PAUSED — \(task.title)"
        } catch {
            approvalMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    public func markAsRead(_ task: CodexTask) async {
        guard task.state == .complete, let repository else { return }

        do {
            try await markTaskAsRead(task, repository: repository)
            errorMessage = nil
            approvalMessage = "MARKED AS READ — \(task.title)"
        } catch {
            approvalMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    public func projectRunningCount(_ projectPath: String) -> Int {
        eligibleTasks(in: projectPath, state: .running).count
    }

    public func projectUnreadCount(_ projectPath: String) -> Int {
        eligibleTasks(in: projectPath, state: .complete).count
    }

    public func pauseAllTasks(in projectPath: String) async {
        guard let approvalController, let repository else { return }
        let candidates = eligibleTasks(in: projectPath, state: .running)
        guard !candidates.isEmpty else { return }

        var pausedCount = 0
        var failures: [Error] = []
        for candidate in candidates {
            guard let current = tasks.first(where: { $0.id == candidate.id }),
                  current.state == .running
            else { continue }
            do {
                try await pauseTask(current, approvalController: approvalController, repository: repository)
                pausedCount += 1
            } catch {
                failures.append(error)
            }
        }
        finishProjectBatch(
            action: "PAUSED",
            successCount: pausedCount,
            attemptedCount: candidates.count,
            projectPath: projectPath,
            failures: failures
        )
    }

    public func markAllAsRead(in projectPath: String) async {
        guard let repository else { return }
        let candidates = eligibleTasks(in: projectPath, state: .complete)
        guard !candidates.isEmpty else { return }

        var readCount = 0
        var failures: [Error] = []
        for candidate in candidates {
            guard let current = tasks.first(where: { $0.id == candidate.id }),
                  current.state == .complete
            else { continue }
            do {
                try await markTaskAsRead(current, repository: repository)
                readCount += 1
            } catch {
                failures.append(error)
            }
        }
        finishProjectBatch(
            action: "MARKED AS READ",
            successCount: readCount,
            attemptedCount: candidates.count,
            projectPath: projectPath,
            failures: failures
        )
    }

    private func eligibleTasks(in projectPath: String, state: TaskAttentionState) -> [CodexTask] {
        tasks.filter {
            $0.projectPath == projectPath
                && $0.state == state
                && !approvalActionsInFlight.contains($0.id)
        }
    }

    private func pauseTask(
        _ task: CodexTask,
        approvalController: any TaskApprovalControlling,
        repository: CodexTaskRepository
    ) async throws {
        guard !approvalActionsInFlight.contains(task.id) else { return }
        approvalActionsInFlight.insert(task.id)
        defer { approvalActionsInFlight.remove(task.id) }

        try await approvalController.pause(threadID: task.id)
        try await repository.setTaskUnread(task.id, unread: true, observedMarker: task.recency)
        pausedStateOverrideUntil[task.id] = Date().addingTimeInterval(10)
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = tasks[index].replacingState(.complete)
        }
    }

    private func markTaskAsRead(_ task: CodexTask, repository: CodexTaskRepository) async throws {
        guard !approvalActionsInFlight.contains(task.id) else { return }
        approvalActionsInFlight.insert(task.id)
        defer { approvalActionsInFlight.remove(task.id) }

        try await repository.setTaskUnread(task.id, unread: false, observedMarker: task.recency)
        pausedStateOverrideUntil[task.id] = nil
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = tasks[index].replacingState(.idle)
        }
    }

    private func finishProjectBatch(
        action: String,
        successCount: Int,
        attemptedCount: Int,
        projectPath: String,
        failures: [Error]
    ) {
        let projectName = URL(fileURLWithPath: projectPath).lastPathComponent.isEmpty
            ? "Home"
            : URL(fileURLWithPath: projectPath).lastPathComponent
        approvalMessage = successCount > 0
            ? "\(action) — \(successCount) \(successCount == 1 ? "TASK" : "TASKS") IN \(projectName)"
            : nil
        if let firstFailure = failures.first {
            errorMessage = "\(failures.count) of \(attemptedCount) project tasks failed: \(firstFailure.localizedDescription)"
        } else {
            errorMessage = nil
        }
    }

    public func moveProject(from source: Int, to destination: Int) {
        var order = projectPaths
        guard order.indices.contains(source) else { return }
        let boundedDestination = min(max(destination, 0), order.count - 1)
        let project = order.remove(at: source)
        order.insert(project, at: boundedDestination)
        customProjectOrder = order
    }

    public func resetProjectOrder() {
        customProjectOrder = TaskListEngine.firstProjectOrder(tasks.sorted { $0.recency > $1.recency })
    }

    public func pinnedCount(in projectPath: String) -> Int {
        tasks.lazy.filter { $0.projectPath == projectPath && $0.isPinned }.count
    }

    public func isProjectPinned(_ projectPath: String) -> Bool {
        pinnedProjectPaths.contains(projectPath)
    }

    public func toggleProjectPin(_ projectPath: String) {
        if pinnedProjectPaths.contains(projectPath) {
            pinnedProjectPaths.remove(projectPath)
            pinnedProjectOrder.removeAll { $0 == projectPath }
            approvalMessage = "PROJECT UNPINNED — \(URL(fileURLWithPath: projectPath).lastPathComponent)"
        } else {
            pinnedProjectPaths.insert(projectPath)
            pinnedProjectOrder.removeAll { $0 == projectPath }
            pinnedProjectOrder.append(projectPath)
            approvalMessage = "PROJECT PINNED — \(URL(fileURLWithPath: projectPath).lastPathComponent)"
        }
    }

    public func movePinnedProject(_ draggedPath: String, relativeTo targetPath: String) {
        guard draggedPath != targetPath else { return }
        var order = pinnedProjectOrder
        guard let source = order.firstIndex(of: draggedPath),
              let originalTarget = order.firstIndex(of: targetPath)
        else { return }
        let moved = order.remove(at: source)
        guard let target = order.firstIndex(of: targetPath) else { return }
        let insertion = source < originalTarget ? target + 1 : target
        order.insert(moved, at: insertion)
        pinnedProjectOrder = order
    }

    public func movePinnedProject(_ projectPath: String, by offset: Int) {
        guard offset != 0,
              let source = pinnedProjectOrder.firstIndex(of: projectPath)
        else { return }
        let destination = min(max(source + offset, 0), pinnedProjectOrder.count - 1)
        guard destination != source else { return }
        var order = pinnedProjectOrder
        let moved = order.remove(at: source)
        order.insert(moved, at: destination)
        pinnedProjectOrder = order
    }

    public func togglePin(_ task: CodexTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let pinned = !tasks[index].isPinned
        if sourcePinStates[task.id] == pinned {
            pinOverrides[task.id] = nil
        } else {
            pinOverrides[task.id] = pinned
        }
        tasks[index] = tasks[index].replacingPinned(pinned)
        pinnedTaskOrder.removeAll { $0 == task.id }
        if pinned { pinnedTaskOrder.append(task.id) }
        persistPreferences()
        approvalMessage = pinned ? "TASK PINNED — \(task.title)" : "TASK UNPINNED — \(task.title)"
    }

    public func movePinnedTask(_ draggedID: String, relativeTo targetID: String) {
        guard draggedID != targetID else { return }
        var order = pinnedTaskOrder
        guard let source = order.firstIndex(of: draggedID),
              let originalTarget = order.firstIndex(of: targetID)
        else { return }
        let moved = order.remove(at: source)
        guard let target = order.firstIndex(of: targetID) else { return }
        let insertion = source < originalTarget ? target + 1 : target
        order.insert(moved, at: insertion)
        pinnedTaskOrder = order
    }

    public func movePinnedTask(_ taskID: String, by offset: Int) {
        guard offset != 0,
              let source = pinnedTaskOrder.firstIndex(of: taskID)
        else { return }
        let destination = min(max(source + offset, 0), pinnedTaskOrder.count - 1)
        guard destination != source else { return }
        var order = pinnedTaskOrder
        let moved = order.remove(at: source)
        order.insert(moved, at: destination)
        pinnedTaskOrder = order
    }

    public var emptyMessage: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No tasks match this search."
        }
        guard selectedStatusFilters.count == 1,
              let filter = selectedStatusFilters.first
        else {
            return selectedStatusFilters.isEmpty
                ? "No Codex tasks found."
                : "No tasks match the selected categories."
        }
        return switch filter {
        case .needs: "No tasks need approval or input."
        case .complete: "No completed unread tasks."
        case .running: "No tasks are running."
        case .read: "No read tasks."
        case .all: "No Codex tasks found."
        }
    }

    private func reconcileProjectOrder() {
        let current = TaskListEngine.firstProjectOrder(tasks.sorted { $0.recency > $1.recency })
        let currentSet = Set(current)
        let retained = customProjectOrder.filter(currentSet.contains)
        let additions = current.filter { !retained.contains($0) }
        let reconciled = retained + additions
        if reconciled != customProjectOrder { customProjectOrder = reconciled }
        expandedProjectPaths.formIntersection(currentSet)
    }

    private func applyPinOverrides(to tasks: [CodexTask]) -> [CodexTask] {
        tasks.map { task in
            guard let pinned = pinOverrides[task.id], pinned != task.isPinned else { return task }
            return task.replacingPinned(pinned)
        }
    }

    private func reconcilePinnedTaskOrder() {
        let current = tasks.filter(\.isPinned).map(\.id)
        let currentSet = Set(current)
        let retained = pinnedTaskOrder.filter(currentSet.contains)
        let additions = current.filter { !retained.contains($0) }
        let reconciled = retained + additions
        if reconciled != pinnedTaskOrder { pinnedTaskOrder = reconciled }
    }

    private func reconcilePinnedProjectOrder() {
        let current = projectPaths.filter(pinnedProjectPaths.contains)
        let retained = pinnedProjectOrder.filter(pinnedProjectPaths.contains)
        let additions = current.filter { !retained.contains($0) }
        let reconciled = retained + additions
        if reconciled != pinnedProjectOrder { pinnedProjectOrder = reconciled }
    }

    private func resetProjectDisclosure() {
        expandedProjectPaths.removeAll()
    }

    private func persistPreferences() {
        let preferences = Preferences(
            selectedStatusFilters: selectedStatusFilters,
            sort: sort,
            groupByProject: groupByProject,
            priorityFirstWithinProjects: priorityFirstWithinProjects,
            showProjectNames: showProjectNames,
            customProjectOrder: customProjectOrder,
            collapsedProjectPaths: collapsedProjectPaths,
            pinnedProjectPaths: pinnedProjectPaths,
            pinnedProjectOrder: pinnedProjectOrder,
            pinnedTaskOrder: pinnedTaskOrder,
            pinOverrides: pinOverrides
        )
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.preferencesKey)
    }

    private static func loadPreferences(defaults: UserDefaults) -> Preferences {
        guard
            let data = defaults.data(forKey: preferencesKey),
            let preferences = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return Preferences() }
        return preferences
    }

    private static func fixtureTasks(named name: String) -> [CodexTask] {
        let now = Date()
        var all = [
            CodexTask(
                id: "00000000-0000-0000-0000-000000000001",
                title: "Build Codex Task Manager",
                projectPath: "/Users/demo/Codex Task Manager",
                latestAssistantMessage: "Implementing the standalone task catalog and visual system now.",
                recency: now,
                isPinned: true,
                state: .running
            ),
            CodexTask(
                id: "00000000-0000-0000-0000-000000000002",
                title: "Fix custom lists page",
                projectPath: "/Users/demo/beersimpl",
                latestAssistantMessage: "Which saved list should I use for the final verification?",
                recency: now.addingTimeInterval(-90),
                isPinned: true,
                state: .needsResponse
            ),
            CodexTask(
                id: "00000000-0000-0000-0000-000000000003",
                title: "Refresh product index",
                projectPath: "/Users/demo/beersimpl",
                latestAssistantMessage: "The next bounded index command is awaiting your approval.",
                recency: now.addingTimeInterval(-45),
                isPinned: false,
                state: .needsApproval
            ),
            CodexTask(
                id: "00000000-0000-0000-0000-000000000004",
                title: "Fix Usage Studio popup layering",
                projectPath: "/Users/demo/AI Usage Bar",
                latestAssistantMessage: "The popup now opens above the menu panel and all checks pass.",
                recency: now.addingTimeInterval(-180),
                isPinned: false,
                state: .complete
            ),
            CodexTask(
                id: "00000000-0000-0000-0000-000000000005",
                title: "Review advanced search mode",
                projectPath: "/Users/demo/CircuitSimpl Learn",
                latestAssistantMessage: "Advanced mode is only selected when the toggle is enabled.",
                recency: now.addingTimeInterval(-260),
                isPinned: false,
                state: .idle
            ),
            CodexTask(
                id: "00000000-0000-0000-0000-000000000006",
                title: "Assess fuzzy beer search",
                projectPath: "/Users/demo/beersimpl",
                latestAssistantMessage: "The search uses normalized token similarity with a prefix boost.",
                recency: now.addingTimeInterval(-330),
                isPinned: false,
                state: .idle
            ),
            CodexTask(
                id: "00000000-0000-0000-0000-000000000007",
                title: "Inspect reconstruction inputs",
                projectPath: "/Users/demo/HandScanner",
                latestAssistantMessage: "The reconstruction consumes light photos and calibrated camera poses.",
                recency: now.addingTimeInterval(-420),
                isPinned: false,
                state: .complete
            ),
            CodexTask(
                id: "00000000-0000-0000-0000-000000000008",
                title: "Build AI Usage Bar",
                projectPath: "/Users/demo/AI Usage Bar",
                latestAssistantMessage: "Usage scanning is idle and ready for the next refresh.",
                recency: now.addingTimeInterval(-500),
                isPinned: false,
                state: .idle
            ),
        ]
        all.append(contentsOf: [
            CodexTask(
                id: "00000000-0000-0000-0000-000000000009",
                title: "Tune beer scan suggestions",
                projectPath: "/Users/demo/beersimpl",
                latestAssistantMessage: "Suggestion ranking now favors exact brewery and beer-name matches.",
                recency: now.addingTimeInterval(-580),
                isPinned: false,
                state: .idle
            ),
            CodexTask(
                id: "00000000-0000-0000-0000-000000000010",
                title: "Compare saved beer lists",
                projectPath: "/Users/demo/beersimpl",
                latestAssistantMessage: "The comparison keeps private and shared lists clearly separated.",
                recency: now.addingTimeInterval(-660),
                isPinned: false,
                state: .idle
            ),
            CodexTask(
                id: "00000000-0000-0000-0000-000000000011",
                title: "Verify cellar naming",
                projectPath: "/Users/demo/beersimpl",
                latestAssistantMessage: "Custom cellar and esky labels persist across the saved views.",
                recency: now.addingTimeInterval(-740),
                isPinned: false,
                state: .complete
            ),
            CodexTask(
                id: "00000000-0000-0000-0000-000000000012",
                title: "Review upload validation",
                projectPath: "/Users/demo/beersimpl",
                latestAssistantMessage: "Bottle and can uploads now share the same validation summary.",
                recency: now.addingTimeInterval(-820),
                isPinned: false,
                state: .idle
            ),
            CodexTask(
                id: "00000000-0000-0000-0000-000000000013",
                title: "Tune menu indicator",
                projectPath: "/Users/demo/AI Usage Bar",
                latestAssistantMessage: "The menu indicator keeps the current usage state readable at a glance.",
                recency: now.addingTimeInterval(-900),
                isPinned: false,
                state: .idle
            ),
            CodexTask(
                id: "00000000-0000-0000-0000-000000000014",
                title: "Add weekly limit card",
                projectPath: "/Users/demo/AI Usage Bar",
                latestAssistantMessage: "The weekly card now follows the existing compact panel hierarchy.",
                recency: now.addingTimeInterval(-980),
                isPinned: false,
                state: .idle
            ),
            CodexTask(
                id: "00000000-0000-0000-0000-000000000015",
                title: "Verify Codex usage scan",
                projectPath: "/Users/demo/AI Usage Bar",
                latestAssistantMessage: "The local scan completed without using the network fallback.",
                recency: now.addingTimeInterval(-1_060),
                isPinned: false,
                state: .complete
            ),
            CodexTask(
                id: "00000000-0000-0000-0000-000000000016",
                title: "Polish settings preview",
                projectPath: "/Users/demo/AI Usage Bar",
                latestAssistantMessage: "Settings spacing now matches the menu panel and Usage Studio.",
                recency: now.addingTimeInterval(-1_140),
                isPinned: false,
                state: .idle
            ),
        ])
        return name == "no-response" ? all.map {
            CodexTask(
                id: $0.id,
                title: $0.title,
                projectPath: $0.projectPath,
                latestAssistantMessage: $0.latestAssistantMessage,
                recency: $0.recency,
                isPinned: $0.isPinned,
                state: $0.state == .needsResponse ? .idle : $0.state
            )
        } : all
    }
}
