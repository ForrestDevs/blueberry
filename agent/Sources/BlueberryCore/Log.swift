import Foundation
import os

public enum Log {
    private static let logger = Logger(subsystem: "dev.forrest.blueberry", category: "agent")

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        if isatty(STDERR_FILENO) != 0 { FileHandle.standardError.write(Data("[info] \(message)\n".utf8)) }
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        if isatty(STDERR_FILENO) != 0 { FileHandle.standardError.write(Data("[error] \(message)\n".utf8)) }
    }
}
