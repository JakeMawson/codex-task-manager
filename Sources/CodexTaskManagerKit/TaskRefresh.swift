import Foundation

public struct TaskRefreshHint: Equatable, Sendable {
    public var requiresFullReconciliation: Bool
    public var catalogChanged: Bool
    public var titleIndexChanged: Bool
    public var unreadStateChanged: Bool
    public var changedRolloutPaths: Set<String>

    public init(
        requiresFullReconciliation: Bool = false,
        catalogChanged: Bool = false,
        titleIndexChanged: Bool = false,
        unreadStateChanged: Bool = false,
        changedRolloutPaths: Set<String> = []
    ) {
        self.requiresFullReconciliation = requiresFullReconciliation
        self.catalogChanged = catalogChanged
        self.titleIndexChanged = titleIndexChanged
        self.unreadStateChanged = unreadStateChanged
        self.changedRolloutPaths = changedRolloutPaths
    }

    public static let none = TaskRefreshHint()
    public static let reconciliation = TaskRefreshHint(requiresFullReconciliation: true)

    public var isEmpty: Bool {
        !requiresFullReconciliation
            && !catalogChanged
            && !titleIndexChanged
            && !unreadStateChanged
            && changedRolloutPaths.isEmpty
    }

    public mutating func merge(_ other: TaskRefreshHint) {
        requiresFullReconciliation = requiresFullReconciliation || other.requiresFullReconciliation
        catalogChanged = catalogChanged || other.catalogChanged
        titleIndexChanged = titleIndexChanged || other.titleIndexChanged
        unreadStateChanged = unreadStateChanged || other.unreadStateChanged
        changedRolloutPaths.formUnion(other.changedRolloutPaths)
    }
}

public struct CodexTaskLoadMetrics: Equatable, Sendable {
    public let taskCount: Int
    public let catalogReloaded: Bool
    public let titleIndexReloaded: Bool
    public let unreadStateReloaded: Bool
    public let rolloutMetadataChecks: Int
    public let rolloutScans: Int
    public let rolloutIncrementalScans: Int
    public let rolloutFullScans: Int
    public let rolloutCacheHits: Int

    public init(
        taskCount: Int = 0,
        catalogReloaded: Bool = false,
        titleIndexReloaded: Bool = false,
        unreadStateReloaded: Bool = false,
        rolloutMetadataChecks: Int = 0,
        rolloutScans: Int = 0,
        rolloutIncrementalScans: Int = 0,
        rolloutFullScans: Int = 0,
        rolloutCacheHits: Int = 0
    ) {
        self.taskCount = taskCount
        self.catalogReloaded = catalogReloaded
        self.titleIndexReloaded = titleIndexReloaded
        self.unreadStateReloaded = unreadStateReloaded
        self.rolloutMetadataChecks = rolloutMetadataChecks
        self.rolloutScans = rolloutScans
        self.rolloutIncrementalScans = rolloutIncrementalScans
        self.rolloutFullScans = rolloutFullScans
        self.rolloutCacheHits = rolloutCacheHits
    }
}
