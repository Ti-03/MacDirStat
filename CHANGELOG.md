# Changelog

All notable changes to MacDirStat are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.4.0] - Unreleased

A correctness release: the scan total is now right by default, and a long
list of user-visible bugs found in an end-to-end audit are fixed.

### Fixed

- **Totals were wrong by default.** The factory settings excluded `.git`,
  `node_modules`, `DerivedData` and `.Trash` and skipped every hidden entry,
  so a real 7.5 GB project scanned as 40 MB. Nothing is excluded now and
  hidden entries are counted; dependency and cache trees (`node_modules`,
  `.git`, `Pods`, `.next`, `.venv`, ...) are collapsed into a single row
  instead of dropped. Existing installs that still carry the old default
  list are migrated once; a customised list is left alone. Verified
  byte-for-byte against `du`.
- The duplicate finder could report two different files as duplicates when
  they shared the same on-disk size and first 64 KB (sparse or compressed
  files), so "Delete All Duplicates" could trash a distinct file.
- Errors from scanning, saving, opening, comparing, exporting and trashing
  were recorded but never shown; they now appear as an alert.
- A flat folder with a few hundred similar-size files drew an empty chart
  labelled "This folder contains no files".
- Collapsed folders (`node_modules` and friends) could be drilled into,
  leaving an empty chart with the Back control hidden.
