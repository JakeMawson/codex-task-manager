import CodexTaskManagerKit
import Darwin
import Dispatch
import Foundation

@main
enum CodexTaskManagerBenchmark {
    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--cold-only" {
            let workers = max(Int(CommandLine.arguments.dropFirst(2).first ?? "8") ?? 8, 1)
            let repository = CodexTaskRepository(maximumConcurrentScans: workers)
            let cold = try await measure {
                try await repository.loadTasks()
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "workers": workers,
                "task_count": cold.value.count,
                "cold_ms": rounded(cold.milliseconds),
            ], options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }

        let iterationCount = max(Int(CommandLine.arguments.dropFirst().first ?? "20") ?? 20, 1)
        let repository = CodexTaskRepository()

        let cold = try await measure {
            try await repository.loadTasks()
        }

        _ = try await repository.loadTasks()

        var warmMilliseconds: [Double] = []
        var taskCount = cold.value.count
        warmMilliseconds.reserveCapacity(iterationCount)
        for _ in 0..<iterationCount {
            let measurement = try await measure {
                try await repository.loadTasks()
            }
            taskCount = measurement.value.count
            warmMilliseconds.append(measurement.milliseconds)
        }

        let warmMetrics = await repository.lastLoadMetrics()

        var incrementalMilliseconds: [Double] = []
        for _ in 0..<iterationCount {
            let measurement = try await measure {
                try await repository.loadTasks(refresh: .none)
            }
            incrementalMilliseconds.append(measurement.milliseconds)
        }
        let incrementalMetrics = await repository.lastLoadMetrics()

        var catalogChangeMilliseconds: [Double] = []
        for _ in 0..<iterationCount {
            let measurement = try await measure {
                try await repository.loadTasks(refresh: TaskRefreshHint(catalogChanged: true))
            }
            catalogChangeMilliseconds.append(measurement.milliseconds)
        }
        let catalogChangeMetrics = await repository.lastLoadMetrics()

        var unreadChangeMilliseconds: [Double] = []
        for _ in 0..<iterationCount {
            let measurement = try await measure {
                try await repository.loadTasks(refresh: TaskRefreshHint(unreadStateChanged: true))
            }
            unreadChangeMilliseconds.append(measurement.milliseconds)
        }
        let unreadChangeMetrics = await repository.lastLoadMetrics()

        var report: [String: Any] = [
            "task_count": taskCount,
            "iterations": iterationCount,
            "cold_ms": rounded(cold.milliseconds),
            "reconciliation": timingReport(warmMilliseconds),
            "reconciliation_last_work": metricsReport(warmMetrics),
            "incremental_no_change": timingReport(incrementalMilliseconds),
            "incremental_no_change_last_work": metricsReport(incrementalMetrics),
            "incremental_catalog_change": timingReport(catalogChangeMilliseconds),
            "incremental_catalog_change_last_work": metricsReport(catalogChangeMetrics),
            "incremental_unread_change": timingReport(unreadChangeMilliseconds),
            "incremental_unread_change_last_work": metricsReport(unreadChangeMetrics),
        ]

        if let rolloutPath = ProcessInfo.processInfo.environment["CODEX_BENCHMARK_ROLLOUT_PATH"],
           !rolloutPath.isEmpty {
            var changedRolloutMilliseconds: [Double] = []
            for _ in 0..<iterationCount {
                let hint = TaskRefreshHint(changedRolloutPaths: [rolloutPath])
                let measurement = try await measure {
                    try await repository.loadTasks(refresh: hint)
                }
                changedRolloutMilliseconds.append(measurement.milliseconds)
            }
            report["incremental_one_rollout"] = timingReport(changedRolloutMilliseconds)
            report["incremental_one_rollout_last_work"] = metricsReport(await repository.lastLoadMetrics())
        }

        let probeRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appending(path: ".codex-work/benchmarks/file-events", directoryHint: .isDirectory)
        let eventSamples = min(iterationCount, 10)
        report["fsevents_delivery_50ms"] = timingReport(try await fseventsLatencies(root: probeRoot, samples: eventSamples, latency: 0.05))
        report["fsevents_delivery_100ms"] = timingReport(try await fseventsLatencies(root: probeRoot, samples: eventSamples, latency: 0.1))
        report["fsevents_delivery_200ms"] = timingReport(try await fseventsLatencies(root: probeRoot, samples: eventSamples, latency: 0.2))
        report["dispatch_source_delivery"] = timingReport(try await dispatchSourceLatencies(root: probeRoot, samples: eventSamples))
        let scannerReport = try scannerLatencies(root: probeRoot, samples: iterationCount)
        report["rollout_full_tail_scan"] = timingReport(scannerReport.full)
        report["rollout_incremental_append_scan"] = timingReport(scannerReport.incremental)

        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func fseventsLatencies(
        root: URL,
        samples: Int,
        latency: TimeInterval
    ) async throws -> [Double] {
        let directory = root.appending(path: "sessions/2026/08/11", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "fsevents-probe.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }

        let observer = try CodexDataChangeObserver(codexHome: root, latency: latency)
        var iterator = observer.events.makeAsyncIterator()
        var latencies: [Double] = []
        latencies.reserveCapacity(samples)
        for sample in 0..<samples {
            let clock = ContinuousClock()
            let start = clock.now
            try append("{\"probe\":\(sample)}\n", to: file)
            while let hint = await iterator.next() {
                if hint.changedRolloutPaths.contains(file.path) || hint.requiresFullReconciliation {
                    latencies.append(milliseconds(clock.now - start))
                    break
                }
            }
        }
        return latencies
    }

    private static func dispatchSourceLatencies(root: URL, samples: Int) async throws -> [Double] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "dispatch-source-probe.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }
        let descriptor = open(file.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue(label: "com.jakemawson.codex-task-manager.dispatch-benchmark")
        )
        var continuation: AsyncStream<Void>.Continuation!
        let events = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        source.setEventHandler { continuation.yield(()) }
        source.setCancelHandler {
            close(descriptor)
            continuation.finish()
        }
        source.activate()
        defer { source.cancel() }

        var iterator = events.makeAsyncIterator()
        var latencies: [Double] = []
        latencies.reserveCapacity(samples)
        for sample in 0..<samples {
            let clock = ContinuousClock()
            let start = clock.now
            try append("{\"probe\":\(sample)}\n", to: file)
            guard await iterator.next() != nil else { break }
            latencies.append(milliseconds(clock.now - start))
        }
        return latencies
    }

    private static func scannerLatencies(
        root: URL,
        samples: Int
    ) throws -> (full: [Double], incremental: [Double]) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "scanner-probe.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            let assistant = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"Benchmark assistant message\"}}\n"
            let filler = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n"
            var data = Data(assistant.utf8)
            while data.count < 3_900_000 {
                data.append(Data(filler.utf8))
            }
            try data.write(to: file, options: .withoutOverwriting)
        }

        var full: [Double] = []
        for _ in 0..<max(min(samples, 5), 1) {
            let measurement = try synchronousMeasure {
                try RolloutScanner.scan(fileURL: file)
            }
            full.append(measurement.milliseconds)
        }

        var cursor = try RolloutScanCursor(fileURL: file)
        var incremental: [Double] = []
        for sample in 0..<samples {
            try append("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"probe\":\(sample)}}\n", to: file)
            let measurement = try synchronousMeasure {
                try cursor.scanAppended(fileURL: file)
            }
            incremental.append(measurement.milliseconds)
        }
        return (full, incremental)
    }

    private static func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private static func measure<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async rethrows -> (value: Value, milliseconds: Double) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await operation()
        return (value, milliseconds(clock.now - start))
    }

    private static func synchronousMeasure<Value>(
        _ operation: () throws -> Value
    ) rethrows -> (value: Value, milliseconds: Double) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try operation()
        return (value, milliseconds(clock.now - start))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func percentile(_ percentile: Double, sorted values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let position = percentile * Double(values.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return values[lower] }
        let weight = position - Double(lower)
        return values[lower] * (1 - weight) + values[upper] * weight
    }

    private static func timingReport(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        return [
            "samples": values.count,
            "mean_ms": rounded(mean),
            "median_ms": rounded(percentile(0.5, sorted: sorted)),
            "p95_ms": rounded(percentile(0.95, sorted: sorted)),
            "min_ms": rounded(sorted.first ?? 0),
            "max_ms": rounded(sorted.last ?? 0),
        ]
    }

    private static func metricsReport(_ metrics: CodexTaskLoadMetrics) -> [String: Any] {
        [
            "task_count": metrics.taskCount,
            "catalog_reloaded": metrics.catalogReloaded,
            "title_index_reloaded": metrics.titleIndexReloaded,
            "unread_state_reloaded": metrics.unreadStateReloaded,
            "rollout_metadata_checks": metrics.rolloutMetadataChecks,
            "rollout_scans": metrics.rolloutScans,
            "rollout_incremental_scans": metrics.rolloutIncrementalScans,
            "rollout_full_scans": metrics.rolloutFullScans,
            "rollout_cache_hits": metrics.rolloutCacheHits,
        ]
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
