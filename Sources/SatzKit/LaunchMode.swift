import Foundation

/// How satz was started: normally, or in test mode with a state file and
/// perhaps a models folder of its own. Read in one place, so the app and the
/// models folder never disagree: `--models-dir /tmp/x --dev-control` with no
/// state file once switched the models folder while the app ran normally.
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
        let stateFile = value(after: "--dev-control", in: arguments)
        let modelsFolder = value(after: "--models-dir", in: arguments)
        switch (stateFile, modelsFolder) {
        case (nil, nil): return .normal
        case (nil, .some): return .invalid("--models-dir works only with --dev-control <state file>")
        case (.some(nil), _): return .invalid("--dev-control needs a state file")
        case (.some, .some(nil)): return .invalid("--models-dir needs a folder")
        case (.some(let file?), let folder): return .test(stateFile: file, modelsFolder: folder ?? nil)
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

    /// nil when the flag is absent, .some(nil) when it has no usable value
    /// (none, empty, or the next flag).
    private static func value(after flag: String, in arguments: [String]) -> String?? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(index + 1) else { return .some(nil) }
        let value = arguments[index + 1]
        return value.isEmpty || value.hasPrefix("--") ? .some(nil) : .some(value)
    }
}
