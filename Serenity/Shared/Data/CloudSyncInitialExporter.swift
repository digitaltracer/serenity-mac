import Foundation

struct CloudSyncInitialExporter {
  let coreRepositories: GRDBCoreRepositorySet
  let aiRepositories: GRDBAIRepositorySet

  func enqueueIfNeeded() throws {
    guard
      let stored = try coreRepositories.cloudSyncState.loadValue(forKey: SerenityCloudKit.StateKey.initialExportCompleted),
      String(data: stored, encoding: .utf8) == "1"
    else {
      try enqueueAll()
      try coreRepositories.cloudSyncState.saveValue(
        Data("1".utf8),
        forKey: SerenityCloudKit.StateKey.initialExportCompleted
      )
      return
    }
  }

  private func enqueueAll() throws {
    let pendingStore = coreRepositories.pendingSyncChanges

    for task in try coreRepositories.tasks.fetchAll() {
      try pendingStore.enqueue(entityType: SyncEntityType.task, entityId: task.id, operation: .upsert)
    }
    for project in try coreRepositories.projects.fetchAll(includeArchived: true) {
      try pendingStore.enqueue(entityType: SyncEntityType.project, entityId: project.id, operation: .upsert)
    }
    for entry in try coreRepositories.journal.fetchAll() {
      try pendingStore.enqueue(entityType: SyncEntityType.journalEntry, entityId: entry.id, operation: .upsert)
    }
    for goal in try coreRepositories.goals.fetchAll() {
      try pendingStore.enqueue(entityType: SyncEntityType.goal, entityId: goal.id, operation: .upsert)
    }
    for insight in try aiRepositories.insights.fetchAll(limit: Int.max) {
      try pendingStore.enqueue(entityType: SyncEntityType.aiInsight, entityId: insight.id, operation: .upsert)
    }
    for recap in try aiRepositories.recaps.fetchAll(limit: Int.max) {
      try pendingStore.enqueue(entityType: SyncEntityType.aiRecap, entityId: recap.id, operation: .upsert)
    }
    for summary in try aiRepositories.summaries.fetchAll() {
      try pendingStore.enqueue(entityType: SyncEntityType.summary, entityId: summary.id, operation: .upsert)
    }
  }
}
