import Foundation
import XCTest
@testable import SerenityMac

@MainActor
final class ClaudeBridgeRouterTests: XCTestCase {
  private var cleanups: [() -> Void] = []

  override func tearDown() {
    cleanups.forEach { $0() }
    cleanups = []
    super.tearDown()
  }

  private func makeRouter() throws -> (AppState, ClaudeBridgeSettings, ClaudeBridgeRouter) {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-claude-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let suiteName = "serenity.claude.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    cleanups.append {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: baseURL)
    }
    let state = AppState(
      backendProfileManager: BackendProfileManager(
        defaults: defaults,
        defaultsKey: "claude.backend",
        registry: BackendProfileRegistry(
          descriptors: BackendProfileRegistry.live.descriptors,
          validators: [.sqliteLocal: { .available(message: "ok") }]
        )
      ),
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil
    )
    let settings = ClaudeBridgeSettings(defaults: defaults)
    return (state, settings, ClaudeBridgeRouter(appState: state, settings: settings))
  }

  private func call(_ router: ClaudeBridgeRouter, _ method: String, _ params: [String: Any]? = nil) async throws -> [String: Any] {
    var request: [String: Any] = ["id": 7, "method": method]
    if let params { request["params"] = params }
    let reply = await router.handle(try JSONSerialization.data(withJSONObject: request))
    XCTAssertFalse(reply.contains(UInt8(ascii: "\n")), "A reply must fit on one line")
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
    XCTAssertEqual(object["id"] as? Int, 7)
    return object
  }

  private func result(_ reply: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
    XCTAssertNil(reply["error"], "\(reply["error"] ?? "")", file: file, line: line)
    return try XCTUnwrap(reply["result"] as? [String: Any], file: file, line: line)
  }

  private func ok(_ router: ClaudeBridgeRouter, _ method: String, _ params: [String: Any]? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
    try result(try await call(router, method, params), file: file, line: line)
  }

  private func field<T>(_ router: ClaudeBridgeRouter, _ method: String, _ params: [String: Any]? = nil, key: String, as type: T.Type, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await ok(router, method, params, file: file, line: line)
    return try XCTUnwrap(result[key] as? T, file: file, line: line)
  }

  private func expectError(_ router: ClaudeBridgeRouter, _ method: String, _ params: [String: Any]? = nil, code: String, file: StaticString = #filePath, line: UInt = #line) async throws {
    let reply = try await call(router, method, params)
    XCTAssertEqual(errorCode(reply), code, file: file, line: line)
  }

  private func errorCode(_ reply: [String: Any]) -> String? {
    (reply["error"] as? [String: Any])?["code"] as? String
  }

  func testStatusReportsTodayAndJournalAccess() async throws {
    let (_, settings, router) = try makeRouter()
    settings.journalAccess = true

    let status = try await ok(router, "status")

    XCTAssertEqual(status["app"] as? String, "Serenity")
    XCTAssertEqual(status["today"] as? String, ClaudeBridgeDates.day(Date()))
    XCTAssertEqual(status["journalAccess"] as? Bool, true)
  }

  func testBadRequestsComeBackAsErrorsNotCrashes() async throws {
    let (_, _, router) = try makeRouter()

    let garbageReply = await router.handle(Data("not json".utf8))
    let garbage = try XCTUnwrap(try JSONSerialization.jsonObject(with: garbageReply) as? [String: Any])
    XCTAssertEqual(errorCode(garbage), "invalid_request")
    try await expectError(router, "tasks.delete", ["id": "x"], code: "unknown_method")
    try await expectError(router, "tasks.add", code: "invalid_params")
    try await expectError(router, "tasks.add", ["title": 4], code: "invalid_params")
    try await expectError(router, "tasks.setDone", ["id": "missing", "done": true], code: "not_found")
  }

  func testAddingATaskGoesThroughTheAppAndIsRecorded() async throws {
    let (state, settings, router) = try makeRouter()

    let added = try await ok(router, "tasks.add", ["title": " Book dentist ", "due": "2026-11-20", "priority": "high"])

    let id = try XCTUnwrap(added["id"] as? String)
    let saved = try XCTUnwrap(state.tasks.first { $0.id == id })
    XCTAssertEqual(saved.title, "Book dentist")
    XCTAssertEqual(saved.priority, .high)
    XCTAssertEqual(added["due"] as? String, "2026-11-20")
    XCTAssertEqual(settings.activity.first?.summary, "Added task “Book dentist”")
  }

  func testCompletingAndReschedulingATask() async throws {
    let (state, settings, router) = try makeRouter()
    let id = try await field(router, "tasks.add", ["title": "Review #212"], key: "id", as: String.self)

    let done = try await ok(router, "tasks.setDone", ["id": id, "done": true])
    XCTAssertEqual(done["done"] as? Bool, true)
    XCTAssertEqual(state.tasks.first { $0.id == id }?.completed, true)

    // Asking for what is already so changes nothing and logs nothing.
    let activityCount = settings.activity.count
    _ = try await ok(router, "tasks.setDone", ["id": id, "done": true])
    XCTAssertEqual(settings.activity.count, activityCount)

    let moved = try await ok(router, "tasks.reschedule", ["id": id, "due": "2026-11-18T15:30"])
    XCTAssertTrue((moved["due"] as? String)?.hasPrefix("2026-11-18T15:30:00") == true)

    try await expectError(router, "tasks.reschedule", ["id": id], code: "invalid_params")
    let inbox = try await ok(router, "tasks.reschedule", ["id": id, "due": NSNull()])
    XCTAssertNil(inbox["due"])
    XCTAssertNil(state.tasks.first { $0.id == id }?.dueDate)
  }

  func testTaskListScopesAndQuery() async throws {
    let (_, _, router) = try makeRouter()
    _ = try await call(router, "tasks.add", ["title": "Inbox thing"])
    _ = try await call(router, "tasks.add", ["title": "Today thing", "due": ClaudeBridgeDates.day(Date())])

    let inbox = try await field(router, "tasks.list", ["scope": "inbox"], key: "items", as: [[String: Any]].self)
    XCTAssertEqual(inbox.map { $0["title"] as? String }, ["Inbox thing"])
    let today = try await field(router, "tasks.list", key: "items", as: [[String: Any]].self)
    XCTAssertEqual(today.map { $0["title"] as? String }, ["Today thing"])
    let searched = try await field(router, "tasks.list", ["scope": "open", "query": "INBOX"], key: "items", as: [[String: Any]].self)
    XCTAssertEqual(searched.count, 1)
    try await expectError(router, "tasks.list", ["scope": "someday"], code: "invalid_params")
  }

  func testFocusSessionFromStartToFinish() async throws {
    let (state, _, router) = try makeRouter()
    let taskID = try await field(router, "tasks.add", ["title": "Sync fixes"], key: "id", as: String.self)

    let idle = try await ok(router, "focus.status")
    XCTAssertTrue(idle["focus"] is NSNull)
    try await expectError(router, "focus.start", ["minutes": 300], code: "invalid_params")

    let started = try await field(router, "focus.start", ["minutes": 25, "taskId": taskID], key: "focus", as: [String: Any].self)
    XCTAssertEqual(started["title"] as? String, "Sync fixes", "Untitled sessions take the linked task's name")
    XCTAssertEqual(started["status"] as? String, "running")
    XCTAssertEqual(started["lengthMinutes"] as? Int, 25)
    XCTAssertEqual(started["taskTitle"] as? String, "Sync fixes")

    let paused = try await field(router, "focus.pause", key: "focus", as: [String: Any].self)
    XCTAssertEqual(paused["status"] as? String, "paused")
    let resumed = try await field(router, "focus.resume", key: "focus", as: [String: Any].self)
    XCTAssertEqual(resumed["status"] as? String, "running")

    let extended = try await field(router, "focus.extend", ["minutes": 5], key: "focus", as: [String: Any].self)
    XCTAssertEqual(extended["lengthMinutes"] as? Int, 30)

    let finished = try await ok(router, "focus.finish")
    XCTAssertTrue(finished["focus"] is NSNull)
    XCTAssertEqual((finished["finishedPrevious"] as? [String: Any])?["status"] as? String, "done")
    XCTAssertNil(state.activeFocusBlock)
    try await expectError(router, "focus.finish", code: "not_found")
  }

  func testStartingFocusWhileOneRunsFinishesTheFirst() async throws {
    let (_, _, router) = try makeRouter()
    _ = try await call(router, "focus.start", ["title": "First", "minutes": 25])

    let second = try await ok(router, "focus.start", ["title": "Second", "openEnded": true])

    XCTAssertEqual((second["focus"] as? [String: Any])?["title"] as? String, "Second")
    XCTAssertNil((second["focus"] as? [String: Any])?["lengthMinutes"])
    XCTAssertEqual((second["finishedPrevious"] as? [String: Any])?["title"] as? String, "First")
    try await expectError(router, "focus.extend", ["minutes": 5], code: "invalid_params")
  }

  func testLinkingTakesNullToUnlink() async throws {
    let (_, _, router) = try makeRouter()
    let taskID = try await field(router, "tasks.add", ["title": "Spec"], key: "id", as: String.self)
    _ = try await call(router, "focus.start", ["title": "Writing", "minutes": 25])

    let linked = try await field(router, "focus.link", ["taskId": taskID], key: "focus", as: [String: Any].self)
    XCTAssertEqual(linked["taskId"] as? String, taskID)
    let unlinked = try await field(router, "focus.link", ["taskId": NSNull()], key: "focus", as: [String: Any].self)
    XCTAssertNil(unlinked["taskId"])
    try await expectError(router, "focus.link", [:], code: "invalid_params")
  }

  func testJournalStaysClosedUntilTurnedOn() async throws {
    let (state, settings, router) = try makeRouter()

    try await expectError(router, "journal.search", code: "journal_off")
    try await expectError(router, "journal.add", ["content": "Hello"], code: "journal_off")
    XCTAssertTrue(state.journalEntries.isEmpty)

    settings.journalAccess = true
    let entry = try await ok(router, "journal.add", ["content": "Shipped the bridge today.", "title": "Bridge"])
    XCTAssertEqual(entry["title"] as? String, "Bridge")
    let found = try await field(router, "journal.search", ["query": "bridge"], key: "items", as: [[String: Any]].self)
    XCTAssertEqual(found.map { $0["id"] as? String }, [entry["id"] as? String])
  }

  func testRoutinesAndGoals() async throws {
    let (state, settings, router) = try makeRouter()
    await state.createRoutine(title: "Vitamins", schedule: .daily, timeOfDay: .morning)
    let routineID = try XCTUnwrap(state.routines.first?.id)
    var draft = GoalDraft()
    draft.title = "Run 60 km"
    draft.kind = .target
    draft.source = .manual
    draft.target = 60
    draft.unit = "km"
    await state.createGoal(draft)
    let goalID = try XCTUnwrap(state.goals.first?.id)

    let ticked = try await ok(router, "routines.setDone", ["id": routineID, "done": true])
    XCTAssertEqual(ticked["today"] as? String, "done")
    let unticked = try await ok(router, "routines.setDone", ["id": routineID, "done": false])
    XCTAssertNil(unticked["today"])

    try await expectError(router, "goals.checkIn", ["id": goalID, "amount": 0], code: "invalid_params")
    let goal = try await ok(router, "goals.checkIn", ["id": goalID, "amount": 5.5])
    XCTAssertEqual(goal["current"] as? Double, 5.5)
    XCTAssertEqual(settings.activity.first?.summary, "Checked in on “Run 60 km”: 5.5 km")

    let today = try await ok(router, "today")
    XCTAssertEqual((today["routines"] as? [[String: Any]])?.count, 1)
    XCTAssertEqual((today["goals"] as? [[String: Any]])?.count, 1)
  }

  func testALockedAppAnswersOnlyStatus() async throws {
    let (state, _, router) = try makeRouter()
    state.localLockStatus = .locked(attemptsRemaining: 5)

    try await expectError(router, "today", code: "locked")
    try await expectError(router, "tasks.add", ["title": "Sneaky"], code: "locked")
    let status = try await call(router, "status")
    XCTAssertNil(status["error"])
    XCTAssertTrue(state.tasks.isEmpty)
  }

  func testActivityIsCappedAndKeptAcrossLaunches() throws {
    let suiteName = "serenity.claude.activity.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = ClaudeBridgeSettings(defaults: defaults)

    for index in 0..<(ClaudeBridgeSettings.activityLimit + 5) {
      settings.record("Change \(index)", at: Date(timeIntervalSince1970: Double(index)))
    }

    let reloaded = ClaudeBridgeSettings(defaults: defaults)
    XCTAssertEqual(reloaded.activity.count, ClaudeBridgeSettings.activityLimit)
    XCTAssertEqual(reloaded.activity.first?.summary, "Change \(ClaudeBridgeSettings.activityLimit + 4)")
  }
}

