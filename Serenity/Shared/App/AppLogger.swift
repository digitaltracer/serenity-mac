import OSLog

enum AppLogger {
  private static let logger = Logger(subsystem: "com.digitaltracer.serenity", category: "app")

  /// Tests read what would have been logged.
  static var observer: ((String) -> Void)?

  static func info(_ message: String) {
    observer?(message)
    logger.notice("\(message, privacy: .public)")
    #if DEBUG
    print("[Serenity] \(message)")
    #endif
  }

  static func error(_ message: String) {
    observer?(message)
    logger.error("\(message, privacy: .public)")
    #if DEBUG
    print("[Serenity:ERROR] \(message)")
    #endif
  }
}
