# Codex Session Doctor

This helper checks the local Codex session index and transcript files when a
VS Code Codex chat looks missing or stale.

By default it is read-only. If you pass `-RepairIndex`, it rebuilds
`session_index.jsonl` from `state_5.sqlite` and writes a timestamped backup of
the previous index first.

## Run It

From the repo root:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-session-doctor.ps1
```

By default, the script opens an interactive picker. Use the up/down arrow keys
to choose a session, press Enter, then confirm with `Y`, `n`, or `exit`.
Pressing Enter at the confirmation prompt also means yes.

To inspect more sessions:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-session-doctor.ps1 -Limit 25
```

To include archived sessions:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-session-doctor.ps1 -IncludeArchived
```

To print the old read-only report without the picker:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-session-doctor.ps1 -List
```

To get machine-readable output:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-session-doctor.ps1 -Json
```

To rebuild a stale session index from the database:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-session-doctor.ps1 -RepairIndex -List
```

## Interactive Resume

The picker shows a fixed-size window of recent sessions. It keeps the selected
row inside the visible block while you move. Sessions with status `ok` can be
resumed. Other statuses stay visible for troubleshooting, but selecting one
will show its note instead of launching `codex`.

When you confirm a selected `ok` session with `Y` or a blank response, the
script runs:

```powershell
codex resume 019df19c-3c59-7043-8c86-a38c50683256
```

If the terminal cannot support arrow-key navigation, the script falls back to
the plain report and prints the direct resume command.

## What To Look For

In report mode, the script prints a recommended command like:

```powershell
codex resume 019df19c-3c59-7043-8c86-a38c50683256
```

Run that command from the workspace where you want Codex to resume.

The `Status` column means:

- `ok`: the database entry points to a non-empty rollout file with session
  metadata.
- `empty`: the rollout file exists but is empty. This can happen briefly while
  a session is still live or before the transcript flushes.
- `missing`: the database entry points to a rollout file that is not present.
- `no_session_meta`: the file has content, but the first lines do not look like
  a normal Codex transcript.

The report also prints a `Session index drift` block. That compares the active
thread rows in `state_5.sqlite` with `session_index.jsonl`.

- `Missing from index`: sessions that exist in the database but are absent from
  the lightweight index. These are the strongest signal that the VS Code
  sidebar may stall or omit recent threads.
- `Orphan index entries`: index rows that no longer map to any database thread.
- `Latest DB update UTC` vs `Latest index UTC`: a quick way to see whether the
  index stopped advancing while the database kept moving.

If drift is present, the script prints a repair command that rebuilds
`session_index.jsonl` from the database and stores the previous file as:

```text
session_index.jsonl.bak-YYYYMMDDTHHMMSSfff
```

## Requirements

The script uses Python's built-in `sqlite3` module to read the Codex database.
It looks for `python` first, then `py -3`.

## Why This Exists

Codex stores local session state in a few places:

- `C:\Users\<you>\.codex\state_5.sqlite`
- `C:\Users\<you>\.codex\session_index.jsonl`
- `C:\Users\<you>\.codex\sessions\...\rollout-*.jsonl`

Sometimes the VS Code sidebar or lightweight index can lag behind the actual
transcript. This script checks the primary database and verifies the transcript
files directly, then gives the exact `codex resume` command. When the index is
the stale piece, `-RepairIndex` lets you rewrite that cache from the database
without touching `state_5.sqlite` or any rollout transcript.
