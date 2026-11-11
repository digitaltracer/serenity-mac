# Acting on the 2026-09-23 Serenity app review

## 1. Outcome

The task was to check the agent-written review in `docs/reviews/2026-09-23-app-review.md` and turn it into one implementation plan.

Most of the review is correct. Every high-risk finding in its "Fix first" section, and in the data, sync and security parts of its implementation section, holds up against the code. Four of its proposed fixes are wrong or incomplete and are corrected below. About two-thirds of the "new features" section is deferred: it adds surface area before the existing sync and import paths are reliable.

The work runs in seven ordered phases:

0. Get Anthropic calls working again, stop logging private text, and make the stand-up test independent of the real date.
1. Stop one failing integration from blocking the others, and stop an unreachable backend from quietly switching the app to local storage.
2. Put all SQLite access on one shared connection, and make secret storage safe.
3. Fix the iCloud sync paths that lose or revert edits.
4. Improve AI requests and error reporting.
5. Fix the prompt problems that cause wrong task updates.
6. Fix a short list of product bugs.

Once this is done, AI features work with current Claude models, edits made on another device (or during a sync) survive, an offline launch never hides your remote data, and one expired token no longer stops every integration.

## 2. Rationale

Decision criteria, in order: no silent data loss; keeping the AI features working; the cost to one developer of building and maintaining each change.

### What the review got right (verified)
- Every Anthropic request sends `temperature: 0` and `max_tokens: 1200` (`Serenity/Shared/AI/AIProviderAPIClient.swift:318-334`). The current API docs confirm that Opus 4.7, 4.8, 5 and 5.5, Sonnet 5 and Fable reject sampling parameters with a 400 error. The built-in fallback model is `claude-opus-4-7` (`Serenity/Shared/AI/AIWorkflowService.swift:62`).
- iCloud sync can lose and revert edits, in seven separate ways:
  - A newer local edit keeps the old row id in the pending-changes queue, and the queue deletes rows by that id when a push finishes (`Serenity/Shared/Data/CloudSyncStateStore.swift:55-60`, `:89-99`).
  - A pull overwrites local records with no pending-edit or `updatedAt` check (`Serenity/Shared/Data/SyncAwareRepositories.swift:50-52`).
  - Every push builds a fresh `CKRecord` and saves it with `.changedKeys`, so CloudKit never reports a conflict (`Serenity/Shared/Data/CloudKitRecordMapping.swift:71`, `Serenity/Shared/Data/iCloudSyncEngine.swift:267`).
  - A record that fails to apply is skipped for good, because the change token advances anyway (`iCloudSyncEngine.swift:338-380`).
  - A sync request made while a sync is running is dropped (`:70`).
  - The "zone created" flag is never reset (`:99-122`).
  - After a pull, the screen is not reloaded (`Serenity/Shared/App/AppState.swift:3831-3835`).
- An unreachable backend at launch makes the fallback to local SQLite permanent (`AppState.swift:477-495` calls `switchProfile`, which saves the choice at `Serenity/Shared/Data/BackendProfiles.swift:180`).
- "Sync all" wraps Google, GitHub and Slack in one `do/catch` (`AppState.swift:1111-1171`). Within Slack, one channel that throws discards every channel's cursor (`Serenity/Shared/Integrations/SlackMessageReader.swift:172`, `:197`, `:227-232`).
- Core, Slack, AI and audit repositories each open their own `DatabaseQueue` on the same file, and none sets a busy timeout (`Serenity/Shared/Data/CoreRepositories.swift:651`, `Serenity/Shared/Data/SQLiteBackendAdapter.swift:54`, `:64`, `:83`, `Serenity/Shared/Data/AIRepositories.swift:1191`).
- The Keychain deletes the old item before adding the new one (`Serenity/Shared/Security/KeychainSecretStore.swift:44-59`). OAuth sessions are stored in UserDefaults (`Serenity/Shared/Auth/AuthSessionManager.swift:217-246`).
- The stand-up planner falls back to `Date()` for day labels (`Serenity/Shared/App/StandupPlanner.swift:587`, `:607`), which breaks the test at `SerenityTests/StandupPlannerTests.swift:199`. Two daily-surface tests already fail on this machine because of the locale (they expect "Dec 5" but get "5 Dec"). This bug adds a third failure.
- Prompt tag lists include internal link tags (`AppState.swift:2706`, not `:2694` as the review says).
- GitHub PR tasks are always due "now" (`Serenity/Shared/Integrations/IntegrationServices.swift:626`). Template insights, recaps and summaries log invented token counts (`AIWorkflowService.swift:946` and nearby).

