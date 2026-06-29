# CI workflow journal

Week 5 (Testing, CI/CD & GitHub Actions). Notes from adding `.github/workflows/ci.yml`
to MacDirStat.

## The workflow

A single matrixed job, `build-test`, runs on every push to `main` and every PR:

- **runs-on:** `macos-14` and `macos-15` (the matrix, MacDirStat is a macOS-only
  SwiftUI app, so it cannot build on Linux runners).
- **Caching:** SwiftPM `.build` + `~/Library/Caches/org.swift.swiftpm`, keyed on `Package.resolved`.
- **Build (static-analysis gate):** `swift build`. The Swift compiler type-checks and, with
  `StrictConcurrency` enabled in `Package.swift`, concurrency-checks all production code. This
  is the Swift equivalent of the "static analysis" base of the Testing Trophy.
- **Test:** `swift test` (20 tests).
- **Badge:** added to `README.md`.

## Why no `swift-format` lint gate

`swift format` is available, but the existing code has ~3,700 violations against swift-format's
defaults (3,404 are indentation alone). A formatting gate would have meant reformatting the entire
codebase, which is out of scope for "add CI." The compile step (with StrictConcurrency) serves as
the static-analysis gate instead. Adopting swift-format with an agreed `.swift-format` config is a
sensible future follow-up.

## Bugs found while wiring up CI

Getting the suite to even compile surfaced three real problems:

1. **`Sparkle` missing from `Package.swift`.** The source does `import Sparkle`, but the dependency
   was only declared in the Xcode project, not the SPM manifest. So `swift build` / `swift test`
   failed from the command line (and would fail in any SPM-based CI). **Fix:** added Sparkle 2.9.1
   to `Package.swift` and linked it to the target.

2. **Stale `TreemapLayoutTests`.** Six tests asserted on `TreemapCell.rect`, but the treemap was
   redesigned from a rectangular layout into a radial sunburst (`startAngle` / `endAngle` /
   `innerRadius` / `outerRadius`). **Fix:** rewrote the six tests against the radial model,
   preserving each test's intent (e.g. "larger items get larger cells" → larger angular span).

3. **Wrong `ByteFormatter` test expectation.** `test_byte_formatter_gb` expected `1.0 GB` for
   `1024^3` bytes, but `ByteFormatter` defaults to decimal (SI) units, so it returns `1.1 GB`.
   The KB/MB cases happened to round to `1.0` and hid the bug. **Fix:** switched the tests to
   decimal inputs and pinned the `useBinarySize` default in `setUp` for determinism.

None of these were caught before because the suite never compiled (the Sparkle gap).

## `act` and macOS: the Task-3 limitation

`act` runs GitHub Actions locally using **Linux Docker containers**. A macOS job
(`runs-on: macos-14`) cannot be reproduced with `act`, there is no macOS container image (Apple
licensing forbids macOS in Docker). Running `act -j build-test` only offers Linux base images,
which can't build a macOS SwiftUI + Sparkle app.

**Conclusion:** for a macOS app, the local-`act` feedback loop is not available. Verification is
done by pushing and watching GitHub Actions, or by running `swift build` / `swift test` directly
on a Mac (which is what was done here, all 20 tests pass locally).

## The matrix earned its keep: a "works on my machine" SDK bug

The very first CI run was **red on both `macos-14` and `macos-15`**, despite a clean local
`swift build`/`swift test`. The cause is exactly the class of bug the OS matrix exists to catch:

- `GlassCompat.swift` calls `glassEffect(...)` and `.buttonStyle(.glass)`, which are **macOS 26
  (Liquid Glass) APIs**. They only exist in the macOS 26 SDK (Xcode 26 / Swift 6.2).
- My local machine runs macOS 26 with the Xcode 26 SDK, so it compiled fine. GitHub's `macos-14`
  / `macos-15` runners ship Xcode 16.x with the macOS 14/15 SDK, where those symbols **do not
  exist**, so the build failed (~300 errors, plus cascading errors in `ContentView` which calls
  the helpers).
- The original code guarded the calls with `if #available(macOS 26, *)`. That is a **runtime**
  check, it does not stop the compiler from needing the symbol at build time. So `#available`
  alone cannot make code compile against an SDK that lacks the API.

**Fix:** wrap each macOS-26-only call in a **compile-time** `#if compiler(>=6.2)` (Swift 6.2 ships
with the Xcode 26 / macOS 26 SDK). Older toolchains compile only the `NSVisualEffectView`-based
fallback; the runtime `#available` stays inside the new-SDK branch so an Xcode-26 build still
back-deploys correctly to macOS 14/15. After this fix the matrix goes green on all runners.

**Lesson:** a green local build proves nothing about other SDKs. The OS matrix turned a latent
portability bug (that would have bitten anyone building the package without the macOS 26 SDK) into
a one-PR fix.
