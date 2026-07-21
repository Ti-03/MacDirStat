<div align="center">

<img src="logo.png" width="120" alt="MacDirStat icon" />

<h1>MacDirStat</h1>

<p><strong>See where your disk space went.</strong><br/>
A fast, beautiful macOS disk usage visualizer — built entirely in Swift.</p>

[![CI](https://github.com/Ti-03/MacDirStat/actions/workflows/ci.yml/badge.svg)](https://github.com/Ti-03/MacDirStat/actions/workflows/ci.yml)
[![App Store](https://img.shields.io/badge/Mac_App_Store-Download-0D96F6?style=flat-square&logo=apple)](https://apps.apple.com/app/dirstat/id6766033292?mt=12)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue?style=flat-square)](./LICENSE)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support-FF5E5B?style=flat-square&logo=ko-fi)](https://ko-fi.com/ti003)

</div>

---

![MacDirStat demo](demo.gif)

---

## What it does

MacDirStat scans any folder and turns your filesystem into an interactive sunburst chart — every ring is a depth level, every arc is a file or folder, sized by disk usage. Hover to inspect. Click to drill in. Right-click to delete.

## Features

- **Sunburst visualization** — depth rings, color-coded by file type (video, code, images, archives…)
- **Spotlight hover** — everything else fades when you hover; selected files pulse with a glow
- **Force Touch haptics** — soft tap for small files, triple thud for multi-GB ones
- **Drill navigation** — click any folder to zoom in, click back to go up
- **Duplicate detection** — finds identical files by content hash, shows wasted space per group
- **One-click cleanup** — keep one copy, trash the rest — or delete file by file
- **File list panel** — sortable tree view beside the chart, toggle to give the chart full width
- **File type breakdown** — top file types with a searchable list of all types
- **Move to Trash** — right-click any arc or row to trash it, chart refreshes instantly
- **CSV export** — dump the full scan as a spreadsheet
- **Settings** — toggle haptic feedback on/off

## Screenshots

| Full view | File types | Expanded types |
|---|---|---|
| ![](docs/screenshot1.png) | ![](docs/screenshot2.png) | ![](docs/screenshot3.png) |

## Install

**[Download on the Mac App Store](https://apps.apple.com/app/dirstat/id6766033292?mt=12)** — published as **DirStat**.

Or grab the DMG directly from **[Releases](https://github.com/Ti-03/MacDirStat/releases)** — open it and drag the app to your Applications folder. It updates itself automatically via the Help menu once installed.

**Build from source**

```bash
git clone https://github.com/Ti-03/MacDirStat.git
cd MacDirStat
swift run
```

Requires macOS 14+ and Xcode 15+.

### Verify a release

Releases from `v1.2.0` on are signed with [Sigstore](https://www.sigstore.dev)
cosign, keylessly, by the release workflow itself. The signature proves the
artifact was built by this repo's `release.yml` at that tag and was not
tampered with afterwards. To check, download the `.zip`, `.sig`, and `.pem`
from the release and run:

```bash
cosign verify-blob \
  --certificate MacDirStat-v1.2.0.zip.pem \
  --signature MacDirStat-v1.2.0.zip.sig \
  --certificate-identity-regexp 'https://github.com/Ti-03/MacDirStat/\.github/workflows/release\.yml@refs/tags/v.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  MacDirStat-v1.2.0.zip
```

`Verified OK` means the artifact matches the signature and the signing
identity was this repo's release workflow. Every signature is also logged in
the public [Rekor](https://docs.sigstore.dev/logging/overview/) transparency
log.

## Tech

Pure Swift + SwiftUI — no Electron, no web views, no dependencies.

| Layer | What |
|---|---|
| Scanner | POSIX `opendir`/`fstatat` with async task groups — parallel, cancellable |
| Layout | Custom sunburst partition algorithm (band-width from view size) |
| Renderer | SwiftUI `Canvas` — draws 1,000+ arcs at 30 fps |
| Haptics | `NSHapticFeedbackManager` — intensity scales with file size |
| Duplicates | SHA-256 content hashing on a background actor |

## Documentation

Tutorial, how-to guides, and API reference: **[docs site](https://ti-03.github.io/MacDirStat/guide/)**. Architecture decisions are recorded in [`docs/adr/`](docs/adr).

## Privacy

MacDirStat collects zero data. No network access. No analytics. No tracking. Everything runs on your device. [Full privacy policy](https://ti-03.github.io/MacDirStat/privacy.html).

## Contributing

PRs welcome. Open an issue first for anything beyond a bug fix.

---

<div align="center">
Built with ❤️ by <a href="https://ti0.me/">Ti</a> &nbsp;·&nbsp; <a href="https://apps.apple.com/app/dirstat/id6766033292?mt=12">Mac App Store</a> &nbsp;·&nbsp; <a href="https://ti-03.github.io/MacDirStat/">Website</a> &nbsp;·&nbsp; <a href="https://ko-fi.com/ti003">Support on Ko-fi</a>
</div>
