# Home and Today Dashboard Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Home the only daily landing page by replacing its duplicate navigation cards with the complete Today overview and deleting the Today route.

**Architecture:** `HomeSectionView` remains the route-level owner of Quick Capture and gains a compact header. The existing Today UI becomes a focused, route-free `TodayOverviewView` embedded beneath Quick Capture; `AppSection.today` and every navigation target to it are removed.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, Swift Package Manager

## Global Constraints

- Preserve the existing Quick Capture behavior and pending AI preview.
- Preserve all Today calculations, task actions, responsive card layout, styling, and empty states.
- Remove the standalone Today route from the enum, sidebar, section switch, Help Center, and tests.
- Add no dependency, persisted state, data migration, or speculative abstraction.

---

### Task 1: Merge the daily overview into Home and remove the Today route

**Files:**
- Modify: `Serenity/Shared/App/AppSection.swift`
- Modify: `Serenity/Shared/App/SerenityAppScene.swift`
- Modify: `SerenityTests/AppSectionTests.swift`
- Modify: `SerenityTests/UI/SectionViewSmokeTests.swift`

**Interfaces:**
- Consumes: `AppState.todayTasks`, `AppState.toggleTaskCompletion(id:)`, `AppState.setSection(_:)`, `SerenityContentDensity`
- Produces: `HomeSectionView(density:)`, private `TodayOverviewView`, and an `AppSection` enum without `today`

- [x] **Step 1: Write the failing navigation and Home-composition tests**

Update the expected navigation order in `AppSectionTests`:

```swift
XCTAssertEqual(
  AppSection.allCases,
  [.home, .actionHub, .journal, .goals, .projects, .integrations, .insights, .aiSummaries, .costCenter, .database, .settings],
)
```

Add this focused source-composition check to `SectionViewSmokeTests`:

```swift
func testHomeOwnsDailyOverviewAndTodayHasNoRoute() throws {
  let source = try appSceneSource()
  let home = try XCTUnwrap(source.slice(from: "private struct HomeSectionView", to: "private struct ActionHubSectionView"))

  XCTAssertTrue(home.contains("TodayOverviewView()"))
  XCTAssertFalse(home.contains("featureGrid"))
  XCTAssertFalse(source.contains("case .today"))
  XCTAssertFalse(source.contains("section: .today"))
}
```

- [x] **Step 2: Run the focused tests and verify they fail for the missing merge**

Run:

```bash
swift test --filter 'AppSectionTests|SectionViewSmokeTests.testHomeOwnsDailyOverviewAndTodayHasNoRoute'
```

Expected: `AppSectionTests.testAllSectionsArePresentInNavigationOrder` fails because `.today` is still present, and `testHomeOwnsDailyOverviewAndTodayHasNoRoute` fails because Home does not yet contain `TodayOverviewView()`.

- [x] **Step 3: Remove the Today route**

Delete `case today` and its title/icon switch branches from `AppSection.swift`.

In `SerenityAppScene.swift`:

```swift
private let primarySections: [AppSection] = [.home, .actionHub, .journal, .goals, .insights, .aiSummaries]
```

Delete the Today subtitle branch, remove `.today` from the core-data refresh list, simplify the custom-header condition to `section != .home`, and delete the `.today` rendering branch.

Retarget the Help Center article:

```swift
HelpCenterArticle(
  title: "Plan your day",
  summary: "Review today's work from Home.",
  keywords: ["home", "today", "due", "overdue"],
  shortcut: nil,
  section: .home
)
```

- [x] **Step 4: Replace the Home hero and feature links with the merged dashboard**

Change the Home call site and initializer shape:

```swift
HomeSectionView(density: density)
```

Compose Home in this order:

```swift
var body: some View {
  VStack(alignment: .leading, spacing: density.sectionSpacing) {
    header
    quickCaptureCard
    if let preview = appState.pendingAIQuickCapturePreview {
      aiQuickCapturePreview(preview)
    }
    TodayOverviewView()
  }
}
```

Use a compact Home header:

