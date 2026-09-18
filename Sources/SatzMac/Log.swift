import Foundation
import os

/// satz has no window to put status in, so the few things worth knowing at
/// runtime go to the unified log. Read them with:
///
///     log stream --predicate 'subsystem == "plus.dpa.satz"'
enum Log {
    private static let logger = Logger(subsystem: "plus.dpa.satz", category: "app")

    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        // Also stderr, so launching the binary from a terminal shows it without
        // needing a second window open on the unified log.
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