- Purgeable space (local snapshots, evictable caches) was reported as
  "Hidden & Unreadable Space" on volume scans; the figure now matches what
  Finder counts as used. Full Disk Access is detected by actually opening a
  protected file, on either TCC database (issue #24).
- A scan that finished while a newer scan or archive load was in progress
  could install its results over the newer one, keep watching the old
  folder, or flip a live scan read-only.
- Live refresh did its disk walk on the main thread (UI stalls during
  builds) and could resurrect a folder that had just been trashed.
- Trashing while duplicate detection was still running left "Scanning for
  duplicates…" spinning until the next rescan.
- Symlinked scan roots (`/tmp`, alias folders) failed with a raw error
  instead of scanning their target.
- Chart labels no longer print on top of each other or spill past their
  arc ("PlugInsMediaProvMotionEffect.fxp"); long names are middle-truncated
  to fit, labels that would be meaningless are dropped, and inner-ring
  labels slide clear of the center disc instead of being cut off by it.
- The file list panel was narrow enough that names truncated to three
  letters ("Fina…"); it now keeps room for the name column.
- Smaller polish: clicking empty chart space clears the selection (and the
  30 fps pulse timer that ran forever after the first click); the synthetic
  hidden-space row no longer offers Reveal/Copy Path/Trash or shows up in
  the legend as "(directory)"; extensionless files are "(no extension)";
  the legend recolors with the color scheme and sizes refresh when the
  unit style changes; "1000.0 KB" now reads "1.0 MB"; selected list rows
  are readable in light mode; expansion state and duplicate-group
  expansion survive deletes; the sidebar Duplicates link that stranded the
  user in the detail pane is gone; Export CSV is disabled with no scan
  loaded; the toolbar shows progress while comparing.

## [1.3.0] - 2026-08-04

A performance-focused release: the scanner, the in-memory tree, and live
refresh were all rebuilt for speed on very large volumes, plus new ways to
save, reopen, and compare scans.

### Added

- **Auto-summarization of dependency and cache folders**: directories like
  `node_modules` (and anything else that looks like thousands of tiny
  files, by heuristic) collapse into a single summary row carrying the
  total size and file count, instead of building a chart node for every
  file inside. On a real Projects folder this cut a scan from 16.0s /
  910,550 nodes to 8.6s / 104,551 nodes, with byte-identical totals.
- **Save and reopen scans**: File > Save Scan... writes the current scan to
  an `.mdscan` file; File > Open Scan... reopens it later as a read-only
  snapshot (no delete actions, no live watching), with a banner showing
  when it was captured. Opening a corrupted or tampered file surfaces an
  error instead of crashing.
- **Compare two scans**: File > Compare With Saved Scan shows what changed
  between now and a saved snapshot: added, removed, grown, shrunk, and
  files that were replaced by a folder (or vice versa) at the same path. A
  whole added or removed directory collapses into a single row instead of
  listing every file inside it.
- **Drag-to-grant Full Disk Access**: the guided permission sheet now shows
  the running app's own icon as a draggable tile, so granting access can't
  accidentally target the wrong build sitting in a file picker (macOS ties
  the grant to one exact copy). A "Show this app in Finder" fallback covers
  drag-and-drop from a Finder window instead.
- **Permissions section in Settings**: check and fix Full Disk Access
  directly from Settings, with a live coloured-dot status, the same
  drag-to-grant tile, and a direct link to the right System Settings pane.

### Changed

- The scanner now enumerates directories with `getattrlistbulk(2)`,
  reading names and metadata in one batched syscall per directory instead
  of one `readdir` plus one `fstatat` per entry, with a `readdir` fallback
  for filesystems that don't support it. Traversal itself moved from
  unbounded recursive fan-out to a bounded worker pool, so a scan no longer
  spawns more concurrent work than the machine can use.
- The in-memory scan result is now a flat, contiguous store instead of a
  tree of individual objects per file and folder, which noticeably lowers
  memory use and speeds up sorting and layout on very large scans.
- Live refresh (the automatic re-scan while a folder is open and being
  watched) now patches only the part of the tree that actually changed
  instead of rescanning the whole root, so background file activity no
  longer causes a visible full reload.
- Move to Trash now removes the deleted item from the current scan
  directly instead of triggering a full rescan, so deleting from the
  Duplicates view no longer bounces you back to the Treemap tab. Fixes
  [#5](https://github.com/Ti-03/MacDirStat/issues/5).

### Fixed

- Scanning `/` (or any volume root) could dramatically under-report disk
  usage, in one case showing 11.8 GB instead of the real 479.3 GB, because
  `/Users`, `/Applications`, `/Library`, `/opt`, `/private`, `/Volumes` and
  `/cores` are macOS firmlinks and were being silently dropped as 0 bytes.
  Directory identity, mount-boundary checks, and alias de-duplication are
  now all decided from the opened directory instead of from what the
  parent folder's listing claimed, which is the only place a firmlink
  resolves correctly.
- A background summarization pass (used for `node_modules`-style folders)
  could, under load, block every available concurrency thread at once and
  wedge a scan so it never finished and could not be stopped. It is now
  fully asynchronous end to end.
- Scanning a volume root and then letting a live file change happen could
  crash the app outright ("Index out of range") because of a bookkeeping
  gap in the synthetic "Hidden & Unreadable Space" entry.
- A live filesystem change that couldn't be folded into the current scan
  incrementally could escalate into a full rescan that cleared the
  Treemap mid-render and then repeated forever. Such changes are now
  skipped with a "Rescan" button offered instead, rather than looping.
- Comparing two scans now reports a file replaced by a folder (or a folder
  replaced by a file) at the same path as a change, instead of dropping it
  from the results entirely.
- Fixed several cases where disk usage from hardlinked files could be
  under- or double-counted after trashing a file, after a live refresh, or
  after an external process (Finder, `rm`, a build tool) deleted the copy
  that was carrying the reported size, including ordering glitches in
  ancestor folders left over from the fix.
- The Full Disk Access sheet no longer claims "Access granted!" when the
  most recent scan still hit denied folders; it only shows success for a
  grant it actually watched happen while it was open.
- GitHub Releases now include a proper `.dmg` installer image alongside
  the signed zip, instead of shipping only a bare executable archive.
  Fixes [#22](https://github.com/Ti-03/MacDirStat/issues/22).

Test suite grew from 50 to 142 tests across this cycle, all passing.

## [1.2.0] - 2026-07-24

- MkDocs Material documentation site and the first Architecture Decision
  Record.
- Unit tests and a GitHub Actions CI workflow.
- Dependabot, Actions pinned to commit SHAs, and a least-privilege CI
  token (OpenSSF Scorecard fixes), plus a SECURITY.md.
- Sigstore-signed release artifacts (keyless cosign).
- CONTRIBUTING, CODE_OF_CONDUCT, GOVERNANCE, issue templates, and a
  license notice for the community.

## [1.1] - 2026-05-10

- macOS 13 Ventura and later are now supported (previously macOS 26 only).
- The Liquid Glass UI gracefully falls back on older macOS versions.

## [1.0] - 2026-05-04

- First public release.
