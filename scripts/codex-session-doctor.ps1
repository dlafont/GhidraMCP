<#
.SYNOPSIS
Inspects local Codex session metadata and helps resume a valid session.

.DESCRIPTION
The VS Code sidebar can occasionally lose track of a usable Codex session.
This script reads the local Codex sqlite/index files, checks recent rollout
files, and either prints the exact resume command or opens a small picker.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [string]$Command,
    [Parameter(Position = 1)]
    [string]$SessionId,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [int]$Limit = 12,
    [switch]$IncludeArchived,
    [switch]$List,
    [switch]$Json,
    [switch]$RepairIndex,
    [switch]$SourceOnly,
    [string]$CodexExecutable = 'codex'
)

$ErrorActionPreference = 'Stop'

# Keep usage mistakes readable instead of exposing raw parameter-binding errors.
function Exit-UsageError {
    param(
        [string]$Message
    )

    [Console]::Error.WriteLine($Message)
    exit 64
}

# The session database is SQLite, so use whichever Python launcher is available.
function Get-PythonRunner {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return [pscustomobject]@{
            FilePath = $python.Source
            Arguments = @('-')
        }
    }

    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        return [pscustomobject]@{
            FilePath = $py.Source
            Arguments = @('-3', '-')
        }
    }

    throw 'Python was not found. Install Python or add it to PATH so sqlite3 can be read.'
}

# Convert the confirmation prompt into a tiny action vocabulary for the picker.
function ConvertTo-ConfirmationAction {
    param(
        [AllowNull()]
        [string]$Response
    )

    $normalized = ([string]$Response).Trim().ToLowerInvariant()
    switch ($normalized) {
        '' { return 'yes' }
        'y' { return 'yes' }
        'yes' { return 'yes' }
        'n' { return 'no' }
        'no' { return 'no' }
        'exit' { return 'exit' }
        default { return 'invalid' }
    }
}

# Only healthy rollout files should be passed through to `codex resume`.
function Test-SessionCanResume {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Session
    )

    return $Session.status -eq 'ok'
}

# Launch the real Codex CLI and return its exit code to this script's caller.
function Invoke-CodexResume {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionId,
        [string]$CodexExecutable = 'codex'
    )

    & $CodexExecutable resume $SessionId
    if ($null -ne $LASTEXITCODE) {
        return [int]$LASTEXITCODE
    }

    return 0
}

# Run the embedded Python report with either the display limit or an internal override.
function Get-SessionDoctorRawJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexHome,
        [Parameter(Mandatory = $true)]
        [string]$PythonCode,
        [int]$Limit,
        [switch]$IncludeArchived
    )

    $env:CODEX_SESSION_DOCTOR_HOME = $CodexHome
    $env:CODEX_SESSION_DOCTOR_LIMIT = [string]$Limit
    $env:CODEX_SESSION_DOCTOR_INCLUDE_ARCHIVED = if ($IncludeArchived) { '1' } else { '0' }

    $runner = Get-PythonRunner
    $rawJson = $PythonCode | & $runner.FilePath @($runner.Arguments)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $rawJson
        exit $exitCode
    }

    return [string]$rawJson
}

# Read the report as a PowerShell object after the Python side validates sqlite access.
function Get-SessionDoctorReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexHome,
        [Parameter(Mandatory = $true)]
        [string]$PythonCode,
        [int]$Limit,
        [switch]$IncludeArchived
    )

    $rawJson = Get-SessionDoctorRawJson -CodexHome $CodexHome -PythonCode $PythonCode -Limit $Limit -IncludeArchived:$IncludeArchived
    return ($rawJson | ConvertFrom-Json)
}

# Rebuild session_index.jsonl from the sqlite thread table, preserving a timestamped backup.
function Repair-SessionIndexFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexHome,
        [Parameter(Mandatory = $true)]
        [array]$Sessions
    )

    $indexPath = Join-Path $CodexHome 'session_index.jsonl'
    $timestamp = Get-Date -Format 'yyyyMMddTHHmmssfff'
    $tempPath = Join-Path $CodexHome ("session_index.jsonl.tmp-{0}" -f $timestamp)
    $backupPath = $null

    $lines = foreach ($session in $Sessions) {
        @{
            id = [string]$session.id
            thread_name = [string]$session.title
            updated_at = [string]$session.updatedAtUtc
        } | ConvertTo-Json -Compress
    }

    if (Test-Path -LiteralPath $indexPath) {
        $backupPath = Join-Path $CodexHome ("session_index.jsonl.bak-{0}" -f $timestamp)
        Copy-Item -LiteralPath $indexPath -Destination $backupPath -Force
    }

    if ($lines.Count -gt 0) {
        Set-Content -LiteralPath $tempPath -Encoding UTF8 -Value $lines
    }
    else {
        Set-Content -LiteralPath $tempPath -Encoding UTF8 -Value @()
    }

    Move-Item -LiteralPath $tempPath -Destination $indexPath -Force

    return [pscustomobject]@{
        applied = $true
        indexPath = $indexPath
        backupPath = $backupPath
        writtenEntryCount = $lines.Count
    }
}