### Where the review is wrong or incomplete
- **Pending-row fix.** The review suggests deleting with `WHERE id = ? AND queued_at = ?`. That still loses an edit made in the same second, because `queued_at` is stored as second-resolution ISO 8601 (`CloudSyncStateStore.swift:67`). Instead, give the pending row a new id on every enqueue (set `id = excluded.id` in the `ON CONFLICT` clause). The finishing push then deletes nothing, and the newer edit stays queued.
- **Keychain fix.** The review suggests `SecItemUpdate`. The delete-then-add exists on purpose: it migrates items to synchronizable (comment at `KeychainSecretStore.swift:41-43`). Use `SecItemUpdate` first, and delete-then-add only when the synchronizable attribute has to change. Do that step so a failure can be recovered from.
- **iCloud test plan.** The review suggests a fake container, but the engine uses a concrete `CKDatabase` (`iCloudSyncEngine.swift:17`). A protocol over the database calls has to come first.
- **"Newer models think by default."** This is true for Opus 5, Opus 5.5, Sonnet 5 and Fable, where Opus 5.5 and Fable cannot turn thinking off at all. It is false for Opus 4.7 and 4.8, where thinking is off unless requested. Raising `max_tokens` is still right.
- **Model catalog.** Adding catalog entries alone changes nothing. When no model is set, the service uses the first entry of an alphabetically sorted list of verified models (`AIWorkflowService.swift:1723-1740`; the sorting is at `AIProviderAPIClient.swift:179`, `:374`, `:462`, `:607`). The default needs to be curated.

### Decisions that were argued out
- **Unreachable backend: keep the remote selection. Do not fall back to SQLite, even for one session.** Postgres and Serenity Cloud have no local cache or offline write path: every read and write goes straight to the adapter (`AppState.swift:3867-3900`). iCloud sync only wraps the SQLite repositories (`AppState.swift:3766`, `:3890`). A session-only fallback would show an old or empty local dataset, and any edit made there would disappear from view at the next launch. Keeping the selection loses nothing silently: saves fail with an error, because the adapters already throw, and already-loaded data stays on screen (`AppState.swift:2805-2834`). The cost is no offline editing for remote-backend users. That was judged acceptable, because offline editing already isn't safe today.
- **One shared `DatabaseQueue`, not a WAL `DatabasePool`.** Nothing in the code needs concurrent reads: refresh loads tables one after another. A pool would also not fix the main-thread blocking. Revisit only if profiling shows stalls.
- **Native structured outputs wait until phase 4.** Dropping temperature, raising `max_tokens`, handling stop reasons and curating the default model fix the breakage. Schema enforcement improves reliability but isn't needed to unblock anything.
- **Repair retries keep the original input, through the existing single-prompt interface.** A multi-turn repair is optional. The stand-up "speakable" retry already includes the previous JSON (`AIWorkflowService.swift:1082-1085`); it mainly needs an accurate message instead of "could not be decoded".

## 3. Scope and Acceptance Criteria

### In scope
Phases 0 to 6 below.

