import CloudKit
import Foundation
import XCTest
@testable import SerenityMac

final class ICloudSyncTests: XCTestCase {
  // MARK: - Pending change ledger

  func testEnqueueRecordsPendingChangeAndCoalescesUpdates() async throws {
    let repositories = try await makeRepositorySet()
    let store = repositories.pendingSyncChanges

    try store.enqueue(entityType: SyncEntityType.task, entityId: "task-1", operation: .upsert)
    try store.enqueue(entityType: SyncEntityType.task, entityId: "task-1", operation: .upsert)
    try store.enqueue(entityType: SyncEntityType.task, entityId: "task-2", operation: .delete)

    let pending = try store.fetchPending(limit: 10)
    XCTAssertEqual(pending.count, 2)
    XCTAssertEqual(Set(pending.map(\.entityId)), Set(["task-1", "task-2"]))

    // Successive upserts on the same target collapse to a single row, so
    // attempts stays at 0 (the unique index re-keys the row).
    let task1Pending = pending.first { $0.entityId == "task-1" }
    XCTAssertEqual(task1Pending?.operation, .upsert)
    XCTAssertEqual(task1Pending?.attempts, 0)
  }

  func testSyncAwareTaskRepositoryEnqueuesOnSaveAndDelete() async throws {
    let repositories = try await makeRepositorySet()
    let now = Date()

    let task = TaskEntity(
      id: UUID().uuidString,
      title: "Sync me",
      description: nil,
      completed: false,
      completedAt: nil,
      priority: .medium,
      dueDate: nil,
      projectId: nil,
      tags: [],
      createdAt: now,
      updatedAt: now,
      subtasks: [],
      recurring: nil,
      userId: nil
    )

    try repositories.tasks.save(task)
    XCTAssertEqual(try repositories.pendingSyncChanges.count(), 1)

    try repositories.tasks.delete(id: task.id)
    let pending = try repositories.pendingSyncChanges.fetchPending(limit: 10)
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(pending.first?.operation, .delete)
  }

  func testSyncAwareProjectGoalAndAIRepositoriesEnqueueOnMutations() async throws {
    let (repositories, aiRepositories, _) = try await makeRepositoryBundle()
    let now = Date()
    let project = makeProject(now: now)
    let goal = makeGoal(now: now)
    let insight = makeInsight(now: now)
    let recap = makeRecap(now: now)
    let summary = makeSummary(now: now)

    try repositories.projects.save(project)
    try repositories.goals.save(goal)
    try aiRepositories.insights.save(insight)
    try aiRepositories.recaps.save(recap)
    try aiRepositories.summaries.save(summary)

    var pending = try repositories.pendingSyncChanges.fetchPending(limit: 20)
    XCTAssertEqual(pending.count, 5)
    XCTAssertEqual(
      Set(pending.map(\.entityType)),
      Set([
        SyncEntityType.project,
        SyncEntityType.goal,
        SyncEntityType.aiInsight,
        SyncEntityType.aiRecap,
        SyncEntityType.summary,
      ])
    )

    try repositories.pendingSyncChanges.markCompleted(ids: pending.map(\.id))
    try repositories.projects.delete(id: project.id)
    try repositories.goals.delete(id: goal.id)
    try aiRepositories.insights.delete(id: insight.id)
    try aiRepositories.recaps.delete(id: recap.id)
    try aiRepositories.summaries.delete(id: summary.id)

    pending = try repositories.pendingSyncChanges.fetchPending(limit: 20)
    XCTAssertEqual(pending.count, 5)
    XCTAssertTrue(pending.allSatisfy { $0.operation == .delete })
  }

  func testApplyRemoteUpsertSkipsLedger() async throws {
    let repositories = try await makeRepositorySet()
    let now = Date()

    let task = TaskEntity(
      id: UUID().uuidString,
      title: "Pulled",
      description: nil,
      completed: false,
      completedAt: nil,
      priority: .low,
      dueDate: nil,
      projectId: nil,
      tags: ["from-cloud"],
      createdAt: now,
      updatedAt: now,
      subtasks: [],
      recurring: nil,
      userId: nil
    )

    try repositories.tasks.applyRemoteUpsert(task)

    let saved = try repositories.tasks.fetchByID(task.id)
    XCTAssertNotNil(saved)
    XCTAssertEqual(try repositories.pendingSyncChanges.count(), 0)
  }

