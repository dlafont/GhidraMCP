param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'codex-session-doctor.ps1'),
    [string]$WrapperPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'codex-session-doctor.cmd')
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param(
        [object]$Expected,
        [object]$Actual,
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message. Expected '$Expected', got '$Actual'"
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-session-doctor-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    . $ScriptPath -SourceOnly

    Assert-Equal 'yes' (ConvertTo-ConfirmationAction '') 'blank confirmation defaults to yes'
    Assert-Equal 'yes' (ConvertTo-ConfirmationAction 'Y') 'Y confirmation means yes'
    Assert-Equal 'yes' (ConvertTo-ConfirmationAction 'yes') 'yes confirmation means yes'
    Assert-Equal 'no' (ConvertTo-ConfirmationAction 'n') 'n confirmation means no'
    Assert-Equal 'no' (ConvertTo-ConfirmationAction 'NO') 'NO confirmation means no'
    Assert-Equal 'exit' (ConvertTo-ConfirmationAction 'exit') 'exit confirmation exits'
    Assert-Equal 'invalid' (ConvertTo-ConfirmationAction 'maybe') 'unknown confirmation is invalid'
    Assert-True (Test-SessionCanResume ([pscustomobject]@{ status = 'ok' })) 'ok session can resume'
    Assert-True (-not (Test-SessionCanResume ([pscustomobject]@{ status = 'missing' }))) 'missing session cannot resume'
    Assert-Equal 0 (Get-SessionPickerStartIndex -SessionCount 20 -SelectedIndex 0 -VisibleRows 5) 'picker starts at first row initially'
    Assert-Equal 2 (Get-SessionPickerStartIndex -SessionCount 20 -SelectedIndex 6 -VisibleRows 5) 'picker scrolls selected row into view'
    Assert-Equal 15 (Get-SessionPickerStartIndex -SessionCount 20 -SelectedIndex 19 -VisibleRows 5) 'picker clamps to final page'
    Assert-Equal 0 (Get-SessionPickerStartIndex -SessionCount 3 -SelectedIndex 2 -VisibleRows 5) 'picker does not scroll short lists'

    $fakeCodex = Join-Path $tempRoot 'codex.cmd'
    $fakeCodexOutput = Join-Path $tempRoot 'codex-args.txt'
    Set-Content -LiteralPath $fakeCodex -Encoding ASCII -Value @(
        '@echo off',
        'echo %*>"%CODEX_RESUME_TEST_OUTPUT%"',
        'exit /b 7'
    )
    $env:CODEX_RESUME_TEST_OUTPUT = $fakeCodexOutput
    $resumeExitCode = Invoke-CodexResume -SessionId 'valid-session' -CodexExecutable $fakeCodex

    Assert-Equal 7 $resumeExitCode 'resume launcher returns child exit code'
    Assert-Equal 'resume valid-session' (Get-Content -LiteralPath $fakeCodexOutput -Raw).Trim() 'resume launcher passes codex resume arguments'

    $codexHome = Join-Path $tempRoot '.codex'
    $sessionDir = Join-Path $codexHome 'sessions\2026\05\04'
    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

    $validRollout = Join-Path $sessionDir 'rollout-valid.jsonl'
    $emptyRollout = Join-Path $sessionDir 'rollout-empty.jsonl'
    $missingRollout = Join-Path $sessionDir 'rollout-missing.jsonl'
    $indexPath = Join-Path $codexHome 'session_index.jsonl'

    Set-Content -LiteralPath $validRollout -Encoding UTF8 -Value @(
        '{"timestamp":"2026-05-04T20:00:00Z","type":"session_meta","payload":{"id":"valid-session","cwd":"d:\\Dev\\PRJ-GhidraMCP"}}',
        '{"timestamp":"2026-05-04T20:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}'
    )
    New-Item -ItemType File -Path $emptyRollout | Out-Null
    Set-Content -LiteralPath $indexPath -Encoding UTF8 -Value @(
        '{"id":"valid-session","thread_name":"Useful prior work","updated_at":"2026-05-03T20:01:00Z"}',
        '{"id":"orphan-session","thread_name":"Old orphan entry","updated_at":"2026-05-03T19:00:00Z"}'
    )

    $dbPath = Join-Path $codexHome 'state_5.sqlite'
    $pythonSetup = @'
import sqlite3
import sys

db_path, valid_path, empty_path, missing_path = sys.argv[1:5]
con = sqlite3.connect(db_path)
con.execute("""
create table threads (
    id text primary key,
    rollout_path text not null,
    created_at integer not null,
    updated_at integer not null,
    source text not null,
    model_provider text not null,
    cwd text not null,
    title text not null,
    sandbox_policy text not null,
    approval_mode text not null,
    tokens_used integer not null default 0,
    has_user_event integer not null default 0,
    archived integer not null default 0,
    archived_at integer,
    git_sha text,
    git_branch text,
    git_origin_url text,
    cli_version text not null default '',
    first_user_message text not null default '',
    agent_nickname text,
    agent_role text,
    memory_mode text not null default 'enabled',
    model text,
    reasoning_effort text,
    agent_path text,
    created_at_ms integer,
    updated_at_ms integer
)
""")
rows = [
    ("valid-session", valid_path, 1777924800, 1777924860, r"\\?\D:\Dev\PRJ-GhidraMCP", "Useful prior work", "Review the handler"),
    ("empty-session", empty_path, 1777924700, 1777924760, r"D:\Dev\PRJ-GhidraMCP", "Just started", "hello"),
    ("missing-session", missing_path, 1777924600, 1777924660, r"D:\Dev\PRJ-GhidraMCP", "Missing transcript", "lost"),
]
for row in rows:
    con.execute("""
        insert into threads (
            id, rollout_path, created_at, updated_at, source, model_provider,
            cwd, title, sandbox_policy, approval_mode, first_user_message
        )
        values (?, ?, ?, ?, 'vscode', 'openai', ?, ?, '{}', 'on-request', ?)
    """, row)
con.commit()
con.close()
'@
    $pythonSetup | python - $dbPath $validRollout $emptyRollout $missingRollout
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create fake Codex sqlite database'
    }

    $jsonText = & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -CodexHome $codexHome -Limit 5 -Json
    if ($LASTEXITCODE -ne 0) {
        throw "Doctor script failed with exit code $LASTEXITCODE"
    }

    $result = $jsonText | ConvertFrom-Json

    Assert-Equal 3 $result.sessions.Count 'reports all fake sessions'

    $valid = $result.sessions | Where-Object { $_.id -eq 'valid-session' }
    $empty = $result.sessions | Where-Object { $_.id -eq 'empty-session' }
    $missing = $result.sessions | Where-Object { $_.id -eq 'missing-session' }

    Assert-Equal 'ok' $valid.status 'valid session is marked ok'
    Assert-Equal 'D:\Dev\PRJ-GhidraMCP' $valid.normalizedCwd 'normalizes extended Windows path prefix'
    Assert-Equal 'codex resume valid-session' $valid.resumeCommand 'valid session has exact resume command'
    Assert-Equal 'empty' $empty.status 'empty rollout is marked empty'
    Assert-Equal 'missing' $missing.status 'missing rollout is marked missing'
    Assert-Equal 'valid-session' $result.recommendation.id 'latest valid session is recommended'
    Assert-Equal 3 $result.sessionIndexDrift.activeThreadCount 'drift summary counts active db threads'
    Assert-Equal 2 $result.sessionIndexDrift.sessionIndexEntryCount 'drift summary counts session index entries'
    Assert-Equal 2 $result.sessionIndexDrift.missingFromIndexCount 'drift summary counts db threads missing from index'
    Assert-Equal 1 $result.sessionIndexDrift.extraInIndexCount 'drift summary counts orphan index entries'
    Assert-True (-not $result.sessionIndexDrift.isInSync) 'drift summary marks stale index as out of sync'

    $repairJsonText = & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -CodexHome $codexHome -Limit 5 -RepairIndex -Json
    if ($LASTEXITCODE -ne 0) {
        throw "Doctor repair output failed with exit code $LASTEXITCODE"
    }

    $repairResult = $repairJsonText | ConvertFrom-Json
    Assert-True $repairResult.repairIndex.applied 'repair mode reports that it rewrote the index'
    Assert-True ([string]$repairResult.repairIndex.backupPath).Length -gt 0 'repair mode records the backup path'
    Assert-Equal 3 $repairResult.repairIndex.writtenEntryCount 'repair mode writes one index row per active session'

    $rebuiltIndexLines = Get-Content -LiteralPath $indexPath
    Assert-Equal 3 $rebuiltIndexLines.Count 'repair mode rewrites the session index with active sessions only'
    Assert-True (-not (($rebuiltIndexLines -join "`n").Contains('orphan-session'))) 'repair mode removes orphan session index entries'

    $postRepairJsonText = & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -CodexHome $codexHome -Limit 5 -Json
    if ($LASTEXITCODE -ne 0) {
        throw "Doctor post-repair output failed with exit code $LASTEXITCODE"
    }

    $postRepairResult = $postRepairJsonText | ConvertFrom-Json
    Assert-True $postRepairResult.sessionIndexDrift.isInSync 'post-repair drift summary reports the index as in sync'
    Assert-Equal 0 $postRepairResult.sessionIndexDrift.missingFromIndexCount 'post-repair drift summary clears missing entries'
    Assert-Equal 0 $postRepairResult.sessionIndexDrift.extraInIndexCount 'post-repair drift summary clears orphan entries'

    $textOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -CodexHome $codexHome -Limit 5 -List
    if ($LASTEXITCODE -ne 0) {
        throw "Doctor text output failed with exit code $LASTEXITCODE"
    }

    $joinedText = $textOutput -join "`n"
    Assert-True ($joinedText.Contains('Session Id')) 'text output shows a stable session id column'
    Assert-True ($joinedText.Contains('valid-session')) 'text output includes the valid session id'
    Assert-True ($joinedText.Contains('empty-session')) 'text output includes the empty session id'
    Assert-True ($joinedText.Contains('missing-session')) 'text output includes the missing session id'
    Assert-True ($joinedText.Contains('Session index drift')) 'text output surfaces session index drift diagnostics'

    $resumeOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath resume valid-session 2>&1
    $resumeExitCode = $LASTEXITCODE
    $joinedResumeOutput = ($resumeOutput | ForEach-Object { [string]$_ }) -join "`n"

    Assert-Equal 64 $resumeExitCode 'mistaken resume subcommand exits with usage error'
    Assert-True ($joinedResumeOutput.Contains('codex-session-doctor.ps1 only inspects sessions')) 'mistaken resume subcommand explains script scope'
    Assert-True ($joinedResumeOutput.Contains('codex resume valid-session')) 'mistaken resume subcommand shows the correct command'
    Assert-True (-not $joinedResumeOutput.Contains('Cannot process argument transformation')) 'mistaken resume subcommand avoids raw PowerShell binding error'

    $wrapperOutput = & cmd /c "`"$WrapperPath`" resume valid-session" 2>&1
    $wrapperExitCode = $LASTEXITCODE
    $joinedWrapperOutput = ($wrapperOutput | ForEach-Object { [string]$_ }) -join "`n"

    Assert-Equal 64 $wrapperExitCode 'cmd wrapper returns doctor script exit code'
    Assert-True ($joinedWrapperOutput.Contains('codex-session-doctor.ps1 only inspects sessions')) 'cmd wrapper forwards arguments to doctor script'
    Assert-True ($joinedWrapperOutput.Contains('codex resume valid-session')) 'cmd wrapper preserves forwarded session id'

    Write-Host 'codex-session-doctor tests passed'
}
finally {
    Remove-Item Env:\CODEX_RESUME_TEST_OUTPUT -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