### Deferred
These wait until the sync and import foundations are fixed:
- imports of reviews requested of you and issues assigned to you
- CI status on PR tasks
- periodic GitHub sync
- a system-wide capture hotkey
- a URL scheme or Shortcuts action
- recognising pasted links without a command
- notification action buttons
- model-written weekly reviews
- more stand-up sources (merged PRs, reviews given, meetings)
- a stand-up reminder and a one-click "mark blocked"
- storing CloudKit system fields beyond what phase 3 needs
- Postgres connection reuse
- app-lock hashing and Keychain storage
- search and `@Published` performance work
- Swift 6 language mode
- pruning Slack's seen-messages table
- prompt caching
- cost-tracking cleanups beyond removing invented usage

### Not doing now
- an MCP server or CLI over tasks
- showing meetings as time blocks
- Slack write-back, such as a ✅ reaction on accept
- failing over between AI providers

### Acceptance criteria
1. A quick capture with only an Anthropic key and no model picked succeeds on a current Claude model. The request body contains no `temperature` field.
2. The stand-up tests pass for any fixed clock, and `swift test` is back to the two known locale failures.
3. With GitHub or Google throwing, the other integrations still sync, and "Sync all" reports each result separately.
4. With one Slack channel returning `not_in_channel`, the cursors of the other channels are saved.
5. Two overlapping Slack syncs never both run, so no duplicate proposals appear and no token refreshes run in parallel.
6. Launching with Postgres or Serenity Cloud unreachable:
   - keeps that backend selected in the saved settings
   - shows a banner with Retry and "Switch to local"
   - writes no tasks, projects, journal entries or goals to SQLite (AI and audit records always live in SQLite, whatever the backend)
   - shows an error on a save and keeps the typed text
7. An expired Serenity Cloud access token is refreshed before the backend is checked, so an expired token alone does not mark it unreachable. A token that expires while the app is running is refreshed too. A refresh that fails because the network is down keeps the stored session.
8. With the repositories sharing one queue, concurrent writes from the core, Slack, AI and audit code never fail with "database is locked". An entity save and its pending-change row commit together, or neither does.
9. A backup taken during writes opens cleanly and passes `PRAGMA integrity_check`.
10. Updating a Keychain secret never leaves it missing when the write fails, even if restoring the old value also fails. OAuth sessions move from UserDefaults to the Keychain, and the UserDefaults copy is removed only after the Keychain read-back succeeds.
11. Using the fake CloudKit database:
    - an edit or delete made during a push, in the same second, survives
    - a failed apply keeps the change token, and the record is retried
    - a record that always fails to apply is set aside after a fixed number of tries, and the token then advances
    - a remote edit newer than a pending local edit wins, and clears that pending row
    - an edit made while a conflict is being resolved is not lost
    - more than 200 queued changes drain, and a pass that makes no progress stops instead of looping
    - a deleted zone is recreated and everything is exported again, without relaunching
    - an expired token triggers a full refetch

    Clearing a due date must also clear it on the server. The fake database can't prove this, so it is part of the manual two-device check.
12. A change pulled from iCloud shows on screen without relaunching, and editing that record afterwards does not revert it.
13. A decode failure is logged without any response text.
14. A Slack "update" proposal keeps the task's title and description unless the message renames or rewrites the work. "Tomorrow" in a message sent yesterday resolves to today.
15. The prompt tag list contains no `slack-thread-*` or `github-pr-*` tags.
16. A GitHub PR task:
    - has no due date
    - completes when the PR is merged or closed
    - updates its title
    - stays deleted after you delete it

## 4. Implementation Plan

### Phase 0: containment (no dependencies)
1. **Anthropic request body** (`AIProviderAPIClient.swift:305-340`):
   - Remove `temperature`.
   - Raise `max_tokens` to about 16,000.
   - Send `output_config: {effort: "low"}` to models that accept it.
   - Decode `stop_reason`, and map `max_tokens` and `refusal` to the existing incomplete-response error instead of the JSON-repair path.
2. **Default model.** Replace "first verified model" in `resolvedModel` (`AIWorkflowService.swift:1723-1740`) with a curated default per provider, used whenever that default appears in the verified list. Show the resolved model in the picker.
   - Add `claude-sonnet-5`, `claude-opus-5-5`, `claude-opus-5`, `claude-opus-4-8` and `claude-fable-5-1` to the catalog and prices (`AIWorkflowService.swift:61-68`, `:1903-1908`).
   - Choosing the curated Anthropic default is left to the implementer; Sonnet 5 fits a cost-sensitive classification route.