```swift
private var header: some View {
  HStack(alignment: .center, spacing: 12) {
    Image(systemName: "house")
      .font(SerenityType.scaledSystem(size: 22, weight: .semibold))
      .foregroundStyle(SerenityPalette.accent)
      .accessibilityHidden(true)

    VStack(alignment: .leading, spacing: 2) {
      Text("Home")
        .font(SerenityType.pageTitle)
      Text("Focus on what matters most right now")
        .font(SerenityType.pageSubtitle)
        .foregroundStyle(SerenityPalette.textSecondary)
      Text(Self.dateFormatter.string(from: Date()))
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary.opacity(0.8))
    }

    Spacer()
  }
}
```

Add the existing full-date formatter to `HomeSectionView`, delete `availableWidth`, `hero`, `featureGrid`, `featureCard`, and their now-unused density metrics.

Rename `TodaySectionView` to `TodayOverviewView` and remove its header so its body contains only the responsive Progress/Focus cards and Today's Tasks.

Update the ActionHub source-test boundaries from `TodaySectionView` to `TodayOverviewView`.

- [x] **Step 5: Run focused tests and verify the merge passes**

Run:

```bash
swift test --filter 'AppSectionTests|SectionViewSmokeTests'
```

Expected: all selected tests pass with zero failures.

- [x] **Step 6: Run full verification**

Run:

```bash
swift test
swift build
rg -n '\.today\b|case today\b|TodaySectionView|featureGrid|featureCard' Serenity SerenityTests README.md
```

Expected: the full test suite and macOS build exit successfully. The source search returns no removed route/view/link symbols; uses of `todayTasks` and user-facing “Today” dashboard labels remain valid.

- [x] **Step 7: Commit the implementation**

```bash
git add docs/superpowers/plans/2026-07-24-home-today-dashboard.md Serenity/Shared/App/AppSection.swift Serenity/Shared/App/SerenityAppScene.swift SerenityTests/AppSectionTests.swift SerenityTests/UI/SectionViewSmokeTests.swift
git commit -m "feat(home): merge Today dashboard into Home"
```

### Task 2: Polish Home dashboard alignment

**Files:**
- Modify: `Serenity/Shared/App/SerenityAppScene.swift`
- Test: `SerenityTests/UI/SectionViewSmokeTests.swift`

**Interfaces:**
- Consumes: `HomeSectionView.header`, `SerenityContentDensity.sectionSpacing`, `TodayOverviewView.progressCard`, `TodayOverviewView.focusCard`
- Produces: a top-aligned Home heading, a dedicated responsive heading gap, and an equal-height summary-card row

- [x] **Step 1: Write the failing layout regression check**

Add this test to `SectionViewSmokeTests`:

```swift
func testHomeDashboardUsesPolishedLayout() throws {
  let source = try appSceneSource()
  let home = try XCTUnwrap(source.slice(from: "private struct HomeSectionView", to: "private struct ActionHubSectionView"))
  let overview = try XCTUnwrap(source.slice(from: "private struct TodayOverviewView", to: "private struct SerenityDateRangePicker"))
  let progressCard = try XCTUnwrap(String(overview).slice(from: "private var progressCard", to: "private var focusCard"))
  let focusCard = try XCTUnwrap(String(overview).slice(from: "private var focusCard", to: "private func focusRow"))

  XCTAssertTrue(home.contains("header\\n        .padding(.bottom, density.sectionSpacing)"))
  XCTAssertTrue(home.contains("HStack(alignment: .top, spacing: 12)"))
  XCTAssertTrue(overview.contains("HStack(alignment: .top, spacing: 16)"))
  XCTAssertTrue(overview.contains(".fixedSize(horizontal: false, vertical: true)"))
  XCTAssertFalse(overview.contains("GridRow"))
  XCTAssertTrue(progressCard.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"))
  XCTAssertTrue(focusCard.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"))
}
```

- [x] **Step 2: Run the focused test and verify it fails**

Run:

```bash
swift test --filter SectionViewSmokeTests.testHomeDashboardUsesPolishedLayout
```

Expected: the assertions fail because the header is center-aligned, has no dedicated bottom padding, and the summary cards do not use the cross-platform equal-height stack structure.

- [x] **Step 3: Implement the minimal native SwiftUI layout fix**

In `HomeSectionView`, add responsive space beneath the heading and top-align the icon/title row:

```swift
header
  .padding(.bottom, density.sectionSpacing)

HStack(alignment: .top, spacing: 12) {
  // existing header content
}
```

In the horizontal `ViewThatFits` candidate, use an `HStack` that resolves its ideal height before both cards fill that height:

