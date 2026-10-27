import Foundation
import os

/// A thin, Sendable wrapper over `os.Logger` with the app's subsystem.
///
/// Messages are redacted (`.private`) in the unified log by default. Pass `privacy: .public`
/// only for values that can never identify a person (states, counts, error codes). For rich
/// interpolation use ``logger`` directly.
public struct Log: Sendable {
    /// Unified-logging subsystem for every category.
    public static let subsystem = Brand.applicationID

    /// Whether a message may appear unredacted in the unified log.
    public enum Privacy: Sendable {
        case `public`
        case `private`
    }

    /// The category (e.g. `"core"`, `"billing"`).
    public let category: String
    /// The underlying logger.
    public let logger: Logger

    public init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: Log.subsystem, category: category)
    }

    public func debug(_ message: @autoclosure () -> String, privacy: Privacy = .private) {
        write(.debug, message(), privacy)
    }

    public func info(_ message: @autoclosure () -> String, privacy: Privacy = .private) {
        write(.info, message(), privacy)
    }

    public func notice(_ message: @autoclosure () -> String, privacy: Privacy = .private) {
        write(.default, message(), privacy)
    }

    public func error(_ message: @autoclosure () -> String, privacy: Privacy = .private) {
        write(.error, message(), privacy)
    }

    public func fault(_ message: @autoclosure () -> String, privacy: Privacy = .private) {
        write(.fault, message(), privacy)
    }

    private func write(_ level: OSLogType, _ message: String, _ privacy: Privacy) {
        switch privacy {
        case .public: logger.log(level: level, "\(message, privacy: .public)")
        case .private: logger.log(level: level, "\(message, privacy: .private)")
        }
    }
}

extension Log {
    /// DDCore's own category.
    public static let core = Log("core")
}