  func testApplyRemoteUpsertForAllSyncedTypesSkipsLedger() async throws {
    let (repositories, aiRepositories, _) = try await makeRepositoryBundle()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let project = makeProject(now: now)
    let goal = makeGoal(now: now)
    let insight = makeInsight(now: now)
    let recap = makeRecap(now: now)
    let summary = makeSummary(now: now)

    guard
      let insightRepository = aiRepositories.insights as? SyncAwareAIInsightRepository,
      let recapRepository = aiRepositories.recaps as? SyncAwareAIRecapRepository,
      let summaryRepository = aiRepositories.summaries as? SyncAwareSummaryRepository
    else {
      XCTFail("Expected sync-aware AI repositories")
      return
    }

    try repositories.projects.applyRemoteUpsert(project)
    try repositories.goals.applyRemoteUpsert(goal)
    try insightRepository.applyRemoteUpsert(insight)
    try recapRepository.applyRemoteUpsert(recap)
    try summaryRepository.applyRemoteUpsert(summary)

    XCTAssertEqual(try repositories.pendingSyncChanges.count(), 0)
    XCTAssertEqual(try repositories.projects.fetchByID(project.id), project)
    XCTAssertEqual(try repositories.goals.fetchByID(goal.id), goal)
    XCTAssertEqual(try aiRepositories.insights.fetchByID(insight.id), insight)
    XCTAssertEqual(try aiRepositories.recaps.fetchByID(recap.id), recap)
    XCTAssertEqual(try aiRepositories.summaries.fetchByID(summary.id), summary)
  }

  func testMarkCompletedRemovesEntries() async throws {
    let repositories = try await makeRepositorySet()
    let store = repositories.pendingSyncChanges

    try store.enqueue(entityType: SyncEntityType.task, entityId: "a", operation: .upsert)
    try store.enqueue(entityType: SyncEntityType.task, entityId: "b", operation: .upsert)

    let pending = try store.fetchPending(limit: 10)
    try store.markCompleted(ids: pending.map(\.id))

    XCTAssertEqual(try store.count(), 0)
  }

  func testMarkFailedIncrementsAttemptsAndRecordsError() async throws {
    let repositories = try await makeRepositorySet()
    let store = repositories.pendingSyncChanges

    try store.enqueue(entityType: SyncEntityType.task, entityId: "a", operation: .upsert)
    let initial = try store.fetchPending(limit: 10)

    try store.markFailed(ids: initial.map(\.id), error: "network down")

    let after = try store.fetchPending(limit: 10)
    XCTAssertEqual(after.first?.attempts, 1)
    XCTAssertEqual(after.first?.lastError, "network down")
    XCTAssertNotNil(after.first?.lastAttemptAt)
  }

  // MARK: - Cloud-sync state store

  func testCloudSyncStateRoundTripsBlobs() async throws {
    let repositories = try await makeRepositorySet()
    let store = repositories.cloudSyncState

    XCTAssertNil(try store.loadValue(forKey: "token"))

    let payload = Data([0x01, 0x02, 0x03, 0x04])
    try store.saveValue(payload, forKey: "token")
    XCTAssertEqual(try store.loadValue(forKey: "token"), payload)

    try store.saveValue(nil, forKey: "token")
    XCTAssertNil(try store.loadValue(forKey: "token"))
  }

  // MARK: - CKRecord round-trip

  func testTaskRecordRoundTripPreservesAllFields() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let task = TaskEntity(
      id: "task-1",
      title: "Review PR",
      description: "Look at the journal sync diff",
      completed: false,
      completedAt: nil,
      priority: .high,
      dueDate: now.addingTimeInterval(3600),
      projectId: "proj-x",
      tags: ["review", "p1"],
      createdAt: now.addingTimeInterval(-3600),
      updatedAt: now,
      subtasks: [
        TaskSubtask(id: "s1", title: "Read it", completed: true, order: 0),
        TaskSubtask(id: "s2", title: "Comment", completed: false, order: 1),
      ],
      recurring: TaskRecurringPattern(type: .weekly, interval: 1, endDate: nil),
      userId: "user-7"
    )