```swift
HStack(alignment: .top, spacing: 16) {
  progressCard
  focusCard
}
.fixedSize(horizontal: false, vertical: true)
```

Inside both card definitions, apply the fill frame before padding, background, and border:

```swift
.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
```

Keep the existing vertical `VStack` fallback unchanged.

- [x] **Step 4: Run focused and full verification**

Run:

```bash
swift test --filter SectionViewSmokeTests
swift test
swift build
```

Expected: all commands pass with zero test failures or compiler errors.

- [x] **Step 5: Build, launch, and visually inspect the Home dashboard**

Use the `SerenityIOS` simulator target and the macOS app to confirm:

- the icon aligns with the Home title;
- the heading has a clear gap before Quick Capture;
- both summary cards have identical height in the horizontal layout; and
- the existing vertical fallback remains usable.

- [x] **Step 6: Commit the layout fix**

```bash
git add docs/superpowers/plans/2026-07-24-home-today-dashboard.md Serenity/Shared/App/SerenityAppScene.swift SerenityTests/UI/SectionViewSmokeTests.swift
git commit -m "fix(home): align dashboard layout"
```

### Task 3: Align the Home header and Quick Capture footer

**Files:**
- Modify: `Serenity/Shared/App/SerenityAppScene.swift`
- Test: `SerenityTests/UI/SectionViewSmokeTests.swift`

**Interfaces:**
- Consumes: `HomeSectionView.header`, `HomeSectionView.quickCaptureCard`, `SerenityType.body`, `SerenityType.caption`
- Produces: a vertically centered Home header and a compact horizontal Quick Capture footer at the reported Mac width

- [x] **Step 1: Update the layout regression check**

Slice the Home header and Quick Capture card inside `testHomeDashboardUsesPolishedLayout`, then assert the approved typography and alignment:

```swift
let header = try XCTUnwrap(String(home).slice(from: "private var header", to: "private var quickCaptureCard"))
let quickCaptureCard = try XCTUnwrap(String(home).slice(from: "private var quickCaptureCard", to: "private var quickCaptureProviderDropdown"))

XCTAssertTrue(header.contains("HStack(alignment: .center, spacing: 12)"))
XCTAssertTrue(header.contains("Text(\"Focus on what matters most right now\")\n          .font(SerenityType.body)"))
XCTAssertTrue(header.contains("Text(Self.dateFormatter.string(from: Date()))\n          .font(SerenityType.caption)"))
XCTAssertTrue(quickCaptureCard.contains("HStack(alignment: .center, spacing: 12)"))
XCTAssertTrue(quickCaptureCard.contains("Text(quickCaptureHelperText)\n            .font(SerenityType.body)"))
```

- [x] **Step 2: Run the focused test and verify it fails**

Run:

```bash
swift test --filter SectionViewSmokeTests.testHomeDashboardUsesPolishedLayout
```

Expected: the test fails because the header is top-aligned, the supporting text uses larger typography, and the horizontal Quick Capture instruction uses `bodyLarge`.

- [x] **Step 3: Implement the minimal SwiftUI adjustment**

Center the header and reduce its supporting typography:

```swift
HStack(alignment: .center, spacing: 12) {
  // existing icon and text
}

Text("Focus on what matters most right now")
  .font(SerenityType.body)

Text(Self.dateFormatter.string(from: Date()))
  .font(SerenityType.caption)
```

Make the preferred Quick Capture footer explicit and compact enough for the reported Mac width:

```swift
HStack(alignment: .center, spacing: 12) {
  Text(quickCaptureHelperText)
    .font(SerenityType.body)
  // existing spacer, provider dropdown, and submit button
}
```

Keep the existing stacked fallback for genuinely narrow layouts.

- [x] **Step 4: Run focused and full verification**

Run:

```bash
swift test --filter SectionViewSmokeTests.testHomeDashboardUsesPolishedLayout
swift test
swift build
```

Expected: the focused test, all 97 tests, and the macOS build pass.

- [x] **Step 5: Commit the implementation**

```bash
git add docs/superpowers/plans/2026-07-24-home-today-dashboard.md Serenity/Shared/App/SerenityAppScene.swift SerenityTests/UI/SectionViewSmokeTests.swift
git commit -m "fix(home): refine header and capture alignment"
```
