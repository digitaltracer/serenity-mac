# Capture Commands: `/slack` and `/github` in the Home input

**Goal:** Paste a Slack conversation link or one-or-more GitHub PR links into the Home input, prefixed with `/slack` or `/github` and optionally followed by your own words, and get back one fully-formed task — title, description, priority, deadline, project, tags, subtasks — drafted from what the conversation or the pull request actually says. You see the draft before it is written.

```
/slack https://acme.slack.com/archives/C05QJ1X2Y/p1726742400123456 I said I'd own the migration, needs to land before the demo
/github https://github.com/acme/api/pull/812 https://github.com/acme/api/pull/815 both need the review comments addressed
```

**Architecture:** A command is a third branch in `submitQuickCapture()` (`SerenityAppScene.swift:1674`), alongside today's AI path and the native `journal:` path. It runs a three-stage pipeline: **parse** the command into typed references (pure, no network), **fetch** the source material through the integration service that already owns that provider's auth, then **draft** a task through the same provider-agnostic structured-JSON door quick capture and the Slack sync both use. The result lands in the existing Home preview card for confirmation.

The feature deliberately adds no new provider plumbing. Slack fetching reuses `SlackAPIClient` (`SlackIntegrationService.swift:75`) including its `Retry-After` handling and the cached `users.list` name map. GitHub fetching reuses `GitHubIntegrationService`'s keychain token list and the injectable `IntegrationRequestHandler` (`IntegrationServices.swift:50`). Drafting reuses `AIWorkflowService`'s credential selection, repair path and Cost Center logging.

**Tech Stack:** Swift 5.10, SwiftUI, GRDB, `URLSession`, XCTest

---

## Scope decisions

| Decision | Choice | Consequence |
|---|---|---|
| Command surface | Literal `/slack` / `/github` prefix, parsed on submit | No autocomplete popover in v1. The Home editor is `NSTextView` on macOS and `TextEditor` on iOS, so a `/` menu is two implementations — see Deferred. |
| What a Slack link resolves to | The whole thread, or a single message plus its neighbours | A one-message excerpt reads as a fragment; the thread is what the user means by "the chat". |
| What a GitHub link resolves to | PR metadata, review verdicts, discussion comments, changed file names | Not the diff. `Accept: vnd.github.diff` on a 900-line PR is a token bonfire for no gain. |
| Issues as well as PRs | Accepted | `/repos/{o}/{r}/issues/{n}` is the same call shape; refusing it would be a deliberate gap. |
| Links per task | One task by default; split when the sources are unrelated | A command is one intent with one deadline, so one task is the common case — but two unrelated PRs in one paste are two pieces of work, and forcing them together buries one of them in the other's subtasks. |
| DM links | Refused at parse time with an explanation | The Slack token has no `im:history` scope by design, so the call could only fail with `missing_scope`. Failing early says *why*. |
| Review before write | Always, for commands | Unlike a typed one-liner, a command's output is six lines long and cost a network round trip. A wrong deadline buried in a drafted description is worse than a wrong one-liner. No confidence shortcut. |
| Already-linked source | Drafts an **update** to the existing task, not a second task | Both syncs already tag their origin. Ignoring those tags means `/github` on a synced PR silently duplicates it. |
| Cost Center | Logged as the existing `quickadd` operation | A new `AIUsageOperation` case needs a third `ai_usage` CHECK rebuild. See Global Constraints. |

---

## Reference: link shapes that must parse

**Slack.** A "Copy link" from Slack produces:

```
https://acme.slack.com/archives/C05QJ1X2Y/p1726742400123456
https://acme.slack.com/archives/C05QJ1X2Y/p1726742400123456?thread_ts=1726740000.111222&cid=C05QJ1X2Y
```

`p1726742400123456` is the message timestamp with the decimal point removed — recover it by inserting a point six digits from the right. `SlackMessage.permalink` (`SlackMessageReader.swift:363`) already builds this form, so the parser is its inverse and the two belong in tests together.

When `thread_ts` is present the link points at a *reply*, and the conversation to fetch is rooted at `thread_ts`, not at the link's own timestamp. Getting this backwards fetches a one-message thread.