final class ClaudeBridgeDatesTests: XCTestCase {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    return calendar
  }()

  func testDaysAndMomentsRoundTrip() throws {
    let day = try XCTUnwrap(ClaudeBridgeDates.parse("2026-11-15", calendar: calendar))
    XCTAssertEqual(day, calendar.startOfDay(for: day))
    XCTAssertEqual(ClaudeBridgeDates.due(day, calendar: calendar), "2026-11-15")

    let local = try XCTUnwrap(ClaudeBridgeDates.parse("2026-11-15T14:30", calendar: calendar))
    XCTAssertEqual(ClaudeBridgeDates.due(local, calendar: calendar), "2026-11-15T14:30:00+05:30")

    let offset = try XCTUnwrap(ClaudeBridgeDates.parse("2026-11-15T09:00:00Z", calendar: calendar))
    XCTAssertEqual(ClaudeBridgeDates.moment(offset, timeZone: calendar.timeZone), "2026-11-15T14:30:00+05:30")
  }

  func testNonsenseDatesAreRefused() {
    XCTAssertNil(ClaudeBridgeDates.parse("2026-02-30", calendar: calendar))
    XCTAssertNil(ClaudeBridgeDates.parse("tomorrow", calendar: calendar))
    XCTAssertNil(ClaudeBridgeDates.parse("", calendar: calendar))
  }
}

