# Codex Session Doctor Interactive Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a default interactive session picker that can confirm and run `codex resume <session-id>`.

**Architecture:** Keep session discovery in the existing script and split display, confirmation parsing, resume launching, and table rendering into small PowerShell functions. Preserve JSON output for automation and move the previous report table behind a `-List` switch.

**Tech Stack:** PowerShell 7, Python `sqlite3` for read-only Codex database inspection, existing PowerShell test harness.

---

### Task 1: Preserve Plain Report Mode

**Files:**
- Modify: `scripts/codex-session-doctor.ps1`
- Modify: `scripts/test_codex_session_doctor.ps1`

- [ ] **Step 1: Write the failing test**

Update the text-output test to call:

```powershell
$textOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -CodexHome $codexHome -Limit 5 -List
```

Expected behavior: the current table output still includes `Session Id`, `valid-session`, `empty-session`, and `missing-session`.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_codex_session_doctor.ps1
```

Expected: FAIL because `-List` does not exist yet.

- [ ] **Step 3: Add `-List` and table rendering function**

Add `[switch]$List` to the script parameters and move the existing table output into `Show-SessionReport`.

- [ ] **Step 4: Run the test to verify it passes**

Run the same test command. Expected: PASS for the plain report assertions.

### Task 2: Add Testable Resume Helpers

**Files:**
- Modify: `scripts/codex-session-doctor.ps1`
- Modify: `scripts/test_codex_session_doctor.ps1`

- [ ] **Step 1: Write failing helper tests**

Dot-source the script with `-SourceOnly`, then assert:

```powershell
Assert-Equal 'yes' (ConvertTo-ConfirmationAction '')
Assert-Equal 'yes' (ConvertTo-ConfirmationAction 'Y')
Assert-Equal 'no' (ConvertTo-ConfirmationAction 'n')
Assert-Equal 'exit' (ConvertTo-ConfirmationAction 'exit')
Assert-Equal 'invalid' (ConvertTo-ConfirmationAction 'maybe')
Assert-True (Test-SessionCanResume ([pscustomobject]@{ status = 'ok' })) 'ok session can resume'
Assert-True (-not (Test-SessionCanResume ([pscustomobject]@{ status = 'missing' }))) 'missing session cannot resume'
```

- [ ] **Step 2: Run the test to verify it fails**

Expected: FAIL because `-SourceOnly` and the helper functions do not exist.

- [ ] **Step 3: Implement helpers**

Add `-SourceOnly`, `ConvertTo-ConfirmationAction`, `Test-SessionCanResume`, and `Invoke-CodexResume`. `Invoke-CodexResume` should run `& $CodexExecutable resume $SessionId` and return the child process exit code.

- [ ] **Step 4: Run the test to verify it passes**

Expected: PASS for helper assertions.

### Task 3: Add Interactive Picker

**Files:**
- Modify: `scripts/codex-session-doctor.ps1`
- Modify: `docs/codex-session-doctor.md`

- [ ] **Step 1: Implement console rendering functions**

Add fixed-window helper functions for clearing lines, formatting rows, and redrawing the selected slice of sessions.

- [ ] **Step 2: Implement selection loop**

Use `[Console]::ReadKey($true)` to handle `UpArrow`, `DownArrow`, `Enter`, `Escape`, and `q`.

- [ ] **Step 3: Implement confirmation loop**

After `Enter`, use `Read-Host` and `ConvertTo-ConfirmationAction`. Yes launches `Invoke-CodexResume`, no returns to the picker, and exit leaves the script.

- [ ] **Step 4: Add fallback behavior**

If console APIs are unavailable or input/output is redirected, call `Show-SessionReport` and print the direct resume command instead of entering the picker.

- [ ] **Step 5: Update docs**

Document default picker mode, `-List`, confirmation choices, and `-Json`.

- [ ] **Step 6: Run verification**

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_codex_session_doctor.ps1
```

Expected: PASS with `codex-session-doctor tests passed`.
