import Foundation

/// Watches a bead store for changes and reports them after a debounce.
///
/// FSEvents rather than kqueue: it coalesces at directory level and survives
/// the atomic rename `bd` uses to rewrite JSONL, which a file-descriptor watch
/// would lose track of entirely.
///
/// The callback firing is not itself a reason to re-analyse — the store gates
/// on the engine's data hash, so an incidental `touch` costs nothing.
public final class FileWatchService: @unchecked Sendable {
    /// Debounce window, matching bv's `BV_DEBOUNCE_MS` default.
    public var debounce: TimeInterval = 0.2

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.qjam.bvx.filewatch")
    private var pendingWork: DispatchWorkItem?
    private var onChange: (@Sendable () -> Void)?
    private var watchedPaths: [String] = []

    public init() {}

    deinit { stopStream() }

    /// True while a stream is running.
    public var isWatching: Bool { stream != nil }

    public var paths: [String] { watchedPaths }

    /// Starts watching the directory containing `source`.
    ///
    /// The *directory* is watched rather than the file because an atomic
    /// rename replaces the inode, and a file-level watch would silently go
    /// deaf after the first write.
    public func start(watching source: String, onChange: @escaping @Sendable () -> Void) {
        stop()

        let directory = URL(fileURLWithPath: source)
            .deletingLastPathComponent()
            .path
        guard !directory.isEmpty else { return }

        self.onChange = onChange
        self.watchedPaths = [directory]

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let service = Unmanaged<FileWatchService>.fromOpaque(info)
                .takeUnretainedValue()
            service.scheduleNotification()
        }

        let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce / 2,  // FSEvents' own latency; the debounce below does the rest
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )
        guard let created else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    public func stop() {
        stopStream()
        queue.sync { pendingWork?.cancel(); pendingWork = nil }
        onChange = nil
        watchedPaths = []
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Collapses a burst of events into a single notification. `bd` rewriting a
    /// store produces several events in quick succession; reloading once at the
    /// end is both correct and much cheaper.
    private func scheduleNotification() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onChange?()
            }
            self.pendingWork = work
            self.queue.asyncAfter(deadline: .now() + self.debounce, execute: work)
        }
    }
}
