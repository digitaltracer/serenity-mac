# Slack → ActionHub Plan

**Goal:** Sign in to Slack once, and from then on Serenity watches the channels you belong to for work that is actually aimed at you, and proposes ActionHub changes — "create this task", "this task's due date moved to Friday", "this one sounds done". Nothing is written until you tap Accept.

**Architecture:** Slack joins `IntegrationProvider` as a third arm, following the Google Calendar shape: a `@MainActor` service that owns auth + fetch, state published on `AppState`, a row in the Integrations section, and a place in `syncIntegrationsNow()`. It diverges from Google in two ways. First, the Slack reader is stateful — it keeps a per-channel cursor in SQLite so each poll reads only what arrived since the last one. Second, nothing it produces is written straight into `tasks`; everything lands in a new `slack_proposals` table, and only Accept turns a proposal into a repository write.

The AI step reuses the quick-capture machinery wholesale. `AIProviderAPIClient.generateQuickCaptureJSON` already takes (provider, key, model, system prompt, user prompt, JSON schema) and is provider-agnostic — the Slack pass is a different schema and prompt through the same door, with usage logged to the same Cost Center.

**Tech Stack:** Swift 5.10, SwiftUI, GRDB, `ASWebAuthenticationSession`, `UserNotifications`, XCTest

---

## Scope decisions (settled 2026-09-17)

| Decision | Choice | Consequence |
|---|---|---|
| Who installs | Your workspace only, your own Slack app | Slack treats it as an internal customer-built app, which keeps `conversations.history` at 50+ req/min and 1000 messages per call. This decision is what makes the whole feature viable — see below. |
| Channel scope | Every public + private channel you are a member of | `users.conversations`, no picker UI in v1. First sync is bounded to 7 days so it does not read years of backlog. |
| Message scope | Messages that mention you, plus threads you have posted in | Everything else is dropped before it costs an AI token. |
| Review surface | Review inbox inside ActionHub, plus one coalesced system notification | Nothing is lost if you ignore the notification. |

**DMs are excluded structurally, not by a filter.** The OAuth request never asks for `im:history` or `mpim:history`, so the token Serenity holds is physically incapable of reading a DM. That is worth keeping true even when it would be convenient to break.

---

## Reference: the Slack platform facts that shape this

**The rate-limit cliff.** Since 29 May 2025, Slack throttles `conversations.history` and `conversations.replies` to **1 request per minute, 15 messages per response** for any app distributed outside the Slack Marketplace. Existing installs fell under it on 2 Sept 2025. At that rate, reading a workspace is not possible — a single busy channel would take hours to catch up. Internal customer-built apps are explicitly exempt and keep 50+ req/min and 1000 objects per call. So: the Slack app must be created inside your own workspace and never publicly distributed. If Serenity is ever shipped to other people's workspaces, this design does not survive the change, and the replacement is either Marketplace approval or an Events API subscription behind a hosted endpoint.

- https://docs.slack.dev/changelog/2025/05/29/rate-limit-changes-for-non-marketplace-apps

**Auth is PKCE, and PKCE means user tokens only.** Slack supports PKCE for public clients, which is what lets a native app authenticate with no client secret embedded in the binary. Two consequences to design around:

- A custom-scheme redirect (`serenity://slack-oauth`) is classed as a desktop redirect. Desktop redirects **must** use PKCE, and **cannot request bot scopes** — only user scopes. That is fine here (we want to read as you), but it also rules out Socket Mode and the Events API, which need a bot token. Polling is the only option.
- Enabling PKCE is one-way and cannot be undone without contacting Slack support. It also forces rotating tokens with a **30-day refresh token expiry**, so the refresh path is not optional — if the app sits unopened for a month, the connection dies and the user must sign in again. Refresh on every sync, not just on 401.

- https://docs.slack.dev/authentication/using-pkce/

**Scopes requested** (all user scopes): `channels:history`, `groups:history`, `channels:read`, `groups:read`, `users:read`, `usergroups:read`. Not requested, deliberately: `im:history`, `mpim:history`, `chat:write`, `search:read`.

---

## Reference: what exists today and gets reused

