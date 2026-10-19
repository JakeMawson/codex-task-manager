# Codex Task Manager release review

Date: 2026-10-20. Scope: native launcher/menu agent, SwiftUI controls, local catalog/rollout parsing, Desktop IPC, preferences, update coordinator, packaging and Homebrew delivery. Method: source tracing, disposable parser/model/socket fixtures, unit tests, read-only live owner comparisons, native rendered inspection and signed-package verification. No cloud backend, tenant authorization service or security-rule deployment exists in this application. Your database is opened read-only; tests use disposable catalogs. Private chat content is excluded from this report and release source.

This review does not establish that every possible defect has been eliminated. Active unrelated chats are not interrupted as test subjects. Cross-version Codex compatibility, Intel execution and every supported macOS release are not physically exercised.

| ID | Priority | Finding | Disposition |
|---|---|---|---|
| CTM-001 | P2 | Terminal log tails and old approval callbacks produce false activity | Fixed; parser and live-owner regression coverage |
| CTM-002 | P2 | Stop uses incompatible IPC version and only a temporary display override | Fixed; transport and persistent-dismissal tests |
| CTM-003 | P2 | Observation resumes chats and replays permission changes through a second daemon | Removed; monitoring now uses read-only owner snapshots |
| CTM-004 | P3 | Development installer points at obsolete staging and merges into installed app | Fixed; fresh build result and existing-install refusal |

## CTM-001 — Reconcile activity with the actual owner

- **Priority:** P2, correctness.
- **Affected assets:** rollout parser and status reconciliation.
- **Evidence:** `RolloutScanner.swift`, `TaskManagerModel.swift`; terminal-rollout and desktop-reconciliation tests.

### Summary and safe reproduction

Feed a disposable rollout `task_started`, `task_complete`, then `custom_tool_call_output`. The previous parser returns running=true; the repaired parser returns false. The same original and repaired source were run against this fixture. A new `task_started` previously retained an unresolved elevated-command callback from an earlier turn. Desktop-positive entries also lacked reconciliation against their actual owner; a separate daemon’s resumed copy is not that owner.

### Impact

Finished chats remain in Running/Needs and counts mislead the user. Your database itself is not corrupted.

### Remediation and verification

Latch terminal turns, recognize final-answer messages, clear old callbacks at a new turn and prevent output/metadata from restarting a completed turn. Query the actual Desktop owner using read-only stream snapshots, bound concurrency and retain unknown states on transport failure. Tests cover terminal tails, new turns, stale approvals, active/idle/input/approval snapshots and missing/unknown responses. Read-only live comparison agreed with each currently positive Desktop chat at inspection.

## CTM-002 — Use native Stop and persist its dismissal

- **Priority:** P2, correctness.
- **Affected assets:** Desktop IPC interrupt and task-list lifecycle.
- **Evidence:** `CodexDesktopIPCClient.userStopRequest`, `TaskManagerModel.pauseTask`, stopped-turn repository state and socket-pair tests.

### Summary and safe reproduction

The old Stop request sent interrupt version4 without `expectedTurnId`; the installed Desktop protocol negotiates version3 for that parameter shape. Its display override lasted ten seconds and then a positive log tail could resurrect the entry. The old fallback archived/unarchived a chat on a different daemon.

### Impact

A user cannot reliably stop or dismiss a reported task. A fallback may mutate persisted chat state without stopping its actual owner.

### Remediation and verification

Send the owner-targeted version3 `user-stop` operation, check acknowledgement and Goal-pause errors, and remove the archive/unarchive fallback. On success, mark read and persist dismissal in Task Manager’s own file until a detected new turn. Failures retain the entry. CLI/extension tasks without Desktop ownership must be stopped in their owning app. Socket-pair tests inspect the exact wire request; model/repository tests cover refresh, restart, new-turn reappearance and partial failure. Unrelated active real chats were deliberately left running.

## CTM-003 — Keep monitoring free of permission and execution side effects

- **Priority:** P2, safety defect; no remote exploit demonstrated.
- **Affected assets:** former approval companion startup/subscription and permission recovery.
- **Evidence:** previous controller `start` invoked daemon setup/remote-control enabling; subscription used `thread/resume` and replayed stored policies. Those executable paths are removed.

### Summary and safe reproduction

Source tracing showed that opening the monitor started a separate App Server companion and subscribing to observed approvals could resume chats and reapply saved allow-all settings. This mixed observation with execution/permission changes. Live permission-mutation testing was unnecessary and was not performed.

### Impact

A monitoring action has unexpected execution and permission side effects. This is not evidence of an attacker crossing a proven security boundary.

### Remediation and verification

Remove the companion, permission policy persistence/replay, archive recovery and externally constructed continuation feature. Open approvals in Codex’s native UI. The remaining client sends only initialization/discovery, read-only following notifications and explicit Stop. Disposable transport tests reject unexpected requests. IPC adds bounded response/frame buffering, ordered input consumption, timeouts, same-user peer checks, close-on-exec and broken-pipe protection.

## CTM-004 — Preserve existing installed bundles

- **Priority:** P3, local development reliability.
- **Affected assets:** `Scripts/install-app-bundle` and build output selection.

### Summary and safe reproduction

The builder prints a fresh UUID-based app path, but the installer referred to the obsolete fixed `Codex Task Manager.bundle-staging` directory. It also used a merging copy and ad-hoc re-sign over an existing installed bundle.

### Impact

Local installation fails or merges obsolete content into the signed app. This helper is not used by Homebrew’s release installation.

### Remediation and verification

Consume and validate the actual fresh build output; reject symlinked or non-fresh destinations. Refuse to overwrite an existing installed app and direct existing installations to Homebrew. Verify signatures before and after the fresh copy. The existing-install refusal was exercised without altering the installed app.

## Update-delivery review

New update handling has separate discover, prepare, install and relaunch operations behind injectable interfaces. Versions are bounded ASCII dotted integers; release notes are bounded before retention; release responses are capped. No release-controlled string becomes a command, path or download URL. Homebrew uses fixed executable candidates and argument arrays, null stdin and bounded combined output. The cask validates both expected bundle identities, the expected Developer ID team, strict signatures and Gatekeeper before app artifact installation. The installed identities/version are checked again before relaunch. Preferences and Application Support are outside the replacement scope. Tests cover opt-out, successful persistence, stale records, failure preservation, installer arguments, output bounds and relaunch construction.

## Release qualification and residual risk

All 78 tests pass. The frozen 0.2.0/build5 universal archive is Developer ID signed, Apple notarized and stapled; strict signature, staple validation and Gatekeeper pass. Homebrew and final installed-app results are recorded in the release notes and local release receipt. The pre-existing 0.1.1 installation passed static signing/notarization checks but macOS execution policy killed its launch; no security protection or quarantine attribute was disabled to bypass that failure.

The app depends on internal Codex IPC/schema and a dynamically resolved private macOS launch API. Unknown protocol/transport states remain conservative; future changes may require a compatibility update. Tail parsing is bounded, so an unavailable live owner can leave an uncertain historical status. A stopped turn’s dismissal expires when a later turn start is detected. Stop does not kill unrelated or independently managed background processes. No production database writes, credential access, external user messages or unrelated task stops were part of this review.
