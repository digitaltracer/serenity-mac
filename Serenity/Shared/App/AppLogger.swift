import OSLog

enum AppLogger {
  private static let logger = Logger(subsystem: "com.digitaltracer.serenity", category: "app")

  static func info(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    #if DEBUG
    print("[Serenity] \(message)")
    #endif
  }

  static func error(_ message: String) {
    logger.error("\(message, privacy: .public)")
    #if DEBUG
    print("[Serenity:ERROR] \(message)")
    #endif
  }
}