3. **Private text in logs.** On decode failure, log the reply's length and top-level keys, never its text (`AIWorkflowService.swift:306-311`, `:484-488`, `:1322-1327`; logger at `Serenity/Shared/App/AppLogger.swift:13`).
4. **Stand-up clock.** Pass `now` into every day and time label (`StandupPlanner.swift:379`, `:389`, `:397`, `:406`, `:412`, `:446`). Then remove the `Date()` defaults at `:587`, `:607` and in `windowLabel` at `:612`, so the compiler finds any call site that was missed.

### Phase 1: failure isolation and the backend choice
1. **"Sync all".** Give each provider its own `do/catch` and collect one result per provider (`AppState.swift:1103-1172`).
2. **Slack channels.** Catch errors per channel in the reader, and return cursors for the channels that succeeded along with the failures (`SlackMessageReader.swift:162-232`).
3. **One Slack sync at a time.** Add an in-flight guard to `syncSlackNow`: a second call waits for, or joins, the running pass (`AppState.swift:1270`). Also make the token refresh run one at a time (`Serenity/Shared/Integrations/SlackIntegrationService.swift:278-303`).
4. **Replies under older threads.** Re-read replies for threads you took part in whose parent is older than the history window (`SlackMessageReader.swift:191-209`). Bound it with a time limit so the list doesn't grow forever.
5. **Unreachable backend** (`AppState.swift:477-495`):
   - Stop calling `switchProfile(to: .sqliteLocal)`.
   - Keep the selection and add an "unavailable" state to the backend state.
   - Show a persistent banner with Retry and "Switch to local". "Switch to local" is the only path that saves a change of backend.
6. **Serenity Cloud token refresh.** Refresh the token before the backend is checked. Instead of copying the token into the adapter once, give the adapter a way to get the current token, so it can refresh after a 401 (`AppState.swift:790-815`, `Serenity/Shared/Data/SerenityCloudAdapter.swift:200`). Today any refresh error clears the stored session, including an offline launch (`Serenity/Shared/Auth/AuthSessionManager.swift:337`). Clear it only when the server rejects the refresh token. This comes before step 5's banner logic, because an expired token is the likeliest reason the fallback fires today.

### Phase 2: storage and secrets (before phase 3)
1. **One shared queue.** Open one `DatabaseQueue` per database file in `SQLiteBackendAdapter`, with a busy timeout of about 5 seconds (`Configuration.busyMode = .timeout`), and pass it to the core, Slack, AI and audit repository sets (`CoreRepositories.swift:646-651`, `SQLiteBackendAdapter.swift:50-90`, `AIRepositories.swift:1185-1191`). Audit events use the same file (`SQLiteBackendAdapter.swift:54`, `:64` and `:83` all resolve the same path). Run migrations once at startup, either on the shared queue or before it opens, not on every audit event (`Serenity/Shared/Data/DatabaseMigrationRunner.swift:37`, `Serenity/Shared/Security/SecurityAuditRepository.swift:104`).
2. **Save the record and its pending change together.** Today `SyncAwareRepositories.swift:40-47` and the AI equivalents in `SyncAwareAIRepositories.swift` run two separate writes. Add variants of the repository save and delete, and of `PendingSyncChangeStore.enqueue`, that take an open `Database`, and run both inside one `dbQueue.write`. Starting a second `dbQueue.write` inside an open one is a fatal error in GRDB, so the inner calls must use the handle they are given.
3. **Backups.** Replace `copyItem` with GRDB `backup(to:)` (`SQLiteBackendAdapter.swift:115`).
4. **Keychain writes.** Change `KeychainSecretStore.set`: try `SecItemUpdate` first, and fall back to delete-then-add only when the synchronizable attribute differs. In that fallback, read the old value first and keep it until the new item reads back correctly. If both the add and the restore fail, throw an error that carries the old value, so the caller still has the secret. Wrap the `SecItem*` calls in a small protocol so failure paths can be tested without the real Keychain.
5. **OAuth sessions.** Move them out of UserDefaults and into the Keychain with a one-time migration that removes the UserDefaults copy only after the Keychain read-back succeeds (`AuthSessionManager.swift:217-246`).