| What | Where | How it is used here |
|---|---|---|
| Integration provider enum, sync outcomes, diagnostics | `Serenity/Shared/Integrations/IntegrationModels.swift` | Gains a `.slack` arm and a `SlackIntegrationState` alongside the Google and GitHub ones |
| Token storage in the keychain | `KeychainSecretStore(service: "com.digitaltracer.serenity.integrations")` | Slack session stored under `integrations.slack.session`, same as `integrations.google.session` |
| Injectable HTTP handler | `IntegrationRequestHandler` typealias, `IntegrationServices.swift:35` | Every Slack call goes through it, so tests stub responses with no network |
| Provider-agnostic structured JSON call | `AIProviderAPIClient.generateQuickCaptureJSON`, `AIWorkflowService.swift:80` | The extraction pass is a new schema through the same function — no new provider code |
| Draft-then-confirm pattern | `AIQuickCapturePreview` + `savePendingAIQuickCapturePreview()`, `AppState.swift:1537` | The proposal model is the durable, multi-item version of this |
| Task history lines | `TaskActivityEntry`, `CoreEntities.swift:32` | Every accepted update appends an event line, already stored as rendered absolute text |
| Notification diffing | `NotificationScheduler`, `Serenity/Shared/App/NotificationScheduler.swift` | Needs a small extension — see Task 7 Step 3 |
| Migration list | `DatabaseMigrationRunner.migrations`, last entry `20260910_010_task_activity` at :607 | New entry `20260917_011_slack_integration`, `schema_version` → `9` |

---

## Global Constraints

- No new Swift package dependency. `ASWebAuthenticationSession` and `URLSession` cover auth and transport.
- No AI call for a message that a free filter could have rejected. Every token spent must be attributable to a message that mentions you or sits in a thread you are in.
- A message is processed exactly once, ever. Re-proposing something you already dismissed is the fastest way to make the feature feel broken.
- Nothing writes to `tasks` except an explicit Accept. Not on high confidence, not on a "obviously correct" update.
- Proposals stay local to the device — they are not added to `SyncEntityType` and not mapped into CloudKit. Accepted tasks sync, because tasks always did.
- Every new file must be added to both targets in `Serenity.xcodeproj/project.pbxproj`; the classic project format needs explicit file refs and the iOS build breaks silently otherwise.

---

### Task 1: Slack sign-in with PKCE

**Files:**
- Modify: `Serenity/Shared/Integrations/IntegrationModels.swift`
- Create: `Serenity/Shared/Integrations/SlackIntegrationService.swift`
- Modify: `Serenity/Shared/App/AppState.swift`
- Modify: `Serenity/Support/macOS/Info.plist`, `Serenity/Support/iOS/Info.plist`

**Interfaces:**
- Produces: `SlackIntegrationService.signIn()`, `.currentSession()`, `.disconnect()`, `.refreshIfNeeded()`
- Produces: `SlackIntegrationSession { accessToken, refreshToken, expiresAt, teamID, teamName, userID, userName, connectedAt }`
- Produces: `SlackIntegrationState`, mirroring `GoogleIntegrationState`

- [x] **Step 1: Create the Slack app in your workspace**

Manual, done once, outside the codebase — but write it down in the README because nothing else explains where the client ID came from. In the Slack app config: enable PKCE, add redirect URL `serenity://slack-oauth`, add the six user scopes above, and do **not** submit for distribution. Record the client ID; there is no secret to record.

- [x] **Step 2: Read the client ID the way Google's is read**

`SlackConfiguration` mirrors `GoogleCalendarConfiguration` (:20): pull `SLACK_CLIENT_ID` from the Info dictionary, treat an unexpanded `$(…)` placeholder as absent, expose `isConfigured`. Add `SLACK_CLIENT_ID` to `.env.example` and both Info.plists.

- [x] **Step 3: Implement the PKCE exchange**

Generate a 64-byte random `code_verifier`, base64url-encode it unpadded, SHA-256 it for the `code_challenge`. Open `https://slack.com/oauth/v2/authorize` with `client_id`, `user_scope`, `redirect_uri`, `code_challenge`, `code_challenge_method=S256`, and a random `state` you verify on return. Present with `ASWebAuthenticationSession(url:callbackURLScheme:"serenity")` — it intercepts the callback itself, so no URL-scheme registration or `onOpenURL` change is needed. Exchange at `oauth.v2.access` with `code` + `code_verifier` and **no** `client_secret`.

