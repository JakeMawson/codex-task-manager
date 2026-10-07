# Beta releases

The first beta is 0.1.0 (build 1). Startup and task-status bugs remain and are not release blockers for this beta. Do not represent this as a stable release.

A public binary must be a universal Apple silicon/Intel Developer ID build, notarized and stapled with this app's own profile. The dedicated profile name is **Codex Task Manager Notary**. Credentials remain in Keychain and are never part of source or release archives.

1. Run `xcrun swift test --jobs 2` against the exact source snapshot.
2. Choose an absolute, fresh output, such as `/absolute/checkout/build/releases/beta-0.1.0-unique`.
3. Run `Scripts/package-release OUTPUT 'Developer ID Application: Publisher (TEAMID)'`.
4. Set up the app-specific notarization profile through `xcrun notarytool store-credentials` using a dedicated Apple app-specific password entered by its owner. Never reuse another app's profile.
5. Run `Scripts/finalize-release OUTPUT`. It waits for notarization, staples the ticket, validates Gatekeeper and creates `Codex-Task-Manager-0.1.0.zip`.
6. Tag the exact source snapshot `v0.1.0`, then publish a GitHub prerelease titled **Codex Task Manager 0.1.0 beta**, attaching only that ZIP and its SHA-256. No build caches, signing credentials, logs or local state belong in the archive.
7. Add `Casks/codex-task-manager.rb` to the existing tap with that exact digest. The cask installs `Codex Task Manager.app`, requires `:sequoia`, and uses the matching GitHub release URL.
8. Verify the public archive checksum and cask metadata, then mark the website install status available. Keep the native app's known beta limitations visible.

Public source updates, releases and tap updates require the owner's current publication instruction. Avoid force pushes and never replace published release bytes silently.