Channel IDs carry their type in the first character: `C` public, `G` private group, `D` direct message, `I`/`M` multi-party DM. A `D`-prefixed link is refused at parse time.

A link with no `p…` component names a channel rather than a conversation. Refused in v1 with "point me at a message, not a channel" — the alternative is guessing a time window.

**GitHub.**

```
https://github.com/acme/api/pull/812
https://github.com/acme/api/pull/812/files
https://github.com/acme/api/pull/812#issuecomment-2384…
https://github.com/acme/api/pull/812#discussion_r1842…
https://github.com/acme/api/issues/455
```

Everything after the number is discarded. Host must be `github.com`; an Enterprise host is refused with a message naming the limitation rather than a generic parse error.

---

## Reference: the API calls, and why each one

**Slack** — one call covers both the threaded and the standalone case:

`conversations.replies` with `channel` and `ts` set to the thread root returns the parent plus every reply. For a message that was never threaded it returns that single message. So there is no branch: resolve the root (`thread_ts ?? ts`), call `replies`, and if exactly one message comes back, top it up with a `conversations.history` window around it (`latest`/`oldest`/`inclusive`) for the same ±3 messages of context the relevance filter already uses.

Names come from `SlackMessageReader`'s existing day-cached `users.list` map (`:334`), and the text goes through `SlackProposalPlanner.clean` so `<@U024BE7LH>` never reaches a task title.

**GitHub** — four calls per link, all cheap against the 5000/hour authenticated budget:

| Call | Why |
|---|---|
| `GET /repos/{o}/{r}/issues/{n}` | Title, body, state, labels, assignees, milestone — **and the issue id**, which is the one the existing sync tags with |
| `GET /repos/{o}/{r}/pulls/{n}` | Draft flag, merged, mergeable state, base/head, review requests, changed-file count |
| `GET /repos/{o}/{r}/pulls/{n}/reviews` | Where "requested changes" lives. This is most of the actionable signal and the most common reason a PR is a task at all |
| `GET /repos/{o}/{r}/issues/{n}/comments` | The discussion. "Can you also handle the null case" is a subtask, and it only exists here |

Optionally a fifth, `GET /repos/{o}/{r}/pulls/{n}/files` with names only, capped at 30 — body-less PRs are common and the file list is often the only description available.

**The id trap.** `/pulls/{n}` and `/issues/{n}` return *different* `id` values for the same pull request: one is a pull id, the other an issue id, in separate number spaces. `syncGitHubPullRequests` (`IntegrationServices.swift:528`) tags `github-pr-<id>` from the **search** API, which returns issue objects — so its tags carry issue ids. Tagging a command-created task with the pull id would never collide with the sync's tag, and the same PR would exist twice with no warning. Take the id from the `issues/{n}` response.

**Which token.** `listTokens().filter(\.isActive)`, tried in order, first one that can see the repo wins. A private repo returns 404, not 403, to a token without access, so "not found" and "no access" are indistinguishable — the error message must say both.

---

## Reference: what exists today and gets reused

| What | Where | How it is used here |
|---|---|---|
| Home submit branch point | `submitQuickCapture()`, `SerenityAppScene.swift:1674` | Gains a command branch ahead of the AI and native paths |
| Ephemeral draft card | `aiQuickCapturePreview`, `SerenityAppScene.swift:1715` / `pendingAIQuickCapturePreview`, `AppState.swift:187` | The confirmation surface. Extended to render an update as before → after |
| Before → after row rendering | `SlackProposalChange` + `SlackProposalInboxView.changes(for:target:)`, `SerenityAppScene.swift:2950` | Lifted out so the Home card and the Slack inbox render a change the same way |
| Provider-agnostic structured JSON | `AIWorkflowService.quickCaptureGenerator`, `:80` | One more schema + prompt through the same injectable door |
| Repair-on-invalid-JSON | `classifyQuickCapture`'s catch, `AIWorkflowService.swift:170` | Same two-shot recovery, same usage accounting |
| Slack HTTP with 429 handling | `SlackAPIClient`, `SlackIntegrationService.swift:75` | Every Slack call in this feature |
| Slack session + refresh | `slackIntegrationService.activeSession()` | Refreshes the rotating token before the fetch, exactly as `syncSlackNow` does |
| Slack name cache and markup cleaner | `SlackMessageReader:334`, `SlackProposalPlanner.clean` | Rendering the conversation for the prompt |
| GitHub tokens in the keychain | `GitHubIntegrationService`, `IntegrationServices.swift:388` | `listTokens()` unchanged; a new fetch method alongside the sync |
| Origin tags | `slack-thread-<channel>-<threadTS>` (`SlackProposalService.swift:33`), `github-pr-<issueID>` (`IntegrationServices.swift:528`) | Duplicate detection, in both directions |
| Task creation and activity seeding | `applySlackCreate` / `applySlackUpdate`, `AppState.swift:1479` | The write path. A command write is the same operation with a different attribution line |
| Relative-date resolution | `QuickCaptureDateParser` | The fallback when no AI credential is configured |

