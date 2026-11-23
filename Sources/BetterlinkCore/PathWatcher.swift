import Foundation

/// Calls `onChange` (debounced) when a file or a folder's entries change,
/// including permission changes: the fix FileSafety asks for is a chmod.
public final class PathWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    public init?(url: URL, queue: DispatchQueue = .main, debounce: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                           eventMask: [.write, .rename, .delete, .extend, .attrib],
                                                           queue: queue)
        source.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let item = DispatchWorkItem(block: onChange)
            self?.pending = item
            queue.asyncAfter(deadline: .now() + debounce, execute: item)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
