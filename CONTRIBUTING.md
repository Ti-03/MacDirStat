# Contributing to MacDirStat

Thanks for considering a contribution. This page covers everything you need to
go from clone to merged PR without having to ask.

## Dev environment

```bash
git clone https://github.com/Ti-03/MacDirStat.git
cd MacDirStat
swift run          # builds and launches the app
```

Requires macOS 14+ and Xcode 15+. There are no third-party dependencies.
`MacDirStat.xcodeproj` works too if you prefer Xcode to SwiftPM.

## Run the tests

```bash
swift test
```

CI runs the same suite on a `macos-15` / `macos-26` matrix. One gotcha the
matrix exists to catch: runtime `#available(macOS 26, *)` checks do NOT make
code compile against an older SDK. Anything using a new-SDK symbol (like the
Liquid Glass APIs) also needs a compile-time `#if compiler(>=6.2)` guard; see
`GlassCompat.swift` and `docs/adr/0001` for the full story.

Docs changes are prose-linted by Vale (Microsoft style) in CI. Run locally
with `vale sync && vale guide docs/adr README.md`.

## File a bug

Use the bug report template. The three things that make a disk-scanner bug
reproducible: your macOS version, the kind of folder you scanned (roughly how
many files, any network mounts / iCloud placeholders / hardlinks), and what
the chart showed versus what you expected. Screenshots help a lot.

Do not report security issues in public issues; see [SECURITY.md](SECURITY.md).

## PR conventions

- **Issue first** for anything bigger than a bug fix or typo, so we agree on
  the direction before you spend your evening on it.
- Keep PRs single-purpose and reviewable in one sitting.
- PR description follows What / Why / How / Test (the template scaffolds it).
- `swift test` green locally before pushing; CI must be green to merge.
- New behavior comes with a test; bug fixes come with the test that would
  have caught the bug.

## Licensing of contributions

MacDirStat is AGPL-3.0, and the same app also ships on the Mac App Store
(as DirStat), which is possible because the maintainer holds the copyright.
By contributing you agree that your contribution is licensed under
AGPL-3.0-only and that you grant the maintainer permission to distribute
your contribution as part of the Mac App Store build. If you are not
comfortable with that, say so in the PR and we will talk before merging.

## Review expectations

Solo maintainer. Honest service levels:

- First response on a PR or issue: within a week, usually faster.
- One-on-one debugging support is not something I can offer; a minimal
  reproducible example in an issue is the reliable way to get my attention.
- Features that add API or UI complexity to serve a narrow use case will
  usually get a "no, but here is how a fork could do it" rather than a merge;
  see [GOVERNANCE.md](GOVERNANCE.md) for how decisions are made.
