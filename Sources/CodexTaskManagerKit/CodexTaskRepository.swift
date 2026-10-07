import Foundation
import SQLite3

public enum CodexTaskRepositoryError: LocalizedError, Sendable {
    case missingDatabase(String)
    case openDatabase(String)
    case prepareQuery(String)
    case query(String)
    case updateGlobalState(String)

    public var errorDescription: String? {
        switch self {
        case let .missingDatabase(path): "Codex task data is not available at \(path)."
        case let .openDatabase(message): "Could not open Codex task data: \(message)"
        case let .prepareQuery(message): "Could not prepare the Codex task query: \(message)"
        case let .query(message): "Could not read Codex tasks: \(message)"
        case let .updateGlobalState(message): "Could not update Codex task read state: \(message)"
        }
    }
}

public actor CodexTaskRepository {
    private static let maximumIncrementalAppendBytes: UInt64 = 4 * 1_024 * 1_024

    private struct ReadStateOverride: Codable, Sendable {
        let unread: Bool
        let marker: Date
    }

    private struct ReadStateOverrideStore: Codable, Sendable {
        static let currentVersion = 1

        let version: Int
        var tasks: [String: ReadStateOverride]
    }

    private struct FileSignature: Equatable, Sendable {
        let size: UInt64
        let modificationDate: Date
        let systemFileNumber: UInt64?
    }

    private struct CatalogSignature: Equatable, Sendable {
        let database: FileSignature?
        let writeAheadLog: FileSignature?
        let sharedMemory: FileSignature?
    }

    private struct CatalogRow: Sendable {
        let id: String
        let title: String
        let cwd: String
        let recencyMilliseconds: Int64
        let rolloutPath: String
        let isPinned: Bool
        let isDesktopManaged: Bool
    }

    private struct CacheEntry: Sendable {
        let signature: FileSignature
        let state: RolloutScanState

        var snapshot: RolloutSnapshot { state.snapshot }
    }

    private struct ScanRequest: Sendable {
        let path: String
        let signature: FileSignature
        let previousState: RolloutScanState?
        let previousSize: UInt64?
    }

    private struct ScanResult: Sendable {
        let request: ScanRequest
        let state: RolloutScanState
        let wasIncremental: Bool
    }

    private struct SnapshotLoadResult: Sendable {
        let snapshots: [String: RolloutSnapshot]
        let metadataChecks: Int
        let scans: Int
        let incrementalScans: Int
        let fullScans: Int
        let cacheHits: Int
    }

    private let codexHome: URL
    private let readStateOverrideURL: URL
    private let maximumConcurrentScans: Int
    private let desktopRuntimeStartDateProvider: @Sendable () -> Date?
    private var rolloutCache: [String: CacheEntry] = [:]
    private var catalogCache: [CatalogRow]?
    private var cachedCatalogSignature: CatalogSignature?
    private var titleIndexCache: [String: String]?
    private var cachedTitleIndexSignature: FileSignature?
    private var unreadCache: Set<String>?
    private var cachedUnreadSignature: FileSignature?
    private var latestReadStateMarkers: [String: Date] = [:]
    private var latestMetrics = CodexTaskLoadMetrics()
    private var desktopRuntimeStartDateCache: (checkedAt: Date, startDate: Date?)?

    public init(codexHome: URL? = nil, maximumConcurrentScans: Int = 8) {
        self.init(
            codexHome: codexHome,
            maximumConcurrentScans: maximumConcurrentScans,
            desktopRuntimeStartDateProvider: {
                CodexDesktopRuntimeDetector.privateDesktopAppServerStartDate()
            }
        )
    }

    init(
        codexHome: URL?,
        maximumConcurrentScans: Int = 8,
        desktopRuntimeStartDateProvider: @escaping @Sendable () -> Date?
    ) {
        let resolvedCodexHome: URL
        if let codexHome {
            resolvedCodexHome = codexHome
        } else if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            resolvedCodexHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            resolvedCodexHome = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex", directoryHint: .isDirectory)
        }
        self.codexHome = resolvedCodexHome
        if codexHome != nil {
            self.readStateOverrideURL = resolvedCodexHome.appending(path: ".codex-task-manager-read-state.json")
        } else {
            self.readStateOverrideURL = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Codex Task Manager", directoryHint: .isDirectory)
                .appending(path: "read-state-overrides.json")
        }
        self.maximumConcurrentScans = max(maximumConcurrentScans, 1)
        self.desktopRuntimeStartDateProvider = desktopRuntimeStartDateProvider
    }

    public func loadTasks(refresh hint: TaskRefreshHint = .reconciliation) async throws -> [CodexTask] {
        let catalogResult = try loadCatalog(refresh: hint)
        let titleIndexResult = loadTitleIndex(refresh: hint)
        let unreadResult = try loadUnreadTaskIDs(refresh: hint)
        let readStateOverrides = try loadReadStateOverrides()
        let snapshotResult = await rolloutSnapshots(for: catalogResult.rows, refresh: hint)
        let desktopRuntimeStartDate = cachedDesktopRuntimeStartDate()
        var readStateMarkers: [String: Date] = [:]
        let tasks = catalogResult.rows.map { row in
            let rollout = snapshotResult.snapshots[row.rolloutPath]
                ?? RolloutSnapshot(latestAssistantMessage: nil, isRunning: false, needsApproval: false, needsResponse: false)
            let catalogRecency = Date(timeIntervalSince1970: Double(row.recencyMilliseconds) / 1_000)
            let readStateMarker = rollout.readStateMarker(fallback: catalogRecency)
            readStateMarkers[row.id] = readStateMarker
            let readStateOverride = readStateOverrides[row.id].flatMap {
                $0.marker >= readStateMarker ? $0 : nil
            }
            let isUnread = readStateOverride?.unread ?? unreadResult.ids.contains(row.id)
            let isDesktopManaged = row.isDesktopManaged || rollout.isDesktopManaged
            let state: TaskAttentionState
            if rollout.needsApproval {
                state = .needsApproval
            } else if rollout.needsResponse {
                state = .needsResponse
            } else if rollout.isRunning && !Self.isStaleDesktopRunningState(
                rowIsDesktopManaged: isDesktopManaged,
                rolloutLatestRecordDate: rollout.latestRecordDate,
                desktopRuntimeStartDate: desktopRuntimeStartDate
            ) {
                state = .running
            } else if isUnread {
                state = .complete
            } else {
                state = .idle
            }

            return CodexTask(
                id: row.id,
                title: titleIndexResult.titles[row.id] ?? row.title,
                projectPath: row.cwd,
                latestAssistantMessage: rollout.latestAssistantMessage ?? "No assistant message yet.",
                recency: rollout.recencyDate(for: state, fallback: catalogRecency),
                isPinned: row.isPinned,
                isDesktopManaged: isDesktopManaged,
                state: state
            )
        }
        latestReadStateMarkers = readStateMarkers
        latestMetrics = CodexTaskLoadMetrics(
            taskCount: tasks.count,
            catalogReloaded: catalogResult.reloaded,
            titleIndexReloaded: titleIndexResult.reloaded,
            unreadStateReloaded: unreadResult.reloaded,
            rolloutMetadataChecks: snapshotResult.metadataChecks,
            rolloutScans: snapshotResult.scans,
            rolloutIncrementalScans: snapshotResult.incrementalScans,
            rolloutFullScans: snapshotResult.fullScans,
            rolloutCacheHits: snapshotResult.cacheHits
        )
        return tasks
    }

    public func loadUnreadTaskIDs() throws -> Set<String> {
        try readUnreadTaskIDs()
    }

    public func setTaskUnread(_ taskID: String, unread: Bool, observedMarker: Date = Date()) throws {
        do {
            var store = try loadReadStateOverrideStore()
            store.tasks[taskID] = ReadStateOverride(
                unread: unread,
                marker: latestReadStateMarkers[taskID] ?? observedMarker
            )
            try FileManager.default.createDirectory(
                at: readStateOverrideURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(store).write(to: readStateOverrideURL, options: .atomic)
        } catch {
            throw CodexTaskRepositoryError.updateGlobalState(error.localizedDescription)
        }
    }

    func readStateOverride(for taskID: String) throws -> (unread: Bool, marker: Date)? {
        guard let value = try loadReadStateOverrides()[taskID] else { return nil }
        return (value.unread, value.marker)
    }

    public func lastLoadMetrics() -> CodexTaskLoadMetrics {
        latestMetrics
    }

    static func isStaleDesktopRunningState(
        rowIsDesktopManaged: Bool,
        rolloutLatestRecordDate: Date?,
        desktopRuntimeStartDate: Date?
    ) -> Bool {
        guard rowIsDesktopManaged,
              let rolloutLatestRecordDate,
              let desktopRuntimeStartDate
        else { return false }
        return rolloutLatestRecordDate < desktopRuntimeStartDate
    }

    private func cachedDesktopRuntimeStartDate() -> Date? {
        let now = Date()
        if let cache = desktopRuntimeStartDateCache,
           now.timeIntervalSince(cache.checkedAt) < 30 {
            return cache.startDate
        }
        let startDate = desktopRuntimeStartDateProvider()
        desktopRuntimeStartDateCache = (now, startDate)
        return startDate
    }

    private func loadCatalog(refresh hint: TaskRefreshHint) throws -> (rows: [CatalogRow], reloaded: Bool) {
        let signature = Self.catalogSignature(codexHome: codexHome)
        let signatureChanged = signature != cachedCatalogSignature
        let shouldReload = catalogCache == nil
            || hint.catalogChanged
            || (hint.requiresFullReconciliation && signatureChanged)
        if shouldReload {
            let rows = try readCatalog()
            catalogCache = rows
            cachedCatalogSignature = Self.catalogSignature(codexHome: codexHome)
            let currentPaths = Set(rows.map(\.rolloutPath))
            rolloutCache = rolloutCache.filter { currentPaths.contains($0.key) }
            return (rows, true)
        }
        return (catalogCache ?? [], false)
    }

    private func loadUnreadTaskIDs(refresh hint: TaskRefreshHint) throws -> (ids: Set<String>, reloaded: Bool) {
        let url = codexHome.appending(path: ".codex-global-state.json")
        let signature = Self.fileSignature(path: url.path)
        let signatureChanged = signature != cachedUnreadSignature
        let shouldReload = unreadCache == nil
            || hint.unreadStateChanged
            || (hint.requiresFullReconciliation && signatureChanged)
        if shouldReload {
            let ids = try readUnreadTaskIDs()
            unreadCache = ids
            cachedUnreadSignature = Self.fileSignature(path: url.path)
            return (ids, true)
        }
        return (unreadCache ?? [], false)
    }

    private func loadReadStateOverrides() throws -> [String: ReadStateOverride] {
        try loadReadStateOverrideStore().tasks
    }

    private func loadReadStateOverrideStore() throws -> ReadStateOverrideStore {
        guard FileManager.default.fileExists(atPath: readStateOverrideURL.path) else {
            return ReadStateOverrideStore(version: ReadStateOverrideStore.currentVersion, tasks: [:])
        }
        let decoded = try JSONDecoder().decode(
            ReadStateOverrideStore.self,
            from: Data(contentsOf: readStateOverrideURL)
        )
        return ReadStateOverrideStore(
            version: ReadStateOverrideStore.currentVersion,
            tasks: decoded.tasks
        )
    }

    private func loadTitleIndex(refresh hint: TaskRefreshHint) -> (titles: [String: String], reloaded: Bool) {
        let url = codexHome.appending(path: "session_index.jsonl")
        let signature = Self.fileSignature(path: url.path)
        let signatureChanged = signature != cachedTitleIndexSignature
        let shouldReload = titleIndexCache == nil
            || hint.titleIndexChanged
            || (hint.requiresFullReconciliation && signatureChanged)
        if shouldReload {
            let titles = readTitleIndex(url: url)
            titleIndexCache = titles
            cachedTitleIndexSignature = Self.fileSignature(path: url.path)
            return (titles, true)
        }
        return (titleIndexCache ?? [:], false)
    }

    private func readTitleIndex(url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        var titles: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard
                let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let id = record["id"] as? String,
                !id.isEmpty,
                let rawTitle = record["thread_name"] as? String
            else { continue }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { titles[id] = title }
        }
        return titles
    }

    private func readUnreadTaskIDs() throws -> Set<String> {
        let url = codexHome.appending(path: ".codex-global-state.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let persisted = root["electron-persisted-atom-state"] as? [String: Any],
            let byHost = persisted["unread-thread-ids-by-host-v1"] as? [String: Any],
            let local = byHost["local"] as? [String]
        else { return [] }
        return Set(local)
    }

    private func readCatalog() throws -> [CatalogRow] {
        let databaseURL = codexHome.appending(path: "state_5.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CodexTaskRepositoryError.missingDatabase(databaseURL.path)
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let database { sqlite3_close(database) }
            throw CodexTaskRepositoryError.openDatabase(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 750)

        let sql = """
        SELECT
            id,
            COALESCE(NULLIF(name, ''), NULLIF(title, ''), NULLIF(preview, ''), 'Untitled task'),
            cwd,
            CASE WHEN recency_at_ms > 0 THEN recency_at_ms ELSE recency_at * 1000 END,
            rollout_path,
            is_pinned,
            COALESCE(thread_source, '')
        FROM threads
        WHERE archived = 0 AND preview <> ''
        ORDER BY recency_at_ms DESC, id DESC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CodexTaskRepositoryError.prepareQuery(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [CatalogRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw CodexTaskRepositoryError.query(String(cString: sqlite3_errmsg(database)))
            }
            rows.append(CatalogRow(
                id: string(statement, column: 0),
                title: string(statement, column: 1),
                cwd: string(statement, column: 2),
                recencyMilliseconds: sqlite3_column_int64(statement, 3),
                rolloutPath: string(statement, column: 4),
                isPinned: sqlite3_column_int(statement, 5) != 0,
                isDesktopManaged: !string(statement, column: 6).isEmpty
            ))
        }
        let canonicalProjectPaths = Self.canonicalProjectPaths(
            for: rows.map(\.cwd),
            codexHome: codexHome
        )
        return rows.map { row in
            CatalogRow(
                id: row.id,
                title: row.title,
                cwd: canonicalProjectPaths[row.cwd] ?? row.cwd,
                recencyMilliseconds: row.recencyMilliseconds,
                rolloutPath: row.rolloutPath,
                isPinned: row.isPinned,
                isDesktopManaged: row.isDesktopManaged
            )
        }
    }

    static func canonicalProjectPaths(
        for rawPaths: [String],
        codexHome: URL,
        fileManager: FileManager = .default
    ) -> [String: String] {
        let worktreeRoot = codexHome
            .appending(path: "worktrees", directoryHint: .isDirectory)
            .standardizedFileURL.path
        let worktreePrefix = worktreeRoot.hasSuffix("/") ? worktreeRoot : worktreeRoot + "/"
        let standardizedPaths = Dictionary(uniqueKeysWithValues: Set(rawPaths).map {
            ($0, URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path)
        })
        let ordinaryPaths = Set(standardizedPaths.values.filter { !$0.hasPrefix(worktreePrefix) })
        let ordinaryByName = Dictionary(grouping: ordinaryPaths) {
            URL(fileURLWithPath: $0, isDirectory: true).lastPathComponent
        }

        return Dictionary(uniqueKeysWithValues: standardizedPaths.map { rawPath, standardizedPath in
            guard standardizedPath.hasPrefix(worktreePrefix) else {
                return (rawPath, standardizedPath)
            }
            if let repositoryRoot = repositoryRootFromWorktreeMetadata(
                at: standardizedPath,
                fileManager: fileManager
            ) {
                return (rawPath, repositoryRoot)
            }

            let projectName = URL(fileURLWithPath: standardizedPath, isDirectory: true).lastPathComponent
            let matchingOrdinaryPaths = ordinaryByName[projectName] ?? []
            if matchingOrdinaryPaths.count == 1, let onlyMatch = matchingOrdinaryPaths.first {
                return (rawPath, onlyMatch)
            }
            return (rawPath, standardizedPath)
        })
    }

    private static func repositoryRootFromWorktreeMetadata(
        at worktreePath: String,
        fileManager: FileManager
    ) -> String? {
        let gitFile = URL(fileURLWithPath: worktreePath, isDirectory: true).appending(path: ".git")
        guard
            let contents = try? String(contentsOf: gitFile, encoding: .utf8),
            let firstLine = contents.split(whereSeparator: \.isNewline).first,
            firstLine.hasPrefix("gitdir:")
        else { return nil }

        let rawGitDirectory = firstLine.dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawGitDirectory.isEmpty else { return nil }
        let gitDirectory: URL
        if rawGitDirectory.hasPrefix("/") {
            gitDirectory = URL(fileURLWithPath: rawGitDirectory, isDirectory: true)
        } else {
            gitDirectory = gitFile.deletingLastPathComponent()
                .appending(path: rawGitDirectory, directoryHint: .isDirectory)
        }
        let standardizedGitPath = gitDirectory.standardizedFileURL.path
        guard let worktreesRange = standardizedGitPath.range(of: "/.git/worktrees/") else { return nil }
        let repositoryRoot = String(standardizedGitPath[..<worktreesRange.lowerBound])
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: repositoryRoot, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return repositoryRoot
    }

    private func rolloutSnapshots(
        for rows: [CatalogRow],
        refresh hint: TaskRefreshHint
    ) async -> SnapshotLoadResult {
        let fallback = RolloutSnapshot(latestAssistantMessage: nil, isRunning: false, needsApproval: false, needsResponse: false)
        var snapshots: [String: RolloutSnapshot] = [:]
        var requests: [ScanRequest] = []
        var metadataChecks = 0
        var cacheHits = 0
        var incrementalScans = 0
        var fullScans = 0

        for row in rows {
            let forceScan = hint.changedRolloutPaths.contains(row.rolloutPath)
            let shouldCheckMetadata = hint.requiresFullReconciliation
                || forceScan
                || rolloutCache[row.rolloutPath] == nil
            if !shouldCheckMetadata, let cached = rolloutCache[row.rolloutPath] {
                snapshots[row.rolloutPath] = cached.snapshot
                cacheHits += 1
                continue
            }

            metadataChecks += 1
            guard let baseRequest = Self.scanRequest(path: row.rolloutPath) else {
                snapshots[row.rolloutPath] = fallback
                rolloutCache.removeValue(forKey: row.rolloutPath)
                continue
            }
            if let cached = rolloutCache[row.rolloutPath],
               cached.signature == baseRequest.signature,
               !forceScan {
                snapshots[row.rolloutPath] = cached.snapshot
                cacheHits += 1
            } else {
                let request: ScanRequest
                if let cached = rolloutCache[row.rolloutPath],
                   Self.canScanIncrementally(from: cached.signature, to: baseRequest.signature) {
                    request = ScanRequest(
                        path: baseRequest.path,
                        signature: baseRequest.signature,
                        previousState: cached.state,
                        previousSize: cached.signature.size
                    )
                } else {
                    request = baseRequest
                }
                requests.append(request)
            }
        }

        await withTaskGroup(of: ScanResult.self) { group in
            var iterator = requests.makeIterator()
            let workerCount = min(maximumConcurrentScans, requests.count)
            for _ in 0..<workerCount {
                if let request = iterator.next() {
                    group.addTask { Self.scan(request) }
                }
            }

            while let result = await group.next() {
                if result.wasIncremental {
                    incrementalScans += 1
                } else {
                    fullScans += 1
                }
                snapshots[result.request.path] = result.state.snapshot
                rolloutCache[result.request.path] = CacheEntry(
                    signature: result.request.signature,
                    state: result.state
                )
                if let request = iterator.next() {
                    group.addTask { Self.scan(request) }
                }
            }
        }
        return SnapshotLoadResult(
            snapshots: snapshots,
            metadataChecks: metadataChecks,
            scans: requests.count,
            incrementalScans: incrementalScans,
            fullScans: fullScans,
            cacheHits: cacheHits
        )
    }

    private static func scanRequest(path: String) -> ScanRequest? {
        guard let signature = fileSignature(path: path) else { return nil }
        return ScanRequest(path: path, signature: signature, previousState: nil, previousSize: nil)
    }

    private static func canScanIncrementally(
        from previous: FileSignature,
        to current: FileSignature
    ) -> Bool {
        guard
            let previousFileNumber = previous.systemFileNumber,
            let currentFileNumber = current.systemFileNumber,
            previousFileNumber == currentFileNumber,
            current.size > previous.size
        else { return false }
        return current.size - previous.size <= maximumIncrementalAppendBytes
    }

    private static func scan(_ request: ScanRequest) -> ScanResult {
        let fileURL = URL(fileURLWithPath: request.path)
        if let previousState = request.previousState,
           let previousSize = request.previousSize,
           let state = try? RolloutScanner.scanAppended(
               fileURL: fileURL,
               previousState: previousState,
               fromOffset: previousSize,
               throughOffset: request.signature.size
           ) {
            return ScanResult(request: request, state: state, wasIncremental: true)
        }
        let state = (try? RolloutScanner.scanState(
            fileURL: fileURL,
            throughOffset: request.signature.size
        )) ?? RolloutScanState()
        return ScanResult(request: request, state: state, wasIncremental: false)
    }

    private static func catalogSignature(codexHome: URL) -> CatalogSignature {
        let database = codexHome.appending(path: "state_5.sqlite").path
        return CatalogSignature(
            database: fileSignature(path: database),
            writeAheadLog: fileSignature(path: database + "-wal"),
            sharedMemory: fileSignature(path: database + "-shm")
        )
    }

    private static func fileSignature(path: String) -> FileSignature? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let fileSize = attributes[.size] as? NSNumber,
            let modificationDate = attributes[.modificationDate] as? Date
        else { return nil }
        return FileSignature(
            size: fileSize.uint64Value,
            modificationDate: modificationDate,
            systemFileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func string(_ statement: OpaquePointer, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }
}
