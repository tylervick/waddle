# WADdle — working rules

An iOS port of the Woof! Doom engine. See `README.md` for build instructions and
`docs/learnings/INDEX.md` for traps this project has already paid for.

## Build & test

- Bootstrap: `mise run bootstrap`. Verify: `mise run test`.
- Never run two `xcodebuild` test sessions against one simulator at the same
  time — they cross-contaminate and produce spurious kills and failures.
- The engine build is deliberately separate from archiving.
  `Scripts/check-engine-fresh.sh` refuses stale frameworks; do not bypass it.

## Engine invariants

- The Woof pin is master `798acebd`. Upstream has no SDL3 release tag, so
  SDL2-era tags such as `woof_15.3.0` must never be used.
- The engine save flag is `-save`, not `-savedir`.
- `woof.pk3` lives at the app bundle root; IWADs live in `GameData/`, whose
  folder reference must never be renamed to "Resources".

## Changes

- Conventional commits, matching existing history (`fix(ui):`, `docs(app-store):`).
- Never edit or delete a test to make it pass.
- Work lands through pull requests, never directly on `main`.
- Hit a trap worth remembering? Add a file under `docs/learnings/` and one line
  to its `INDEX.md`, in the same PR.
- A learning that can be an executable check should become one —
  `Scripts/check-engine-fresh.sh` is the pattern — and the learning file then
  points at the check instead of restating it.
