# ActionHub Professional Task Rows

## Goal

Make dark mode calmer and make the ActionHub task list easier to scan without removing access to task details or actions.

## Dark-mode typography

- Reduce the opacity of the shared dark `textPrimary` color to 86%.
- Keep light mode, secondary text, semantic status colors, and filled-button foregrounds unchanged.
- Preserve at least 4.5:1 contrast against the dark window and panel backgrounds.

## Collapsed task row

Each task is compact by default and shows:

- selection and completion controls;
- a 16-point medium-weight title;
- one secondary metadata line containing only available due date, project, and subtask progress;
- the priority badge; and
- a native disclosure chevron.

Created date, description, tags, subtask controls, and edit/delete actions are hidden while collapsed. A completed title uses secondary text and strikethrough styling.

## Expanded task row

- The disclosure chevron toggles inline details.
- Only one task can be expanded at a time.
- Expanded content reuses the existing description preview, tags, subtask checklist and entry field, and edit/delete actions.
- Missing or empty detail sections are omitted.
- Clicking the task title continues to open the existing task editor.
- Selection and completion controls retain their current behavior.

Expansion is transient view state. It does not modify persisted task data.

## Implementation scope

- Update the existing task-row composition in `SerenityAppScene.swift`.
- Update the existing shared dark primary-text token in `SerenityDesignSystem.swift`.
- Reuse the existing editor, row helpers, palette, and subtask state.
- Add no new component, dependency, persistence key, or data migration.

## Verification

- Extend the palette test to verify dark primary-text contrast remains at least 4.5:1.
- Run the focused palette test and full Swift test suite.
- Build and launch the macOS and iOS targets.
- Visually verify light and dark modes:
  - light mode is unchanged;
  - collapsed rows are compact and readable;
  - only one row expands at a time;
  - title, chevron, selection, completion, subtask, edit, and delete interactions remain distinct;
  - primary text is calmer while semantic colors remain clear.
