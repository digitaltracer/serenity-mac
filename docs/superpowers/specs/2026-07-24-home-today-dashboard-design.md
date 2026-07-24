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

- Top-align the Home icon with the Home title instead of centering it against the entire three-line heading.
- Add a dedicated gap between the heading and Quick Capture without changing spacing between the remaining dashboard sections.
- Place Today's Progress and Today's Focus in one native grid row so both containers receive the same height from the row's tallest content.
- Keep the existing vertical fallback for narrow layouts.