# Keep the selected row visible while the picker scrolls through sessions.
function Get-SessionPickerStartIndex {
    param(
        [int]$SessionCount,
        [int]$SelectedIndex,
        [int]$VisibleRows
    )

    if ($SessionCount -le 0 -or $VisibleRows -le 0) {
        return 0
    }

    $maxStart = [Math]::Max(0, $SessionCount - $VisibleRows)
    $start = $SelectedIndex - $VisibleRows + 1
    if ($start -lt 0) {
        return 0
    }
    if ($start -gt $maxStart) {
        return $maxStart
    }

    return $start
}

# Trim long values so table rows stay inside the current console width.
function Limit-DisplayText {
    param(
        [AllowNull()]
        [string]$Text,
        [int]$MaxLength
    )

    $value = [string]$Text
    if ($MaxLength -lt 1) {
        return ''
    }
    if ($value.Length -le $MaxLength) {
        return $value
    }
    if ($MaxLength -le 3) {
        return $value.Substring(0, $MaxLength)
    }

    return $value.Substring(0, $MaxLength - 3) + '...'
}

# Display timestamps consistently without leaking the full ISO string into tables.
function Format-SessionUpdated {
    param(
        [AllowNull()]
        [object]$UpdatedAtUtc
    )

    if ($UpdatedAtUtc -is [datetime]) {
        $updated = $UpdatedAtUtc.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    }
    else {
        $updated = [string]$UpdatedAtUtc
        $updated = $updated.Replace('T', ' ').Replace('Z', '')
    }

    return (Limit-DisplayText -Text $updated -MaxLength 19)
}

# Build one fixed-width row for the interactive session picker.
function Format-SessionPickerRow {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Session,
        [int]$Index,
        [int]$Width,
        [switch]$Selected
    )

    $marker = if ($Selected) { '>' } else { ' ' }
    $updated = Format-SessionUpdated -UpdatedAtUtc $Session.updatedAtUtc
    $titleWidth = [Math]::Max(12, $Width - 77)
    $title = Limit-DisplayText -Text $Session.title -MaxLength $titleWidth
    $line = '{0} {1,2}. {2,-12} {3,-19} {4,-36} {5}' -f $marker, ($Index + 1), $Session.status, $updated, $Session.id, $title
    return (Limit-DisplayText -Text $line -MaxLength $Width)
}

# Rewrite a console line in-place and clear any text left from a longer line.
function Write-FixedConsoleLine {
    param(
        [AllowNull()]
        [string]$Text,
        [int]$Width
    )

    $line = Limit-DisplayText -Text $Text -MaxLength $Width
    [Console]::Write($line.PadRight($Width))
}

# Redirected terminals cannot support arrow-key selection, so fall back to text.
function Test-CanUseInteractivePicker {
    try {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
            return $false
        }

        $null = [Console]::WindowWidth
        $null = [Console]::CursorTop
        return $true
    }
    catch {
        return $false
    }
}

