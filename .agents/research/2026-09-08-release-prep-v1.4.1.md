# Release Prep Report — v1.4.1 (Mac App Store)

**Date:** 2026-09-08
**Version:** 1.4.1 (Build 12)
**Release Type:** Patch (fixes only)
**Status:** Ready to upload (package built and signed; upload needs the account holder)

## Version Bump

- [x] MARKETING_VERSION: 1.4 → 1.4.1 (App Store Connect already has an approved 1.4, build 10)
- [x] CURRENT_PROJECT_VERSION: 10 → 12
- [x] CHANGELOG 1.4.1 dated 2026-09-08

## Build artefacts (gitignored, in `build/AppStore-1.4.1-12/`)

| File | Purpose |
|---|---|
| `DirStat-1.4.1-12.pkg` | App Store Connect upload package, signed "3rd Party Mac Developer Installer", app signed "Cloud Managed Apple Distribution", profile "Mac Team Store Provisioning Profile: com.macdirstat.app" |
| `DirStat-1.4.1-12.xcarchive` | The archive (Sparkle stripped: no Frameworks dir, no Sparkle load command; sandbox + user-selected read-write entitlements) |
| `exportOptions-appstore.plist` | `method=app-store-connect`, `signingStyle=automatic`, team L4UH9K7AW4 |
| `WhatsNew.txt` | Copy-paste release notes for App Store Connect |

## Code readiness

| Check | Status | Notes |
|---|---|---|
| Tests | ✓ | 156 tests, 0 failures (`swift test`) |
| Both configs build | ✓ | Release (Developer ID) and AppStore |
| Debug prints outside DEBUG | ✓ | none |
| Blocking TODOs | ✓ | one design note in AtomicDirectorySummary, not a blocker |
| Deployment target | ✓ | macOS 13.0 |
| Verified on a real disk | ✓ | Developer ID build: 881.2 GB shown vs 880 GB Finder used |
| Sandboxed build driven by hand | ✗ | not exercised this session (open panel needs a human); last verified 2026-08-25 |

## Privacy & compliance

| Check | Status | Notes |
|---|---|---|
| Privacy manifest | ✓ | `PrivacyInfo.xcprivacy`, UserDefaults reason CA92.1, no tracking, no collected data |
| Required-reason APIs | ✓ | UserDefaults declared; `volumeAvailableCapacity*` is macOS-only (no reason required on macOS) |
| Third-party SDKs in store bundle | ✓ | none (Sparkle physically stripped) |
| ATS exceptions | ✓ | none |
| Entitlements | ✓ | sandbox + files.user-selected.read-write only |
| Export compliance | ✓ | ITSAppUsesNonExemptEncryption=false |

## App Store metadata

| Check | Status | Notes |
|---|---|---|
| App icon | ✓ | 16…1024 present |
| What's New | ✓ | `WhatsNew.txt` |
| Screenshots | ? | existing listing screenshots predate the label/list changes; refresh if desired |
| Support / privacy URLs | ? | verify in App Store Connect |

## Upload

Either drop `DirStat-1.4.1-12.pkg` on Transporter, or from the repo:

```bash
xcodebuild -exportArchive \
  -archivePath build/AppStore-1.4.1-12/DirStat-1.4.1-12.xcarchive \
  -exportOptionsPlist build/AppStore-1.4.1-12/exportOptions-upload.plist \
  -allowProvisioningUpdates
```

where `exportOptions-upload.plist` is the export plist with `destination` set to `upload`. Then in App Store Connect: create version 1.4.1, attach build 12, paste `WhatsNew.txt`, submit for review.

## Post-release

- [ ] Confirm 1.4.1 live; existing store users get the legacy-defaults migration on first launch
- [ ] Watch crash reports 48 h
- [ ] Tag `v1.4.1` once the DMG track ships the same commit