**As built:** `SlackIntegrationService` takes an optional `clientID` so the whole PKCE flow is testable without an Info.plist; it falls back to `SlackConfiguration.clientID` in the app.

Slack returns the user token nested under `authed_user`, not at the top level. This trips everyone once.

- [x] **Step 4: Handle refresh as a routine step, not an error path**

Rotating tokens mean the access token expires in hours and the refresh token in 30 days. `refreshIfNeeded()` runs at the top of every sync: if `expiresAt` is within 5 minutes, POST `oauth.v2.access` with `grant_type=refresh_token`. Persist the new refresh token immediately — Slack rotates it too, and losing it means a forced re-sign-in. If refresh returns `invalid_refresh_token`, clear the session and set `lastError` to something that tells the user to reconnect.

- [x] **Step 5: Wire connect/disconnect into AppState**

Follow `connectGoogleIntegration()` (:939) and `disconnectGoogleIntegration()` (:991) exactly, including the `refreshIntegrationDiagnostics()` calls on both success and failure. Restore the session in `bootstrapIntegrations()` (:912).

---

### Task 2: Read the channels you are in

**Files:**
- Create: `Serenity/Shared/Integrations/SlackMessageReader.swift`
- Modify: `Serenity/Shared/Integrations/IntegrationModels.swift`

**Interfaces:**
- Produces: `SlackMessageReader.fetchNewActivity(since:) async throws -> SlackActivityBatch`
- Produces: `SlackMessage { channelID, channelName, ts, threadTS, userID, authorName, text, permalink, isOwn }`

- [x] **Step 1: Identify yourself**

`auth.test` once per session → your user ID and team ID, cached on the session. Everything downstream depends on knowing which mention string is yours.

- [x] **Step 2: List the channels**

`users.conversations` with `types=public_channel,private_channel`, `exclude_archived=true`, `limit=200`, following `response_metadata.next_cursor`. Refresh this list once per sync, not per channel.

- [x] **Step 3: Read each channel forward from its cursor**

Per channel, `conversations.history` with `oldest` set to the stored cursor and `limit=200`, paginating until `has_more` is false. First run for a channel: `oldest` = seven days ago, so connecting a workspace does not pull years of backlog. After a successful pass, store the newest `ts` seen as the new cursor — and only then, so a crash mid-sync re-reads rather than skips.

- [x] **Step 4: Follow threads you are in**

A channel-level read returns thread parents but not replies. Keep a set of `thread_ts` values where you have posted (seeded from your own messages as they are seen, persisted alongside the cursor). For each such thread touched in this window, call `conversations.replies`. This is the second-largest source of calls, so only call it for threads whose parent shows a newer `latest_reply` than the stored cursor.

- [x] **Step 5: Resolve names once, cache them**

`users.list` on first sync into an in-memory `[userID: displayName]` map, refreshed daily. Rendering `<@U024BE7LH>` as a raw ID in a proposal makes the proposal unreadable, and calling `users.info` per message is a rate-limit own-goal.

- [x] **Step 6: Respect 429 properly**

Slack sends `Retry-After` in seconds on 429. Sleep exactly that long and retry the same request — do not treat it as a failure, do not advance the cursor, do not surface an error to the user. Cap total sync duration (say 2 minutes) and leave the rest for the next poll.

**As built:** Slack timestamps needed a numeric comparison (`SlackTimestamp`). Compared as strings, `"250.0" > "50.0"` is false, which silently skipped thread replies — it only looks correct because real timestamps happen to be fixed-width.

---

### Task 3: Local schema for cursors and proposals

**Files:**
- Modify: `Serenity/Shared/Data/DatabaseMigrationRunner.swift`
- Create: `Serenity/Shared/Data/SlackRepositories.swift`
- Modify: `SerenityTests/Data/DatabaseMigrationRunnerTests.swift`

**Interfaces:**
- Produces: migration `20260917_011_slack_integration`, `schema_version` = `9`
- Produces: `GRDBSlackProposalRepository`, `GRDBSlackCursorRepository`