final class ClaudeBridgeSocketTests: XCTestCase {
  func testRoundTripOverTheSocketAndOwnerOnlyPermissions() throws {
    // sun_path is short, so keep the path well under 104 bytes.
    let path = "/tmp/serenity-bridge-\(UUID().uuidString.prefix(8)).sock"
    let server = ClaudeBridgeSocketServer(path: path) { line in
      Data("echo:".utf8) + line
    }
    try server.start()
    defer { server.stop() }

    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      let bytes = Array(path.utf8)
      buffer.copyBytes(from: bytes)
      buffer[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(connected, 0)
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    // Two requests in one write, split across lines, each answered on its own line.
    let request = Array("one\ntwo\n".utf8)
    XCTAssertEqual(request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, request.count)

    var received = Data()
    var chunk = [UInt8](repeating: 0, count: 1024)
    while received.filter({ $0 == UInt8(ascii: "\n") }).count < 2 {
      let count = read(fd, &chunk, chunk.count)
      XCTAssertGreaterThan(count, 0, "No reply before the timeout")
      guard count > 0 else { break }
      received.append(contentsOf: chunk[0..<count])
    }
    let lines = String(decoding: received, as: UTF8.self).split(separator: "\n").map(String.init)
    XCTAssertEqual(Set(lines), ["echo:one", "echo:two"])
  }

  func testStoppingRemovesTheSocketFile() throws {
    let path = "/tmp/serenity-bridge-\(UUID().uuidString.prefix(8)).sock"
    let server = ClaudeBridgeSocketServer(path: path) { $0 }
    try server.start()
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))

    server.stop()

    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
  }
}
