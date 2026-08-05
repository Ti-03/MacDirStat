# 0002. Enumerate directories with getattrlistbulk, not per-entry stat

## Status

Accepted, 2026-07-24.

## Context

The scanner's previous directory walk did what most POSIX code does: open a
directory, call `readdir` to get one entry's name, then call `fstatat` on
that name to get its metadata (size, type, inode). That is two syscalls per
entry, and on a directory with thousands of files (a `node_modules`, a
Photos library, a build output folder) that means thousands of syscalls
just to enumerate one directory, before any of the actual scanning work
happens.

Traversal itself compounded the problem: each directory spawned a new
recursive task for every subdirectory it found, with no cap. On a wide,
shallow tree (again, `node_modules` is the canonical case) this could fan
out into far more concurrent tasks than the machine has cores to run them
on, all contending for the same thread pool.

macOS offers `getattrlistbulk(2)`, a single syscall that returns a batch of
directory entries with their names and requested attributes (size, type,
inode, flags) together, amortizing the syscall cost across the whole batch
instead of paying it per entry. Not every filesystem or mount supports it,
though (some network and legacy filesystems don't), so it cannot be the
only path.

## Decision

Replace the `readdir`/`fstatat` pair with `getattrlistbulk(2)` as the
primary enumeration path in `BulkDirectoryEnumerator`, requesting name and
all previously-`fstatat`'d metadata in one call per batch. Keep a
`readdir`-based fallback path for volumes that reject `getattrlistbulk`
(detected by the syscall itself failing, not by pre-checking filesystem
type), so no volume becomes unscannable.

Change traversal from unbounded recursive task fan-out to an iterative work
queue drained by a bounded worker pool sized
`min(max(2, cores/2), 8)`: enough parallelism to keep disk and CPU busy,
capped so a wide directory tree cannot spawn more concurrent work than the
machine can usefully run.

All existing scan semantics (allocated vs. logical size, symlink/hidden/
exclusion skips, mount-point and hardlink dedup, access-denied surfacing)
are preserved identically in both the bulk and fallback paths, and a
fingerprint test scans the same fixture tree once with bulk enumeration and
once with the fallback forced, asserting the resulting trees are identical
byte-for-byte in every field that matters. The public `FileScanner`/
`FSNode`/`ScanProgress` API is unchanged, so this is purely an internal
rewrite.

Measured on `/Applications`: 1.63s with `getattrlistbulk` vs. 2.02s with
the `readdir` fallback, on the same machine and directory.

## Consequences

- Two enumeration code paths now exist and must be kept in sync; the
  parity test is the thing that makes that safe; anyone changing what a
  scan captures (a new attribute, a new skip rule) must update both paths
  or the parity test will (correctly) fail.
- The bounded worker pool means a scan of a very wide, shallow tree no
  longer transiently spikes to thousands of concurrent tasks, at a small
  cost in wall-clock time on such trees compared to fully unbounded
  fan-out; this trade was accepted because unbounded fan-out was also
  the root cause of thread-pool exhaustion bugs fixed later on this branch
  (see the async summary-walk fix).
- `getattrlistbulk` returning inode/device information here is what later
  interacted badly with macOS firmlinks (see ADR 0004): the enumerator's
  own report of an entry's identity cannot be trusted for firmlinked
  directories, only what you get back from actually opening them.
