import CryptoKit
import Foundation

/// Fetches a sherpa-onnx model's files from Hugging Face, one after another,
/// into its folder, with one progress for all of them, and stops when
/// cancelled. Every file is the one its pinned revision has: a download is
/// kept only if its SHA-256 is right, and so is a file already there, which
/// spares trying again after a lost connection from starting over. A file of
/// the right size and other bytes was kept before, and the model loader
/// ended satz on it.
public final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    public enum Failure: Error, LocalizedError {
        case status(Int)
        case size(String)
        /// The right size and other bytes.
        case damaged(String)

        public var errorDescription: String? {
            switch self {
            case .status(let code): de("Hugging Face antwortete mit \(code).", en: "Hugging Face answered \(code).")
            case .size(let file): de("\(file) kam unvollständig an.", en: "\(file) arrived incomplete.")
            case .damaged(let file): de("\(file) kam beschädigt an.", en: "\(file) arrived damaged.")
            }
        }
    }

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var waiting: CheckedContinuation<Void, any Error>?
    private var cancelled = false
    /// The file being fetched, and where it goes.
    private var target: (file: SherpaModel.File, url: URL)?
    private var finished: Int64 = 0
    private var total: Int64 = 1
    private var moveError: (any Error)?
    /// The last fraction passed on: every few kilobytes would flood the main thread.
    private var reported = 0.0
    private let progress: @Sendable (Double) -> Void
    private let configuration: URLSessionConfiguration

    /// - Parameter configuration: for the requests; a test answers them itself.
    public init(progress: @escaping @Sendable (Double) -> Void, configuration: URLSessionConfiguration = .default) {
        self.progress = progress
        self.configuration = configuration
    }

    /// Throws `CancellationError` once `cancel` was called, also when every
    /// file was there already: a cancelled download must never count as done
    /// (it went on to be chosen, prepared and timed).
    public func run(_ model: SherpaModel, into folder: URL) async throws {
        try checkCancelled()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
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
            if Self.size(of: destination) != nil {
                if try isIntact(file, at: destination) {
                    lock.withLock { finished += file.bytes }
                    progress(Double(lock.withLock { finished }) / Double(total))
                    continue
                }
                // Cut short, or damaged, or of another version: not kept.
                try? FileManager.default.removeItem(at: destination)
            }
            // Qwen3's tokenizer files sit in a folder of their own.
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await fetch(model.url(of: file), file: file, to: destination, session: session)
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

    private func fetch(_ url: URL, file: SherpaModel.File, to destination: URL, session: URLSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.withLock {
                guard !cancelled else { return continuation.resume(throwing: CancellationError()) }
                target = (file, destination)
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

    /// Whether the file at `url` is `file`: its size and its checksum.
    private func isIntact(_ file: SherpaModel.File, at url: URL) throws -> Bool {
        guard Self.size(of: url) == file.bytes else { return false }
        do {
            return try Self.sha256(of: url, isCancelled: { lock.withLock { cancelled } }) == file.sha256
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    /// A file's SHA-256 as lowercase hex, read in pieces: Parakeet's encoder
    /// is 650 MB. Stops with `CancellationError` once `isCancelled` says so.
    public static func sha256(of file: URL, isCancelled: () -> Bool = { false }) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var reading = true
        while reading {
            if isCancelled() { throw CancellationError() }
            // A pool per piece: the pieces are Foundation objects, and a
            // 650 MB file would otherwise keep all of them until the end.
            reading = try autoreleasepool {
                guard let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty else { return false }
                hash.update(data: piece)
                return true
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
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
    /// when it is complete and the file it must be.
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let target = lock.withLock({ self.target }) else { return }
        do {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw Failure.status(status) }
            guard Self.size(of: location) == target.file.bytes else { throw Failure.size(target.file.name) }
            guard try Self.sha256(of: location, isCancelled: { lock.withLock { cancelled } }) == target.file.sha256 else {
                throw Failure.damaged(target.file.name)
            }
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
