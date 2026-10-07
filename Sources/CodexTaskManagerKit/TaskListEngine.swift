import Foundation

public enum TaskListEngine {
    public static func presentation(
        tasks: [CodexTask],
        filter: Set<TaskStatusFilter>,
        sort: TaskSortMode,
        searchText: String,
        groupByProject: Bool,
        customProjectOrder: [String],
        priorityFirstWithinProjects: Bool = false,
        pinnedProjectPaths: Set<String> = [],
        pinnedProjectOrder: [String] = [],
        pinnedTaskOrder: [String] = [],
        expandedProjectPaths: Set<String>,
        collapsedLimit: Int = 4
    ) -> TaskListPresentation {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let promotesPins = query.isEmpty
        let activeFilters = Set(filter.filter(\.isSelectableCategory))
        var matches = tasks.filter { task in
            matchesFilter(task, filter: activeFilters)
                && (query.isEmpty || task.searchableText.localizedCaseInsensitiveContains(query))
        }

        matches = sorted(
            matches,
            mode: sort,
            customProjectOrder: customProjectOrder,
            pinnedTaskOrder: pinnedTaskOrder,
            promotesPins: promotesPins
        )

        let shouldGroup = groupByProject || sort.forcesGrouping
        let pinnedMatches = promotesPins ? matches.filter(\.isPinned) : []
        let matchingPinnedProjectPaths = promotesPins
            ? pinnedProjectPaths.intersection(matches.map(\.projectPath))
            : []
        let standalonePinnedMatches = pinnedMatches.filter {
            !matchingPinnedProjectPaths.contains($0.projectPath)
        }
        let projectEligibleMatches = promotesPins
            ? matches.filter { !$0.isPinned || matchingPinnedProjectPaths.contains($0.projectPath) }
            : matches
        let baseProjectOrder = projectOrder(
            for: projectEligibleMatches,
            mode: sort,
            customProjectOrder: customProjectOrder,
            pinnedProjectPaths: matchingPinnedProjectPaths,
            pinnedProjectOrder: pinnedProjectOrder
        )
        let fullSections: [TaskSection]
        if shouldGroup {
            let pinnedSection = standalonePinnedMatches.isEmpty
                ? []
                : [TaskSection(projectPath: nil, tasks: standalonePinnedMatches, isPinnedSection: true)]
            fullSections = pinnedSection + grouped(
                projectEligibleMatches,
                baseOrder: baseProjectOrder,
                priorityFirst: priorityFirstWithinProjects && groupByProject,
                promotesPins: promotesPins
            )
        } else {
            let taskPinnedSection = standalonePinnedMatches.isEmpty
                ? []
                : [TaskSection(projectPath: nil, tasks: standalonePinnedMatches, isPinnedSection: true)]
            let projectPinnedTasks = projectEligibleMatches.filter {
                matchingPinnedProjectPaths.contains($0.projectPath)
            }
            let projectPinnedSections = grouped(projectPinnedTasks, baseOrder: baseProjectOrder)
            let ordinaryTasks = projectEligibleMatches.filter {
                !matchingPinnedProjectPaths.contains($0.projectPath)
            }
            let ordinarySection = ordinaryTasks.isEmpty ? [] : [TaskSection(projectPath: nil, tasks: ordinaryTasks)]
            fullSections = taskPinnedSection + projectPinnedSections + ordinarySection
        }
        let shouldLimitProjects = activeFilters.isEmpty && query.isEmpty && fullSections.contains { $0.projectPath != nil }
        let sections = shouldLimitProjects
            ? limitedByProject(
                fullSections,
                expandedProjectPaths: expandedProjectPaths,
                collapsedLimit: collapsedLimit
            )
            : fullSections

        return TaskListPresentation(
            sections: sections,
            totalCount: matches.count
        )
    }

    public static func presentation(
        tasks: [CodexTask],
        filter: TaskStatusFilter,
        sort: TaskSortMode,
        searchText: String,
        groupByProject: Bool,
        customProjectOrder: [String],
        priorityFirstWithinProjects: Bool = false,
        pinnedProjectPaths: Set<String> = [],
        pinnedProjectOrder: [String] = [],
        pinnedTaskOrder: [String] = [],
        expandedProjectPaths: Set<String>,
        collapsedLimit: Int = 4
    ) -> TaskListPresentation {
        presentation(
            tasks: tasks,
            filter: filter.isSelectableCategory ? [filter] : [],
            sort: sort,
            searchText: searchText,
            groupByProject: groupByProject,
            customProjectOrder: customProjectOrder,
            priorityFirstWithinProjects: priorityFirstWithinProjects,
            pinnedProjectPaths: pinnedProjectPaths,
            pinnedProjectOrder: pinnedProjectOrder,
            pinnedTaskOrder: pinnedTaskOrder,
            expandedProjectPaths: expandedProjectPaths,
            collapsedLimit: collapsedLimit
        )
    }

    public static func matchesFilter(_ task: CodexTask, filter: Set<TaskStatusFilter>) -> Bool {
        let activeFilters = Set(filter.filter(\.isSelectableCategory))
        guard !activeFilters.isEmpty else { return true }
        guard let taskFilter = TaskStatusFilter(state: task.state) else { return false }
        return activeFilters.contains(taskFilter)
    }

