# Codex Task Manager

**Early beta · macOS 15+ · Swift 6.2+**

Your next task. In plain sight. A native menu-bar companion for Codex Desktop, from Simpl Industries.

[Website](https://stacksimpl.web.app/codex-task-manager/) · [Issues](https://github.com/JakeMawson/codex-task-manager/issues)

This is an early beta. Version 0.1.1 gives Task Manager an independent menu-bar launcher and preserves existing app settings. Its bundled agent runs independently of other apps' menu-bar switches. Task-status behavior is still being refined; use Codex as the source of truth.

## Install

The signed Homebrew beta release is being prepared. Once published:

```sh
brew install --cask JakeMawson/tap/codex-task-manager
```

You can build locally now with `Scripts/build-app-bundle release`. Local development builds use an ad-hoc signature. Public release archives use Developer ID signing and Apple notarization; see [RELEASING.md](RELEASING.md).


Codex Task Manager is a private, standalone macOS menu-bar app for triaging local Codex tasks. It is intentionally separate from both Codex and AI Usage Bar and never modifies either application or their source.

## What it shows

* Compact two-line task cards with the task title and latest assistant message.
* Project-folder grouping, optional project labels, and ungrouped views.
* Running, needs-response, blue complete/unread, and idle states.
* Status filters plus recent, priority, alphabetical-project, and custom-and-pinned sorting.
* Per-project four-task disclosure for the grouped All-tasks view, with independent Show more and Show less controls using each folder's exact total.
* Custom project ordering; Codex-pinned tasks stay first within each project.
* A task-card context action for task-scoped `Allow all for this task` recovery. Reference implementations for allow-once and similar-command approvals remain disabled because Codex's native buttons own those callbacks most reliably.

Selecting a card opens `codex://threads/<task-id>`, which focuses the exact task in Codex and launches Codex if it is not already running.

## Approval companion

The app is local-only and has no Accessibility requirement. It opens the Codex task catalog database in SQLite read-only mode, reads append-only rollout JSONL for current state and latest assistant text, and reads Codex's persisted local unread task IDs for the blue completion marker.

Approval actions use Codex's built-in local IPC and App Server interfaces. When Codex Desktop owns a pending callback, Task Manager discovers that exact live owner and routes the settings update, interruption, and one continuation through Codex's follower API. The shared local App Server daemon remains the fallback for tasks it owns. Task Manager does not edit the Codex application, its bundle, its source, raw session history, or global Codex approval defaults.

No Codex restart is required. `Allow all for this task` clears the selected task's current desktop-owned approval, preserves an active persistent Goal, and resumes it exactly once with `approvalPolicy: never`, `approvalsReviewer: auto_review`, and `dangerFullAccess`. Unrelated tasks keep their own settings and continue to request approval normally.

## Refresh behavior

The task list uses a recursive macOS file-event stream with file-level events. Rollout appends invalidate only the changed task; SQLite/WAL and unread-state events invalidate only their matching caches. Parsed rollout state is advanced from newly appended bytes, while file size, modification date, and inode signatures protect cache reuse and atomic replacement handling.

Events are batched for 100 milliseconds. A full file-signature reconciliation still runs every 30 seconds, and dropped/coalesced/root-change event flags immediately request the same conservative reconciliation. If the event stream cannot start, the app automatically retains the previous 2.5-second polling behavior.

## Build and install

```bash
swift test
swift run -c release CodexTaskManagerBenchmark 20
Scripts/build-app-bundle release
Scripts/install-app-bundle
```

The installer creates `/Applications/Codex Task Manager.app` and registers it with Launch Services.

## Visual QA

The normal app is menu-bar-only. A suppressed-by-default native QA window is available for repeatable rendered verification. Quit the ordinary app first; deliberately creating a second instance with `open -n` is not supported.

```bash
open "/Applications/Codex Task Manager.app" --args --qa-menu --qa-fixture
open "/Applications/Codex Task Manager.app" --args --qa-menu --qa-no-response
```

Tests use fictional fixtures. The optional live catalogue smoke test runs only with `CTM_TEST_LOCAL_CATALOG=1`; ordinary tests do not read your local chats.
