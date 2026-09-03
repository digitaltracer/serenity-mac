# NVIDIA NIM Provider Implementation Plan

**Goal:** Add NVIDIA NIM as a fourth AI credential provider alongside OpenAI, Gemini and Anthropic, using the hosted NVIDIA API catalog endpoint.

**Architecture:** NIM is OpenAI-compatible, so it joins the existing per-provider switch pattern rather than introducing an abstraction. `AIProviderAPIClient` gains a `.nvidia` arm in both entry points; the three provider enums and the six SQLite `CHECK (provider IN (...))` constraints widen to admit `nvidia`. No new columns, no base-URL field, no protocol extraction.

**Scope decision:** Hosted catalog only — fixed base URL `https://integrate.api.nvidia.com/v1` with an `nvapi-` bearer key. Self-hosted NIM containers (arbitrary base URL, optional keyless auth) are explicitly out of scope; supporting them later means adding a `base_url` column to `ai_provider_credentials` plus an endpoint field in the settings form.

**Tech Stack:** Swift 5.10, SwiftUI, GRDB, XCTest, Swift Package Manager

## Global Constraints

- Add no dependency, no speculative abstraction, and no provider-agnostic refactor of the existing three arms.
- Existing rows and existing CloudKit records must survive the migration untouched.
- Every `switch` over a provider enum stays exhaustive — no `default:` arms added to silence the compiler.
- Keep the credential form's shape; NIM is one more card in the existing picker row.

## Reference: what the enums and constraints look like today

Three separate provider enums in `Serenity/Shared/Data/AIEntities.swift`:

| Enum | Line | Cases today | Used for |
|---|---|---|---|
| `AIProvider` | :3 | `openai`, `gemini`, `anthropic`, `local` | insights, recaps, summaries |
| `AIUsageProvider` | :158 | `openai`, `gemini`, `anthropic` | usage log, model rates |
| `AICredentialProvider` | :304 | `openai`, `gemini`, `anthropic` | stored credentials, settings |

`AIWorkflowService.providerForCredential` (:1085) maps a credential onto `AIProvider`, and its result is written to insights (:374, :401, :430), summaries (:504) and recaps (:585) — which is why all three enums and all six tables must widen together.

---

### Task 1: Widen the domain enums

**Files:**
- Modify: `Serenity/Shared/Data/AIEntities.swift`
- Modify: `Serenity/Shared/App/AppState.swift`
- Modify: `SerenityTests/Data/AIRepositoriesTests.swift`

**Interfaces:**
- Produces: `AICredentialProvider.nvidia`, `AIProvider.nvidia`, `AIUsageProvider.nvidia`, `AIPreferredModels.nvidia`

- [x] **Step 1: Add the case to all three enums**

`AIProvider` (:3), `AIUsageProvider` (:158) and `AICredentialProvider` (:304) each gain `case nvidia`. Raw value stays `nvidia` — see Task 4 Step 3 for why it must not be `nvidia_nim`.

- [x] **Step 2: Add the preferred-model slot**

`AIPreferredModels` (:386) gains `public var nvidia: String?` and its init widens to `init(openai:gemini:anthropic:nvidia:)`. The struct is `Codable` and persisted as JSON on the settings row, so existing rows decode the absent key as `nil` — no data fixup needed.

**As built:** `nvidia:` took a `= nil` default, so neither existing call site (`AppState.swift:1310`, `AIRepositoriesTests.swift:354`) needed touching.

- [x] **Step 3: Extend the `setAIPreferredModel` switch**

`AppState.setAIPreferredModel` (:1309) switches over the credential provider to pick which field to write; add the `.nvidia` arm.

- [x] **Step 4: Build and collect the exhaustiveness errors**

`swift build` now fails at every non-exhaustive switch. That error list is the worklist for Tasks 4 and 5 — capture it rather than guessing at call sites.

---

### Task 2: Widen the six provider CHECK constraints

**Files:**
- Modify: `Serenity/Shared/Data/DatabaseMigrationRunner.swift`

**Interfaces:**
- Produces: migration `20260901_008_nvidia_provider`, `schema_version` = `7`

SQLite cannot alter a `CHECK` constraint in place, so each table needs the create-new / `INSERT INTO … SELECT` / `DROP` / `RENAME` cycle.