# Draw the visible picker window without changing selection state.
function Show-SessionPickerBlock {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Sessions,
        [int]$SelectedIndex,
        [int]$Top,
        [int]$VisibleRows,
        [int]$Width,
        [AllowNull()]
        [string]$Message
    )

    $startIndex = Get-SessionPickerStartIndex -SessionCount $Sessions.Count -SelectedIndex $SelectedIndex -VisibleRows $VisibleRows
    [Console]::SetCursorPosition(0, $Top)

    $lines = @(
        'Codex Session Doctor - Select a session',
        'Up/Down move | Enter restore | q/Esc exit',
        '',
        ('  {0,2}  {1,-12} {2,-19} {3,-36} {4}' -f '#', 'Status', 'Updated UTC', 'Session Id', 'Title')
    )

    foreach ($line in $lines) {
        Write-FixedConsoleLine -Text $line -Width $Width
        [Console]::WriteLine()
    }

    for ($offset = 0; $offset -lt $VisibleRows; $offset++) {
        $sessionIndex = $startIndex + $offset
        if ($sessionIndex -lt $Sessions.Count) {
            $line = Format-SessionPickerRow -Session $Sessions[$sessionIndex] -Index $sessionIndex -Width $Width -Selected:($sessionIndex -eq $SelectedIndex)
        }
        else {
            $line = ''
        }

        Write-FixedConsoleLine -Text $line -Width $Width
        [Console]::WriteLine()
    }

    $endIndex = [Math]::Min($Sessions.Count, $startIndex + $VisibleRows)
    Write-FixedConsoleLine -Text '' -Width $Width
    [Console]::WriteLine()
    Write-FixedConsoleLine -Text ("Showing {0}-{1} of {2}" -f ($startIndex + 1), $endIndex, $Sessions.Count) -Width $Width
    [Console]::WriteLine()
    Write-FixedConsoleLine -Text $Message -Width $Width
}

# Let the user choose a resumable session and confirm before launching Codex.
function Show-InteractiveSessionPicker {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Report,
        [string]$CodexExecutable = 'codex',
        [int]$PreferredVisibleRows = 10
    )

    $sessions = @($Report.sessions)
    if ($sessions.Count -eq 0) {
        Show-SessionReport -Report $Report
        return 0
    }

    [Console]::Clear()
    $width = [Math]::Max(80, [Console]::WindowWidth - 1)
    $availableRows = [Math]::Max(4, [Console]::WindowHeight - 8)
    $visibleRows = [Math]::Min($PreferredVisibleRows, [Math]::Min($sessions.Count, $availableRows))
    $top = 0
    $selectedIndex = 0
    $message = ''

    while ($true) {
        Show-SessionPickerBlock -Sessions $sessions -SelectedIndex $selectedIndex -Top $top -VisibleRows $visibleRows -Width $width -Message $message
        $message = ''
        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            'UpArrow' {
                if ($selectedIndex -gt 0) {
                    $selectedIndex--
                }
            }
            'DownArrow' {
                if ($selectedIndex -lt ($sessions.Count - 1)) {
                    $selectedIndex++
                }
            }
            'Escape' {
                return 0
            }
            'Enter' {
                $session = $sessions[$selectedIndex]
                if (-not (Test-SessionCanResume -Session $session)) {
                    $notes = @($session.notes)
                    $note = if ($notes.Count -gt 0) { [string]$notes[0] } else { 'Selected session is not resumable.' }
                    $message = "Cannot resume status '$($session.status)'. $note Press any key."
                    Show-SessionPickerBlock -Sessions $sessions -SelectedIndex $selectedIndex -Top $top -VisibleRows $visibleRows -Width $width -Message $message
                    $null = [Console]::ReadKey($true)
                    $message = ''
                    continue
                }

                while ($true) {
                    $prompt = "Restore session $($session.id)? (Y/n/exit): "
                    Show-SessionPickerBlock -Sessions $sessions -SelectedIndex $selectedIndex -Top $top -VisibleRows $visibleRows -Width $width -Message $prompt
                    [Console]::SetCursorPosition($prompt.Length, $top + $visibleRows + 6)
                    $response = [Console]::ReadLine()
                    $action = ConvertTo-ConfirmationAction -Response $response

                    if ($action -eq 'yes') {
                        [Console]::WriteLine()
                        Write-Host "Running: codex resume $($session.id)"
                        return (Invoke-CodexResume -SessionId $session.id -CodexExecutable $CodexExecutable)
                    }
                    if ($action -eq 'no') {
                        $message = ''
                        break
                    }
                    if ($action -eq 'exit') {
                        return 0
                    }

                    $message = 'Please enter Y, n, or exit.'
                }
            }
            default {
                if ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q') {
                    return 0
                }
            }
        }
    }
}