- [x] **Step 1: Add three tables**

`slack_channel_cursors` — channel id, channel name, last ts, participated thread ts values as JSON, updated at.

`slack_seen_messages` — channel id + message ts as a composite primary key, plus the outcome (`filtered`, `proposed`, `ignored_by_ai`). This table is the "exactly once" guarantee; it is cheap and it is what stops the same message being re-read into an AI call after a crash.

`slack_proposals` — id, kind (`create` / `update`), target task id (nullable), payload JSON, confidence, status (`pending` / `accepted` / `dismissed` / `superseded`), source channel id, source channel name, source message ts, source thread ts, source author, source excerpt, permalink, created at, decided at.

Index `slack_proposals(status, created_at)` for the inbox query and `slack_seen_messages(channel_id, ts)` for the dedupe check.

- [x] **Step 2: Register the migration**

Append to the `migrations` array with the `INSERT OR REPLACE INTO app_metadata … schema_version '9'` line, matching every prior entry. Note 009 is a skipped number in the existing sequence — 011 is correct, not 010.

- [x] **Step 3: Write the repositories**

Plain GRDB repos following `GRDBTaskRepository` (`CoreRepositories.swift:156`). These are deliberately **not** wrapped in the `SyncAware…` decorators and get no `SyncEntityType` constant — proposals are device-local by design.

**As built:** the `failed` outcome value exists in the CHECK constraint but is never written. A failed signal is recorded nowhere and its channel cursor is held back instead, so the next sync re-reads it. The value stays in the schema because widening a SQLite CHECK later costs a table rebuild.

---

### Task 4: Decide what is worth an AI call

**Files:**
- Create: `Serenity/Shared/Integrations/SlackRelevanceFilter.swift`
- Create: `SerenityTests/Integrations/SlackRelevanceFilterTests.swift`

**Interfaces:**
- Produces: `SlackRelevanceFilter.candidates(from:ownUserID:ownGroupIDs:) -> [SlackSignal]`
- Produces: `SlackSignal { anchor: SlackMessage, context: [SlackMessage] }`

- [x] **Step 1: Keep only what is aimed at you**

A message is an anchor if it contains `<@YOUR_ID>`, or `<!subteam^ID>` for a user group you belong to, or it is a reply in a thread you have posted in. `@here` and `@channel` are excluded by default behind a setting — in most workspaces they are announcements, and including them is the difference between a handful of proposals a day and dozens.

- [x] **Step 2: Drop the noise**

Skip your own messages as anchors (they still travel as context). Skip join/leave/topic/purpose subtypes. Skip `bot_message` by default, behind a setting — bot posts are usually already-tracked work from Jira, GitHub or a CI pipeline.

- [x] **Step 3: Attach context**

An anchor alone reads as a fragment. For a thread reply, context is the thread parent plus up to 10 surrounding replies. For a channel message, context is up to 3 messages either side. Cap the whole signal at roughly 4000 characters; truncate from the middle, keeping the anchor and the newest messages.

- [x] **Step 4: Test the filter hard**

This file is pure functions over structs with no network and no AI, which makes it the cheapest place to buy confidence. Cases: mention of you, mention of someone else, group mention, thread you are in, thread you are not in, your own message, bot message, join subtype, `@channel` with the setting off and on.

---

### Task 5: Turn signals into proposals

**Files:**
- Create: `Serenity/Shared/AI/SlackProposalService.swift`
- Modify: `Serenity/Shared/Data/AIEntities.swift`
- Modify: `Serenity/Shared/Data/DatabaseMigrationRunner.swift`
- Create: `SerenityTests/AI/SlackProposalServiceTests.swift`

**Interfaces:**
- Produces: `SlackProposalService.proposals(for signals: [SlackSignal], openTasks: [TaskEntity], projects: […]) async throws -> [SlackProposal]`

**As built:** the file holds the pure parts — prompt, schema, shortlisting, rendering, and the decision-to-proposal mapping. The provider call itself became `AIWorkflowService.proposeSlackDecisions`, so credential selection, the repair path and Cost Center logging are reused rather than reimplemented.
- Produces: `AIUsageOperation.slack`

- [x] **Step 1: Shortlist the tasks a signal might be about**