---

## Global Constraints

- No new Swift package dependency.
- Nothing reaches `tasks` until the user confirms the draft. Not on high confidence, not on an unambiguous PR title.
- **A command must bypass the Slack sync's gates entirely.** `slack_seen_messages` exists to guarantee a message is processed once, ever; the relevance filter exists to drop messages not aimed at you. A command is an explicit instruction about a specific message — quite possibly one the filter already rejected or the sync already proposed on. Routing a command through either gate makes it silently do nothing. The command reads, and does not record seen state or advance any cursor.
- No AI call on a command that failed to fetch anything. A parse error or an unreachable link costs zero tokens.
- The command still works with no AI credential configured, degraded and honest about it: a task titled from the PR title or the anchor message, links in the description, no invented deadline, and a toast saying the draft was not written by a model.
- A deadline is set only where there is evidence for one — a date in your own words, a date stated in the conversation, or a PR milestone due date. A pull request has no inherent deadline and inventing one is the fastest way to stop trusting the field.
- Every new file goes into both targets in `Serenity.xcodeproj/project.pbxproj`; the classic project format needs explicit file refs and the iOS build breaks silently otherwise.
- No migration. Cost is logged against the existing `quickadd` operation. `ai_usage.operation` is constrained by a CHECK at `DatabaseMigrationRunner.swift:621`, and SQLite cannot widen a CHECK in place — a new operation value costs a third create-new / `INSERT … SELECT` / `DROP` / `RENAME` rebuild, which is not worth a Cost Center row label.

---

### Task 1: Parse the command

**Files:**
- Create: `Serenity/Shared/App/CaptureCommandParser.swift`
- Create: `SerenityTests/CaptureCommandParserTests.swift`

**Interfaces:**
- Produces: `CaptureCommandParser.parse(_ text: String) -> CaptureCommand?`
- Produces: `CaptureCommand { kind: .slack | .github, references: [CaptureReference], context: String }`
- Produces: `SlackConversationReference { channelID, threadRootTS, linkedTS, workspaceHost }`
- Produces: `GitHubPullReference { owner, repo, number, isPullRequest }`
- Produces: `CaptureCommandParseError` — `.notACommand`, `.noLinks`, `.directMessage`, `.channelWithoutMessage`, `.enterpriseHost`, `.wrongProvider(expected:)`, `.tooManyLinks(limit:)`

- [x] **Step 1: Recognise the command**

Match a leading `/slack` or `/github` case-insensitively, followed by whitespace or end of input. Anything else returns `nil` and falls through to today's behaviour untouched — `journal:` and plain text must keep working exactly as they do.

- [x] **Step 2: Split links from prose**

Tokenise the remainder on whitespace. A token parsing as an `https` URL with the expected host is a link; everything else, in original order, is the user's context. Prose containing a URL-shaped token is the awkward case — take links greedily and let the rest be context; a link mentioned mid-sentence still being fetched is the more useful failure.

Cap at 5 links per command and report the cap rather than truncating silently.

- [x] **Step 3: Parse a Slack link**

Path `archives/<channelID>/p<digits>`. Recover the timestamp by inserting a decimal point six digits from the right of the `p`-stripped digits. Read `thread_ts` from the query if present; the thread root is `thread_ts ?? recoveredTS` and `linkedTS` keeps the message the user actually pointed at, so the draft can say which reply it was about.

