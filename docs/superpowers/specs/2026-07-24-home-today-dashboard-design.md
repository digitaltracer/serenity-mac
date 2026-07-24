# Home and Today Dashboard Merge

## Goal

Make Home the app's useful daily landing page by removing navigation cards that duplicate the sidebar and merging the complete Today overview into Home.

## Home layout

Home displays, in order:

1. A compact Home header with today's full date and the existing daily-focus subtitle.
2. The existing Quick Capture card and any pending AI capture preview.
3. Today's Progress and Today's Focus cards.
4. The complete Today's Tasks panel, including completion toggles, due times, and the empty-state action.

The current centered Serenity Notes hero and feature-link grid are removed.

## Today route removal

- Remove the `today` case from `AppSection`.
- Remove Today from the sidebar, section title and icon switches, section rendering, and refresh routing.
- Delete the standalone Today route and make Home the only daily-overview destination.
- Retarget Today-specific Help Center navigation and wording to Home.
- Keep `AppState.todayTasks`; the merged Home dashboard still uses it.
- No current global-search result type routes directly to Today, so no result mapping needs migration.

## View structure

- Keep `HomeSectionView` as the route-level view.
- Convert the current `TodaySectionView` into a route-free `TodayOverviewView`.
- Remove the overview's standalone Today header because Home provides the page header.
- Embed `TodayOverviewView` beneath Quick Capture.
- Reuse all existing Today calculations, cards, task rows, actions, styling, and empty states.

No new abstraction, dependency, persisted state, or data migration is required.

## Verification

- Update the navigation-order test to confirm Today is absent.
- Update source-based UI smoke-test boundaries affected by the renamed overview view.
- Add a focused source-based check that Home includes the overview and no longer includes the feature-link grid.
- Run the full Swift test suite and build the macOS app.
- Visually confirm Home at regular and narrow widths:
  - the layout order matches the design;
  - the progress cards collapse vertically when needed;
  - task completion and the empty-state action still work;
  - Today is absent from the sidebar, Help destinations, and all routes.

## Home visual polish

- Vertically center the Home icon against the complete heading text block.
- Reduce the supporting hierarchy: use body typography for “Focus on what matters most right now” and caption typography for the date.
- Add a dedicated gap between the heading and Quick Capture without changing spacing between the remaining dashboard sections.
- Keep the Quick Capture instruction, provider selector, and Submit button vertically centered in the horizontal footer. Use body typography for the instruction so the horizontal layout fits at the reported Mac width.
- Retain the existing stacked Quick Capture footer only for genuinely narrow layouts.
- Let Today's Progress and Today's Focus fill the tallest intrinsic card height in their horizontal row.
- Keep the existing vertical summary-card fallback for narrow layouts.