| Table | CHECK at | Enum governing it |
|---|---|---|
| `ai_insights` | :220 | `AIProvider` (keeps `local`) |
| `ai_recaps` | :244 | `AIProvider` (keeps `local`) |
| `ai_usage` | :264 | `AIUsageProvider` |
| `summaries` | :282 | `AIProvider` (keeps `local`) |
| `ai_provider_credentials` | :293 | `AICredentialProvider` |
| `ai_model_rates` | :384 | `AIUsageProvider` |

- [x] **Step 1: Write the migration test first**

Assert the migration admits `nvidia` on all six tables and still rejects an unknown value. A fresh-bootstrap test plus an upgrade-from-006 test — the upgrade path is the one that exercises the table rebuild.

- [x] **Step 2: Add the migration**

Append one `DatabaseMigration` to the `migrations` array, ending with `INSERT OR REPLACE INTO app_metadata (key, value) VALUES ('schema_version', '7');` to match the house pattern.

Rebuild gotchas:

- **`ai_usage` gained four columns in migration 007** (`model`, `input_cost_usd`, `output_cost_usd`, `total_cost_usd`). The rebuilt DDL must include them or the copy silently drops cost history.
- **`ai_provider_credentials` carries `UNIQUE(provider, name)`** — preserve it.
- **`ai_model_rates` carries `UNIQUE(provider, model)`** and a `source` CHECK — preserve both.
- **Indexes die with their table.** Recreate: `idx_ai_insights_created_at`, `idx_ai_insights_category`, `idx_ai_insights_type`, `idx_ai_insights_theme_id`, `idx_ai_recaps_created_at`, `idx_ai_recaps_type`, `idx_ai_usage_timestamp`, `idx_ai_usage_model`, `idx_summaries_type`, `idx_summaries_date_range`, `idx_summaries_generated`, `idx_ai_credentials_provider`, `idx_ai_credentials_enabled`, `idx_ai_credentials_priority`, `idx_ai_model_rates_provider_model`.
- **Foreign keys are a non-issue.** The only FK in the entire schema is `tasks.project_id → projects(id)` (:128); nothing references these six tables, so the drop/rename cannot orphan a reference.

---

### Task 3: Add the NIM API client arms

**Files:**
- Modify: `Serenity/Shared/AI/AIProviderAPIClient.swift`

**Interfaces:**
- Consumes: `perform`, `jsonData`, `jsonString`, `estimateTokenCount` (existing private helpers)
- Produces: `fetchNvidiaModels(apiKey:)`, `generateNvidiaJSON(apiKey:model:systemPrompt:userPrompt:schema:)`, plus `case .nvidia` in `fetchModels` (:38) and `generateQuickCaptureJSON` (:59)

- [x] **Step 1: Model listing**

`GET https://integrate.api.nvidia.com/v1/models` with `Authorization: Bearer <key>`. The response is OpenAI-shaped, so the existing `OpenAIModelsResponse` / `OpenAIModel` decodables work unchanged.

**Filtering is mandatory, not polish.** The catalog returns 100+ entries mixing chat, embedding, reranking, OCR and vision models with no capability field to sort by. `fetchOpenAIModels` solves the same problem with an allowlist of prefixes (`isLikelyOpenAIChatModel`, :106); NIM needs the inverse — a denylist dropping ids containing `embed`, `rerank`, `nv-embedqa`, `ocr` and similar, falling back to the unfiltered list when the filter empties it (mirroring the `chatIDs.isEmpty ? allIDs : chatIDs` pattern at :101).

- [x] **Step 2: JSON generation**

`POST https://integrate.api.nvidia.com/v1/chat/completions` with `model`, `messages` (system + user), `temperature: 0`, `max_tokens`.

Structured output: NVIDIA recommends `nvext.guided_json` over `response_format: {"type": "json_object"}`, because the latter permits any valid JSON including an empty object. Hosted-catalog support for `nvext` varies by model, so also restate the schema in the user message the way the Anthropic arm already does (:239) — belt and braces, and it matches existing house style.

- [x] **Step 3: A separate usage decodable**

Chat Completions reports `usage.prompt_tokens` / `usage.completion_tokens`. The existing `OpenAIResponsesPayload.Usage` decodes `input_tokens` / `output_tokens` (the Responses API naming) and will silently yield `nil` — so NIM needs its own payload struct, falling back to `estimateTokenCount` exactly as the other three arms do.

---

