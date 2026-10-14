import Foundation

/// How satz was started: normally, or in test mode with a state file and
/// perhaps a models folder of its own. Read in one place, so the app and the
/// models folder never disagree: `--models-dir /tmp/x --dev-control` with no
/// state file once switched the models folder while the app ran normally.
///
/// A flag is written `--flag value` or `--flag=value`. Anything that looks
/// like a test flag but is not read whole is refused, never ignored: a test
/// copy that parsed as `.normal` ran as the user's own satz, quit theirs and
/// answered their shortcut.
public enum LaunchMode: Equatable, Sendable {
    case normal
    /// `--dev-control <state file>`, and `--models-dir <folder>` if given:
    /// downloads go only there.
    case test(stateFile: String, modelsFolder: String?)
    /// A test flag without a usable value: satz says why and quits, rather
    /// than run as the user's own satz.
    case invalid(String)

    public static let current = parse(CommandLine.arguments)

    public static func parse(_ arguments: [String]) -> LaunchMode {
        // `-models-dir` is a typo for `--models-dir`; read as nothing, the
        // folder would be dropped and the run would go on without it.
        for argument in arguments.dropFirst() where argument.hasPrefix("-") && !argument.hasPrefix("--") {
            let name = argument.drop { $0 == "-" }.prefix { $0 != "=" }
            if testFlags.contains("--" + name) { return .invalid("\(argument) needs two dashes: -\(argument)") }
        }
        // `--test-media` and `--test-cleanup-remote` are switches: a value
        // would only be misread.
        if arguments.contains(where: { $0.hasPrefix("--test-media=") }) {
            return .invalid("--test-media takes no value")
        }
        if arguments.contains(where: { $0.hasPrefix("--test-cleanup-remote=") }) {
            return .invalid("--test-cleanup-remote takes no value")
        }

        let stateFile = value(of: "--dev-control", in: arguments)
        let modelsFolder = value(of: "--models-dir", in: arguments)
        let testAudio = value(of: "--test-audio", in: arguments)
        let testMedia = arguments.contains("--test-media")
        let testCleanupRemote = arguments.contains("--test-cleanup-remote")
        switch (stateFile, modelsFolder) {
        case (nil, nil):
            // Clips for the microphone, or the user's music left alone, mean
            // a test copy; without a state file this would be the real satz
            // answering from a file.
            if testAudio != nil { return .invalid("--test-audio works only with --dev-control <state file>") }
            if testMedia { return .invalid("--test-media works only with --dev-control <state file>") }
            if testCleanupRemote { return .invalid("--test-cleanup-remote works only with --dev-control <state file>") }
            return .normal
        case (nil, .some): return .invalid("--models-dir works only with --dev-control <state file>")
        case (.some(nil), _): return .invalid("--dev-control needs a state file")
        case (.some, .some(nil)): return .invalid("--models-dir needs a folder")
        case (.some(let file?), let folder):
            if testAudio == .some(nil) { return .invalid("--test-audio needs a file") }
            return .test(stateFile: file, modelsFolder: folder ?? nil)
        }
    }

    public var stateFile: String? {
        if case .test(let file, _) = self { file } else { nil }
    }

    public var modelsFolder: String? {
        if case .test(_, let folder) = self { folder } else { nil }
    }

    /// Model files may be downloaded or removed: by the user's own satz, or
    /// by a test copy with a folder of its own. A test copy without one
    /// shares the user's models and only uses them.
    public var canChangeModels: Bool {
        switch self {
        case .normal: true
        case .test(_, let folder): folder != nil
        case .invalid: false
        }
    }

    /// Whether this test run may pause the user's music (`--test-media`).
    /// Only meaningful in test mode, where `parse` has already refused it
    /// anywhere else.
    public static var allowsMediaInTest: Bool {
        CommandLine.arguments.contains("--test-media")
    }

    /// Whether cleanup may go only to this computer: in test mode, unless the
    /// test passes `--test-cleanup-remote`. A test copy shares the key files
    /// with the real satz, so `cleanup:on` with the provider that transcribes
    /// would otherwise send a real request, and cost real money. The same
    /// switch has the same name on Windows and Linux.
    public func cleanupStaysHere(arguments: [String] = CommandLine.arguments) -> Bool {
        stateFile != nil && !arguments.contains("--test-cleanup-remote")
    }

    /// The value of a flag, spelled `--flag value` or `--flag=value`; nil
    /// when the flag is absent or has no usable value. For the flags the app
    /// reads itself (`--snapshot`, `--test-audio`, …).
    public static func argument(_ flag: String, in arguments: [String] = CommandLine.arguments) -> String? {
        value(of: flag, in: arguments) ?? nil
    }

    private static let testFlags = ["--dev-control", "--models-dir", "--test-audio", "--test-media", "--test-cleanup-remote"]

    /// nil when the flag is absent, .some(nil) when it has no usable value
    /// (none, empty, or the next flag).
    private static func value(of flag: String, in arguments: [String]) -> String?? {
        for (index, argument) in arguments.enumerated().dropFirst() {
            if argument == flag {
                guard arguments.indices.contains(index + 1) else { return .some(nil) }
                let value = arguments[index + 1]
                return value.isEmpty || value.hasPrefix("--") ? .some(nil) : .some(value)
            }
            // Only the first "=" splits: a path may contain more.
            if argument.hasPrefix(flag + "=") {
                let value = String(argument.dropFirst(flag.count + 1))
                return value.isEmpty ? .some(nil) : .some(value)
            }
        }
        return nil
    }
}
