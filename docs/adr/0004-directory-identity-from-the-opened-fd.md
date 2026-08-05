# 0004. Decide directory identity, mount boundaries, and dedup from the opened directory, never the parent listing

## Status

Accepted, 2026-07-27.

## Context

The bulk enumerator (ADR 0002) added a TOCTOU (time-of-check-to-time-of-use)
guard: when a parent directory's listing reports an entry's `(dev, ino)`,
and the scanner later opens that entry to recurse into it, the guard
compared the opened directory's `(dev, ino)` against what the listing had
claimed and treated a mismatch as evidence that the entry changed out from
under the scan (swapped for a symlink, replaced, etc.), and dropped it.
That is a reasonable-sounding safety check, and it shipped as part of the
same commit that introduced batch enumeration.

It broke nearly the entire scan. Running MacDirStat on `/` reported
**11.8 GB used** instead of the real **479.3 GB** on the same machine.
`/Users`, `/Applications`, `/Library`, `/opt`, `/private`, `/Volumes`, and
`/cores` all came back as 0 bytes, and the missing ~818 GB was silently
folded into the synthetic "Hidden & Unreadable Space" node, so nothing
about the failure looked like an error, it just looked like a very
restricted disk. Since Users and Applications carry essentially all of a
typical Mac's non-system data, this was not an edge case: it was
functionally "the scanner doesn't work."

The cause: every one of those paths is a macOS firmlink. Since Catalina,
the boot volume is split into a read-only system volume and a writable
data volume, joined by firmlinks, kernel-level directory aliases that
present as ordinary directories in one namespace but resolve to a
different location, and a different inode, on the other volume. A parent
listing's `getattrlistbulk`/`readdir` entry for `/Users` reports the
firmlink's own identity; opening `/Users` and asking the open file
descriptor for its identity reports the Data volume's identity underneath.
Those two `(dev, ino)` pairs are supposed to disagree, that disagreement is
what a firmlink *is*, not evidence of a race. The TOCTOU guard, applied at
the listing level, could not tell a real swapped-directory attack apart
from completely ordinary firmlink resolution, and rejected both.

The existing bulk-vs-fallback parity test (ADR 0002) could not have caught
this: its fixture is a temporary directory with no firmlinks or mount
points, so both enumeration paths agreed with each other and both were
equally wrong about the real world.

## Decision

Directory identity, the mount-boundary check (is this entry on a different
volume than its parent, and should the scan cross it), and alias
deduplication (has this physical location already been visited under a
different path, e.g. `/Users` vs. `/System/Volumes/Data/Users`) are now all
decided from the *opened* directory, never from the parent listing's report
of it. Concretely: open the directory first, ask the open descriptor for
its `(dev, ino)`, and make every identity-sensitive decision from that
value. The listing is used only to know what names exist and to get a
cheap first-pass size/type hint; it is never treated as authoritative about
identity.

This is not just a bug fix but a strictly more correct model for two
things that were already true before firmlinks entered the picture:

- `/dev` enumerates with the root filesystem's device number, but is
  actually `devfs`; only the opened identity reveals that.
- Firmlink aliases only collide (resolve to the same underlying location)
  *after* opening; comparing pre-open identities can never detect the
  aliasing that alias-dedup exists to catch in the first place.

A regression test scans the real startup volume shallowly and asserts
`/Users` (or the equivalent well-known firmlink on the test machine) is
reported with nonzero size; it fails against the pre-fix commit with
`/Users` at 0 bytes, and passes after.

## Consequences

- Any future scanner change that adds a new identity-sensitive decision
  (a new dedup rule, a new mount-crossing rule, a new "have I seen this
  before" check) must key it off the identity obtained after `open()`,
  not off anything read from a parent directory's listing. This is the
  single most important invariant in the scanner: violating it silently
  drops firmlinked data with no error, no crash, and a plausible-looking
  (merely wrong) total.
- There is deliberately no TOCTOU guard left at the listing level anymore.
  A real swap-after-list race is not defended against by comparing
  listing-time identity to open-time identity, because that comparison
  cannot distinguish an attack from a firmlink. If TOCTOU hardening is
  wanted again, it needs a different signal than pre-open vs. post-open
  identity.
- Whoever touches this code next should re-run the shallow `/` scan
  regression test (not just the synthetic-fixture parity test) before
  trusting any change to enumeration, identity, or dedup logic; a synthetic
  temp-directory fixture will never exercise firmlinks and cannot catch
  this class of bug.
