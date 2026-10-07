# Beta releases

The current beta is 0.1.1 (build 4). The signed app launcher starts its own nested menu agent with independent macOS process responsibility. This prevents a terminal or IDE's disabled menu-bar appearance switch from hiding Task Manager. The launcher and agent use `com.jakemawson.codex-task-manager.launcher` and `com.jakemawson.codex-task-manager.menuagent`; only app-owned settings migrate from the previous two identities. The popover publishes its full fixed panel size before positioning so its header and controls remain on screen. Task-status behavior is still being refined; do not represent this as a stable release.

The launch bridge dynamically resolves the macOS responsibility attribute also used by LLVM/LLDB. It is a private platform API: verify it on supported macOS versions before release, and fail with a visible launch error if unavailable. It changes process attribution, not OS permission grants or other apps' settings. The helper is bundled; no other installed app is required. Login startup is not automatically enabled.

Before releasing a menu-bar change, test the installed bundle on macOS: visually confirm one item and process, open and close the real popover, exercise its search and display controls, launch a second instance, quit through its menu and relaunch twice. A live process or an Accessibility entry alone does not prove the item is visible. Test the registration-failure and item-removal QA routes and preserve app settings during identity changes.

A public binary must be a universal Apple silicon/Intel Developer ID build, notarized and stapled with this app's own profile. The dedicated profile name is **Codex Task Manager Notary**. Credentials remain in Keychain and are never part of source or release archives.

1. Run `xcrun swift test --jobs 2` against the exact source snapshot.
2. Choose an absolute, fresh output, such as `/absolute/checkout/build/releases/beta-0.1.1-unique`.
3. Run `Scripts/package-release OUTPUT 'Developer ID Application: Publisher (TEAMID)'`.
4. Set up the app-specific notarization profile through `xcrun notarytool store-credentials` using a dedicated Apple app-specific password entered by its owner. Never reuse another app's profile.
5. Run `Scripts/finalize-release OUTPUT`. It waits for notarization, staples the ticket, validates Gatekeeper and creates `Codex-Task-Manager-0.1.1.zip`.
6. Tag the exact source snapshot `v0.1.1`, then publish a GitHub prerelease titled **Codex Task Manager 0.1.1 beta**, attaching only that ZIP and its SHA-256. No build caches, signing credentials, logs or local state belong in the archive.
7. Add `Casks/codex-task-manager.rb` to the existing tap with that exact digest. The cask installs `Codex Task Manager.app`, requires `:sequoia`, and uses the matching GitHub release URL.
8. Verify the public archive checksum and cask metadata, then mark the website install status available. Keep the native app's known beta limitations visible.

Public source updates, releases and tap updates require the owner's current publication instruction. Avoid force pushes and never replace published release bytes silently.