# Plain report mode works in redirected terminals, logs, and automation.
function Show-SessionReport {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Report
    )

    Write-Host ''
    Write-Host 'Codex Session Doctor'
    Write-Host '===================='
    Write-Host "Codex home: $($Report.codexHome)"
    Write-Host "Database:   $($Report.database)"
    Write-Host ''

    if ($Report.sessionIndexDrift) {
        Write-Host 'Session index drift'
        Write-Host '-------------------'
        Write-Host ("Active DB threads:     {0}" -f $Report.sessionIndexDrift.activeThreadCount)
        Write-Host ("Index entries:         {0}" -f $Report.sessionIndexDrift.sessionIndexEntryCount)
        Write-Host ("Missing from index:    {0}" -f $Report.sessionIndexDrift.missingFromIndexCount)
        Write-Host ("Orphan index entries:  {0}" -f $Report.sessionIndexDrift.extraInIndexCount)
        Write-Host ("Latest DB update UTC:  {0}" -f $Report.sessionIndexDrift.latestThreadUpdatedAtUtc)
        Write-Host ("Latest index UTC:      {0}" -f $Report.sessionIndexDrift.latestIndexUpdatedAtUtc)
        if (-not $Report.sessionIndexDrift.isInSync) {
            Write-Host 'Repair command:'
            Write-Host '  pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-session-doctor.ps1 -RepairIndex -List'
        }
        Write-Host ''
    }

    if ($Report.repairIndex -and $Report.repairIndex.applied) {
        Write-Host 'Session index repair'
        Write-Host '--------------------'
        Write-Host ("Index path:           {0}" -f $Report.repairIndex.indexPath)
        Write-Host ("Backup path:          {0}" -f $Report.repairIndex.backupPath)
        Write-Host ("Entries rewritten:    {0}" -f $Report.repairIndex.writtenEntryCount)
        Write-Host ''
    }

    if ($Report.recommendation) {
        Write-Host 'Recommended resume command:'
        Write-Host "  $($Report.recommendation.resumeCommand)"
        Write-Host ''
    }
    else {
        Write-Host 'No valid rollout file was found in the inspected sessions.'
        Write-Host ''
    }

    Write-Host ('{0,-16} {1,-20} {2,-36} {3}' -f 'Status', 'Updated UTC', 'Session Id', 'Title')
    Write-Host ('{0,-16} {1,-20} {2,-36} {3}' -f ('-' * 6), ('-' * 11), ('-' * 10), ('-' * 5))

    foreach ($session in $Report.sessions) {
        if ($session.updatedAtUtc -is [datetime]) {
            $updated = $session.updatedAtUtc.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        }
        else {
            $updated = [string]$session.updatedAtUtc
            $updated = $updated.Replace('T', ' ').Replace('Z', '')
        }

        if ($updated.Length -gt 20) {
            $updated = $updated.Substring(0, 20)
        }

        $title = [string]$session.title
        if ($title.Length -gt 72) {
            $title = $title.Substring(0, 69) + '...'
        }

        Write-Host ('{0,-16} {1,-20} {2,-36} {3}' -f $session.status, $updated, $session.id, $title)
    }

    Write-Host ''
    Write-Host 'Use the Id from the table with:'
    Write-Host '  codex resume <session-id>'
    Write-Host ''
    Write-Host 'When the VS Code sidebar looks stale, the exact resume command is usually more reliable.'

    $problemSessions = @($Report.sessions | Where-Object { $_.status -ne 'ok' -or $_.notes.Count -gt 0 })
    if ($problemSessions.Count -gt 0) {
        Write-Host ''
        Write-Host 'Notes'
        Write-Host '-----'
        foreach ($session in $problemSessions) {
            foreach ($note in $session.notes) {
                Write-Host "- $($session.id): $note"
            }
        }
    }
}

# Tests dot-source this script with -SourceOnly so they can call helper functions.
if ($SourceOnly) {
    return
}

# Catch accidental `codex-session-doctor resume <id>` usage and show the right CLI.
if ($Command) {
    if ($Command -ieq 'resume') {
        if ([string]::IsNullOrWhiteSpace($SessionId)) {
            Exit-UsageError 'Missing session id. codex-session-doctor.ps1 only inspects sessions. To resume, run: codex resume <session-id>'
        }

        Exit-UsageError "codex-session-doctor.ps1 only inspects sessions. To resume, run: codex resume $SessionId"
    }

    Exit-UsageError "Unknown command '$Command'. codex-session-doctor.ps1 only inspects sessions. Run it with named options such as -Limit 25, or resume with: codex resume <session-id>"
}

# Keep the sqlite query bounded; very large limits make the report harder to read.
if ($Limit -lt 1) {
    throw '-Limit must be 1 or greater.'
}