### Task 4: Wire the service layer

**Files:**
- Modify: `Serenity/Shared/AI/AIWorkflowService.swift`

- [x] **Step 1: Seed the model catalog**

`AIProviderModelCatalog.models` (:27) gains a `.nvidia` list. Note NIM model ids are namespaced and contain a slash (`meta/llama-3.1-70b-instruct`, `nvidia/llama-3.3-nemotron-super-49b-v1`); nothing interpolates a model into a URL path except the Gemini arm, so this is safe.

- [x] **Step 2: Extend the four provider switches**

- `preferredModel(for:settings:)` (:1040) — reads `settings.preferredModels?.nvidia`, falls back to the catalog head
- `AIUsageCostService`'s preferred-model switch (:1280) — same shape
- `providerForCredential` (:1085) — `.nvidia → .nvidia`
- `usageProviderForCredential` (:1096) — `.nvidia → .nvidia`

- [x] **Step 3: Fix the LiteLLM rate lookup — silent failure**

`AIUsageCostService.fetchLiteLLMRate` matches on `litellm_provider == provider.rawValue` (:1306). LiteLLM files NIM models under `litellm_provider: "nvidia_nim"`, so a raw value of `nvidia` matches nothing: every NIM request logs at **zero cost with no error surfaced**.

Fix with a `litellmSlug` mapping on `AIUsageProvider` (`.nvidia → "nvidia_nim"`, the others returning `rawValue`) rather than renaming the enum case. A raw value of `nvidia_nim` would leak into the DB CHECK constraints and into `provider.rawValue.capitalized`, which is the fallback credential name (:271) — yielding "Nvidia_nim Credential".

`modelKeyMatches` (:1326) already handles NIM's slash-bearing ids via its `hasSuffix("/\(model)")` branch, so no change needed there.

- [x] **Step 4: Seed cost rates**

Add NIM entries to `seededRates` (:1149) so the cost centre shows real numbers before the first LiteLLM refresh.

---

### Task 5: Wire the UI

**Files:**
- Modify: `Serenity/Shared/App/SerenityAppScene.swift`
- Create: `Serenity/Assets.xcassets/ProviderNvidia.imageset/Contents.json`
- Create: `Serenity/Assets.xcassets/ProviderNvidia.imageset/ProviderNvidia.svg`

- [x] **Step 1: Widen the two hard-coded provider lists**

`providerOptions` is hard-coded as `[.openai, .gemini, .anthropic]` in two places — :5123 and :7695. These are the only reason NIM would not appear in the picker even with the enum extended.

- [x] **Step 2: Extend the presentation switches**

Credential-provider switches: preferred-model read (:1515), title (:1532), icon (:1543), tint (:1554), title (:7698), logo asset (:7719), icon (:7730), tint (:7741).

Usage-provider switches: `rateProviderTitle` (:5765), `rateProviderSubtitle` (:5771), icon (:5781), tint (:5789).

The rate-card picker itself enumerates `AIUsageProvider.allCases` (:5646), so it picks up NIM with no edit — but its four presentation switches are exhaustive and will fail to compile until extended.

- [x] **Step 3: Add the logo asset**

Copy the `Contents.json` shape from `ProviderOpenAI.imageset` — single universal SVG, `preserves-vector-representation: true`, `template-rendering-intent: template`. `providerLogoAsset` (:7719) returns `"ProviderNvidia"`.

**As built:** the tint is plain `.green`, matching how `.purple` and `.orange` serve Gemini and Anthropic, rather than a new palette token for one provider. The asset catalog is referenced as a folder in `project.pbxproj`, so the new imageset needed no project-file change.

---

### Task 6: Tests and verification

**Files:**
- Modify: `SerenityTests/AppStateTests.swift`
- Modify: `SerenityTests/AI/AIWorkflowServiceTests.swift`
- Modify: `SerenityTests/Data/AIRepositoriesTests.swift`

- [x] **Step 1: Provider-list assertions**

`AppStateTests.swift:63` asserts exact arrays out of `AIProviderDropdownAvailability.enabledProviders`. Add a NIM case.

- [x] **Step 2: Quick-capture round trip**

`AIWorkflowService.init` takes an injectable `QuickCaptureGenerationHandler` (:90) — stub it for `.nvidia` and assert the classification path, usage row and cost row all land with `provider = nvidia`.

