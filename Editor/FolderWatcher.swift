import CoreServices
import Foundation

/// Calls back when anything changes inside a folder, at any depth, once a
/// burst of changes is over (FSEvents).
@MainActor
final class FolderWatcher {
    private let onChange: @MainActor () -> Void
    /// Only touched on the main actor, and in `deinit` once nothing else can.
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var pending: Task<Void, Never>?
    private let latency: Duration

    init(url: URL, latency: Duration = .milliseconds(200), onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        self.latency = latency
        start(url)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func stop() {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func start(_ url: URL) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.eventsArrived() }
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [url.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func eventsArrived() {
        pending?.cancel()
        pending = Task { [weak self, latency] in
            try? await Task.sleep(for: latency)
            guard !Task.isCancelled, let self else { return }
            self.onChange()
        }
    }
}
