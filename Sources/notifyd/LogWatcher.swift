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
    /// Inode the file source is currently armed on, so the directory watch can
    /// detect a rename-over (inode changed) and re-arm onto the live file.
    private var watchedInode: UInt64 = 0
    /// Directory watch on the parent dir — the reliable signal that the file was
    /// replaced. Lives for the watcher's lifetime, independent of file re-arms.
    private var dirFD: Int32 = -1
    private var dirSource: DispatchSourceFileSystemObject?
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
        armDirectory()
        arm()
    }

    /// Watch the parent directory for entry changes. A rename-over of the file
    /// (atomic write, `mv`, our own compaction) does NOT reliably deliver
    /// `.delete`/`.rename` to the *old* file vnode on APFS, so the file source
    /// alone can go deaf after a replacement. A directory `.write` note fires
    /// whenever an entry is added/removed/renamed inside it — we use that to
    /// re-stat the path and re-arm on the live inode. Armed once and kept alive.
    private func armDirectory() {
        let dir = file.deletingLastPathComponent()
        dirFD = open(dir.path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: [.write], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                // Content on the new inode may already be visible; coalesce a read.
                self.fire()
                // If the path now resolves to a different inode than we're armed
                // on (or we lost the file fd), follow it.
                let cur = Self.inode(ofPath: self.file.path)
                if self.fileFD < 0 || (cur != 0 && cur != self.watchedInode) {
                    self.arm()
                }
            }
        }
        src.setCancelHandler { [weak self] in
            MainActor.assumeIsolated {
                if let fd = self?.dirFD, fd >= 0 { close(fd) }
                self?.dirFD = -1
            }
        }
        dirSource = src
        src.resume()
    }

    /// Open the file and start a source on it. If it's missing, poll until it
    /// shows up (the hook creates it on the first event).
    private func arm() {
        teardownSource()
        let fd = open(file.path, O_EVTONLY)
        guard fd >= 0 else { fileFD = -1; watchedInode = 0; schedulePoll(); return }
        fileFD = fd
        // Record the inode we're now armed on, so the directory watch can tell
        // when a replacement has swapped the file out from under us.
        var st = stat()
        watchedInode = (fstat(fd, &st) == 0) ? UInt64(st.st_ino) : 0

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
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
        // Close the fd THIS source owns — captured by value, not via self.fileFD,
        // which a subsequent arm() may have already reassigned to a new fd.
        src.setCancelHandler {
            close(fd)
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
        dirSource?.cancel()
        dirSource = nil
    }

    /// Inode of the file at `path`, or 0 if it can't be stat'd.
    private static func inode(ofPath path: String) -> UInt64 {
        var st = stat()
        return stat(path, &st) == 0 ? UInt64(st.st_ino) : 0
    }
}
