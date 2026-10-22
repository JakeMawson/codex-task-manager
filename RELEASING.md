# Releases

Release version: **0.2.3, build 8**. This release detects asynchronous questions in Needs, including questions without a waiting flag and questions left open while idle. It matches structured answers by question identity and preserves approval priority. Catalogue placeholders without a real local history file do not trigger native discovery. Release archives contain only the signed application and its nested menu agent. Source, logs, signing credentials and local chat data do not belong in an archive.

The launcher and agent retain their existing identities:

- `com.jakemawson.codex-task-manager.launcher`
- `com.jakemawson.codex-task-manager.menuagent`

The independent launch bridge dynamically resolves a private macOS responsibility attribute. Verify launch and visible menu-bar behavior on the supported OS; fail visibly if the API is unavailable. Do not change OS permissions, remove quarantine, or reset unrelated menu-bar state to make a release appear functional. Login startup is not automatically enabled.

## Validation

1. Run `swift test --jobs 2` against the frozen release source.
2. Inspect the actual menu item, task panel, settings, approval/response states, search/filter/project controls, dismissal and quit/relaunch. Confirm duplicate opens converge to one agent. Inspect a native top strip and enlarged target crop; process/Accessibility metadata alone is insufficient.
3. Replay asynchronous question acknowledgement, unanswered/answered and skipped states, partial replies, later-turn answers and idle questions. Reconcile positive status entries with their actual Desktop owner. Exercise Stop with disposable protocol/model fixtures; stop a real active chat only with specific authority.
4. Check automatic-update opt-out, preparation persistence, failed check/staging/install, post-install identity/version validation and relaunch handling.
5. Review public source for private paths, credentials, chat content and unintended artifacts. See `Support/SECURITY_AUDIT_HACKERONE.md` for scope and residual risks.

## Signed package

Use an absolute **fresh** output under `build/releases/`; packaging never empties an existing destination.

```sh
Scripts/package-release /absolute/checkout/build/releases/0.2.3-unique 'Developer ID Application: Publisher (TEAMID)'
Scripts/finalize-release /absolute/checkout/build/releases/0.2.3-unique
```

Both architectures are built with two Swift workers. Signing requires the publisher’s Developer ID certificate. Notarization uses this app’s existing dedicated **Codex Task Manager Notary** Keychain profile. Credentials stay in Keychain; never borrow another app’s profile or put passwords in source/arguments. New credential setup requires its separate owner handoff.

Finalize submits the exact signed archive, waits for acceptance, staples and validates the app, verifies strict signatures and Gatekeeper, then creates `Codex-Task-Manager-0.2.3.zip` and prints its SHA-256.

## Publish and install

Public source pushes, tags, GitHub release/asset writes and tap changes require the owner’s current exact publication instruction. Preserve the pre-push guard. Never force-push or silently replace existing release bytes.

1. Push the reviewed source commit and matching `v0.2.3` tag.
2. Publish a stable GitHub release with only the finalized ZIP and its SHA-256 text.
3. Update the existing `JakeMawson/tap/codex-task-manager` cask to that version and digest. Preserve its publisher, bundle-ID and notarization preflight checks; these run before app installation. Use `xcrun stapler validate` for the ticket; `spctl` assessment cannot access its Mach service inside Homebrew’s cask sandbox. The updater assesses Gatekeeper outside that sandbox before relaunch.
4. Fetch through Homebrew, compare the exact public digest, then upgrade the installed app. Preserve preferences and Application Support. Recheck both installed identities, universal architectures, strict signatures, stapling, Gatekeeper and version. Also run `/usr/bin/gktool scan` against the installed bundle; unlike static assessment, this exercises the execution scan used by ordinary launch.
5. Launch through the installed outer bundle. Repeat the native visibility, controls, duplicate, quit/relaunch and Settings update-check tests against the installed release.

Inline `codesign -R` requirements must begin with `=` so they are parsed as expressions, rather than filenames. Exercise the exact cask requirement against the signed release before publication, including rejection of an incorrect publisher.

The update client checks only stable numeric tags at the fixed repository endpoint. Release metadata never chooses commands, paths or asset URLs. A release API response is not permission to install arbitrary bytes.

## Retained-directory upgrade diagnosis

On the release Mac, Homebrew retained the 0.1.1 bundle directory while replacing its contents. Version 0.2.0 passed strict signature, stapling, `spctl` and `syspolicy_check distribution`, but its execution scan rejected it. An exact seven-file copy with quarantine preserved passed `gktool scan`; replacing only the installed bundle directory with that copy changed the installed scan to the normal first-open approval state. The original installed bundle was preserved locally. This isolates directory-associated execution-policy state; it does not establish a general Homebrew or macOS defect.

For this symptom, first capture both execution-scan results and verify identical signed bytes and preserved quarantine. A scoped fresh-directory replacement requires local app replacement authority and preservation of preferences/Application Support. Never clear security databases, disable Gatekeeper, remove quarantine, or reset unrelated apps. Verify normal first-open approval, the installed process and visible menu item afterward. Future normal upgrades should be tested before assuming this recovery is necessary.