# Resolve Codex home once so both PowerShell and Python use the same path.
$resolvedCodexHome = if (Test-Path -LiteralPath $CodexHome) {
    (Resolve-Path -LiteralPath $CodexHome).Path
}
else {
    throw "Codex home was not found: $CodexHome"
}

# Python does the sqlite/jsonl inspection; PowerShell keeps the UI and CLI surface.
$pythonCode = @'
import datetime as _dt
import json
import os
import sqlite3
import sys
from pathlib import Path


# Codex can store Windows paths with an extended prefix; remove it for display.
def normalize_cwd(value):
    if not value:
        return ""
    if value.startswith("\\\\?\\"):
        return value[4:]
    return value


# Store times as stable UTC strings so PowerShell can render them directly.
def iso_utc(epoch):
    if epoch is None:
        return None
    try:
        return _dt.datetime.fromtimestamp(int(epoch), _dt.UTC).isoformat().replace("+00:00", "Z")
    except Exception:
        return None


# session_index.jsonl is a useful cross-check against the sqlite thread rows.
def read_session_index(index_path):
    result = {
        "exists": index_path.exists(),
        "entries": 0,
        "latestUpdatedAt": None,
        "byId": {},
    }
    if not index_path.exists():
        return result

    latest = None
    try:
        with index_path.open("r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue
                session_id = item.get("id")
                updated_at = item.get("updated_at")
                if session_id:
                    result["byId"][session_id] = item
                result["entries"] += 1
                if updated_at and (latest is None or updated_at > latest):
                    latest = updated_at
    except OSError as exc:
        result["error"] = str(exc)

    result["latestUpdatedAt"] = latest
    return result


# A resumable session needs a present, non-empty rollout with session metadata.
def inspect_rollout(path_text):
    path = Path(path_text)
    info = {
        "exists": path.exists(),
        "size": None,
        "hasSessionMeta": False,
        "status": "missing",
        "notes": [],
    }

    if not path.exists():
        info["notes"].append("Database points to a rollout file that is not present.")
        return info

    try:
        size = path.stat().st_size
    except OSError as exc:
        info["status"] = "unreadable"
        info["notes"].append(f"Could not stat rollout file: {exc}")
        return info

    info["size"] = size
    if size == 0:
        info["status"] = "empty"
        info["notes"].append("Rollout file exists but is empty. This can happen briefly while a session is live.")
        return info

    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for index, line in enumerate(handle):
                if index >= 50:
                    break
                if '"type":"session_meta"' in line or '"type": "session_meta"' in line:
                    info["hasSessionMeta"] = True
                    break
    except OSError as exc:
        info["status"] = "unreadable"
        info["notes"].append(f"Could not read rollout file: {exc}")
        return info

    if info["hasSessionMeta"]:
        info["status"] = "ok"
    else:
        info["status"] = "no_session_meta"
        info["notes"].append("Rollout file is non-empty but the first lines do not contain session_meta.")
    return info


# Build one JSON report that PowerShell can render as text, JSON, or a picker.
def main():
    codex_home = Path(os.environ["CODEX_SESSION_DOCTOR_HOME"])
    limit = int(os.environ.get("CODEX_SESSION_DOCTOR_LIMIT", "12"))
    include_archived = os.environ.get("CODEX_SESSION_DOCTOR_INCLUDE_ARCHIVED") == "1"
    db_path = codex_home / "state_5.sqlite"
    index_path = codex_home / "session_index.jsonl"

    output = {
        "codexHome": str(codex_home),
        "database": str(db_path),
        "databaseExists": db_path.exists(),
        "sessionIndex": read_session_index(index_path),
        "sessions": [],
        "recommendation": None,
    }

    if not db_path.exists():
        output["error"] = f"state_5.sqlite was not found at {db_path}"
        print(json.dumps(output, indent=2))
        return 2

    where = "" if include_archived else "where archived = 0"
    limit_clause = "" if limit <= 0 else "limit ?"
    query = f"""
        select id, title, cwd, rollout_path, created_at, updated_at, archived,
               first_user_message, model, reasoning_effort
        from threads
        {where}
        order by updated_at desc
        {limit_clause}
    """

    active_ids_query = f"""
        select id, updated_at
        from threads
        {where}
        order by updated_at desc
    """

    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        if limit <= 0:
            rows = con.execute(query).fetchall()
        else:
            rows = con.execute(query, (limit,)).fetchall()
        active_id_rows = con.execute(active_ids_query).fetchall()
        all_thread_ids = {row[0] for row in con.execute("select id from threads").fetchall()}
    finally:
        con.close()

    index_by_id = output["sessionIndex"].get("byId", {})
    index_ids = set(index_by_id.keys())
    active_thread_ids = [row[0] for row in active_id_rows]
    active_thread_id_set = set(active_thread_ids)
    missing_from_index = sorted(active_thread_id_set - index_ids)
    extra_in_index = sorted(index_ids - all_thread_ids)

    latest_thread_updated_at = None
    if active_id_rows:
        latest_thread_updated_at = iso_utc(active_id_rows[0][1])

    output["sessionIndexDrift"] = {
        "activeThreadCount": len(active_thread_ids),
        "sessionIndexEntryCount": len(index_ids),
        "missingFromIndexCount": len(missing_from_index),
        "extraInIndexCount": len(extra_in_index),
        "missingFromIndexIds": missing_from_index,
        "extraInIndexIds": extra_in_index,
        "latestThreadUpdatedAtUtc": latest_thread_updated_at,
        "latestIndexUpdatedAtUtc": output["sessionIndex"].get("latestUpdatedAt"),
        "isInSync": len(missing_from_index) == 0 and len(extra_in_index) == 0,
    }

    for row in rows:
        (
            session_id,
            title,
            cwd,
            rollout_path,
            created_at,
            updated_at,
            archived,
            first_user_message,
            model,
            reasoning_effort,
        ) = row
        rollout = inspect_rollout(rollout_path)
        index_entry = index_by_id.get(session_id)
        notes = list(rollout["notes"])

        if index_entry:
            index_updated = index_entry.get("updated_at")
        else:
            index_updated = None
            notes.append("Session is not present in session_index.jsonl.")

        item = {
            "id": session_id,
            "title": title,
            "cwd": cwd,
            "normalizedCwd": normalize_cwd(cwd),
            "rolloutPath": rollout_path,
            "createdAtUtc": iso_utc(created_at),
            "updatedAtUtc": iso_utc(updated_at),
            "archived": bool(archived),
            "firstUserMessage": first_user_message,
            "model": model,
            "reasoningEffort": reasoning_effort,
            "exists": rollout["exists"],
            "size": rollout["size"],
            "hasSessionMeta": rollout["hasSessionMeta"],
            "status": rollout["status"],
            "indexUpdatedAt": index_updated,
            "resumeCommand": f"codex resume {session_id}",
            "notes": notes,
        }
        output["sessions"].append(item)

    for item in output["sessions"]:
        if item["status"] == "ok":
            output["recommendation"] = {
                "id": item["id"],
                "title": item["title"],
                "updatedAtUtc": item["updatedAtUtc"],
                "resumeCommand": item["resumeCommand"],
            }
            break

    print(json.dumps(output, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
'@

$report = Get-SessionDoctorReport -CodexHome $resolvedCodexHome -PythonCode $pythonCode -Limit $Limit -IncludeArchived:$IncludeArchived

if ($RepairIndex) {
    $fullReport = Get-SessionDoctorReport -CodexHome $resolvedCodexHome -PythonCode $pythonCode -Limit 0 -IncludeArchived:$IncludeArchived
    $repairInfo = Repair-SessionIndexFile -CodexHome $resolvedCodexHome -Sessions @($fullReport.sessions)
    $report = Get-SessionDoctorReport -CodexHome $resolvedCodexHome -PythonCode $pythonCode -Limit $Limit -IncludeArchived:$IncludeArchived
    $report | Add-Member -NotePropertyName repairIndex -NotePropertyValue $repairInfo -Force
}
else {
    $report | Add-Member -NotePropertyName repairIndex -NotePropertyValue ([pscustomobject]@{
        applied = $false
        indexPath = Join-Path $resolvedCodexHome 'session_index.jsonl'
        backupPath = $null
        writtenEntryCount = 0
    }) -Force
}

# -Json is the automation-friendly output path.
if ($Json) {
    $report | ConvertTo-Json -Depth 6
    return
}

# Non-interactive shells get the stable text report instead of the arrow-key UI.
if ($List -or -not (Test-CanUseInteractivePicker)) {
    Show-SessionReport -Report $report
    return
}

$pickerExitCode = Show-InteractiveSessionPicker -Report $report -CodexExecutable $CodexExecutable
exit $pickerExitCode