Before the model sees anything, narrow the candidate set. An exact link first: tasks tagged `slack-thread-<channelID>-<threadTS>` came from this thread and win outright. Otherwise, score open tasks by normalized word overlap against the anchor text and take the top 8. Handing the model 300 open tasks is both expensive and worse — it will match on vibes.

**As built:** the thread tag is lowercased at the point it is created. Tags are normalized to lowercase when stored, so an uppercase channel ID in the tag would have meant the lookup never matched the tag it had just written.

- [x] **Step 2: Define the output schema**

Mirror `quickCaptureSchema()` (`AIWorkflowService.swift:977`). One array of decisions, each: `action` (`create` / `update` / `ignore`), `targetTaskId` (null unless updating), `title`, `description`, `priority`, `dueDate` (ISO-8601 or null), `projectId`, `tags`, `subtasks`, `statusChange` (`none` / `completed` / `reopened`), `confidence`, `reason` (one line, shown to you in the inbox).

Note the ceiling here: `TaskEntity` has `completed: Bool` and no in-progress state, so "Ravi picked this up, it's in progress" can only be expressed as a description or activity line, never as a status. If a real status enum is wanted, that is a separate change to the task model and its CloudKit mapping.

- [x] **Step 3: Write the prompt**

System prompt states the job: read a Slack excerpt, decide whether it creates work for the user, updates work they already have, or neither — and say `ignore` freely, because a wrong proposal costs more than a missed one. User prompt carries the rendered signal with display names and absolute timestamps, today's date, the candidate tasks with their ids and due dates, the project list, and the existing tag vocabulary — the same context `quickCaptureUserPrompt` assembles.

Resolve all relative dates to absolute before storing, matching the rule already documented on `TaskActivityEntry` — a proposal reviewed two days later must not still say "tomorrow".

- [x] **Step 4: Batch, and log the cost**

One AI call per signal is simplest but pays the context overhead repeatedly. Batch up to 5 signals per call, splitting when the rendered prompt passes ~12k characters. Log every call to `ai_usage` with a new `slack` operation so it appears in the Cost Center next to quick-add and recaps.

- [x] **Step 5: Widen the two operation CHECK constraints**

`ai_usage.operation` is constrained to `('analyze','recap','quickadd','summary')` in two places — the original table at :265 and its rebuilt form at :476. SQLite cannot alter a CHECK in place, so this needs the create-new / `INSERT … SELECT` / `DROP` / `RENAME` cycle that migration `20260901_008_nvidia_provider` already demonstrates. Fold it into the 011 migration.

- [x] **Step 6: Record every message as seen**

Whatever the model returns — proposal, ignore, or an error that aborts the batch — write the anchor ts into `slack_seen_messages`. On error, mark it in a way that allows one retry; anything else risks an error loop that re-bills the same messages every 15 minutes.

---

### Task 6: Apply an accepted proposal

**Files:**
- Modify: `Serenity/Shared/App/AppState.swift`
- Create: `SerenityTests/SlackProposalApplyTests.swift`

**Interfaces:**
- Produces: `AppState.acceptSlackProposal(id:)`, `.dismissSlackProposal(id:)`, `.dismissAllSlackProposals()`
- Produces: `@Published var slackProposals: [SlackProposal]`

- [x] **Step 1: Create**

Build a `TaskEntity` from the payload and save it through the existing task repository so the CloudKit ledger picks it up. Tag it `slack` and `slack-thread-<channelID>-<threadTS>` — that tag is what makes every later message in the thread resolve to this task instead of spawning a duplicate. Seed the activity with one event line naming the channel, the author and the date.

- [x] **Step 2: Update**

Fetch the target task, apply only the fields the proposal actually changes, and append one `TaskActivityEntry` of kind `.event` per change, written in absolute terms: "Due date moved to Fri 19 Sep 2026 — @jane in #eng-platform, 17 Sep". If the target task has been deleted since the proposal was made, mark the proposal `superseded` and surface it as a dismissal rather than failing.

- [x] **Step 3: Close the loop on related proposals**

Accepting or dismissing anything from the same thread marks other pending proposals for that thread `superseded`. Two proposals about one conversation is the common annoying case.

