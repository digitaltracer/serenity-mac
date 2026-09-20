# Stand-up Generator

**Goal:** One button produces the words you say in your daily stand-up. Serenity gathers what actually happened since your last stand-up — finished tasks, and, just as importantly, the partial progress recorded in each task's activity log — lays it out as three columns you can rearrange, and then writes a script you can read out verbatim. Around forty seconds of speech, with every number, identifier and date preserved, and the detail it compressed one glance away.

```
Since Friday I got the Slack token refresh shipped, and fixed proposals coming in one per
reply instead of one per thread. The GitHub capture command is three of five subtasks in —
I'm finishing that today along with the Cost Center rate refresh. I'm still stuck on the
Postgres adapter timeouts: I need infra credentials, and it's been four days.
```

**Architecture:** Four stages, each independently testable. **Resolve** the window (pure; reads the last stand-up's timestamp). **Gather** the three columns from tasks and their activity logs (pure; no network, no model). **Confirm** on a three-column board where cards drag between columns and into a leaving-out tray. **Write** through the same provider-agnostic structured-JSON door that quick capture, Slack decisions and capture commands already use.

The model is called exactly once, and only after you have confirmed facts. Nothing on the confirmation board is model output — it is rows from the database with their provenance attached — so an edit there is an edit to reality, not a correction of a draft you have to proofread first.

**Tech Stack:** Swift 5.10, SwiftUI, GRDB, XCTest. macOS 14+ / iOS 17, so `draggable` / `dropDestination` and `swipeActions` are both available.

---

## Scope decisions

| Decision | Choice | Consequence |
|---|---|---|
| What "yesterday" means | Since the last generated stand-up; previous working day on first run | Monday picks up Friday, a skipped day is covered, and generating twice in one morning doesn't repeat itself. Requires stored history, which the carry-over behaviour needs anyway. |
| Sources | Tasks and their activity logs only | Journal stays out: a private entry reaching a team channel is the one unrecoverable failure here. GitHub activity and calendar events are deferred, which puts more weight on hand-added cards. |
| Partial progress | A first-class card, not a footnote | Subtask completions, comments and field changes all carry timestamps. This is the line people most often forget, and the activity log is the only place it exists. |
| Blockers | Derived as candidates, always labelled as guesses | The app has no blocker concept. Inferring one from staleness plus overdue is useful; presenting the inference as something you said is not. |
| A carried-over item | Stays in Today by default, marked neutrally | An item you mentioned last time is usually still today's work. The value of knowing you said it before is phrasing it as movement, not dropping it. |
| One task, two columns | Allowed | A task can be genuinely both "moved three subtasks yesterday" and "two left today". Forcing a choice loses half the truth. |
| Dropping a card | Goes to a leaving-out tray, recoverable | Excluding something before you speak should be auditable and reversible in the same gesture. |
| Format | A plain-English instruction the user writes, stored and editable | Teams run stand-up differently, and the format changes when feedback lands. |
| What the instruction controls | The words only, never the gathering | The three columns stay the fixed gathering model. Making columns configurable means a placement rule for every derived signal. |
| Length lever vs. instruction | Both; the instruction wins a conflict, and the screen says so | Length is the lever you reach for on a rushed morning; the instruction is the standing rule and shouldn't be silently overridden. |
| Model calls | Exactly one, after confirmation | Drafting first would mean confirming model output, two round trips, and a screen you must proofread rather than read. |
| No AI key | Deterministic template, badged | Matches how capture commands already degrade. |
| Storage | A new `standups` table | See Global Constraints — reusing the summaries table costs a full rebuild and still can't hold the per-item record. |
| Cost Center | Logged as the existing `summary` operation | A new usage operation means a fourth rebuild of the usage table. Capture commands made the same trade. |
| iPhone | One scrolling list, swipe a card to move it | You see the whole stand-up at once, which is what reviewing one is for. |

---

## Global constraints: two CHECK traps and one free lunch

**The usage log constrains its operation column.** `ai_usage.operation` is `CHECK (operation IN ('analyze','recap','quickadd','summary','slack'))`, and the table has already been rebuilt three times (`DatabaseMigrationRunner.swift:472`, `:617`, `:762`) because SQLite cannot alter a CHECK in place — each rebuild is a create, a copy, a drop, a rename and both indexes recreated. Adding a `standup` operation would make it four. The stand-up's single call logs as `summary` instead — it is a generated prose summary of a period, so the label is not even a lie.

**The summaries table constrains its type column the same way** — `CHECK(summary_type IN ('tasks','journal','combined'))` (`:272`), and it has been rebuilt twice already (`:499`, `:789`). So storing stand-ups as summaries costs the same again. It also would not work: a summary holds one content string, and the carry-over logic needs to read back *which task was in which column and what was said about it*. Hence a new table.

**Settings are free.** AI settings are a JSON blob under one key in `secure_settings` (`AIRepositories.swift:959`), so the format instruction and the length preference cost no migration at all — add the fields to the settings struct and they persist. The catch: `secure_settings` is not in the CloudKit record mapping, so the format instruction stays on the device that wrote it. Acceptable for now, worth stating in the UI if it ever surprises someone.

**A new synced table costs seven touch points**, which is the real price of storing history: the migration, the entity, a GRDB repository, a sync-aware wrapper that enqueues into the pending ledger (`SyncAwareRepositories.swift`), a CloudKit record kind (`CloudKitRecordMapping.swift`), registration in the record-kind list (`AppState.swift:3544`), and a line in the initial exporter (`CloudSyncInitialExporter.swift`). It does **not** touch the Postgres or Serenity Cloud adapters — those carry only the four core entities, and every AI table is already local-plus-CloudKit.

---

## Reference: resolving the window

Anchor to the `generated_at` of the most recent stored stand-up.

| Situation | Window start |
|---|---|
| A stand-up exists | Its `generated_at` |
| First ever run, today is Tue–Fri | Start of the previous day |
| First ever run, today is Monday | Start of Friday |
| First ever run, today is Sat/Sun | Start of Friday |
| Last stand-up is older than 14 days | 14 days ago, and the header says the window was capped |
| Last stand-up was earlier today | That timestamp, with the header noting the window is a few hours |

Working days are Monday to Friday, not configurable in v1. The cap exists because three weeks of activity after a holiday is not a stand-up, it is a status report, and the model will happily try to say all of it.

The window end is always now.

---

## Reference: what lands in each column

Everything below comes from `TaskEntity` and its `activity` array. Activity lines are already stored rendered and in absolute terms (`CoreEntities.swift:30`), so a line written a month ago still reads correctly — which is exactly what a stand-up needs and what makes this cheap.

**Since &lt;window start&gt;** — what to claim credit for.

| Signal | Card's fact line |
|---|---|
| `completedAt` inside the window | "Finished Friday 4:12 PM" |
| Open task with `activity` events inside the window | "3 of 5 subtasks done Friday" — count the subtask lines |
| Open task with your own comments inside the window | The comment text, quoted, plus its time |
| Task created inside the window and since touched | "Picked up Friday" |

**Today** — what to commit to.

| Signal | Card's fact line |
|---|---|
| Open and due today | "Due today" |
| Open and overdue | "Overdue by 2 days" |
| Open, and in the previous stand-up's Today column | "Due Tuesday · 2 subtasks left", plus the carried-over chip |
| Open with activity in the window (still moving) | "2 subtasks left" |

**Blocked on** — candidates only, every one labelled as a guess.

| Signal | Why it is a candidate |
|---|---|
| Open, overdue, **has at least one activity entry**, and nothing for 3+ days | The classic silent stall |
| Carries a `blocked` tag | Stated, not guessed — this one is not labelled |
| In the previous stand-up's blocked column and still open | Still stuck, and now you can say how long |

The activity requirement was added while building: without it, every overdue
backlog item you never picked up was being called a blocker. A stall is only
worth raising when there is evidence you started the work and it then went
quiet, so an empty activity log disqualifies the guess. The cost is a false
negative on tasks predating the activity log, which is the better failure.

**Leaving out**, pre-filled — tasks in the Google Calendar project (they are synced meetings, tagged `google-calendar`, and are usually noise), plus anything you drag there. Everything in the tray is one drag from coming back.

A task appearing in two columns is two cards with the same task id and different fact lines. Card identity is the pair, not the task.

---

## Reference: the one model call

**System prompt** carries the rules that always hold, regardless of the user's format:

- Use only the supplied facts. Never invent a task, a number, a name or a date.
- Preserve every number, identifier, PR reference and date that appears in a fact line.
- Write for speaking: contractions, no bullet characters, no headings in the spoken rendering.
- Anything you compress out of the spoken script goes in `folded`, one entry per omitted specific.
- For an item marked as said before, say where it got to. Do not repeat the previous phrasing.

**User prompt** carries, in order: today's date and the window in words; the length target; the user's format instruction verbatim inside a fenced block; then the three columns as confirmed, each card giving its fact line, whether the user added it by hand, whether it was flagged as a guess, and what the previous stand-up said about it.

Conflict rule, stated in the system prompt: where the format instruction and the length target disagree, the instruction wins. The screen says the same thing in a line under the length control, so the behaviour is not a surprise.

**Response schema** through the existing structured-JSON door (`AIProviderAPIClient.swift:106`), which already fans out to OpenAI, Anthropic, Gemini, NVIDIA and any OpenAI-compatible base URL:

```json
{
  "spoken": "one paragraph, no bullets",
  "paste": "markdown with the format's own sections",
  "folded": ["specifics compressed out of the spoken version"]
}
```

Decoding reuses the repair path the capture drafter already has for a model that returns prose around its JSON.

**Without a key**, a deterministic renderer produces the same three fields from templates and the screen carries the "No AI key" badge, the way the capture preview does (`SerenityAppScene.swift:2043`).

---

## Reference: what exists today and gets reused

| Need | What already does it |
|---|---|
| Per-task history with timestamps | The activity log written on every save (`CoreWorkflowModels.swift`, `TaskActivityRecorder`) |
| Provider-agnostic structured JSON | `AIProviderAPIClient.generateQuickCaptureJSON` |
| Credential choice, repair, usage logging | `AIWorkflowService`'s existing selection and `recordUsage` paths |
| A confirmation surface before anything is written | The capture-command preview card, same principle at a larger size |
| Compact-layout switching for iPhone | The existing compact layout environment value |
| Saving the result as a journal entry | The existing journal create path, so it syncs like any other entry |
| Storing settings with no migration | The AI settings JSON blob |

---

## Build order

**1 — Window and gathering, pure.** Resolve the window from a supplied "last stand-up at" and a supplied now. Build the three columns plus the leaving-out tray from a supplied task array. No UI, no database, no network. This is where the behaviour actually lives, and it is fully unit-testable in isolation.

**2 — Storage.** Migration `20260921_013_standups`, the entity, the repository, the sync-aware wrapper, the CloudKit record kind, registration, the exporter line. Columns: id, generated_at, window_start, window_end, spoken, paste, folded JSON, items JSON (task id, column, fact line, source kind, user-added, was-a-guess, per item), the format instruction actually used, the length, provider, the three token counts, created_at, updated_at.

**3 — The board on macOS.** Three columns, drag between them, the leaving-out tray, per-column add, the guess and carried-over chips. Every card also gets a context menu offering the same moves — the keyboard and VoiceOver path, which is needed regardless and is the same code the iPhone will use.

**4 — Writing and output.** The single call, the deterministic fallback, and the output screen: spoken/paste toggle, word-and-seconds count, the folded detail strip, copy, and edit-in-place before copying.

**5 — The format instruction.** Field on the AI settings struct, a sheet reachable from the board header and from Settings, presets that fill the box as editable text rather than acting as modes, and a just-for-today override that does not persist.

**6 — iPhone.** One scrolling list, sections inline, swipe a card toward its neighbour to move it, the context menu as the accessible path.

**7 — Entry points.** A Home strip that appears only when the gather finds something, and a Stand-up section in the sidebar that also lists past stand-ups. Adding a section shifts the ⌘1–⌘8 assignments, which are driven by the navigation order (`AppSection.swift`).

**8 — Save to journal.** On finish, optionally write today's stand-up as a journal entry tagged `standup`, using the paste rendering.

Stages 1 and 2 are independent of each other and of the UI; 3 needs 1; 4 needs 1 and 2.

---

## Testing

- **Window resolution:** Monday with Friday's stand-up; a two-week gap hitting the cap; a second run the same morning; the very first run on each weekday.
- **Gathering:** a fixture task set with completions, subtask events, comments, overdue-and-stale, a `blocked` tag, and a calendar-tagged task, asserting each lands in the right column with the right fact line; and the two-column case.
- **Carry-over:** a stored previous stand-up marks the right cards and supplies what was said.
- **Prompt assembly:** the instruction appears verbatim and fenced; guessed items are labelled; the conflict rule is present.
- **Decode:** a clean response, a response wrapped in prose, a response missing `folded`.
- **Fallback:** the deterministic renderer with no credential configured.
- **Storage:** migration applies on a fresh and an existing database; repository round-trip; CloudKit encode/decode symmetry.
- **UI:** a section smoke test for the board, and a phone-layout test for the list variant.

---

## Deferred, and why

**Your GitHub activity as a source.** Your merged PRs and review comments describe a day better than a task list does, and the tokens are already stored. It is a whole fetch layer, and it should land once the three columns have proven themselves.

**Posting to Slack.** The Slack app holds a user token with history scopes only, deliberately. Posting needs `chat:write`, which means re-authorising every existing install. The paste rendering covers async stand-ups until then.

**A scheduled nudge.** A notification ten minutes before stand-up with the board already built is the obvious next move, and the notification scheduler is already there. Not until the gathering is trusted.

**Configurable columns.** Deliberately rejected for v1 — every derived signal would need a rule for where it lands.

**Syncing the format instruction across devices.** Blocked on `secure_settings` not being in the CloudKit mapping.
