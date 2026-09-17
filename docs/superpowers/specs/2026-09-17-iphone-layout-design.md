# Serenity on iPhone

## Goal

Make the shared SwiftUI app usable on an iPhone without forking the Mac design. The iOS target already builds and runs; everything below is layout, chrome, and touch behavior.

Every change is gated on the compact horizontal size class, not on `os(iOS)`. macOS and regular-width iPad keep the split-view shell, the sidebar, the toolbar buttons, hover states, and the task inspector exactly as they are.

## Navigation shell

Compact width replaces `NavigationSplitView` with a `TabView`:

- Home, ActionHub (labelled "Hub"), Journal, Goals, More.
- More is a pushable list holding Insights, AI Summaries, Integrations, and Settings, plus Help Center and the theme toggle, which are Mac toolbar buttons today.
- Each tab owns its own `NavigationStack`, so a push inside one tab does not reset another.

`AppState.selectedSection` stays the single source of truth. The tab selection binds to it, so `setSection`, the global-search result mapping, Help Center destinations, and the stored last-section restore all keep working untouched. Selecting a section that has no tab makes More the active tab and pushes that section onto More's stack.

`AppSection.navigationOrder` is not reordered — it still drives ⌘1–⌘8 on the Mac.

The iOS-only `SerenityTopBar`, a 32pt strip carrying search, help, and theme, is removed at compact width. Search moves into each section header as a 44pt button; help and theme move into More.

## Section header

The page header keeps the icon tile and title, drops to the phone size tier, and gains a 44pt Search button, which is the only chrome the removed top bar has to re-home on the page itself.

ActionHub needs no New Task button in the header: its task list already opens with a full-width "Add a task" card that expands into the quick-add form in place.

## Density

`SerenityContentDensity.from(width:)` bottoms out at `.tight` below 980pt, so a 390pt phone renders at spacing tuned for a narrow Mac window. Add a `.phone` tier below 480pt:

- section spacing 14, content padding 16, page-header spacing 20
- section icon container 40, icon 19, title 24 semibold
- quick-capture editor height 92, editor padding 12, prompt padding 14

`SectionView.sectionContent` pads the trailing edge by `contentPadding + 14` to clear the custom hover scrollbar. There is no hover scrollbar on a phone, so at compact width the trailing padding equals the leading padding.

## Type scale

`SerenityScreenMetrics.screenDiagonalInches` returns a hardcoded `14.9` on iOS. That trips the `< 15` branch and multiplies every font by `smallScreenFontScale` (0.85), so the phone currently renders all type 15% small before Dynamic Type is applied. Return `nil` on iOS so `fontScale` is 1.0 and Dynamic Type is the only scaling in play.

## Touch targets

Raise to the 44pt minimum at compact width:

- quick-capture submit button: 28pt circle
- `TopBarButton`: 32pt square (Mac keeps 32)
- task completion toggle: icon-sized, inside a row that becomes 56pt tall
- `SerenityPrimaryButtonStyle`, `SerenitySecondaryButtonStyle`, `SerenityPillButtonStyle`: 7–8pt vertical padding yields roughly 30pt controls; add a 44pt minimum height

On a task row the whole row is the tap target for opening the editor, with a 44×44 checkbox carved out of the leading edge.

## Swipe actions

The ActionHub task list is a `LazyVStack(spacing: 0)` inside `SerenityThemedScrollView`, not a `List`, so `.swipeActions` is unavailable. Converting to `List` would cost `taskListShape` — the single-container look the current smoke test asserts — and the Mac styling with it.

Instead, add a row modifier compiled only for compact width that:

- tracks a horizontal `DragGesture` offset per row
- reveals Complete and Delete behind the trailing edge, 76pt each
- snaps open or closed with a rubber-band, and closes when the list scrolls or another row opens

Complete calls the existing `toggleTaskCompletion`. Delete has no confirmation anywhere today — the expanded row's Delete button calls `deleteTask` outright — so swipe-delete gets a confirmation dialog of its own rather than destroying a task on a mis-swipe.

## Task editor

`SectionView` already branches: regular width gets `.inspector`, compact gets `.navigationDestination`. Change the compact branch to a `.sheet` with `.medium` as the resting detent and `.large` available, so the list stays visible behind the editor and a drag dismisses it.

The regular branch keeps `.inspector(isPresented: editorIsPresented)` — `SectionViewSmokeTests.testTaskInspectorIsHostedOutsideActionHubScrollContent` asserts that string is still present in `SectionView`.

The unsaved-changes confirmation dialog stays on the shared path and must still fire on sheet dismissal.

## Sheets sized for a Mac window

These carry unconditional minimum widths larger than a 390pt screen:

- `GlobalSearchSheet` and `HelpCenterSheet`: `minWidth: 760, minHeight: 560`
- the journal entry editor host: `minWidth: 460, minHeight: 380`
- the project editor and AI provider editor hosts: `minWidth: 420, minHeight: 260`

Apply each minimum only on macOS. At compact width these present full-screen with a Cancel/Done bar.