Refuse a `D`/`I`/`M`-prefixed channel with `.directMessage`, and a path with no `p…` component with `.channelWithoutMessage`.

- [x] **Step 4: Parse a GitHub link**

Host must be `github.com`. Path `<owner>/<repo>/(pull|issues)/<number>`, with everything after the number discarded. Anything else is `.enterpriseHost` or `.wrongProvider`.

- [x] **Step 5: Test the parser hard**

Pure functions over strings, so this is the cheapest confidence in the feature. Round-trip every case against `SlackMessage.permalink` where it applies. Cases: plain permalink, permalink with `thread_ts` and `cid`, trailing slash, uppercase `/SLACK`, a DM link, a channel-only link, `/pull/812/files`, `/pull/812#discussion_r…`, `/issues/455`, an Enterprise host, a `/slack` command holding a GitHub link, two links plus trailing prose, prose whose last word is a URL, six links, and no links at all.

---

### Task 2: Fetch the Slack conversation

**Files:**
- Modify: `Serenity/Shared/Integrations/SlackMessageReader.swift`
- Create: `SerenityTests/Integrations/SlackConversationFetchTests.swift`

**Interfaces:**
- Produces: `SlackMessageReader.fetchConversation(session:reference:contextRadius:) async throws -> SlackConversationExcerpt`
- Produces: `SlackConversationExcerpt { channelID, channelName, messages: [SlackMessage], anchor: SlackMessage, names: [String: String], permalink: String? }`

- [x] **Step 1: Add the fetch to the reader, not a new type**

`SlackMessageReader` already owns the client, the name cache and the message-from-raw mapping. A second actor would duplicate all three and refresh `users.list` twice.

- [x] **Step 2: Resolve the channel name**

A reference carries an ID, not a name, and `#eng-platform` in the draft is worth one call. `conversations.info` for the single channel — cheaper than the `users.conversations` walk the sync does, and it also works for a channel the pagination happened to miss.

- [x] **Step 3: Read the thread**

`conversations.replies` with `ts` = the reference's thread root, paginated on `response_metadata.next_cursor`. If it returns exactly one message, the link pointed at something unthreaded: follow up with `conversations.history` bounded by `latest`/`oldest`/`inclusive` around the anchor for `contextRadius` messages either side, defaulting to 3.

- [x] **Step 4: Fail with the reason, not the status code**

Map Slack's error strings to something actionable: `not_in_channel` → you are not in that channel; `channel_not_found` → the channel is private to others, or the link is from a different workspace; `missing_scope` → reconnect Slack; `thread_not_found` → the message was deleted. A raw `ok: false` in a toast tells the user nothing they can act on.

- [x] **Step 5: Test against fixtures**

`SlackAPIClient` takes an injectable `IntegrationRequestHandler`, so every case is a canned JSON response with no network: a threaded conversation, a paginated one, a standalone message that triggers the history top-up, each mapped error, and a 429 followed by success to confirm the existing retry still applies.

**As built:** all four Slack list responses (`channels`, `messages`, `members`, `usergroups`) declared their payload array as required, but Slack omits it entirely when it answers `ok: false`. Decoding threw before the transport could read the code, so every `not_in_channel` surfaced as "the data couldn't be read" — in the background sync too, not just here. Each array is now decoded as optional behind a non-optional accessor.


---

### Task 3: Fetch the pull request

**Files:**
- Modify: `Serenity/Shared/Integrations/IntegrationServices.swift`
- Create: `SerenityTests/Integrations/GitHubPullFetchTests.swift`

**Interfaces:**
- Produces: `GitHubIntegrationService.fetchPullRequest(_ reference: GitHubPullReference, includeFiles: Bool) async throws -> GitHubPullSnapshot`
- Produces: `GitHubPullSnapshot { issueID, number, owner, repo, title, body, state, isDraft, isMerged, labels, assignees, milestoneTitle, milestoneDueOn, reviews: [GitHubReviewSummary], comments: [GitHubCommentSummary], changedFileNames, htmlURL, createdAt, updatedAt }`

- [x] **Step 1: Pick a token that can see the repo**

