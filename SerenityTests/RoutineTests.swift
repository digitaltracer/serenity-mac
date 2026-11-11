import CloudKit
import Foundation
import XCTest
@testable import SerenityMac

final class RoutineStreakTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
  }()

  private func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
  }

  private func routine(_ schedule: RoutineSchedule, createdOn created: Date) -> RoutineEntity {
    RoutineEntity(id: "r1", title: "Walk", schedule: schedule, timeOfDay: .evening, archived: false, createdAt: created, updatedAt: created)
  }

  private func checks(_ entries: [(Int, Int, RoutineCheckStatus)]) -> [String: RoutineCheckStatus] {
    entries.reduce(into: [:]) { map, entry in
      map[RoutineDay.key(for: date(entry.0, entry.1), calendar: calendar)] = entry.2
    }
  }

  private func summary(
    _ entries: [(Int, Int, RoutineCheckStatus)],
    schedule: RoutineSchedule = .daily,
    created: Date? = nil,
    now: Date? = nil
  ) -> RoutineSummary {
    RoutineStreaks.summary(
      for: routine(schedule, createdOn: created ?? date(11, 1)),
      checks: checks(entries),
      now: now ?? date(11, 11),
      calendar: calendar
    )
  }

  func testDayStaysOpenUntilThreeInTheMorning() {
    XCTAssertEqual(RoutineDay.key(for: RoutineDay.current(now: date(11, 12, hour: 2), calendar: calendar), calendar: calendar), "2026-11-11")
    XCTAssertEqual(RoutineDay.key(for: RoutineDay.current(now: date(11, 12, hour: 4), calendar: calendar), calendar: calendar), "2026-11-12")
  }

  func testUnmarkedTodayDoesNotBreakTheRun() {
    let result = summary([(11, 8, .done), (11, 9, .done), (11, 10, .done)])

    XCTAssertEqual(result.streak, 3)
    XCTAssertEqual(result.lastSevenDays.last, .open)
    XCTAssertEqual(result.streakLabel, "3 days")
  }

  func testDoneTodayExtendsTheRun() {
    XCTAssertEqual(summary([(11, 9, .done), (11, 10, .done), (11, 11, .done)]).streak, 3)
  }

  func testSkipKeepsTheRunWithoutCounting() {
    let result = summary([(11, 8, .done), (11, 9, .skipped), (11, 10, .done)])

    XCTAssertEqual(result.streak, 2)
    XCTAssertFalse(result.wasReset)
  }

  func testMissedDayResetsTheStreak() {
    XCTAssertEqual(summary([(11, 8, .done), (11, 10, .done)]).streak, 1)

    let reset = summary([(11, 8, .done)])
    XCTAssertEqual(reset.streak, 0)
    XCTAssertTrue(reset.wasReset)
    XCTAssertEqual(reset.streakLabel, "reset")
    XCTAssertEqual(Array(reset.lastSevenDays.suffix(3)), [.missed, .missed, .open])
  }

  func testNewRoutineIsNotReportedAsReset() {
    let result = summary([], created: date(11, 11))

    XCTAssertEqual(result.streak, 0)
    XCTAssertFalse(result.wasReset)
    XCTAssertEqual(result.streakLabel, "new")
    XCTAssertEqual(Array(result.lastSevenDays.prefix(6)), [.off, .off, .off, .off, .off, .off])
  }

  func testSetDaysIgnoreDaysOffSchedule() {
    let monWedFri: RoutineSchedule = .weekdays([2, 4, 6])
    let result = summary([(11, 4, .done), (11, 6, .done), (11, 9, .done)], schedule: monWedFri)

    XCTAssertEqual(result.streak, 3)
    XCTAssertTrue(result.isScheduledToday)
    XCTAssertFalse(summary([], schedule: monWedFri, now: date(11, 12)).isScheduledToday)
  }

  func testTimesAWeekCountsWeeksAndForgivesThePartialFirstWeek() {
    let result = summary(
      [(10, 28, .done), (10, 30, .done), (11, 2, .done), (11, 4, .done), (11, 6, .done), (11, 9, .done), (11, 10, .done)],
      schedule: .timesPerWeek(3),
      created: date(10, 28)
    )

    XCTAssertEqual(result.unit, .weeks)
    XCTAssertEqual(result.streak, 1)
    XCTAssertEqual(result.weekProgress?.done, 2)
    XCTAssertEqual(result.weekProgress?.target, 3)
    XCTAssertFalse(result.wasReset)
    XCTAssertFalse(result.lastSevenDays.contains(.missed))
  }

  func testTimesAWeekResetsAfterAShortWeek() {
    let result = summary([(11, 2, .done)], schedule: .timesPerWeek(3), created: date(10, 1))

    XCTAssertEqual(result.streak, 0)
    XCTAssertTrue(result.wasReset)
  }
}