### Phase 3: iCloud correctness (needs phase 2)
1. **Protocol over the database calls.** Put the `CKDatabase` operations the engine uses (modify records, fetch zone changes, save zone and subscription) behind a protocol. Keep a thin live implementation, and write a fake for tests (`iCloudSyncEngine.swift:17`). Every test below uses the fake.
2. **New pending-row id on every enqueue.** Set `id = excluded.id` in the conflict clause (`CloudSyncStateStore.swift:55-60`).
3. **Pull-side conflict rule.** Steps 3 and 4 land together. When a pulled record has a pending local row, compare `updatedAt`:
   - If the remote copy is newer, apply it and delete the pending row. Do both in one transaction, and only if the pending row's id hasn't changed since it was read, so an edit made in the meantime is kept.
   - If the local copy is newer, skip the remote copy and keep the pending row.
4. **Pending-aware pull.** On pull, a record without a pending row applies only if it is newer than the local copy. Remote deletes follow the same pending-row rule (`iCloudSyncEngine.swift:317-381`, `SyncAwareRepositories.swift:50-56`).
5. **Keep the change token when an apply fails.** Save the change token only when every record in the batch has either applied or been set aside (`iCloudSyncEngine.swift:338-380`).
   - Count apply attempts for each record. A record that fails the same way every time, such as one missing a required field (`CloudKitRecordMapping.swift:104-108`), is moved to a small "could not apply" list after a fixed number of tries, and the Sync status shows how many there are.
   - Without this cap, one bad record would hold the token back for good.
6. **Queue a rerun instead of dropping it.** A sync request made while a sync is running sets a rerun flag (`:70`). Keep pushing until the pending queue is empty, not just one batch of 200 (`:158`), but stop when a pass makes no progress. Retry failed rows with a delay that grows with the attempt count, because today they can be picked up again straight away (`CloudSyncStateStore.swift:78`, `:100-116`). Trigger a sync after project and goal saves (`AppState.swift:3980-4030`, `:4138-4190`).
7. **Recover from CloudKit errors.**
   - On `zoneNotFound` or `userDeletedZone`, clear the zone-created flag, the subscription-created flag (`iCloudSyncEngine.swift:122-127`), the change token and the initial-export flag. Then run the initial exporter again in the same session. Today it runs only when the engine is first installed (`AppState.swift:3790-3802`, `Serenity/Shared/Data/CloudSyncInitialExporter.swift:7-19`).
   - On `changeTokenExpired`, clear the token and fetch everything again.
8. **Refresh the screen after a pull.** The engine returns the ids it applied, and `AppState` reloads the affected collections on the main actor (`AppState.swift:3831-3853`).
9. **Last step: push-side conflict detection.** This is one change. Store each record's CloudKit system fields next to the local row, save with `.ifServerRecordUnchanged` (`CloudKitRecordMapping.swift:71`, `iCloudSyncEngine.swift:267`), and turn the `serverRecordChanged` branch into real resolution. That branch is unreachable today, because saves never ask CloudKit to check for conflicts (`iCloudSyncEngine.swift:208-217`).
   - When resolving, re-read the current local record and pending row rather than using the copy captured when the push started.
   - Then apply the same "newer wins" rule as step 3.

