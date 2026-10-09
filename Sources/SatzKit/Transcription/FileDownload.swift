import Foundation

/// Fetches a sherpa-onnx model's files from Hugging Face, one after another,
/// into its folder, with one progress for all of them, and stops when
/// cancelled. A file already there at its full size is kept, so trying again
/// after a lost connection does not start over.
public final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    public enum Failure: Error, LocalizedError {
        case status(Int)
        case size(String)

        public var errorDescription: String? {
            switch self {
            case .status(let code): de("Hugging Face antwortete mit \(code).", en: "Hugging Face answered \(code).")
            case .size(let file): de("\(file) kam unvollständig an.", en: "\(file) arrived incomplete.")
            }
        }
    }

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var waiting: CheckedContinuation<Void, any Error>?
    private var cancelled = false
    /// Where the file being fetched goes, and what it must weigh.
    private var target: (url: URL, bytes: Int64, name: String)?
    private var finished: Int64 = 0
    private var total: Int64 = 1
    private var moveError: (any Error)?
    /// The last fraction passed on: every few kilobytes would flood the main thread.
    private var reported = 0.0
    private let progress: @Sendable (Double) -> Void

    public init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    /// Throws `CancellationError` once `cancel` was called, also when every
    /// file was there already: a cancelled download must never count as done
    /// (it went on to be chosen, prepared and timed).
    public func run(_ model: SherpaModel, into folder: URL) async throws {
        try checkCancelled()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        lock.withLock {
            self.session = session
            total = max(1, model.bytes)
            finished = 0
            reported = 0
        }
        defer { session.finishTasksAndInvalidate() }
        for file in model.files {
            try checkCancelled()
            let destination = folder.appendingPathComponent(file.name)
            if Self.size(of: destination) == file.bytes {
                lock.withLock { finished += file.bytes }
                continue
            }
            try await fetch(model.url(of: file), to: destination, bytes: file.bytes, name: file.name, session: session)
            lock.withLock { finished += file.bytes }
            progress(Double(lock.withLock { finished }) / Double(total))
        }
        try checkCancelled()
    }

    public func cancel() {
        lock.withLock {
            cancelled = true
            task?.cancel()
        }
    }

    private func checkCancelled() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    private func fetch(_ url: URL, to destination: URL, bytes: Int64, name: String, session: URLSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.withLock {
                guard !cancelled else { return continuation.resume(throwing: CancellationError()) }
                target = (destination, bytes, name)
                moveError = nil
                waiting = continuation
                let task = session.downloadTask(with: URLRequest(url: url, timeoutInterval: 60))
                self.task = task
                task.resume()
            }
        }
    }

    private static func size(of file: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fraction: Double? = lock.withLock {
            let fraction = min(1, Double(finished + totalBytesWritten) / Double(total))
            guard fraction - reported >= 0.002 else { return nil }
            reported = fraction
            return fraction
        }
        if let fraction { progress(fraction) }
    }

    /// The temporary file is gone once this returns: moved now, and only
    /// when it is complete.
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let target = lock.withLock({ self.target }) else { return }
        do {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw Failure.status(status) }
            guard Self.size(of: location) == target.bytes else { throw Failure.size(target.name) }
            try? FileManager.default.removeItem(at: target.url)
            try FileManager.default.moveItem(at: location, to: target.url)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, moved, wasCancelled) = lock.withLock {
            let continuation = waiting
            waiting = nil
            self.task = nil
            return (continuation, moveError, cancelled)
        }
        if wasCancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let failure = error ?? moved {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }
}