Walk `listTokens().filter(\.isActive)` and use the first whose `issues/{n}` call succeeds. On exhausting them, throw an error that names both possibilities — the repo does not exist, or no configured token can reach it — because GitHub returns 404 for each.

- [x] **Step 2: Make the four calls**

`issues/{n}` first, since its failure decides the token and its `id` is the one that matters for tagging. Then `pulls/{n}`, `pulls/{n}/reviews` and `issues/{n}/comments`. For an issue link, skip the two `pulls` calls.

Cap comments at the 30 most recent and reviews at the latest verdict per reviewer — a review thread with 80 comments is mostly "LGTM" and resolved chatter, and the prompt budget is better spent on the PR body.

- [x] **Step 3: Carry the milestone due date through**

`milestone.due_on` is the only real deadline a pull request has. It is the difference between a drafted deadline the user believes and one they delete.

- [x] **Step 4: Test against fixtures**

Same injectable handler as `syncGitHubPullRequests`. Cases: an open PR with requested changes, a draft, a merged PR, a PR with a milestone, an issue link, 404 on the first token and success on the second, 404 on all tokens, a 403 rate-limit body, and a PR whose body is empty so the file list carries the description.

**As built:** the two-id hazard was confirmed against live GitHub rather than taken on trust. For `groue/GRDB.swift#1876`, `issues/1876` and the search API both answer `5095599377`, while `pulls/1876` answers `4232991238`. Tagging from the pull endpoint would never have collided with the sync's tag.

---

### Task 4: Draft the task

**Files:**
- Create: `Serenity/Shared/AI/CaptureCommandDrafter.swift`
- Modify: `Serenity/Shared/AI/AIWorkflowService.swift`
- Create: `SerenityTests/AI/CaptureCommandDrafterTests.swift`

**Interfaces:**
- Produces: `CaptureCommandDrafter` — prompt, schema, rendering, and decode, with no network or credentials
- Produces: `AIWorkflowService.draftCaptureCommand(source:userContext:candidates:projects:availableTags:now:credentialID:) async throws -> CaptureDraft`
- Produces: `CaptureDraft { kind: .create | .update, targetTaskID: String?, payload: SlackProposalPayload, confidence, reason, sourceAttribution: String }`

- [x] **Step 1: Reuse the payload type rather than inventing one**

`SlackProposalPayload` (`SlackRepositories.swift:27`) is already "the fields a draft would set, each optional so an update writes only what changed", and `applySlackCreate`/`applySlackUpdate` already consume it. A parallel type would mean a parallel write path.

- [x] **Step 2: Render the source material**

Slack: `#channel`, then each message as `Name (abs date): text` through `SlackProposalPlanner.clean`, with the linked message marked. GitHub: a header line (`acme/api#812 — open, 2 approvals, 1 requested change`), the body, each review as verdict plus body, each comment as author plus text, and the file list last so it truncates first. Cap the whole rendering at ~10k characters, dropping oldest comments first.

- [x] **Step 3: Write the prompt**

The job: read this source material and the user's own words, and draft one task. The user's words outrank the source on every field they touch — they said "needs to land before the demo" because the conversation does not say it.

State the rules the Slack prompt already states, for the same reasons: absolute ISO dates resolved against today, short imperative titles, no Slack or Markdown markup in the title. Add the ones specific to commands:

- A deadline only with evidence — the user's words, a date stated in the source, or a milestone. Null otherwise, and never a deadline derived from "reviews should be quick".
- The description carries what a person would need to act without opening the link: what is being asked, by whom, and what is blocking. Every source link goes in it verbatim.
- Subtasks come from distinct asks actually present in the source — review comments to address, files to change, questions to answer. Not invented scaffolding.
- `ignore` is not an option here. The user asked for a task; produce one.

- [x] **Step 4: Define the schema**

Mirror `SlackProposalPlanner.schema()` minus the `ignore` action and the per-signal array, plus a `sourceSummary` string — one line naming what the draft was read from, shown on the card.

The array carries one entry in the common case. The prompt, not the schema, is what keeps it there — see Settled decisions.

- [x] **Step 5: Detect an existing task for this source**