- [x] **Step 4: Refresh**

Reuse the existing post-write refresh path so ActionHub, Home and task notifications all pick the change up — the same one `savePendingAIQuickCapturePreview()` (:1537) uses.

---

### Task 7: The review inbox and the nudge

**Files:**
- Modify: `Serenity/Shared/App/SerenityAppScene.swift`
- Modify: `Serenity/Shared/App/NotificationScheduler.swift`

**Interfaces:**
- Produces: `SlackProposalInboxView`, presented from `ActionHubSectionView` (:2455)

- [x] **Step 1: Build the inbox**

A card per proposal, built from the existing design-system components: the proposed title, the fields that would change shown as before → after, the model's one-line reason, and the source line — channel, author, excerpt, timestamp — with the excerpt being the thing that actually earns trust. Accept and Dismiss buttons on the card. The whole list is reachable from a badge on the ActionHub header showing the pending count.

Keep the existing quick-capture preview card (`SerenityAppScene.swift:1715`) as the visual reference; this is the same idea with more rows and a source attribution.

- [x] **Step 2: Deep link to Slack**

The source line links to the message permalink. One tap to check the real conversation is the difference between trusting a proposal and ignoring the whole feature.

- [x] **Step 3: One coalesced notification**

Do not fire per proposal. Post a single notification — "4 Slack items need a decision" — replacing any previous one by reusing a fixed identifier.

This needs a small change to the notification layer. `SystemNotificationCenter.pendingIdentifiers()` currently filters to the `task:` prefix, so pointing a second `NotificationScheduler` at it would compute every task reminder as stale and cancel them all. Give the adapter an identifier-prefix parameter at init, and add a direct `postNow` for immediate, non-scheduled notifications — the reconcile-diff model does not fit a thing that fires once, right now.

**As built:** only `postNow` was needed. `pendingIdentifiers()` already filters to the `task:` prefix, so a Slack notification is invisible to the task reconcile and cannot be cancelled by it — the prefix parameter would have been dead weight.

- [x] **Step 4: Handle the empty state**

No pending proposals is the normal state, and it should read as calm, not broken: when Slack is connected and quiet, say when it last looked.

---

### Task 8: Settings, sync loop and diagnostics

**Files:**
- Modify: `Serenity/Shared/App/SerenityAppScene.swift` (`IntegrationsSectionView`, :1991)
- Modify: `Serenity/Shared/App/AppState.swift`

- [x] **Step 1: Add the Slack row**

Copy the shape of `googleServiceRow` (:2086): icon, name, connected pill showing the workspace name, sync toggle, Connect/Disconnect. Add Slack's outcome to `syncIntegrationsNow()` (:1050) alongside Google's and GitHub's so "Sync Now" covers it.

- [x] **Step 2: Add the settings that matter**

Poll interval (default 15 minutes), include `@here`/`@channel` (default off), include bot messages (default off), and which AI credential the extraction uses. Everything else stays a constant until there is a reason.

**As built:** no credential picker. The extraction uses the highest-priority enabled credential, matching how the AI service already resolves a default. A picker is worth adding the first time that turns out to be the wrong key.

- [x] **Step 3: Poll while the app is open**

A cancellable task on a timer, plus a sync when the app returns to the foreground. Be explicit in the UI that this is what happens: a quit Mac app does not poll, so proposals arrive when you open Serenity, not while you are away. iOS background refresh is a later addition, not v1.

- [x] **Step 4: Extend the diagnostics block**

`refreshIntegrationDiagnostics()` (:1117) gains Slack lines: connected, workspace, token expiry, channels watched, last sync, messages read last sync, signals filtered, AI calls made, pending proposals, last error. When this feature misbehaves it will be because of a cursor or a filter, and these lines are what make that visible without a debugger.

---

### Task 9: Tests, parity and the iOS build

**Files:**
- Create: `SerenityTests/Integrations/SlackIntegrationServiceTests.swift`
- Modify: `SerenityTests/Parity/FeatureParityRegressionTests.swift`
- Modify: `Serenity.xcodeproj/project.pbxproj`

- [x] **Step 1: Cover the reader against stubbed responses**