`GlobalSearchSheet`'s `NSEvent` key monitor is already `#if os(macOS)`; arrow-key result navigation stays Mac-only and results are tapped on a phone.

## Quick capture

- The iOS `QuickCaptureEditor` is a plain `TextEditor`. Add a keyboard toolbar with Done so the keyboard can be dismissed, and scroll the focused card clear of the keyboard.
- Editor height comes from the phone density tier.
- The footer's provider dropdown and submit button fit on one row at 390pt; the existing `ViewThatFits` stacked fallback covers Dynamic Type growth.
- The ⌘-Return shortcut stays but is invisible on a phone; the 44pt submit button is the affordance.

## Pull to refresh

`SerenityThemedScrollView` wraps `ScrollView`, so `.refreshable` is available. Add it at compact width for Home, ActionHub, Journal, and Goals, calling the same refreshes `SectionView.onAppear` already makes (`refreshCoreWorkflowData`, and `refreshAIWorkflows` for the AI sections). Suppress the custom hover scrollbar overlay at compact width.

## Sections on the phone

All nine sections ship. Home, ActionHub, Journal, and Goals are tabs and fully functional. Insights, AI Summaries, Integrations, and Settings are pushed from More.

Reflows needed for the heavier panels:

- **Cost Center metric cards**: the existing `ViewThatFits` already falls back to a two-column `LazyVGrid`, which is what a phone gets. No change.
- **Cost Center charts**: bar and donut keep their 180pt height. At compact width the donut's legend moves beneath the chart and carries each slice's value, so identity never rests on color alone.
- **Cost Center rate editor and spend panels**: both already carry a `ViewThatFits` stacked fallback that a phone width selects, so the `minWidth: 300` model field never competes with its siblings. No change.
- **Backend configuration**: the Postgres fields already stack full width with Port and SSL mode sharing a row. The `maxWidth: 300` caps on the backend dropdowns become `maxWidth: .infinity` at compact width, and the Save/Clear pair gains the stacked fallback the cloud actions already had.
- **Database tab**: the statistics and quick-action columns are a fixed `HStack` with a 320pt side column, which cannot fit. At compact width they stack, the four stat cards become a two-column grid, and the quick actions fill the width.
- **Calendar grids**: the seven-column grids fit at 390pt (about 46pt per column). ActionHub's month cells are already 62pt tall; the date-range picker and the due-date popover size theirs at 30pt and are raised to 44pt at compact width.

## Found while building

Three problems the mockups could not show, all fixed here:

- **The app ran in compatibility scaling.** `Serenity/Support/iOS/Info.plist` declared no `UILaunchScreen`, so iOS rendered the whole app at a legacy size and scaled it up roughly 3x: clipped text, no layout at all. Declaring an empty `UILaunchScreen` is what makes the phone render at its native size.
- **The detail backdrop sized the screen.** `SerenityDetailBackground` draws 520 and 560pt blur circles, and as a `ZStack` sibling of the content it made the stack 560pt wide, so the page sat off-centre and overflowed both edges. On the phone it is a `.background` instead, which does not participate in sizing. The Mac keeps its `ZStack` — a window that wide never noticed.
- **ActionHub's search and filter row does not fit.** Side by side, the search field squeezes to a few characters and the filter pills wrap their labels onto two lines. At compact width the field takes its own row and the pills sit below it in a horizontal scroll view.

## Not in this pass

- No menu-bar equivalent. `MenuBarExtra` and `MenuBarCaptureView` stay macOS-only, and no widget, share extension, or Siri intent is added.
- No iPad-specific layout beyond keeping the existing split view.
- `NotificationScheduler` already runs on iOS and is unchanged.

## Verification

- `swift build && swift test` — the macOS suite is the regression net for the shared code and must stay green. The swift-testing runner reporting "0 tests" is normal; check the XCTest "Executed N tests" line.
- `xcodebuild -scheme SerenityIOS -destination 'generic/platform=iOS Simulator' build`.

New source-based checks in `SerenityTests/UI/PhoneLayoutTests.swift`, alongside the existing smoke tests: the compact shell uses `TabView` while the regular shell keeps `NavigationSplitView`; the tab selection derives from `selectedSection`; the editor is a sheet on compact and an inspector otherwise; phone widths get their own density tier; no desktop sheet minimum is applied unconditionally; and `SerenityScreenMetrics` no longer reports a diagonal on iOS.

Run on an iPhone 17 simulator and confirm:

- the tab bar switches sections with no push or pop
- a section opened from More pushes, and Back returns to More
- global search opens full-screen, and selecting a result lands on the right tab
- swipe reveals Complete and Delete on an ActionHub row, and scrolling closes an open row
- the task editor opens as a sheet, and the unsaved-changes dialog still fires on dismissal
- the keyboard does not cover the quick-capture card, and Done dismisses it
- pull to refresh works on Home
- Cost Center charts and the backend form lay out at 390pt with no horizontal clipping
- the largest Dynamic Type size clips neither the tab bar labels nor the task rows

Confirm on macOS that the sidebar, toolbar buttons, ⌘1–⌘8, hover states, and the task inspector are unchanged.