    let recordID = CKRecord.ID(recordName: task.id, zoneID: SerenityCloudKit.zoneID)
    let record = CKRecord(recordType: SyncEntityType.task, recordID: recordID)
    try TaskSyncRecordKind.encode(task, into: record)

    let decoded = try TaskSyncRecordKind.decode(record)
    XCTAssertEqual(decoded, task)
  }

  func testJournalRecordRoundTripPreservesAllFields() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = JournalEntryEntity(
      id: "entry-1",
      title: "Sunday recap",
      content: "Long content body with newline\nand emoji 🎉",
      date: now.addingTimeInterval(-86_400),
      tags: ["personal"],
      createdAt: now.addingTimeInterval(-86_400),
      updatedAt: now,
      pinned: true,
      mood: .happy,
      attachments: [
        JournalAttachmentEntity(
          id: "a1",
          type: .image,
          filename: "photo.jpg",
          originalName: "IMG_0001.jpg",
          path: "Attachments/photo.jpg",
          size: 12_345,
          mimeType: "image/jpeg",
          createdAt: now.addingTimeInterval(-3600)
        )
      ],
      userId: "user-9"
    )

    let recordID = CKRecord.ID(recordName: entry.id, zoneID: SerenityCloudKit.zoneID)
    let record = CKRecord(recordType: SyncEntityType.journalEntry, recordID: recordID)
    try JournalEntrySyncRecordKind.encode(entry, into: record)

    let decoded = try JournalEntrySyncRecordKind.decode(record)
    XCTAssertEqual(decoded, entry)
  }

  func testProjectGoalAndAIRecordRoundTripsPreserveAllFields() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let project = makeProject(now: now)
    let goal = makeGoal(now: now)
    let insight = makeInsight(now: now)
    let recap = makeRecap(now: now)
    let summary = makeSummary(now: now)

    let projectRecord = CKRecord(
      recordType: SyncEntityType.project,
      recordID: CKRecord.ID(recordName: project.id, zoneID: SerenityCloudKit.zoneID)
    )
    try ProjectSyncRecordKind.encode(project, into: projectRecord)
    XCTAssertEqual(try ProjectSyncRecordKind.decode(projectRecord), project)

    let goalRecord = CKRecord(
      recordType: SyncEntityType.goal,
      recordID: CKRecord.ID(recordName: goal.id, zoneID: SerenityCloudKit.zoneID)
    )
    try GoalSyncRecordKind.encode(goal, into: goalRecord)
    XCTAssertEqual(try GoalSyncRecordKind.decode(goalRecord), goal)

    let insightRecord = CKRecord(
      recordType: SyncEntityType.aiInsight,
      recordID: CKRecord.ID(recordName: insight.id, zoneID: SerenityCloudKit.zoneID)
    )
    try AIInsightSyncRecordKind.encode(insight, into: insightRecord)
    XCTAssertEqual(try AIInsightSyncRecordKind.decode(insightRecord), insight)

    let recapRecord = CKRecord(
      recordType: SyncEntityType.aiRecap,
      recordID: CKRecord.ID(recordName: recap.id, zoneID: SerenityCloudKit.zoneID)
    )
    try AIRecapSyncRecordKind.encode(recap, into: recapRecord)
    XCTAssertEqual(try AIRecapSyncRecordKind.decode(recapRecord), recap)

    let summaryRecord = CKRecord(
      recordType: SyncEntityType.summary,
      recordID: CKRecord.ID(recordName: summary.id, zoneID: SerenityCloudKit.zoneID)
    )
    try SummarySyncRecordKind.encode(summary, into: summaryRecord)
    XCTAssertEqual(try SummarySyncRecordKind.decode(summaryRecord), summary)
  }

  func testICloudEngineRegistersEverySyncedEntityType() async throws {
    let (repositories, aiRepositories, _) = try await makeRepositoryBundle()
    guard
      let insightRepository = aiRepositories.insights as? SyncAwareAIInsightRepository,
      let recapRepository = aiRepositories.recaps as? SyncAwareAIRecapRepository,
      let summaryRepository = aiRepositories.summaries as? SyncAwareSummaryRepository
    else {
      XCTFail("Expected sync-aware AI repositories")
      return
    }

    let engine = ICloudSyncEngine(
      container: FakeICloudSyncContainer(),
      pendingStore: repositories.pendingSyncChanges,
      stateStore: repositories.cloudSyncState,
      recordKinds: [
        TaskSyncRecordKind(repository: repositories.tasks),
        ProjectSyncRecordKind(repository: repositories.projects),
        JournalEntrySyncRecordKind(repository: repositories.journal),
        GoalSyncRecordKind(repository: repositories.goals),
        AIInsightSyncRecordKind(repository: insightRepository),
        AIRecapSyncRecordKind(repository: recapRepository),
        SummarySyncRecordKind(repository: summaryRepository),
      ],
      stateUpdate: { _ in }
    )

    let registered = await engine.registeredEntityTypes()
    XCTAssertEqual(
      registered,
      Set([
        SyncEntityType.task,
        SyncEntityType.project,
        SyncEntityType.journalEntry,
        SyncEntityType.goal,
        SyncEntityType.aiInsight,
        SyncEntityType.aiRecap,
        SyncEntityType.summary,
      ])
    )
  }

  func testInitialExportEnqueuesEverySyncedEntityOnce() async throws {
    let (repositories, aiRepositories, _) = try await makeRepositoryBundle()
    let now = Date()

    try repositories.tasks.save(
      TaskEntity(
        id: "task-initial",
        title: "Initial task",
        description: nil,
        completed: false,
        completedAt: nil,
        priority: .medium,
        dueDate: nil,
        projectId: nil,
        tags: [],
        createdAt: now,
        updatedAt: now,
        subtasks: [],
        recurring: nil,
        userId: nil
      )
    )
    try repositories.projects.save(makeProject(now: now))
    try repositories.journal.save(
      JournalEntryEntity(
        id: "journal-initial",
        title: "Initial journal",
        content: "Entry",
        date: now,
        tags: [],
        createdAt: now,
        updatedAt: now,
        pinned: false,
        mood: nil,
        attachments: [],
        userId: nil
      )
    )
    try repositories.goals.save(makeGoal(now: now))
    try aiRepositories.insights.save(makeInsight(now: now))
    try aiRepositories.recaps.save(makeRecap(now: now))
    try aiRepositories.summaries.save(makeSummary(now: now))
    try repositories.pendingSyncChanges.markCompleted(
      ids: try repositories.pendingSyncChanges.fetchPending(limit: 20).map(\.id)
    )

    let exporter = CloudSyncInitialExporter(coreRepositories: repositories, aiRepositories: aiRepositories)
    try exporter.enqueueIfNeeded()

    let pending = try repositories.pendingSyncChanges.fetchPending(limit: 20)
    XCTAssertEqual(pending.count, 7)
    XCTAssertEqual(
      Set(pending.map(\.entityType)),
      Set([
        SyncEntityType.task,
        SyncEntityType.project,
        SyncEntityType.journalEntry,
        SyncEntityType.goal,
        SyncEntityType.aiInsight,
        SyncEntityType.aiRecap,
        SyncEntityType.summary,
      ])
    )

    try exporter.enqueueIfNeeded()
    XCTAssertEqual(try repositories.pendingSyncChanges.fetchPending(limit: 20).count, 7)
  }

  // MARK: - Helpers

  private func makeRepositorySet() async throws -> GRDBCoreRepositorySet {
    let (repositories, _, _) = try await makeRepositoryBundle()
    return repositories
  }

  private func makeRepositoryBundle() async throws -> (GRDBCoreRepositorySet, GRDBAIRepositorySet, URL) {
    let databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("serenity-icloud-tests")
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("serenity.sqlite3")

    let runner = DatabaseMigrationRunner()
    _ = try await runner.bootstrapDatabase(at: databaseURL)

    let repositories = try GRDBCoreRepositorySet.make(databasePath: databaseURL.path)
    let aiRepositories = try GRDBAIRepositorySet.make(
      databasePath: databaseURL.path,
      pendingStore: repositories.pendingSyncChanges
    )
    return (repositories, aiRepositories, databaseURL)
  }

  private func makeProject(now: Date) -> ProjectEntity {
    ProjectEntity(
      id: "project-1",
      name: "Project",
      description: "Project description",
      color: "#33AA77",
      icon: "folder",
      createdAt: now.addingTimeInterval(-300),
      updatedAt: now,
      archived: true,
      userId: "user-1"
    )
  }

  private func makeGoal(now: Date) -> GoalEntity {
    GoalEntity(
      id: "goal-1",
      title: "Goal",
      description: "Goal description",
      type: .projectTasks,
      config: GoalConfig(
        targetCount: 10,
        projectId: "project-1",
        priority: .high,
        streakDays: nil,
        targetRate: nil,
        timeframe: .weekly
      ),
      progress: GoalProgress(
        current: 4,
        target: 10,
        percentage: 40,
        isCompleted: false,
        periodStart: now.addingTimeInterval(-86_400),
        periodEnd: now.addingTimeInterval(86_400)
      ),
      status: .active,
      priority: .high,
      reminders: [
        GoalReminder(
          id: "reminder-1",
          goalId: "goal-1",
          taskId: nil,
          title: "Check goal",
          description: "Review progress",
          reminderDate: now.addingTimeInterval(3600),
          type: .goalCheck,
          status: .pending,
          repeatPattern: ReminderRepeatPattern(type: .weekly, interval: 1, endDate: nil),
          notificationSettings: ReminderNotificationSettings(enabled: true, sound: false, popup: true, beforeMinutes: 15),
          createdAt: now,
          updatedAt: now,
          userId: "user-1"
        )
      ],
      createdAt: now.addingTimeInterval(-400),
      updatedAt: now,
      userId: "user-1"
    )
  }

  private func makeInsight(now: Date) -> AIInsightEntity {
    AIInsightEntity(
      id: "insight-1",
      provider: .openai,
      type: .recommendation,
      title: "Insight",
      description: "Recommendation body",
      confidence: 0.82,
      category: .goals,
      actionable: true,
      metadataJSON: #"{"metric":"test"}"#,
      createdAt: now.addingTimeInterval(-200),
      updatedAt: now,
      userRating: 4,
      dismissed: false,
      markedHelpful: true,
      userNotes: "Helpful",
      visualizationDataJSON: #"{"kind":"bar"}"#,
      actionabilitySuggestions: ["Do one thing", "Then another"],
      themeID: "theme-1",
      isRecurring: true,
      occurrenceNumber: 2
    )
  }

  private func makeRecap(now: Date) -> AIRecapEntity {
    AIRecapEntity(
      id: "recap-1",
      provider: .gemini,
      type: .weekly,
      title: "Weekly recap",
      summary: "Summary",
      highlights: ["A", "B"],
      challenges: ["C"],
      recommendations: ["D"],
      period: AIRecapPeriod(start: now.addingTimeInterval(-604_800), end: now),
      metadataJSON: #"{"source":"test"}"#,
      createdAt: now.addingTimeInterval(-100),
      updatedAt: now,
      viewed: true,
      favorited: true,
      exported: false
    )
  }

  private func makeSummary(now: Date) -> SummaryEntity {
    SummaryEntity(
      id: "summary-1",
      title: "Task summary",
      content: "Summary content",
      summaryType: .tasks,
      startDate: now.addingTimeInterval(-604_800),
      endDate: now,
      generatedAt: now,
      wordCount: 2,
      metadataJSON: #"{"source":"test"}"#,
      provider: .anthropic,
      promptTokens: 10,
      completionTokens: 20,
      totalTokens: 30,
      createdAt: now.addingTimeInterval(-50),
      updatedAt: now
    )
  }
}

private struct FakeICloudSyncContainer: ICloudSyncContainer {
  func accountStatus() async throws -> CKAccountStatus {
    .available
  }

  func privateDatabase() -> CKDatabase {
    CKContainer.default().privateCloudDatabase
  }
}