### Phase 4: AI plumbing
1. **Structured outputs on Anthropic.** Send `output_config.format` with the JSON schema, with `minimum` and `maximum` removed, and check them locally. Keep the schema-in-prompt path for models that don't support structured outputs.
2. **Retries.** Retry 429, 5xx and "overloaded" responses with backoff, honouring `retry-after`, and use a longer request timeout (`AIProviderAPIClient.swift:672-699`).
3. **Error reporting.**
   - Report 403 as a permissions error, not "Invalid API key".
   - Record bad model output as an output error, not a credential error.
   - Name the schema after each feature instead of always `quick_capture_classification` on the OpenAI and custom paths.
4. **Stop logging invented usage.** Template insights, recaps and summaries should stop recording made-up token counts. Log them as zero-cost template runs, or not at all (`AIWorkflowService.swift:770-1203`).
5. **Credential choice.** Slack sync and capture commands should use the active provider setting, as the stand-up does (`AppState.swift:1845-1852`).

### Phase 5: prompt fixes
1. **Prompt tag list.** Drop `slack-thread-*` and `github-pr-*` tags and keep the 50 most-used (`AppState.swift:2706`; used from `Serenity/Shared/AI/SlackProposalService.swift:78` and `Serenity/Shared/AI/CaptureCommandDrafter.swift:164`).
2. **Slack proposal prompt** (`SlackProposalService.swift:100-227`):
   - Close each signal block with a marker, and add the rule that signal text is evidence, never instructions, and affects only its own signal.
   - Show each context line's sent time and a "(you)" marker.
   - Resolve relative dates against the sent time of the message.
   - For "update", set only the fields the message changes. The schema already allows null for title and description (`:211`). Check that the code applying an update treats null or empty values as "leave unchanged", and fix it if not.
   - Add guidance on priority, project and tags.
3. **Capture commands** (`CaptureCommandDrafter.swift:193-472`):
   - Wrap each source in `<source key label>…</source>` and add the same evidence rule.
   - Resolve dates against the message or comment date.
   - Define `projectName` or drop it.
4. **Repair retries.** Include the original user input, format and length target in the repair prompt (`AIWorkflowService.swift:1053-1088`, `:1575-1591`), and send the schema only once. The speakable retry should say what actually failed.
5. **Stand-up revise.**
   - Include the current spoken script and the folded detail in the revise prompt (`Serenity/Shared/AI/StandupWriter.swift:255`).
   - Store the just-for-today instruction next to the script, so the first revision reuses it (`AppState.swift:2335-2367`).
   - Add the rule that the format instruction never overrides the spoken rules (`StandupWriter.swift:94-96`, `:179`, `:192`).
6. **Quick capture** (`AIWorkflowService.swift:1521-1573`):
   - Define confidence as the probability that the user saves the draft unchanged.
   - Add a rule for a note mixing reflection and action.
   - Copy journal content verbatim.
   - A date with no time means 23:59 local. This is a parser change as well as a prompt change: the `yyyy-MM-dd` path returns midnight today (`AIWorkflowService.swift:1521-1524`).
   - Remove archived projects in code rather than telling the model to ignore them.

   The broader rewrite the review proposes is optional.

### Phase 6: product fixes
1. **GitHub PR tasks** (`IntegrationServices.swift:540-650`):
   - no due date
   - on each sync, update the title and complete the task when the PR is merged or closed
   - a small table of imported PR ids, so deleted tasks stay deleted
2. **Save the sync toggles.** Persist the Google and GitHub sync toggles and the Slack "@here" and "bots" toggles (`AppState.swift:1230`, `:1247`, and the Google and GitHub state).
3. **Menu-bar capture.** Route it through the same capture path as the main window, so `/slack`, `/github`, `journal:` and the AI all work there (`Serenity/macOS/MenuBarCaptureView.swift:98-105`).
4. **Repeating tasks.** Create the next occurrence when tasks are completed in bulk, or when an accepted draft marks a task done (`AppState.swift:3059-3072`, `:1804-1807`).
5. **Help Center.** Change the shortcut text from ⌘1–⌘8 to ⌘1–⌘9 (`Serenity/Shared/App/SerenityAppScene.swift:12656`).
6. **Build config.** Remove the `Serenity/Config` exclude from `Package.swift`.

