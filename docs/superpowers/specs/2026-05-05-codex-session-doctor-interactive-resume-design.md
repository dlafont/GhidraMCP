# Codex Session Doctor Interactive Resume Design

## Goal

Make the default no-parameter script flow useful on its own: inspect recent
Codex sessions, let the user choose one with the keyboard, confirm the choice,
then run `codex resume <session-id>` from the current shell context.

## User Flow

When the script runs without `-Json` or `-List`, it shows a fixed-height session
picker. The visible window contains a header, a small help line, and a bounded
set of session rows. Up and down arrows move the highlighted row. When there
are more sessions than visible rows, the selected row stays inside the window
and the list scrolls.

Pressing `Enter` prompts:

```text
Restore selected session? (Y/n/exit):
```

`Y`, `yes`, or a blank response resumes the selected session. `n` or `no`
returns to the picker. `exit` exits the script. `Esc` or `q` exits from the
picker.

## Script Behavior

The existing SQLite and transcript inspection stays read-only. `-Limit`,
`-IncludeArchived`, and `-CodexHome` still control which sessions are loaded.
`-Json` remains non-interactive and returns machine-readable output. A new
`-List` switch keeps the current table output for users who want a plain report
without launching the picker.

The picker should only allow `ok` sessions to be resumed. Other statuses stay
visible, but selecting them shows their notes and returns to the picker instead
of trying to resume a missing or incomplete rollout.

## Implementation Notes

Use PowerShell console APIs rather than a module dependency. The picker can use
`[Console]::ReadKey($true)` for arrow keys and `[Console]::SetCursorPosition()`
plus bounded redraws for the fixed text block. If the host is non-interactive,
or if console cursor APIs fail, the script should fall back to the table output
and print the direct `codex resume <session-id>` command.

Session rendering should keep stable column widths so the list does not jump as
the user moves. Titles can be truncated to fit the current console width.

## Testing

Keep the existing fake Codex home and SQLite database test. Add coverage for:

- `-List` preserving the current report output.
- default mode entering the picker path when sessions exist.
- confirmation parsing for yes, no, blank, and exit.
- selecting a non-`ok` session not launching `codex`.
- the resume launcher using `codex resume <selected-id>`.

The full arrow-key loop is partly manual by nature, so isolate the selection and
confirmation logic into testable helper functions where possible.
