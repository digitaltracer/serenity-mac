import Foundation

/// What a bridge call came back with: a result object, or the app's own error code and message.
public enum BridgeReply {
  case result(Any)
  case failure(code: String, message: String)
}

public protocol BridgeTransport: AnyObject {
  func call(method: String, params: [String: Any]?) throws -> BridgeReply
}

public enum BridgeClientError: LocalizedError {
  case unavailable
  case lostReply
  case badReply

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      return "Serenity isn't accepting requests from Claude. Open Serenity on this Mac and turn on Settings › Claude › Connect to Claude."
    case .lostReply:
      return "Serenity stopped answering before it replied. The change may still have gone through; check with get_today before trying again."
    case .badReply:
      return "Serenity sent a reply this connector couldn't read. Make sure the app and connector are from the same build."
    }
  }
}

/// Talks to the running app over its Unix socket, one request at a time. Opens Serenity in the
/// background when it isn't running, then waits briefly for it to start listening.
public final class SerenityBridgeClient: BridgeTransport {
  public static let socketEnvironmentKey = "SERENITY_BRIDGE_SOCKET"

  private let socketPath: String
  private let launchApp: (() -> Void)?
  private let launchWait: TimeInterval
  private let replyTimeout: Int
  private var fd: Int32 = -1
  private var nextID = 1
  private var buffer = Data()

  public init(socketPath: String, launchApp: (() -> Void)? = nil, launchWait: TimeInterval = 8, replyTimeout: Int = 30) {
    self.socketPath = socketPath
    self.launchApp = launchApp
    self.launchWait = launchWait
    self.replyTimeout = replyTimeout
  }

  deinit {
    disconnect()
  }

  /// The app's socket: the environment can point elsewhere for tests and debugging.
  public static func defaultSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if let override = environment[socketEnvironmentKey], !override.isEmpty { return override }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return support.appendingPathComponent("Serenity/claude-bridge.sock").path
  }

  /// The app this helper ships inside, found from its own path; nil when run outside a bundle.
  public static func enclosingApp(executablePath: String) -> URL? {
    let resolved = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
    guard let range = resolved.range(of: ".app/Contents/", options: .backwards) else { return nil }
    return URL(fileURLWithPath: String(resolved[..<range.lowerBound]) + ".app")
  }

  public func call(method: String, params: [String: Any]?) throws -> BridgeReply {
    try ensureConnected()
    let id = nextID
    nextID += 1
    var request: [String: Any] = ["id": id, "method": method]
    if let params { request["params"] = params }
    var line = try JSONSerialization.data(withJSONObject: request)
    line.append(UInt8(ascii: "\n"))

    if !send(line) {
      // Nothing reached the app, so one retry on a fresh connection can't repeat a change.
      disconnect()
      try ensureConnected()
      guard send(line) else {
        disconnect()
        throw BridgeClientError.unavailable
      }
    }

    guard let reply = readLine() else {
      disconnect()
      throw BridgeClientError.lostReply
    }
    guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
          object["id"] as? Int == id else {
      disconnect()
      throw BridgeClientError.badReply
    }
    if let error = object["error"] as? [String: Any] {
      return .failure(code: error["code"] as? String ?? "failed", message: error["message"] as? String ?? "Serenity couldn't do that.")
    }
    return .result(object["result"] ?? NSNull())
  }

  private func ensureConnected() throws {
    guard fd < 0 else { return }
    if connect() { return }
    guard let launchApp else { throw BridgeClientError.unavailable }
    launchApp()
    let deadline = Date().addingTimeInterval(launchWait)
    while Date() < deadline {
      Thread.sleep(forTimeInterval: 0.25)
      if connect() { return }
    }
    throw BridgeClientError.unavailable
  }

  private func connect() -> Bool {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: bytes)
      buffer[bytes.count] = 0
    }
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else { return false }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      close(socketFD)
      return false
    }
    var on: Int32 = 1
    setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: replyTimeout, tv_usec: 0)
    setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    fd = socketFD
    buffer.removeAll()
    return true
  }

  private func send(_ line: Data) -> Bool {
    var sent = 0
    let bytes = [UInt8](line)
    while sent < bytes.count {
      let written = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      guard written > 0 else { return false }
      sent += written
    }
    return true
  }

  private func readLine() -> Data? {
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(buffer.startIndex...newline)
        return Data(line)
      }
      let count = read(fd, &chunk, chunk.count)
      guard count > 0 else { return nil }
      buffer.append(contentsOf: chunk[0..<count])
    }
  }

  private func disconnect() {
    if fd >= 0 { close(fd) }
    fd = -1
    buffer.removeAll()
  }
}
