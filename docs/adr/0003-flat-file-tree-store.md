# 0003. Replace the FSNode class tree with a flat struct-of-arrays store

## Status

Accepted, 2026-07-24.

## Context

The app's in-memory representation of a scan was a tree of `FSNode` class
instances: one heap-allocated object per file and folder, each holding a
`URL`, a `UUID`, a size, a type, an array of child references, and a weak
parent reference. That is a natural way to model a filesystem tree, and it
made the early implementation straightforward, but it does not scale well:

- Every file and folder in a scan is a separate heap allocation and a
  separate reference-counted object, which is slow to allocate in bulk and
  slow for ARC to tear down when a scan is discarded or replaced.
- Sorting children by size, walking the tree for layout, or searching by
  path all chase pointers through scattered heap objects instead of
  scanning contiguous memory, which is unfriendly to the CPU cache on
  scans with hundreds of thousands of nodes.
- A `URL` and a `UUID` per node is more retained state per node than a
  treemap actually needs to render and interact with a chart: identity for
  UI purposes doesn't require a real `URL`, and the path can always be
  rebuilt from parent links when it's actually needed (opening in Finder,
  computing a delete target).

On the auto-summarization work (ADR-adjacent, not its own ADR) this became
a hard blocker: summarizing away a folder full of tiny files back into
individual `FSNode`s only for them to be discarded again the moment the
summary collapses them was pure waste, both in time and peak memory.

## Decision

Replace `FSNode` as the model layer's tree representation with `FileTree`,
a flat struct-of-arrays store: a `FileNodeRecord` per node holds only what
the UI and business logic actually need (name, size, type, safety level,
hardlink ref), stored in a single contiguous `records` array. Parent/child
relationships are represented as an index into that array (a
`UInt32`-style parent index per record) plus a `childStart`/`childCount`
span describing a contiguous run of children, rather than child arrays or
object references. `FileNode` is a lightweight handle (effectively an
index plus a reference to the owning `FileTree`) that call sites use in
place of the old class reference; paths are reconstructed on demand by
walking parent indices up to the root, not stored per node.

`FSNode` is kept, deliberately, as the scanner's internal build type: the
scanner still constructs a tree incrementally while walking the
filesystem, where a class tree with real parent/child object references is
the natural shape for that job (nodes get created, reparented, and
summarized away before the scan finishes). Once a scan completes, it is
converted once into a `FileTree`, which is what the rest of the app (view
model, layout, duplicates, compare, archive) operates on from then on.
Everything downstream of the scanner only ever sees `FileTree`.

The split that makes later live-refresh and hardlink work tractable is
that a `FileTree`'s topology (the parent indices and child spans) is
treated as effectively immutable once built, and reshaped only through a
small number of whole-operation functions (`replacingSubtree`,
`removingSubtrees`, `promotingSurvivingTwin`) that rebuild the affected
spans and ancestor sizes in one pass, rather than through ad hoc mutation
of individual records. Per-record fields that do change in place, size
above all, are mutated directly in the `records` array without touching
topology at all.

## Consequences

- Real numbers from the migration: `swift build`/`swift test` stayed fully
  green throughout (the migration touched essentially every test file),
  and the store change alone, independent of auto-summarization, is what
  made scans of hundreds of thousands of nodes practical to hold in memory
  and sort/lay out responsively.
- Every consumer of the tree (layout, duplicates, compare, archive,
  live-refresh) works in terms of `FileNode` handles and `FileTree`
  queries, not object references; code that assumes it can hold a stable
  reference to "a node" across a topology-mutating operation is wrong by
  construction; handles must be re-resolved after any `replacingSubtree`/
  `removingSubtrees` call.
- The immutable-topology/mutable-fields split is what several later fixes
  on this branch depend on being respected: the synthetic "Hidden &
  Unreadable Space" node bug (records/parentIndex extended but childStart/
  childCount left one entry short) and the ancestor re-sort gap after
  hardlink removal were both violations of this split slipping through
  because a new code path mutated part of the arrays without going through
  the shared span-rebuilding helpers. `FileTree`'s initializer now asserts
  all per-node arrays are the same length specifically to catch the first
  kind of gap at construction time instead of at some distant read.
- `.mdscan` archives serialize `FileNodeRecord`/`HardLinkRef`/
  `SafetyLevel` directly (they're `Codable`), which is only straightforward
  because they are plain value types with no object graph to break out of;
  this would have been considerably more awkward to do safely with the old
  `FSNode` class tree.