- [x] **Step 3: LiteLLM slug regression**

`testLiteLLMSlugMapsNvidiaOntoNvidiaNim` in `AIWorkflowServiceTests`, so the zero-cost failure from Task 4 Step 3 cannot regress silently.

**Not built:** a test asserting every catalog model has a seeded rate — `AIUsageCostService.defaultRates` is `private`, and widening it just for the assertion was not worth the access change.

- [x] **Step 4: Full verification**

```
swift build && swift test
```

87 XCTest tests today; the swift-testing runner reporting "0 tests" is normal — read the XCTest "Executed N tests" line.

```
xcodebuild -scheme SerenityIOS -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme SerenityMac -configuration Debug build
```

Both matter: the classic pbxproj needs explicit file refs per target, and the new imageset is a new file ref.

For visual confirmation, launch the Xcode-built app — the raw SPM binary (`.build/debug/SerenityMac`) traps in `CKContainer.init` without the iCloud entitlement:

```
open ~/Library/Developer/Xcode/DerivedData/Serenity-*/Build/Products/Debug/SerenityMac.app
```

---

## Notes

**CloudKit is safe.** `ai_insights` is the only AI table that syncs. Its decoder falls back to `AIProvider.local` for unrecognised provider strings (`CloudKitRecordMapping.swift:390`), so an older client pulling a NIM-authored insight degrades to `local` — a value its own CHECK constraint already accepts — instead of failing to decode.

**The external Postgres adapter needs nothing.** `ExternalPostgresAdapter.swift` carries no provider constraint or provider-shaped DDL.

## Sources

