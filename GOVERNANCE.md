# Governance

## The model: BDFL

MacDirStat is maintained by one person, [Qutibah Ananzeh](https://github.com/Ti-03)
(Ti-03), who has final say on every decision: what gets merged, what the
roadmap is, when releases happen, and what the project will not do. This is
the honest description of how a one-maintainer project works, written down
because implicit governance is the worst kind.

## How decisions are made

- **Bug fixes:** if it is broken and the fix has a test, it gets merged.
- **Features:** open an issue first. The bar is "does this serve the core
  job (see where your disk space went) without adding complexity everyone
  else pays for". If you disagree with a decision, file an issue and make
  the case; decisions get reversed when the argument or the evidence is
  better, not when it is louder.
- **Breaking changes** to file formats, CLI behavior, or the public docs
  structure get an ADR in `docs/adr/` before they land.

## What a "no" looks like

A "no" here comes with a reason and, where possible, an alternative: usually
"maintain it as a fork, and I will link it from the README". A "not now" means
the idea is fine but unstaffed; a PR that includes maintenance (tests, docs)
changes that answer.

## Path to shared maintainership

If someone shows up with a run of quality PRs and sticks around through a few
review cycles, commit access is on the table. If that happens, this document
gets rewritten first: at two maintainers, "the founder decides" stops being
governance and starts being a bottleneck.

## Releases

The maintainer tags releases (SemVer). From v1.2.0 they are signed with
Sigstore cosign by the release workflow; verify per the README.
