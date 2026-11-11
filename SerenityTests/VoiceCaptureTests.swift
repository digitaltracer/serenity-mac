import Foundation
import XCTest
@testable import SerenityMac

final class VoiceCaptureParserTests: XCTestCase {
  private let utc = TimeZone(identifier: "UTC")!
  private let context = VoiceCaptureContext(
    goals: [.init(id: "run", title: "Run 60 km a month", unit: "km")],
    routines: [.init(id: "walk", title: "Evening walk")],
    projects: [.init(id: "agency", name: "Agency")]
  )

  func testSplitsOneNoteIntoTypedItems() throws {
    let response = """
    {"items":[
      {"kind":"task","text":"Send the Acme invoice","due":"2026-11-13T15:00","hasTime":true,"projectId":"agency","goalId":null,"amount":null,"routineId":null},
      {"kind":"goal_check_in","text":"felt slow","due":null,"hasTime":false,"projectId":null,"goalId":"run","amount":5,"routineId":null},
      {"kind":"journal","text":"Felt scattered first thing.","due":null,"hasTime":false,"projectId":null,"goalId":null,"amount":null,"routineId":null},
      {"kind":"routine_done","text":"","due":null,"hasTime":false,"projectId":null,"goalId":null,"amount":null,"routineId":"walk"}
    ]}
    """

    let items = try VoiceCaptureParser.decode(response, context: context, timeZone: utc)

    XCTAssertEqual(items.map(\.kind), [.task, .goalCheckIn, .journal, .routineDone])
    XCTAssertEqual(items[0].projectId, "agency")
    XCTAssertTrue(items[0].hasTime)
    XCTAssertEqual(items[0].dueDate, ISO8601DateFormatter().date(from: "2026-11-13T15:00:00Z"))
    XCTAssertEqual(items[1].amount, 5)
    XCTAssertEqual(items[3].routineId, "walk")
  }

  func testMadeUpIdsDemoteTheItem() throws {
    let response = """
    {"items":[
      {"kind":"goal_check_in","text":"did 20 pushups","due":null,"hasTime":false,"projectId":null,"goalId":"invented","amount":20,"routineId":null},
      {"kind":"routine_done","text":"meditated","due":null,"hasTime":false,"projectId":null,"goalId":null,"amount":null,"routineId":"nope"},
      {"kind":"task","text":"Call Sam","due":"tomorrow","hasTime":false,"projectId":"ghost","goalId":null,"amount":null,"routineId":null}
    ]}
    """

    let items = try VoiceCaptureParser.decode(response, context: context, timeZone: utc)

    XCTAssertEqual(items.map(\.kind), [.journal, .task, .task])
    XCTAssertNil(items[0].goalId)
    XCTAssertNil(items[2].projectId)
    XCTAssertNil(items[2].dueDate, "an unparseable date is dropped rather than guessed")
  }

  func testPromptListsWhatTheModelMayReference() {
    let prompt = VoiceCaptureParser.userPrompt(
      transcript: "Ran five k",
      context: context,
      now: Date(timeIntervalSince1970: 1_794_384_000),
      timeZone: utc
    )

    XCTAssertTrue(prompt.contains("- run: Run 60 km a month [km]"))
    XCTAssertTrue(prompt.contains("- walk: Evening walk"))
    XCTAssertTrue(prompt.contains("Ran five k"))
  }

  func testUploadCarriesModelPromptAndAudio() {
    let body = VoiceTranscriptionClient.multipartBody(
      boundary: "B",
      fields: ["model": "gpt-4o-transcribe", "prompt": "CloudKit", "response_format": "json"],
      fileName: "note.m4a",
      fileData: Data("audio".utf8)
    )
    let text = String(decoding: body, as: UTF8.self)

    XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ngpt-4o-transcribe\r\n"))
    XCTAssertTrue(text.contains("name=\"prompt\"\r\n\r\nCloudKit\r\n"))
    XCTAssertTrue(text.contains("filename=\"note.m4a\"\r\nContent-Type: audio/mp4\r\n\r\naudio\r\n"))
    XCTAssertTrue(text.hasSuffix("--B--\r\n"))
  }
}

@MainActor
final class VoiceCaptureSavingTests: XCTestCase {
  func testSavesEachKindWhereItBelongs() async throws {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-voice-state-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let suiteName = "serenity.voice.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: baseURL)
    }
    let state = AppState(
      backendProfileManager: BackendProfileManager(
        defaults: defaults,
        defaultsKey: "voice.backend",
        registry: BackendProfileRegistry(
          descriptors: BackendProfileRegistry.live.descriptors,
          validators: [.sqliteLocal: { .available(message: "ok") }]
        )
      ),
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil
    )

    var draft = GoalDraft()
    draft.title = "Run"
    draft.kind = .target
    draft.target = 60
    draft.unit = "km"
    await state.createGoal(draft)
    await state.createRoutine(title: "Walk", schedule: .daily, timeOfDay: .evening)
    let goalID = try XCTUnwrap(state.goals.first?.id)
    let routineID = try XCTUnwrap(state.routines.first?.id)

    let saved = await state.saveVoiceCaptureItems([
      VoiceCaptureItem(kind: .task, text: "Send the invoice", dueDate: Date(), hasTime: false),
      VoiceCaptureItem(kind: .journal, text: "Felt scattered."),
      VoiceCaptureItem(kind: .goalCheckIn, text: "felt slow", goalId: goalID, amount: 5),
      VoiceCaptureItem(kind: .routineDone, text: "", routineId: routineID),
      VoiceCaptureItem(kind: .task, text: "Left out", include: false),
    ])

    XCTAssertNil(state.activeAlert?.message)
    XCTAssertEqual(saved, 4)
    XCTAssertEqual(state.tasks.map(\.title), ["Send the invoice"])
    XCTAssertEqual(state.tasks.first?.tags, ["voice"])
    XCTAssertEqual(state.tasks.first?.dueDate, Calendar.current.startOfDay(for: Date()))
    XCTAssertEqual(state.journalEntries.map(\.content), ["Felt scattered."])
    XCTAssertEqual(state.goals.first?.config.checkIns?.map(\.amount), [5])
    XCTAssertEqual(state.routineSummaries().first?.today, .done)
  }
}