- [Structured Generation with NVIDIA NIM for LLMs](https://docs.nvidia.com/nim/large-language-models/1.12.0/structured-generation.html)
- [NVIDIA NIM LLM APIs](https://docs.api.nvidia.com/nim/reference/llm-apis)
- [LiteLLM — NVIDIA NIM provider](https://docs.litellm.ai/docs/providers/nvidia_nim)

## Build log

Completed 2026-09-01 on `feat/3`.

- `swift build` clean; `swift test` — 153 tests, 0 failures (up from 150; the three new ones are the two migration tests and the NIM quick-capture routing test, plus the slug test).
- `xcodebuild -scheme SerenityMac -configuration Debug build` — succeeded.
- `xcodebuild -scheme SerenityIOS -destination 'generic/platform=iOS Simulator' build` — succeeded.
- `assetutil --info Assets.car` lists `ProviderNvidia` beside the other three provider renditions.
- `strings` on the built binary contains `NVIDIA NIM`.

**Not verified:** a screenshot of the four-card provider picker. The app's window kept dropping off the onscreen list after a relaunch (it also vends a `MenuBarExtra`), and `screencapture -R` failed against the stale rect. Worth a manual look at Settings → AI Provider.

## Post-ship fix: HTTP 400 on every request

Reported after the first pass. Root cause was the seeded model catalog, not the payload.

**What was wrong.** The six NIM model ids in `AIProviderModelCatalog` were written from memory rather than read off `/v1/models`. Probed against the live gateway, five were dead — three end-of-life (HTTP 410), two nonexistent (HTTP 404) — including the catalog head, which is what `preferredModel` hands back when a credential has no explicit model preference. Every default-model request therefore hit a dead id.

**Why it was hard to see.** `perform` collapsed every non-2xx into `.unexpected(status)` and dropped the response body, so the gateway's own explanation ("has reached its end of life on 2026-08-26") never reached the UI — the toast said only "Provider returned HTTP 400".

**How the payload was cleared.** The gateway validates the model id *before* auth, so an invalid key still distinguishes a bad request (400/404/410) from a good one (403). Replaying the app's exact body with a throwaway key returns 403, with and without `nvext`, with `temperature: 0`, and with a system role — so none of those fields is rejected at validation.

**Changes:**

- `providerErrorDetail(from:)` extracts `detail` / `message` / `title` / `error.message` from the body and `.unexpected` carries it, so the next provider rejection explains itself. `errorDescription` degrades to the bare status when there is no body.
- Catalog replaced with six ids verified live against the gateway, defaulting to `nvidia/nemotron-3.5-lightning-30b-a3b` — the one model confirmed working end-to-end with a real key. Seeded rates follow the same list.
- `nvext.guided_json` dropped. It survives pre-auth validation, but whether guided decoding is accepted *at inference* for a given hosted model could not be verified without a key, and the prompt already restates the schema with `extractJSONObject` downstream — the same arrangement the Anthropic arm relies on. Removing it takes an unverifiable dependency out of the request.
- `reasoning_content` is now read when `content` comes back empty. The default is a reasoning model, and it can answer entirely inside the reasoning channel.

**Still unverified:** no request has been authenticated end-to-end. Structured-output quality per model, and whether guided decoding is worth reinstating behind a retry, both need a real key.

## Post-ship fix 2: verified models never reached model selection

The real reason a dead catalog id could ever be sent.

**What was already working.** Pressing Verify calls `fetchModels` with that key, the live list drives the add-form Model dropdown, and on save it is persisted to the credential's `metadataJSON.availableModels`. Existing credential rows read their dropdown from that stored list.

**What was broken.** Both `chooseCredential` paths resolved the model as `credential.modelPreference ?? preferredModel(provider, settings)`, and `preferredModel` consulted only `settings.preferredModels` and then the compiled-in `AIProviderModelCatalog`. The credential's own verified list was never consulted. So a user who verified successfully and left Model on "Default" still sent a hardcoded id — the actual path to the end-of-life 400.

Two smaller holes in the same flow:

- Save was enabled on a non-empty key field with `keyVerification == .idle`, so skipping Verify stored no model list at all.
- `AppState.aiModelCatalog` is populated from `AIWorkflowService.modelCatalog()`, which returns the static dict — the app-wide catalog is never live.

**Changes:**

- `resolvedModel(for:settings:)` replaces the provider-only lookup at both call sites, resolving in order: the credential's own model → the provider-wide setting → the list verified against the live API → the compiled-in catalog. `preferredModel` became `catalogFallbackModel`, since the settings check now happens one level up.
- `AppState.addAICredential` fetches the model list itself when saving a credential that was never verified. A failure there is swallowed — the key still saves, matching the previous tolerance for unverified keys.
- Two tests pin the order: a "Default" credential uses its verified list rather than the catalog head, and an explicit `modelPreference` still wins over both.

**Still not addressed:** the stored list is captured once at add time and never refreshed, so it rots as models reach end of life. A re-verify affordance on an existing credential row, or a refresh on a 404/410 response, would close that.

## Follow-up: searchable dropdown

The NIM catalog returns 60+ chat models after filtering, which is not scrollable in any useful sense.

`SerenityDropdownField` gained an opt-in `searchable` flag (default `false`, so no other dropdown in the app changes). When set and the option count exceeds 8, the menu grows a filter field that matches title and subtitle case-insensitively, focuses on open, clears on close, offers a clear button, and shows "No matches" when a query excludes everything. Enabled on both model dropdowns — the add form and the per-credential row. The Cost Center's model input is a free-text field, not a dropdown, so it was left alone.

## Post-ship fix 3: "response was invalid: The data couldn't be read because it is missing"

`RawQuickCaptureClassification` required `kind`, `confidence` and `tasks`. The schema marks all five
top-level keys required, but only OpenAI's strict `json_schema` mode enforces that — with
`nvext.guided_json` dropped, nothing holds a NIM model to it, and a journal-mode reply legitimately
omits `tasks`.

Three layers were wrong at once:

- **The decodable was stricter than the responses it would really see.** `tasks` and `confidence` are
  now optional: `tasks` defaults to empty (`.tasks` mode still fails with its own clear message when
  no valid task survives), and an absent `confidence` defaults to 0.5, which routes to the preview
  rather than saving unreviewed. `kind` stays required — inferring it would be inventing intent.
- **The error named nothing.** `DecodingError.localizedDescription` is the useless "The data couldn't
  be read because it is missing." `describeDecodingFailure` now unwraps the real case into
  "missing required field 'tasks' in the root object", naming the field and the coding path.
- **The repair retry was feeding that useless string back to the model.** `quickCaptureRepairPrompt`
  received `error.localizedDescription`, so the retry was asked to fix an unspecified problem and
  had no better chance than the first attempt. It now gets the precise reason.

A decode failure also logs the reason, the payload's top-level keys and its byte count through
`AppLogger`; the truncated raw payload is logged only in DEBUG, to keep user-entered text out of the
release-build system log.

## Where the logs are

`AppLogger` writes to OSLog under subsystem `com.digitaltracer.serenity`, category `app`. The
`print` fallback is `#if DEBUG` only and goes to stdout, which is invisible when the app is launched
via `open` — hence "I don't know where to see the logs".

Live tail:

```
/usr/bin/log stream --predicate 'subsystem == "com.digitaltracer.serenity"' --level debug
```

After the fact:

```
/usr/bin/log show --predicate 'subsystem == "com.digitaltracer.serenity"' --last 30m --info --debug --style compact
```

Use the **absolute path** — `log` is shadowed in this shell and the bare command fails with "too many
arguments" or silently returns nothing. In Console.app, search `subsystem:com.digitaltracer.serenity`
and enable Action → Include Info/Debug Messages.

## Post-ship fix 4: "malformed JSON at the root object"

Log evidence (2026-09-03 14:23:47 and 14:24:19, two attempts — the second is the repair retry):

```
AI quick capture decode failed: malformed JSON at the root object: The given data was not valid
JSON.. Payload keys: unparseable, 3819 bytes
```

~3.8KB of text with no parseable object anywhere in it. Not a shape mismatch — the reply was never
JSON at all.

**Cause: the default model is a reasoning model, and it was being cut off mid-thought.** `max_tokens`
was 1_200, copied from the Anthropic arm. A reasoning model spends that budget deliberating before it
answers, so `content` came back empty and `reasoning_content` held ~3.8KB of thinking prose. The
`reasoning_content` fallback added in fix 2 then handed that prose to the JSON decoder as if it were
the answer — which is how a token-budget problem surfaced as a JSON syntax error.

**Changes:**

- `chat_template_kwargs: {"enable_thinking": false}` — this task wants the answer, not the
  deliberation. Validated against the endpoint (403, not 400, so the field is accepted).
- `max_tokens` raised to 4_096, so a model that does reason still has room to finish.
- The blanket `reasoning_content` fallback is gone. Reasoning text is now only mined for an object
  when it actually contains braces; otherwise the client throws
  `AIProviderAPIError.incompleteResponse` naming the reasoning length, whether `finish_reason` was
  `length`, and suggesting a non-reasoning model.
- `finish_reason` is decoded so truncation reports itself as truncation.

**Diagnostics gap this exposed:** the raw-payload log line was `#if DEBUG`, and the Xcode project
defines no `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, so `DEBUG` is never set — the one line that would
have identified this immediately never ran. The first 200 characters of a failed payload are now
logged unconditionally; the 2_000-character dump stays DEBUG-only.

## Post-ship fix 5: "by tonight" landed on tomorrow

Reported for the input *"Work with Nirdosh on hubspot and marketo cookie displaying in dashboard and
finish it by tonight"*. Evidence straight from the app database:

```
created_at  2026-09-03T09:29:02Z   (14:59 IST)
due_date    2026-09-03T23:59:59.000Z
```

Machine timezone is Asia/Kolkata (UTC+5:30), so `23:59:59Z` renders as **2026-09-04 05:29 IST** —
tomorrow morning. The model was not wrong; it was misinformed.

**Cause.** `quickCaptureUserPrompt` built its timestamp with a bare `ISO8601DateFormatter()`, which
formats in UTC and states no timezone: `Current time: 2026-09-03T09:29:02Z`. Given only that frame,
end-of-day is 23:59:59Z. Every relative date ("tonight", "today", "tomorrow", "this evening") was
therefore resolved in UTC and then rendered in local time, shifting by the UTC offset — forward into
the next day east of Greenwich, backward west of it.

**Changes:**

- The prompt now sends local time with its offset and names the zone:
  `Current time: 2026-09-03T14:59:02+05:30 (timezone Asia/Kolkata)`.
- The system prompt instructs the model to resolve relative dates against that time and timezone,
  to echo the same UTC offset back in `dueDate`, and spells out that "tonight" / "today" / "by end
  of day" mean the end of the current local day.
- `parseQuickCaptureDueDate` needed no change — `ISO8601DateFormatter` with `.withInternetDateTime`
  already parses an explicit `+05:30` offset correctly.
- A test asserts the prompt names `TimeZone.current.identifier` and carries a real offset rather
  than a bare `Z`, skipping the offset assertion only when the machine genuinely runs on UTC.

**Not changed:** tasks already stored with a UTC-resolved due date keep it. The one above is off by
the offset and needs editing by hand.