Use the injected `IntegrationRequestHandler` the way `IntegrationServicesTests` already does (`SerenityTests/Integrations/IntegrationServicesTests.swift:35`): cursor advances only after a full pass, pagination follows `next_cursor`, 429 with `Retry-After` retries without advancing, an already-seen ts is never re-emitted.

- [x] **Step 2: Cover the AI pass with a stubbed generator**

`AIWorkflowServiceTests` injects a fake generation handler; do the same and assert schema decoding, that `ignore` produces no proposal, that an unknown `targetTaskId` degrades to a create rather than a crash, and that relative dates come back absolute.

- [x] **Step 3: Add the files to both targets**

Every new Swift file needs an explicit file ref in `project.pbxproj` for both `SerenityMac` and `SerenityIOS`. Verify with `xcodebuild -scheme SerenityIOS -destination 'generic/platform=iOS Simulator' build` — `swift build` passing proves nothing about the iOS target.

- [x] **Step 4: Full verification**

`swift build && swift test`, then the iOS build, then a real connect against your workspace. The swift-testing runner reporting "0 tests" is expected; read the XCTest "Executed N tests" line.

---

## Effort

| Task | Estimate |
|---|---|
| 1 — PKCE sign-in | 1 day |
| 2 — Message reader | 1.5 days |
| 3 — Schema and repositories | 0.5 day |
| 4 — Relevance filter | 0.5 day |
| 5 — AI extraction and matching | 2 days |
| 6 — Apply | 0.5 day |
| 7 — Inbox and notification | 1.5 days |
| 8 — Settings and diagnostics | 0.5 day |
| 9 — Tests and iOS parity | 1 day |

Roughly **9 working days** to a v1 you would actually leave switched on. The mechanical parts — OAuth, polling, storage, UI — are about four days and carry little risk. The remaining five are Task 5 and the tuning loop after it, which is where this feature is either good or annoying.

## What actually makes this hard

The Slack API is not the hard part, and neither is the AI call. Three things are:

**Matching a message to an existing task.** Word-overlap shortlisting plus a model decision is a reasonable v1, but it will mis-target sometimes. The thread tag makes the common case exact — any follow-up in a thread that already produced a task resolves directly — and the before → after display in the inbox means a mis-targeted update is visible before it is applied, not after.

**Precision over recall.** A proposal you dismiss costs more attention than a message that was quietly skipped, because dismissing is work and it teaches you to distrust the queue. Every default here leans quiet: no `@channel`, no bots, `ignore` encouraged in the prompt. Loosen later against real dismissal rates, which the proposal table records for free.

**Never proposing the same thing twice.** Three separate mechanisms, because any one of them fails on its own: per-channel cursors so old messages are not re-read, `slack_seen_messages` so a crash mid-sync cannot re-bill the same message, and dismissed rows kept forever so a dismissal is permanent.

Products in this space — Reclaim, Motion, Sunsama, Linear's Slack sync — have all solved it at the product level, so the shape is proven. But none of it arrives as a library. The extraction and matching quality *is* the feature, and that is bespoke work no matter which of them you look at.

## Out of scope for v1

- DMs and group DMs. The scopes are not requested, so this is a locked door rather than a missing feature.
- Writing back to Slack — no reactions, no replies, no "✅ added to Serenity". Would need `chat:write` and `reactions:write`.
- Multiple workspaces. The session model is single-team; making it a list is a contained later change.
- Distribution to other people's workspaces, which the rate-limit section rules out on this architecture.
- A true task status beyond done/not-done. Wanted, but it is a change to the task model, its migration and its CloudKit mapping, not a Slack feature.
- Background polling on a quit app, and iOS background refresh.

---

## Status

Built and verified on 2026-09-18 against `swift build && swift test` (234 tests; the two `DailySurfaceTests` date failures predate this work and reproduce on a clean tree — the machine's locale renders "5 Dec" where the test expects "Dec 5"), plus `xcodebuild` for both `SerenityIOS` and `SerenityMac`.

Not yet done: the feature has never talked to a real workspace. Everything below the sign-in button is covered by stubbed responses, so the first live connection is still the real test — particularly the shape of `authed_user` on the token exchange and whether the relevance filter is as quiet in a busy workspace as it is in the fixtures.
