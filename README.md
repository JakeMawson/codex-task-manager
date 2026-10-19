# Codex Task Manager

A native menu-bar companion for Codex Desktop. macOS 15 or later; Apple silicon and Intel.

[Releases](https://github.com/JakeMawson/codex-task-manager/releases) · [Issues](https://github.com/JakeMawson/codex-task-manager/issues)

## Install

```sh
brew install --cask JakeMawson/tap/codex-task-manager
open "/Applications/Codex Task Manager.app"
```

Public release archives are universal, Developer ID signed, notarized and stapled. The cask validates the publisher and both app identities before installation.

## Tasks

The menu item shows how many chats need you. Open it for running, approval, response, complete/unread and read states. Search, filter, pin tasks and projects, arrange project order, or choose grouped and ungrouped views. Selecting a task opens that exact chat in Codex.

Desktop activity is checked against the chat’s actual live owner. Historical log entries and delayed tool output cannot keep a finished turn running. A failed live connection preserves the available log state rather than guessing that a chat stopped. CLI/extension logs remain a best-effort fallback.

**Stop task** sends Codex’s native user-stop operation to that chat’s owner, including its Goal handling. After acknowledgement, the entry is dismissed across refreshes and app relaunches; a detected new turn brings it back. A rejected action stays visible with an error. Stopping a turn does not terminate independent background processes launched by the chat. Approval decisions stay in Codex’s native approval UI.

## Settings and updates

Open the gear button or right-click the menu item and choose **Settings…**. Settings shows the installed version and build, a manual update check, and **Automatically prepare updates**.

Checks run at launch and every two hours. With automatic preparation enabled, the app fetches a newer stable release through its fixed Homebrew cask. It installs a prepared update on the next ordinary launch, or when you choose **Install and relaunch**. It never replaces the app merely because a periodic check found an update. An explicit opt-out is preserved.

GitHub release metadata is an availability signal. It cannot supply executable commands or installation URLs. Homebrew verifies its pinned archive checksum, the cask checks signatures and notarization before replacement, and the app rechecks the installed identities and version before relaunching. Application Support, preferences, Codex chats and unrelated running work are preserved.

Manual update:

```sh
brew update
brew upgrade --cask JakeMawson/tap/codex-task-manager
```

## Privacy and compatibility

The catalog is opened read-only in SQLite. Rollouts and unread markers are read locally. Task Manager stores its own preferences, read overrides and stopped-turn markers; it does not rewrite Codex session history or its global state. Monitoring does not resume chats, start a companion daemon, enable remote control or replay approval permissions. No Accessibility permission is needed for normal use.

Only the fixed GitHub update endpoint and Homebrew’s delivery services are used for updates; chat contents are not sent to them. No analytics or cloud backend is included.

Codex Desktop’s local IPC is an internal compatibility surface. The independent launcher also uses a dynamically resolved macOS process-responsibility API. Unsupported changes fail with an error; compatibility with future Codex/macOS releases cannot be guaranteed. The current release is tested on this development Mac; Intel packaging is verified, but Intel execution is not physically tested.

## Development

Swift 6.2 or later:

```sh
swift test --jobs 2
Scripts/build-app-bundle debug
```

The build prints a fresh bundle path. Local builds are ad-hoc signed. See [RELEASING.md](RELEASING.md) for signed distribution and [SECURITY_AUDIT_HACKERONE.md](Support/SECURITY_AUDIT_HACKERONE.md) for the release review.

Quit the normal app before opening a fictional native QA window:

```sh
open "/path/to/Codex Task Manager.app" --args --qa-menu --qa-fixture
```

Ordinary tests use disposable fixtures. Optional local-catalogue and live-action tests require explicit environment opt-in; never target a real running chat merely to smoke-test Stop.