Before the AI call, and **once per link**, look for an open task tagged `slack-thread-<channel>-<threadRoot>` or `github-pr-<issueID>`. Each hit goes into the prompt with that task's current fields and is asked for an update rather than a create. This is what stops `/github` on an already-synced PR producing a duplicate — and because it runs per link, one paste can legitimately return a create and an update together.

Also shortlist by word overlap the way `SlackProposalPlanner.shortlist` does, so an untagged but obviously-related task can still be matched — capped at 8 candidates.

- [x] **Step 6: Route through the existing generator**

`draftCaptureCommand` follows `proposeSlackDecisions` (`AIWorkflowService.swift:199`): `chooseCredential`, call `quickCaptureGenerator`, decode, and on a decode failure take the same repair shot `classifyQuickCapture` takes. Log usage as `.quickadd`.

- [x] **Step 7: Test the pure parts**

Rendering, truncation order, candidate shortlisting, tag-based matching, and decoding — including a response that names a task id not in the candidate list, which must be rejected rather than written to a stranger's task.

---

### Task 5: Wire the command into the Home input

**Files:**
- Modify: `Serenity/Shared/App/SerenityAppScene.swift`
- Modify: `Serenity/Shared/App/AppState.swift`
- Create: `SerenityTests/CaptureCommandFlowTests.swift`

**Interfaces:**
- Produces: `AppState.submitCaptureCommand(_ command: CaptureCommand) async -> Bool`
- Produces: `@Published var captureCommandProgress: CaptureCommandProgress?`
- Produces: `@Published var pendingCaptureDraft: CaptureDraftPreview?`

- [x] **Step 1: Branch before everything else**

In `submitQuickCapture()`, try `CaptureCommandParser.parse` first. A parsed command goes to `submitCaptureCommand`; `nil` falls through to today's code path unchanged.

- [x] **Step 2: Say what it is doing**

These commands take seconds, not milliseconds. Publish a progress line the card renders under the input — "Reading #eng-platform…", "Reading acme/api#812…", "Drafting…" — and keep the submit button in its spinner state throughout. A silent five-second pause on a paste reads as a hang.

- [x] **Step 3: Refuse cleanly when the provider is not connected**

Check `slackIntegrationState.connected` / a non-empty active token list before fetching, and surface the fix rather than the failure: "Connect Slack in Integrations first." Parse errors surface their own message — the DM case in particular should explain that Serenity's Slack token cannot read DMs by design, or it reads as a bug.

- [x] **Step 4: Show the draft, always**

Hold the result in `pendingCaptureDraft` and render it in the Home card — a list when the draft split, each entry carrying its own create/update badge. No confidence shortcut: a command's output is long enough that reading it before it is written is the point. One Save writes every entry; Discard drops all of them.

- [x] **Step 5: Write on confirm**

Accept routes to `applySlackCreate` / `applySlackUpdate`, which already handle tags, subtasks, project validation, status change and the activity line. Pass an attribution line naming the source — "Drafted from acme/api#812, 19 Sep 2026" — so the task's history says where it came from. Then the existing post-write refresh, so Home, ActionHub and notifications all pick it up.

Discard clears the draft and leaves the typed command in the input, so a near-miss can be re-run with a word changed instead of re-pasted.

- [x] **Step 6: Degrade without an AI credential**

No enabled credential means no draft, but the fetch already succeeded and the material is in hand. Build a plain task — title from the PR title or the first line of the anchor message, links and the user's context in the description, `QuickCaptureDateParser` over the user's context for a date, origin tag applied — and say in the toast that it was assembled without a model.

- [x] **Step 7: Update the helper text**

`quickCaptureHelperText` (`SerenityAppScene.swift:1864`) is the only discovery surface in v1: "Paste a Slack or GitHub link after `/slack` or `/github`."

---

### Task 6: Share the before → after rendering

**Files:**
- Modify: `Serenity/Shared/App/SerenityAppScene.swift`

- [x] **Step 1: Lift the change rows out of the inbox**

`SlackProposalChange` and `SlackProposalInboxView.changes(for:target:)` (`:2950`) compute exactly what the command card needs for an update. Extract them to a shared helper and a small view so both surfaces render a change identically. A second, subtly different diff renderer is how the two surfaces start disagreeing about what a change looks like.