    public static func sorted(
        _ tasks: [CodexTask],
        mode: TaskSortMode,
        customProjectOrder: [String],
        pinnedTaskOrder: [String] = [],
        promotesPins: Bool = true
    ) -> [CodexTask] {
        let pinPositions = Dictionary(uniqueKeysWithValues: pinnedTaskOrder.enumerated().map { ($1, $0) })
        let baseSorted: [CodexTask] = switch mode {
        case .recent:
            tasks.sorted(by: recencyThenID)

        case .priority:
            tasks.sorted { lhs, rhs in
                if lhs.state.priorityRank != rhs.state.priorityRank {
                    return lhs.state.priorityRank < rhs.state.priorityRank
                }
                return recencyThenID(lhs, rhs)
            }

        case .alphabetical:
            tasks.sorted { lhs, rhs in
                let projectCompare = lhs.projectName.localizedStandardCompare(rhs.projectName)
                if projectCompare != .orderedSame { return projectCompare == .orderedAscending }
                let titleCompare = lhs.title.localizedStandardCompare(rhs.title)
                if titleCompare != .orderedSame { return titleCompare == .orderedAscending }
                return lhs.id < rhs.id
            }
        }
        guard promotesPins else { return baseSorted }
        let fallbackPinPositions = Dictionary(uniqueKeysWithValues: baseSorted.enumerated().map { ($1.id, $0) })
        return baseSorted.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            guard lhs.isPinned else {
                return (fallbackPinPositions[lhs.id] ?? .max) < (fallbackPinPositions[rhs.id] ?? .max)
            }
            let left = pinPositions[lhs.id] ?? (pinnedTaskOrder.count + (fallbackPinPositions[lhs.id] ?? .max))
            let right = pinPositions[rhs.id] ?? (pinnedTaskOrder.count + (fallbackPinPositions[rhs.id] ?? .max))
            return left != right ? left < right : lhs.id < rhs.id
        }
    }

    public static func grouped(
        _ tasks: [CodexTask],
        baseOrder: [String],
        priorityFirst: Bool = false,
        promotesPins: Bool = true
    ) -> [TaskSection] {
        var buckets: [String: [CodexTask]] = [:]
        for task in tasks { buckets[task.projectPath, default: []].append(task) }

        var seen = Set<String>()
        var projectOrder: [String] = []
        for project in baseOrder where buckets[project] != nil && seen.insert(project).inserted {
            projectOrder.append(project)
        }
        for task in tasks where seen.insert(task.projectPath).inserted {
            projectOrder.append(task.projectPath)
        }

        return projectOrder.compactMap { project in
            guard let tasks = buckets[project], !tasks.isEmpty else { return nil }
            let orderedTasks = priorityFirst
                ? priorityFirstWithinProject(tasks, promotesPins: promotesPins)
                : tasks
            return TaskSection(projectPath: project, tasks: orderedTasks)
        }
    }

    public static func firstProjectOrder(_ tasks: [CodexTask]) -> [String] {
        var seen = Set<String>()
        return tasks.compactMap { seen.insert($0.projectPath).inserted ? $0.projectPath : nil }
    }

    private static func projectOrder(
        for tasks: [CodexTask],
        mode: TaskSortMode,
        customProjectOrder: [String],
        pinnedProjectPaths: Set<String>,
        pinnedProjectOrder: [String]
    ) -> [String] {
        let encountered = firstProjectOrder(tasks)
        let known = Set(encountered)
        let base: [String]
        if mode == .alphabetical {
            base = encountered.sorted {
                URL(fileURLWithPath: $0).lastPathComponent.localizedStandardCompare(
                    URL(fileURLWithPath: $1).lastPathComponent
                ) == .orderedAscending
            }
        } else {
            base = customProjectOrder.filter(known.contains)
                + encountered.filter { !customProjectOrder.contains($0) }
        }
        let pinPositions = Dictionary(uniqueKeysWithValues: pinnedProjectOrder.enumerated().map { ($1, $0) })
        let fallbackPositions = Dictionary(uniqueKeysWithValues: base.enumerated().map { ($1, $0) })
        let pinned = base.filter(pinnedProjectPaths.contains).sorted { lhs, rhs in
            let left = pinPositions[lhs] ?? (pinnedProjectOrder.count + (fallbackPositions[lhs] ?? .max))
            let right = pinPositions[rhs] ?? (pinnedProjectOrder.count + (fallbackPositions[rhs] ?? .max))
            return left != right ? left < right : lhs < rhs
        }
        return pinned
            + base.filter { !pinnedProjectPaths.contains($0) }
    }

    private static func priorityFirstWithinProject(
        _ tasks: [CodexTask],
        promotesPins: Bool
    ) -> [CodexTask] {
        let basePositions = Dictionary(uniqueKeysWithValues: tasks.enumerated().map { ($1.id, $0) })
        return tasks.sorted { lhs, rhs in
            if promotesPins && lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.state.priorityRank != rhs.state.priorityRank {
                return lhs.state.priorityRank < rhs.state.priorityRank
            }
            return (basePositions[lhs.id] ?? .max) < (basePositions[rhs.id] ?? .max)
        }
    }

    private static func limitedByProject(
        _ sections: [TaskSection],
        expandedProjectPaths: Set<String>,
        collapsedLimit: Int
    ) -> [TaskSection] {
        sections.map { section in
            guard
                let projectPath = section.projectPath,
                section.tasks.count > collapsedLimit,
                !expandedProjectPaths.contains(projectPath)
            else { return section }

            return TaskSection(
                projectPath: projectPath,
                tasks: Array(section.tasks.prefix(collapsedLimit)),
                totalCount: section.tasks.count
            )
        }
    }

    private static func recencyThenID(_ lhs: CodexTask, _ rhs: CodexTask) -> Bool {
        if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
        return lhs.id > rhs.id
    }
}

public enum CodexDeepLink {
    public static func url(for taskID: String) -> URL? {
        guard UUID(uuidString: taskID) != nil, taskID.count == 36 else { return nil }
        return URL(string: "codex://threads/\(taskID)")
    }
}
