import Foundation

/// Watches `events.jsonl` for changes and invokes a callback on the main queue.
///
/// We watch the FILE directly for `.write`/`.extend` — appends grow the file's
/// vnode, which a *directory* watcher does NOT report. When the file is replaced
/// or rotated (`.delete`/`.rename`, e.g. our atomic compaction rewrite), the
/// source fires and we re-arm against the new file. If the file doesn't exist
/// yet, we poll briefly until it appears. A short debounce coalesces the burst
/// an append can produce.
@MainActor
final class LogWatcher {
    private let file: URL
    private var fileFD: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private let onChange: @MainActor () -> Void
    private var debounce: DispatchWorkItem?
    private var rearmTimer: DispatchSourceTimer?

    init(file: URL, onChange: @escaping @MainActor () -> Void) {
        self.file = file
        self.onChange = onChange
    }

    func start() {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        arm()
    }

    /// Open the file and start a source on it. If it's missing, poll until it
    /// shows up (the hook creates it on the first event).
    private func arm() {
        teardownSource()
        fileFD = open(file.path, O_EVTONLY)
        guard fileFD >= 0 else { schedulePoll(); return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileFD,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                let flags = src.data
                self.fire()
                // File replaced/rotated → the old vnode is dead; re-arm on the new one.
                if !flags.intersection([.delete, .rename]).isEmpty {
                    self.arm()
                }
            }
        }
        src.setCancelHandler { [weak self] in
            MainActor.assumeIsolated {
                if let fd = self?.fileFD, fd >= 0 { close(fd) }
                self?.fileFD = -1
            }
        }
        source = src
        src.resume()
        // Coalesce any writes we missed between teardown and re-arm.
        fire()
    }

    /// Poll for the file to appear (used before it exists).
    private func schedulePoll() {
        rearmTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                if FileManager.default.fileExists(atPath: self.file.path) {
                    self.rearmTimer?.cancel()
                    self.rearmTimer = nil
                    self.arm()
                }
            }
        }
        rearmTimer = t
        t.resume()
    }

    private func fire() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func teardownSource() {
        source?.cancel()
        source = nil
    }

    func stop() {
        rearmTimer?.cancel(); rearmTimer = nil
        teardownSource()
    }
}