final class RoutineStorageTests: XCTestCase {
  func testRoutinesAndChecksRoundTripAndQueueForSync() async throws {
    let repositories = try await makeRepositorySet()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let routine = RoutineEntity(
      id: "routine-1",
      title: "Morning pages",
      schedule: .weekdays([2, 4, 6]),
      timeOfDay: .morning,
      archived: false,
      createdAt: now,
      updatedAt: now
    )
    let check = RoutineCheckEntity(routineId: routine.id, day: "2027-01-15", status: .skipped, createdAt: now, updatedAt: now)

    try repositories.routines.save(routine)
    try repositories.routineChecks.save(check)

    XCTAssertEqual(try repositories.routines.fetchByID(routine.id), routine)
    XCTAssertEqual(try repositories.routineChecks.fetchByID(check.id), check)
    XCTAssertEqual(check.id, "routine-1:2027-01-15")

    let queued = try repositories.pendingSyncChanges.fetchPending(limit: 10).map(\.entityType)
    XCTAssertEqual(Set(queued), [SyncEntityType.routine, SyncEntityType.routineCheck])

    try repositories.routineChecks.deleteAll(routineId: routine.id)
    XCTAssertTrue(try repositories.routineChecks.fetchAll().isEmpty)
    let deletes = try repositories.pendingSyncChanges.fetchPending(limit: 10).filter { $0.entityType == SyncEntityType.routineCheck }
    XCTAssertEqual(deletes.map(\.operation), [.delete])
  }

  func testRoutineRecordsRoundTripThroughCloudKit() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let routine = RoutineEntity(id: "routine-2", title: "Run", schedule: .timesPerWeek(3), timeOfDay: .anytime, archived: true, createdAt: now, updatedAt: now)
    let check = RoutineCheckEntity(routineId: routine.id, day: "2027-01-16", status: .done, createdAt: now, updatedAt: now)

    let routineRecord = CKRecord(recordType: SyncEntityType.routine, recordID: CKRecord.ID(recordName: routine.id, zoneID: SerenityCloudKit.zoneID))
    try RoutineSyncRecordKind.encode(routine, into: routineRecord)
    XCTAssertEqual(try RoutineSyncRecordKind.decode(routineRecord), routine)

    let checkRecord = CKRecord(recordType: SyncEntityType.routineCheck, recordID: CKRecord.ID(recordName: check.id, zoneID: SerenityCloudKit.zoneID))
    RoutineCheckSyncRecordKind.encode(check, into: checkRecord)
    XCTAssertEqual(try RoutineCheckSyncRecordKind.decode(checkRecord), check)
  }

  private func makeRepositorySet() async throws -> GRDBCoreRepositorySet {
    let databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("serenity-routine-tests")
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("serenity.sqlite3")
    _ = try await DatabaseMigrationRunner().bootstrapDatabase(at: databaseURL)
    return try GRDBCoreRepositorySet.make(databasePath: databaseURL.path)
  }
}

@MainActor
final class RoutineAppStateTests: XCTestCase {
  func testTodayCanBeTickedUntickedAndSkipped() async throws {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-routine-state-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let suiteName = "serenity.routines.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: baseURL)
    }
    let state = AppState(
      backendProfileManager: BackendProfileManager(
        defaults: defaults,
        defaultsKey: "routines.backend",
        registry: BackendProfileRegistry(
          descriptors: BackendProfileRegistry.live.descriptors,
          validators: [.sqliteLocal: { .available(message: "ok") }]
        )
      ),
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil
    )

    await state.createRoutine(title: "  Vitamins ", schedule: .daily, timeOfDay: .morning)
    let routine = try XCTUnwrap(state.routines.first)
    XCTAssertEqual(routine.title, "Vitamins")

    await state.toggleRoutineDone(id: routine.id)
    XCTAssertEqual(state.routineChecks.map(\.status), [.done])
    XCTAssertEqual(state.routineChecks.first?.day, RoutineDay.key(for: RoutineDay.current()))
    XCTAssertEqual(state.routineSummaries().first?.streak, 1)

    await state.toggleRoutineDone(id: routine.id)
    XCTAssertTrue(state.routineChecks.isEmpty)

    await state.toggleRoutineSkip(id: routine.id)
    XCTAssertEqual(state.routineChecks.map(\.status), [.skipped])

    await state.deleteRoutine(id: routine.id)
    XCTAssertTrue(state.routines.isEmpty)
    XCTAssertTrue(state.routineChecks.isEmpty)
  }
}
