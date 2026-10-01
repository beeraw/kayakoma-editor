import Foundation

/// Calls back when a file changes on disk, including when an editor saves it
/// by replacing it with a new file.
@MainActor
final class FileWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    /// Only touched on the main actor, and in `deinit` once nothing else can.
    nonisolated(unsafe) private var source: (any DispatchSourceFileSystemObject)?
    private var pendingChange: Task<Void, Never>?

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        watch()
    }

    deinit {
        source?.cancel()
    }

    func stop() {
        pendingChange?.cancel()
        source?.cancel()
        source = nil
    }

    private func watch() {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fileDidChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// Changes come in bursts while a file is written: wait for the burst to
    /// end. A file that was replaced is watched again under its path.
    private func fileDidChange() {
        let replaced = source.map { !$0.data.isDisjoint(with: [.delete, .rename]) } ?? false
        if replaced {
            source?.cancel()
            source = nil
        }
        pendingChange?.cancel()
        pendingChange = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            if replaced { self.watch() }
            self.onChange()
        }
    }
}