### Step dependencies
- Phase 3 needs phase 2's shared queue and atomic saves.
- Within phase 3, steps 3 and 4 land together.
- Within phase 3, step 9 lands as one change.
- Phase 1's token refresh (step 6) comes before its banner logic (step 5).
- The phase 5 Slack prompt fixes are independent, but share tests with the Slack sync work in phase 1.
- Everything else can land on its own.

## 5. Testing Strategy

Commands (from `README.md:41` and the project's recorded verification steps):
- `swift build && swift test`. Expect only the two known locale failures in the daily-surface tests. Read the XCTest "Executed N tests" line, not the swift-testing "0 tests" line.
- `xcodebuild -scheme SerenityIOS -destination 'generic/platform=iOS Simulator' build`, so that new files are registered in the Xcode project.
- `xcodebuild -scheme SerenityMac -configuration Debug build`, then launch the built app for manual checks. The raw SPM binary crashes in `CKContainer.init`.

Proposed tests (new, to be confirmed while implementing). Numbers refer to the acceptance criteria.

| Criterion | Test |
| --- | --- |
| 1 | Request-body tests for each provider through a `URLProtocol` stub: no temperature, `max_tokens`, stop-reason mapping, and the resolved default model. Then one live Anthropic call by hand. |
| 2 | Stand-up planner tests with two fixed clocks in different weeks. |
| Quick-capture dates | Date-only parsing gives 23:59 in explicit time zones and across a daylight-saving change. |
| 3, 4, 5 | `AppState` sync-all with stub services that throw. Slack reader tests with one failing channel. A test that starts two `syncSlackNow` calls at once. |
| 6, 7 | Backend selection with injected `UserDefaults` and an adapter that fails validation: the saved profile stays unchanged. Auth refresh with a network error: the session is kept. An adapter returning 401: it refreshes and retries once. |
| 8, 9 | Concurrent writes across repository sets on one temporary database. A save test where the ledger write fails and the entity rolls back. Backup plus `PRAGMA integrity_check`. |
| 10 | Keychain update, migration, failed-add and failed-restore tests through the `SecItem` wrapper. One round-trip test against the real Keychain. |
| 11, 12 | Fake-database engine tests for each case listed. Then a manual two-device check on a signed build, including clearing a due date. |
| 13 | A log-capture test on decode failure. |
| 14, 15 | Prompt-rendering tests: markers, timestamps, "(you)", tag filtering. Proposal-apply tests: null title keeps the old one; relative dates resolve against the sent time. |
| 16 | GitHub import tests with fixture search results: a merged PR completes its task; a deleted task is not re-imported. |

## 6. Constraints and Open Questions

- **Settled:** keep the remote backend when it is unreachable; one shared `DatabaseQueue`; rotate the pending-row id rather than comparing timestamps; update the Keychain first.
- **Left to the implementer:**
  - which curated default model to use per provider
  - the exact busy timeout
  - the banner copy
  - whether repair uses a multi-turn request
  - the bound on re-reading old Slack threads
- **Non-blocking assumptions:**
  - A single user on two or three Apple devices.
  - Remote-backend users accept no offline editing until an offline cache exists.
  - Output from Opus 4.7 and 4.8 with thinking off is good enough at low effort. Check the first live call.
- **Unverified in this review:**
  - How an accepted Slack update writes fields onto a task. This affects phase 5, step 2.
- **Blockers:** none. Every phase is ready to start in order.

## 7. Verification Status

- Inspected `feat/3` at `d86409a`, whose only uncommitted change is the untracked `docs/reviews/` directory.
- All evidence came from reading the code: the key file:line claims above were checked directly, and the Claude API behaviour comes from current API documentation.
- No build or test was run during this review.
- The agents checked the draft plan twice. The final amendments were checked against the code by the orchestrator but were not reviewed again by the agents: attempt caps, the pull-side conflict rule, the exporter re-run, keeping the session on offline refresh, the Keychain recovery copy, and the date parser.
