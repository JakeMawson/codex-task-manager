import Foundation

public enum TaskAttentionState: String, Codable, CaseIterable, Sendable {
    case needsApproval
    case needsResponse
    case running
    case complete
    case idle

    public var priorityRank: Int {
        switch self {
        case .needsApproval: 0
        case .needsResponse: 1
        case .complete: 2
        case .running: 3
        case .idle: 4
        }
    }
}

public enum TaskStatusFilter: String, Codable, CaseIterable, Sendable {
    case all
    case needs
    case complete
    case running
    case read

    public var label: String {
        switch self {
        case .all: "All tasks"
        case .needs: "Needs input"
        case .complete: "Complete"
        case .running: "Running"
        case .read: "Read"
        }
    }

    public var isSelectableCategory: Bool {
        self != .all
    }

    public static var selectableCases: [TaskStatusFilter] {
        [.needs, .running, .complete, .read]
    }

    public static var attentionCases: [TaskStatusFilter] {
        [.needs]
    }

    public init?(state: TaskAttentionState) {
        switch state {
        case .needsApproval, .needsResponse: self = .needs
        case .running: self = .running
        case .complete: self = .complete
        case .idle: self = .read
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "all": self = .all
        case "needs", "needsApproval", "needsResponse": self = .needs
        case "complete": self = .complete
        case "running": self = .running
        case "read": self = .read
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown task status filter"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TaskSortMode: String, Codable, CaseIterable, Sendable {
    case recent
    case priority
    case alphabetical

    public var label: String {
        switch self {
        case .recent: "Recent"
        case .priority: "Priority"
        case .alphabetical: "Projects A–Z"
        }
    }

    public var forcesGrouping: Bool { self == .alphabetical }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "recent", "customPinned": self = .recent
        case "priority": self = .priority
        case "alphabetical": self = .alphabetical
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown task sort mode"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CodexTask: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let projectPath: String
    public let latestAssistantMessage: String
    public let recency: Date
    public let isPinned: Bool
    public let isDesktopManaged: Bool
    public let state: TaskAttentionState

    public init(
        id: String,
        title: String,
        projectPath: String,
        latestAssistantMessage: String,
        recency: Date,
        isPinned: Bool,
        isDesktopManaged: Bool = true,
        state: TaskAttentionState
    ) {
        self.id = id
        self.title = title
        self.projectPath = projectPath
        self.latestAssistantMessage = latestAssistantMessage
        self.recency = recency
        self.isPinned = isPinned
        self.isDesktopManaged = isDesktopManaged
        self.state = state
    }

    public var projectName: String {
        let standardized = NSString(string: projectPath).standardizingPath
        if standardized == NSHomeDirectory() { return "Home" }
        let component = URL(fileURLWithPath: standardized).lastPathComponent
        return component.isEmpty ? standardized : component
    }

    public var searchableText: String {
        "\(title) \(projectName) \(projectPath) \(latestAssistantMessage)"
    }

    public func replacingState(_ state: TaskAttentionState) -> CodexTask {
        CodexTask(
            id: id,
            title: title,
            projectPath: projectPath,
            latestAssistantMessage: latestAssistantMessage,
            recency: recency,
            isPinned: isPinned,
            isDesktopManaged: isDesktopManaged,
            state: state
        )
    }

    public func replacingPinned(_ isPinned: Bool) -> CodexTask {
        CodexTask(
            id: id,
            title: title,
            projectPath: projectPath,
            latestAssistantMessage: latestAssistantMessage,
            recency: recency,
            isPinned: isPinned,
            isDesktopManaged: isDesktopManaged,
            state: state
        )
    }
}

public struct TaskSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let projectPath: String?
    public let tasks: [CodexTask]
    public let totalCount: Int
    public let isPinnedSection: Bool

    public init(
        projectPath: String?,
        tasks: [CodexTask],
        totalCount: Int? = nil,
        isPinnedSection: Bool = false
    ) {
        self.projectPath = projectPath
        self.tasks = tasks
        self.totalCount = totalCount ?? tasks.count
        self.isPinnedSection = isPinnedSection
        self.id = isPinnedSection ? "__pinned__" : (projectPath ?? "__ungrouped__")
    }

    public var isLimited: Bool { tasks.count < totalCount }
}

public struct TaskListPresentation: Equatable, Sendable {
    public let sections: [TaskSection]
    public let totalCount: Int
    public let isLimited: Bool

    public init(sections: [TaskSection], totalCount: Int) {
        self.sections = sections
        self.totalCount = totalCount
        self.isLimited = sections.contains(where: \.isLimited)
    }

    public var displayedCount: Int {
        sections.reduce(0) { $0 + $1.tasks.count }
    }
}

public struct RolloutSnapshot: Equatable, Sendable {
    public let latestAssistantMessage: String?
    public let latestAssistantMessageDate: Date?
    public let latestUserMessageDate: Date?
    public let attentionRequestDate: Date?
    public let completionDate: Date?
    public let latestRecordDate: Date?
    public let isDesktopManaged: Bool
    public let isRunning: Bool
    public let needsApproval: Bool
    public let needsResponse: Bool

    public init(
        latestAssistantMessage: String?,
        latestAssistantMessageDate: Date? = nil,
        latestUserMessageDate: Date? = nil,
        attentionRequestDate: Date? = nil,
        completionDate: Date? = nil,
        latestRecordDate: Date? = nil,
        isDesktopManaged: Bool = false,
        isRunning: Bool,
        needsApproval: Bool = false,
        needsResponse: Bool
    ) {
        self.latestAssistantMessage = latestAssistantMessage
        self.latestAssistantMessageDate = latestAssistantMessageDate
        self.latestUserMessageDate = latestUserMessageDate
        self.attentionRequestDate = attentionRequestDate
        self.completionDate = completionDate
        self.latestRecordDate = latestRecordDate
        self.isDesktopManaged = isDesktopManaged
        self.isRunning = isRunning
        self.needsApproval = needsApproval
        self.needsResponse = needsResponse
    }

    public func recencyDate(for state: TaskAttentionState, fallback: Date) -> Date {
        switch state {
        case .needsApproval, .needsResponse:
            attentionRequestDate ?? fallback
        case .running:
            latestUserMessageDate ?? fallback
        case .complete:
            completionDate ?? fallback
        case .idle:
            latestAssistantMessageDate ?? fallback
        }
    }

    public func readStateMarker(fallback: Date) -> Date {
        [completionDate, latestAssistantMessageDate].compactMap { $0 }.max() ?? fallback
    }
}