---

## Settled decisions

**One task by default, several when the sources are unrelated.** The schema returns an array. The prompt's rule: one task unless the links describe work that would be tracked separately anyway — different repos, unconnected asks, different people waiting. When it splits, each task gets its own deadline and its own origin tag, and the confirm card becomes a list of cards rather than one. A split of more than 3 is treated as the model failing to find the common thread: fall back to one task with the links as subtasks rather than flooding ActionHub from a single paste.

**The draft is always shown.** No confidence threshold, no fast path. Confidence still renders on the card, because it tells the user how hard to read before accepting.

**A source that already has a task drafts an update.** This runs *per link*, not per command — so a paste of two PRs where one is already tracked produces one create and one update in the same card. Mixed cards are the normal case, not an edge case, and the card must lead with the kind badge on each row so the difference is visible at a glance.

## Deferred

- **A `/` autocomplete menu.** The macOS editor is an `NSTextView` subclass and the iOS one is a `TextEditor`, so a token-aware popover is two implementations plus key handling. Worth doing once the command set justifies it.
- **Bare links with no command.** Pasting a PR URL alone could do the same thing, but it would hijack the perfectly reasonable "keep this link in a task".
- **A real task status.** `TaskEntity` has `completed: Bool` and nothing else (`CoreEntities.swift:70`), so "open, approved, waiting on CI" can only live in tags and the description — the same ceiling the Slack sync documented. A status enum means a migration, a CloudKit mapping change, and every reader of `completed`.
- **GitHub Enterprise hosts.** A configurable API base URL per token, and a different auth story.
- **Slack channel links.** Resolving "this channel" to a time window is a guess; if it is wanted, it should be an explicit window.
- **Renaming `journal:` to `/journal`.** Two prefix conventions in one input is a small ongoing wart, and the rename is a handful of lines with the old form kept working. It is a separate concern from this feature.


---

## As built

Every task above is done; `swift test` reports 368 tests with only the two pre-existing `DailySurfaceTests` locale failures, and both the macOS and iOS targets build.

Verified against live data on 19 Sep 2026: `/slack` drafted a task from a real `#field-support` thread end to end, and the GitHub fetch and renderer were run against the real payloads of `DocketAI/inbound-se-backend#761`. That pull request also settled the two-id hazard on the user's own data — `issues/761` answers `5475132920`, `pulls/761` answers `4548108149`.

Two things changed shape during the build:

**The apply path was refactored rather than duplicated.** `applySlackCreate` / `applySlackUpdate` took a whole `SlackProposal`, which a command has no honest way to construct — its source is a pull request, not a Slack message. They now take a payload plus the one activity line that says where the work came from, and the Slack proposal path passes its own attribution into them. A command writes through exactly the same two functions.

**Automated reviewers had to be told apart from people.** Running the feature on a real pull request (`DocketAI/inbound-se-backend#761`) showed all four of its reviews and all three of its comments were review bots — 12,876 characters of generated walkthrough and zero human discussion. The original truncation shed comments by age, so a person's one-line ask from last week would have lost to a bot's summary of the diff from today. Reviews and comments now carry an `isBot` flag, people are listed first, bots are labelled `(automated)` so the model can weigh them, and truncation sheds every bot before it touches a human. This is the same call the Slack relevance filter already made for bot messages.

**Bot markers are stripped, from bots only.** Review bots bracket their output with HTML comments GitHub never renders — `<!-- ENTELLIGENCE_WALKTHROUGH -->`, `<!-- BUGBOT_FIX_ALL -->`, `<!-- CONFIDENCE_SCORE -->` — which otherwise reach the prompt as text. They are removed from a bot's comment or review body, and a bot comment left with nothing readable is dropped entirely, though a bot *verdict* keeps its line because the state is the signal. The pull request body and anything a person wrote are passed through untouched: an HTML comment someone typed, they typed on purpose. On `#761` this removed 268 characters of marker text across four bot posts.

**A new `AIWorkflowError` case was added after all.** The Slack decode failure message is reused everywhere else, but putting the word "Slack" in front of a failed GitHub draft would be actively misleading, so capture drafts report their own.
