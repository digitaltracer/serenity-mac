import AppKit
import Combine
import Foundation

/// A Unix socket only this user can reach: the file is 0600 and every peer's uid is checked.
/// Each line in is one request; each reply goes back as one line.
final class ClaudeBridgeSocketServer: @unchecked Sendable {
  typealias Handler = @Sendable (Data) async -> Data

  enum StartError: LocalizedError {
    case pathTooLong
    case system(String, Int32)

    var errorDescription: String? {
      switch self {
      case .pathTooLong:
        return "The socket path is too long for this system."
      case let .system(call, code):
        return "\(call) failed: \(String(cString: strerror(code)))"
      }
    }
  }

  private let path: String
  private let handler: Handler
  private let queue = DispatchQueue(label: "serenity.claude-bridge")
  private var listenSource: DispatchSourceRead?
  private var connections: [Int32: Connection] = [:]

  init(path: String, handler: @escaping Handler) {
    self.path = path
    self.handler = handler
  }

  deinit {
    listenSource?.cancel()
  }

  func start() throws {
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw StartError.pathTooLong }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: pathBytes)
      buffer[pathBytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw StartError.system("socket", errno) }
    // A socket file left by a crash would make bind fail.
    unlink(path)
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else {
      let code = errno
      close(fd)
      throw StartError.system("bind", code)
    }
    chmod(path, 0o600)
    guard listen(fd, 8) == 0 else {
      let code = errno
      close(fd)
      unlink(path)
      throw StartError.system("listen", code)
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
    source.setCancelHandler { close(fd) }
    listenSource = source
    source.resume()
  }

  func stop() {
    queue.sync {
      listenSource?.cancel()
      listenSource = nil
      for connection in connections.values { connection.source.cancel() }
      connections.removeAll()
    }
    unlink(path)
  }

  private func acceptPending(on listenFD: Int32) {
    while true {
      let client = accept(listenFD, nil, nil)
      guard client >= 0 else { return }

      var uid: uid_t = 0
      var gid: gid_t = 0
      guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
        close(client)
        continue
      }
      var on: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      // Writes block, but never for long: a client that stops reading is dropped.
      var timeout = timeval(tv_sec: 2, tv_usec: 0)
      setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

      let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
      let connection = Connection(fd: client, source: source)
      connections[client] = connection
      source.setEventHandler { [weak self] in self?.readAvailable(from: connection) }
      source.setCancelHandler { close(client) }
      source.resume()
    }
  }

  private func readAvailable(from connection: Connection) {
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    let count = read(connection.fd, &chunk, chunk.count)
    guard count > 0 else {
      drop(connection)
      return
    }
    connection.buffer.append(contentsOf: chunk[0..<count])

    while let newline = connection.buffer.firstIndex(of: UInt8(ascii: "\n")) {
      let line = connection.buffer[connection.buffer.startIndex..<newline]
      connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
      guard !line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) else { continue }
      respond(to: Data(line), on: connection)
    }
    if connection.buffer.count > ClaudeBridgeWire.maximumLineBytes {
      drop(connection)
    }
  }

  private func respond(to line: Data, on connection: Connection) {
    let handler = handler
    Task { [weak self] in
      let reply = await handler(line)
      self?.queue.async { [weak self] in
        guard let self, self.connections[connection.fd] === connection else { return }
        var bytes = [UInt8](reply)
        bytes.append(UInt8(ascii: "\n"))
        var sent = 0
        while sent < bytes.count {
          let written = bytes[sent...].withUnsafeBytes { write(connection.fd, $0.baseAddress, $0.count) }
          guard written > 0 else {
            self.drop(connection)
            return
          }
          sent += written
        }
      }
    }
  }

  private func drop(_ connection: Connection) {
    guard connections.removeValue(forKey: connection.fd) != nil else { return }
    connection.source.cancel()
  }

  private final class Connection: @unchecked Sendable {
    let fd: Int32
    let source: DispatchSourceRead
    var buffer = Data()

    init(fd: Int32, source: DispatchSourceRead) {
      self.fd = fd
      self.source = source
    }
  }
}

/// Opens the socket while "Connect to Claude" is on and closes it when it goes off or the app quits.
@MainActor
final class ClaudeBridgeController: ObservableObject {
  enum Status: Equatable {
    case off
    case listening
    case failed(String)
  }

  static let shared = ClaudeBridgeController()

  let settings: ClaudeBridgeSettings
  @Published private(set) var status: Status = .off

  private var server: ClaudeBridgeSocketServer?
  private var router: ClaudeBridgeRouter?
  private var observers: Set<AnyCancellable> = []

  init(settings: ClaudeBridgeSettings? = nil) {
    self.settings = settings ?? ClaudeBridgeSettings()
  }

  var socketPath: String? {
    ClaudeBridgeWire.socketURL()?.path
  }

  func install(appState: AppState) {
    guard router == nil else { return }
    router = ClaudeBridgeRouter(appState: appState, settings: settings)
    settings.$isEnabled
      .removeDuplicates()
      .sink { [weak self] enabled in self?.apply(enabled: enabled) }
      .store(in: &observers)
    NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
      .sink { [weak self] _ in self?.stop() }
      .store(in: &observers)
  }

  private func apply(enabled: Bool) {
    enabled ? start() : stop()
  }

  private func start() {
    guard server == nil, let router else { return }
    guard let path = socketPath else {
      status = .failed("Couldn't find the Application Support folder.")
      return
    }
    let server = ClaudeBridgeSocketServer(path: path) { line in
      await router.handle(line)
    }
    do {
      try server.start()
      self.server = server
      status = .listening
    } catch {
      status = .failed(error.localizedDescription)
      AppLogger.error("Claude bridge failed to start: \(error.localizedDescription)")
    }
  }

  private func stop() {
    server?.stop()
    server = nil
    status = .off
  }
}
