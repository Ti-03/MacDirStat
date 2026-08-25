# 0002. Ship two distribution tracks from one target, split by build configuration

## Status

Accepted, 2026-08-25.

## Context

DirStat goes out two ways, and the two ways contradict each other:

- **Developer ID / notarized DMG** from GitHub Releases. Unsandboxed, so it can
  hold Full Disk Access and chart an entire volume. Ships Sparkle so it can
  update itself.
- **Mac App Store** (`com.macdirstat.app`, app id 6766033292). The store
  requires the App Sandbox, which permanently rules out Full Disk Access. It
  also bars self-updaters under guideline 2.4.5, and Sparkle nests `Updater.app`
  plus XPC services inside its framework, which fails upload validation on
  nested-bundle grounds before a human ever sees it.

The repo had drifted onto the Developer ID track alone: `MacDirStat.entitlements`
turned the sandbox off in commit `319117c` so Full Disk Access would work. The
App Store listing was left behind at 1.0, because the tree could no longer
produce a build the store would accept.

## Decision

One app target, three build configurations. `AppStore` differs from `Release`
in exactly four ways:

| | Release (Developer ID) | AppStore |
|---|---|---|
| Entitlements | `MacDirStat.entitlements`, sandbox **off** | `MacDirStat-AppStore.entitlements`, sandbox **on** + `files.user-selected.read-write` |
| Info.plist | `Info.plist`, Sparkle feed keys present | `Info-AppStore.plist`, no Sparkle keys, no FDA usage string |
| Swift flags | none | `APPSTORE` compilation condition |
| Linker | default | `-Wl,-dead_strip_dylibs` |

`Build.isAppStore` in `MacDirStatApp.swift` reads the compilation condition once
so the rest of the app can branch on a plain constant instead of scattering
`#if` blocks. It switches off the Full Disk Access probe, banner, sheet, and
menu item, none of which mean anything in a sandbox.

Two consequences follow from the sandbox and are deliberate, not oversights:

- The App Store build scans only what the user hands it through the open panel.
  There is no whole-disk view. Read-write is requested because the treemap and
  duplicate views move files to the Trash.
- "Auto-scan last folder" cannot work from a stored path, because a sandboxed
  app loses access at exit. `ScanViewModel.rememberLastScannedFolder` stores a
  security-scoped bookmark for App Store builds and a plain path otherwise.

## Why not a second target

A duplicate target is the textbook answer, because SwiftPM product
dependencies attach to a target and cannot be scoped to a configuration, so the
`AppStore` configuration still links and embeds Sparkle. Instead: the `APPSTORE`
condition removes every Sparkle call, `-dead_strip_dylibs` drops the now-unused
load command, and a `Strip Sparkle (App Store)` shell phase deletes the embedded
framework. Xcode signs the bundle after that phase runs, so the signature comes
out valid over the stripped bundle. The phase re-checks with `otool -L` and fails
the build if the load command survived, because a stripped app that still
references Sparkle would crash on launch.

That is three moving parts against a duplicate target's ongoing cost of keeping
two source lists, two phase lists, and two settings blocks in step. If the strip
ever gets fragile, the second target is the upgrade path.

## Consequences

- Archive the store build with `-configuration AppStore`; the DMG workflow keeps
  using `-configuration Release` and is untouched.
- The store build needs an **Apple Distribution** certificate. The existing
  "Mac Team Store Provisioning Profile: com.macdirstat.app" is valid to
  2027-05-03.
- The two tracks now share a version number. Both read `MARKETING_VERSION`.
