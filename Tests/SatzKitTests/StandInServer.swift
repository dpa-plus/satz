import Foundation
import Network

/// A real HTTP server on 127.0.0.1 that records every request exactly as it
/// arrives and answers from a script. For the providers satz has no key for
/// (Microsoft, Google): what is checked is the request on the wire, and what
/// comes back is the answer the provider documents. The real services are
/// never called.
final class StandInServer: @unchecked Sendable {

    struct Captured {
        let method: String
        /// Path and query, as sent.
        let target: String
        /// Header names in lowercase.
        let headers: [String: String]
        let body: Data
    }

    struct Answer {
        var status = 200
        var headers: [String: String] = [:]
        var body = ""
    }

    private let listener: NWListener
    private let lock = NSLock()
    private var captured: [Captured] = []
    private var script: [Answer]
    private let queue = DispatchQueue(label: "satz.standin")

    private(set) var port: UInt16 = 0

    var requests: [Captured] { lock.withLock { captured } }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private init(script: [Answer]) throws {
        self.script = script
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Answers the requests in order; once the script runs out, 500.
    static func start(_ script: [Answer]) async throws -> StandInServer {
        let server = try StandInServer(script: script)
        server.listener.newConnectionHandler = { connection in server.serve(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = Once()
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.first() { continuation.resume() }
                case .failed(let error): if once.first() { continuation.resume(throwing: error) }
                default: break
                }
            }
            server.listener.start(queue: server.queue)
        }
        server.port = server.listener.port?.rawValue ?? 0
        return server
    }

    func stop() { listener.cancel() }

    // MARK: - One connection

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, finished, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                respond(to: request, on: connection)
            } else if error != nil || finished {
                connection.cancel()
            } else {
                read(connection, buffer: buffer)
            }
        }
    }

    /// nil until the headers and as many body bytes as Content-Length says are in.
    private static func parse(_ buffer: Data) -> Captured? {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex ..< end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        return Captured(method: String(first[0]), target: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(to request: Captured, on connection: NWConnection) {
        let answer: Answer = lock.withLock {
            captured.append(request)
            return script.isEmpty ? Answer(status: 500) : script.removeFirst()
        }
        var head = "HTTP/1.1 \(answer.status) Stand-in\r\nContent-Type: application/json\r\nContent-Length: \(answer.body.utf8.count)\r\nConnection: close\r\n"
        for (name, value) in answer.headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + Data(answer.body.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// The parts of a `multipart/form-data` body, binary safe.
struct MultipartParts {
    struct Part {
        let name: String
        let filename: String?
        let contentType: String?
        let data: Data
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    let parts: [Part]

    init?(body: Data, contentType: String?) {
        guard let contentType, let range = contentType.range(of: "boundary=") else { return nil }
        let boundary = Data(("--" + contentType[range.upperBound...]).utf8)
        let crlf = Data("\r\n".utf8)
        var pieces: [Data] = []
        var cursor = body.startIndex
        while let found = body.range(of: boundary, in: cursor ..< body.endIndex) {
            pieces.append(body[cursor ..< found.lowerBound])
            cursor = found.upperBound
        }
        // Before the first boundary: nothing. After the last: the closing "--".
        var parts: [Part] = []
        for piece in pieces.dropFirst() {
            guard let split = piece.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: piece[piece.startIndex ..< split.lowerBound], as: UTF8.self)
            var content = Data(piece[split.upperBound...])
            // Each part's content ends with the CRLF before the next boundary.
            if content.suffix(crlf.count) == crlf { content.removeLast(crlf.count) }
            var name = "", filename: String?, type: String?
            for line in head.components(separatedBy: "\r\n") where !line.isEmpty {
                if line.lowercased().hasPrefix("content-disposition:") {
                    name = Self.value(of: "name", in: line) ?? ""
                    filename = Self.value(of: "filename", in: line)
                } else if line.lowercased().hasPrefix("content-type:") {
                    type = line.dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces)
                }
            }
            parts.append(Part(name: name, filename: filename, contentType: type, data: content))
        }
        self.parts = parts
    }

    subscript(name: String) -> Part? { parts.first { $0.name == name } }

    private static func value(of key: String, in line: String) -> String? {
        // With the space before it: "filename" holds "name" too.
        guard let range = line.range(of: " \(key)=\"") else { return nil }
        let rest = line[range.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
}
