import CoreServices
import Foundation

public enum CodexDataChangeObserverError: LocalizedError, Sendable {
    case streamCreationFailed
    case streamStartFailed

    public var errorDescription: String? {
        switch self {
        case .streamCreationFailed: "Could not create the local Codex file-change stream."
        case .streamStartFailed: "Could not start the local Codex file-change stream."
        }
    }
}

enum CodexDataChangeClassifier {
    static func classify(
        paths: [String],
        flags: [FSEventStreamEventFlags],
        codexHome: URL
    ) -> TaskRefreshHint {
        let codexHomePath = codexHome.standardizedFileURL.path
        let sessionsPath = codexHome.appending(path: "sessions", directoryHint: .isDirectory).standardizedFileURL.path
        var hint = TaskRefreshHint.none
        for index in 0..<max(paths.count, flags.count) {
            guard flags.indices.contains(index) else {
                hint.requiresFullReconciliation = true
                continue
            }
            let eventFlags = flags[index]
            if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                || eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0
                || eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
                || eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagMount) != 0
                || eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount) != 0 {
                hint.requiresFullReconciliation = true
            }

            guard paths.indices.contains(index) else {
                hint.requiresFullReconciliation = true
                continue
            }
            classify(
                path: NSString(string: paths[index]).standardizingPath,
                flags: eventFlags,
                codexHomePath: codexHomePath,
                sessionsPath: sessionsPath,
                into: &hint
            )
        }
        return hint
    }

    private static func classify(
        path: String,
        flags: FSEventStreamEventFlags,
        codexHomePath: String,
        sessionsPath: String,
        into hint: inout TaskRefreshHint
    ) {
        guard path == codexHomePath || path.hasPrefix(codexHomePath + "/") else {
            hint.requiresFullReconciliation = true
            return
        }

        let lastComponent = URL(fileURLWithPath: path).lastPathComponent
        if lastComponent == ".codex-global-state.json" {
            hint.unreadStateChanged = true
            return
        }
        if lastComponent == "session_index.jsonl" {
            hint.titleIndexChanged = true
            return
        }
        if lastComponent == "state_5.sqlite"
            || lastComponent == "state_5.sqlite-wal"
            || lastComponent == "state_5.sqlite-shm" {
            hint.catalogChanged = true
            return
        }

        guard path == sessionsPath || path.hasPrefix(sessionsPath + "/") else { return }
        let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        let changedIdentity = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0

        if isDirectory {
            if changedIdentity {
                hint.requiresFullReconciliation = true
            }
            return
        }
        guard path.hasSuffix(".jsonl") else { return }
        hint.changedRolloutPaths.insert(path)
        if changedIdentity {
            hint.catalogChanged = true
        }
    }
}

public final class CodexDataChangeObserver: @unchecked Sendable {
    fileprivate final class CallbackState: @unchecked Sendable {
        let codexHomePath: String
        let continuation: AsyncStream<TaskRefreshHint>.Continuation

        init(
            codexHome: URL,
            continuation: AsyncStream<TaskRefreshHint>.Continuation
        ) {
            codexHomePath = codexHome.standardizedFileURL.path
            self.continuation = continuation
        }

        func receive(
            paths: [String],
            flags: UnsafePointer<FSEventStreamEventFlags>,
            count: Int
        ) {
            let hint = CodexDataChangeClassifier.classify(
                paths: Array(paths.prefix(count)),
                flags: (0..<count).map { flags[$0] },
                codexHome: URL(fileURLWithPath: codexHomePath, isDirectory: true)
            )

            if !hint.isEmpty {
                continuation.yield(hint)
            }
        }
    }

    public let events: AsyncStream<TaskRefreshHint>

    private let callbackState: CallbackState
    private let queue = DispatchQueue(label: "com.jakemawson.codex-task-manager.fsevents", qos: .utility)
    private let stream: FSEventStreamRef

    public init(codexHome: URL? = nil, latency: TimeInterval = 0.1) throws {
        let resolvedHome: URL
        if let codexHome {
            resolvedHome = codexHome
        } else if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            resolvedHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            resolvedHome = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex", directoryHint: .isDirectory)
        }

        var continuation: AsyncStream<TaskRefreshHint>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation = $0 }
        callbackState = CallbackState(codexHome: resolvedHome, continuation: continuation)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackState).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagFileEvents
        )
        guard let created = FSEventStreamCreate(
            nil,
            codexTaskManagerFSEventsCallback,
            &context,
            [resolvedHome.standardizedFileURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            createFlags
        ) else {
            continuation.finish()
            throw CodexDataChangeObserverError.streamCreationFailed
        }
        stream = created
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            continuation.finish()
            throw CodexDataChangeObserverError.streamStartFailed
        }
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        callbackState.continuation.finish()
    }
}

private let codexTaskManagerFSEventsCallback: FSEventStreamCallback = {
    _, info, eventCount, eventPaths, eventFlags, _ in
    guard let info else { return }
    let state = Unmanaged<CodexDataChangeObserver.CallbackState>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
    state.receive(paths: paths, flags: eventFlags, count: eventCount)
}
