---
name: l2-source-verification-proposal
status: proposed (separate reviewed change; not implemented)
created: 2026-10-22T02:20:00Z
updated: 2026-10-22T02:20:00Z
---

# Strict full-file source verification for lineage packages (proposal)

Raised by the independent review of 2026-10-22: `ProjectsModel.fileFingerprint(atPath:)` hashes only a file's size plus its first and last 4 MB, and reads inside it are optional (`try?`), so a read failure can silently shorten what is hashed. The L2 preflight's `sources-not-protected` and `sources-disjoint-across-splits` checks (D-018) rest on those fingerprints. This page proposes a strict mechanism alongside them, without changing any existing identity or ledger.

## What the partial fingerprint is for, and what it cannot prove

`file:<sha256 of size ‖ head 4 MB ‖ tail 4 MB>` is the project's **provenance identity** for a video file: it is stored in `project.json` (`fingerprint`), used by `ReservedVideos.closure` to link aliases, written into the manifest's identities and the exposure ledger, and recognises a copied or renamed file quickly. It must stay exactly as it is: changing it would re-identify every video and break the ledgers' history.

It cannot prove two files are byte-identical, and because its reads are `try?`, a file whose middle cannot be read still yields a fingerprint. For the leak check — *is the video behind a packaged clip the same recording as a withheld one?* — that is a weaker guarantee than the rest of the preflight gives (every package file and every protected image is fully hashed).

## Proposal

1. **A full-file SHA-256 per source, computed in the preflight, kept separate from the identity.** `LineagePackage.sourceDigests(of:)` reads each packaged clip's video from start to end (streaming, 4 MB chunks) and every withheld recording's video and cut file the same way (the same set `protectedSourceFingerprints` covers); the result is recorded as `sha256:<hex>` next to the existing `file:` value in the preflight record (`sourceFingerprints` → `sourceDigests`, `protectedSourceFingerprints` → `protectedSourceDigests`). Nothing is written to `project.json`, the manifest or the ledger; identities and aliases are untouched.
2. **Fail closed on any read error.** No `try?`: a file that cannot be opened, whose `stat` size disagrees with the bytes read, or whose read stops short throws `SourceError.sourceUnreadable`, and nothing is packaged. The same `stat`-errno rule as `protectedFrames` (absent vs unreachable) applies to withheld sources: absent → `protectedSourceUnknown` (already fatal); unreachable → `sourceUnreadable`.
3. **Two more checks**, mirroring the partial ones: `sources-not-protected-full` (no packaged source digest equals a withheld one) and `sources-disjoint-across-splits-full` (no digest on both the train and val side). Both must pass; the partial checks stay (they catch a cut file whose head and tail match a withheld video even when the full hashes differ).
4. **Reconciliation written into the record**: the count of sources hashed on each side, the count of withheld sources hashed, and an explicit list of any withheld recording that contributed only link identities (`youtube:`…) and no file — which `protectedSourceFingerprints` already refuses, so the list should be empty.
5. **Cost.** Full hashing reads every packaged video once more (about 75 GB for the current package) and every withheld video (25 GB). Over the SMB share at the measured ~37 MB/s that is roughly 45 minutes, in addition to the export; on local disk a few minutes. Acceptable for a step that runs once per package. To keep the export itself unchanged, the digests are computed before the exporter starts (with the other source checks) and compared after `windows.jsonl` is known, as today.
6. **Compatibility.** Records written before this change decode unchanged (`sourceDigests` and `protectedSourceDigests` are optional); `verify_package.ps1` is unaffected (it hashes the package, not the sources). The partial `file:` fingerprint remains the identity everywhere.

## Reconciliation of today's protected-content inventory (2026-10-22, before the proposal)

Independently recomputed in Python from the sessions, `project.json`, `validation.json` and the image folders, against what RallyLab logged for the running export:

| Quantity | RallyLab | Recomputed |
|---|---|---|
| Withheld closure (validation.json reserved names ∪ holdout, expanded over identities) | 21 | 21, same names |
| Withheld frame records with a file (kept or parked) | — | 425 |
| Withheld frame records with no file (dangling) | 54 | 54, all `grs_onl_dusk_land_onl_03` |
| Dataset image files named for a withheld recording (exact store shapes) | — | 452, of which 27 have no record (all `grs_onl_dusk_land_onl_03`, dated Oct 6) |
| Protected image files hashed | 452 | 425 + 27 = 452 |
| Eligible names that extend a withheld name (`<withheld>_…`, the sibling risk) | — | none |

Correction to an earlier note: `bch_onl_sun_land_onl_03` has **no** orphan files; the 40 extra files counted before were its sibling `bch_onl_sun_land_onl_03_v2`'s, which the exact-shape match correctly keeps apart.

## Out of scope

Changing `fileFingerprint` itself, re-identifying videos, or touching the exposure ledger. Replacing the partial checks: they stay as the identity-level guard.
