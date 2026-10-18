# Termini

`../reports/rearchitecture-2026/PLAN.md` is the source of truth for how Faux Fox uses this repository and wins over this file. Termini is a SwiftUI terminal library that wraps Ghostty's terminal engine (`GhosttyKit.xcframework`): the `Termini` renderer and local shell, and the `TerminiSSH` client over SwiftNIO SSH. Faux Fox maintains it at `FauxFoxIO/Termini`. Mirage uses it for the terminal people use (macOS Remote Login over SSH, PLAN 1.10).

## License and attribution

- Termini is MIT licensed. Keep `LICENSE`, its copyright line and `THIRD_PARTY_NOTICES.md` (including Ghostty's notice) intact, and add a notice for any newly bundled code.
- It is a public, general-purpose library: no Faux Fox or Mirage product code, names, hosts, bundle IDs, team IDs or policy in sources, docs or defaults. Mirage-specific behavior stays in Mirage.

## Platforms

- `Package.swift` declares macOS 14, iOS 17 and visionOS 1, and the demo project iOS 17, below the company's OS 27 floor. Whether to raise them to 27 or keep a public library's floor is Ethan's decision; do not change them until he decides. Mirage builds it at 27 either way.
- iOS and visionOS are SSH-only; the local PTY and shell APIs are macOS-only.

## GhosttyKit

- The package uses a local `vendor/ghostty/macos/GhosttyKit.xcframework` when one with the required embedding declarations is present, otherwise the release artifact named in `Package.swift`. Build it with `scripts/build-ghosttykit.sh` from the tracked patches in `patches/ghostty/`, and keep native build output outside the repository.
- `vendor/` is ignored; never commit a local framework. The shipped framework excludes private macOS APIs so App Store builds can use it; keep it that way.
- Publishing a GhosttyKit release artifact or changing the release URL and checksum needs Ethan's OK.

## Code and versions

- Keep the public SwiftUI surface small so the rendering backend can change without breaking apps. Before changing a public API, update Mirage in the same work.
- Four spaces; no force unwrap or `try` for recoverable failures. No file over 1,500 lines. Comments describe present behavior.
- Dependencies are swift-nio, swift-nio-ssh and swift-nio-transport-services. Add no others without Ethan's approval.
- GhosttyKit artifacts are published as tagged GitHub releases (`ghosttykit-*`); do not tag or change versions by assumption.

## Tests and validation

- Do not add tests without Ethan's approval. Leave the existing test targets as they are.
- Cheap check: `swift package dump-package`. Build only when asked, with output outside the repository and no signing.
- Phase 1 work lands on `phase1` (with a draft PR) through `p1/*` branches in their own linked worktrees. Do not push, tag, publish or release without Ethan's OK. Preserve others' uncommitted work.
