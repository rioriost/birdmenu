import Foundation
import OSLog

enum BirdMenuLog {
    static let debugLoggingDefaultsKey = "debugLoggingEnabled"

    private static let logger = Logger(subsystem: "st.rio.birdmenu", category: "BirdMenu")

    static var isDebugLoggingEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: debugLoggingDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: debugLoggingDefaultsKey)
            info("debugLogging \(newValue ? "enabled" : "disabled")")
        }
    }

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    static func debugData(_ message: String) {
        guard isDebugLoggingEnabled else {
            return
        }
        logger.notice("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
