# 0001. Guard Liquid Glass APIs with a compile-time check, not just `#available`

## Status

Accepted, 2026-06-29.

## Context

MacDirStat's UI uses macOS 26's Liquid Glass APIs (`glassEffect`,
`.buttonStyle(.glass)`) so the app looks native on macOS 26, while still
running on macOS 14/15 via a fallback to `.ultraThinMaterial`. The existing
code guarded every call with a runtime check:

```swift
if #available(macOS 26, *) {
    self.glassEffect(in: .capsule)
} else {
    self.background(.ultraThinMaterial, in: Capsule())
}
```

This looked correct and built successfully on the local development
machine. But `#available` is a *runtime* check: it decides which branch
*executes*, not which branch the compiler is allowed to *see*. The
`glassEffect` symbol only exists in the macOS 26 SDK (Xcode 26, Swift 6.2).
Compiling this file against an older SDK, such as the one available on the
`macos-15` GitHub Actions runner, fails outright, because the compiler
still has to type-check the `if` branch even though it will never run on
that OS at runtime.

This was invisible locally because the development Mac only had the
macOS 26 SDK installed. It surfaced only once a CI matrix build (`[macos-15,
macos-26]`, added the same week to test SDK compatibility) tried to compile
the project against the macOS 15 SDK and failed.

## Decision

Wrap every Liquid Glass call site in `GlassCompat.swift` with a
*compile-time* guard, `#if compiler(>=6.2)`, around the existing runtime
`#available` check:

```swift
@ViewBuilder
func glassCapsule() -> some View {
    #if compiler(>=6.2)
    if #available(macOS 26, *) {
        self.glassEffect(in: .capsule)
    } else {
        self.background(.ultraThinMaterial, in: Capsule())
    }
    #else
    self.background(.ultraThinMaterial, in: Capsule())
    #endif
}
```

`#if compiler(>=6.2)` is resolved by the compiler before type-checking, so
on an older toolchain the entire `glassEffect` branch is never parsed, let
alone type-checked. The runtime `#available` check stays inside the
compile-time branch, so a build made with Xcode 26 still back-deploys
correctly to macOS 14/15 at runtime.

We also dropped `macos-14` from the CI matrix: its SDK predates both
`glassEffect` and the `ContentUnavailableView` backport check, so it cannot
build this project at all regardless of guards, and keeping it would only
produce a permanently red, unfixable job.

## Consequences

- Every new Liquid Glass call site must use the same double guard
  (`#if compiler(>=6.2)` wrapping `#available(macOS 26, *)`), not
  `#available` alone. A future contributor who copies an existing
  `#available`-only pattern from elsewhere in SwiftUI code will reintroduce
  this bug; there is no compiler warning for it.
- The CI matrix (`macos-15`, `macos-26`) is now load-bearing: it is the
  only thing that would have caught this before it shipped, since a
  single-SDK local build cannot reproduce the failure.
- Slightly more boilerplate per call site (two nested conditionals instead
  of one), in exchange for the app actually compiling on the SDK most
  users' Macs currently have.
