# Two detail-page UI tests are already red at HEAD, and CI will not tell you

`WADdleUITests/PlayTabTests/testBaseGameDetailControlsOverridePersists` and
`WADdleUITests/PresetEditTests/testEditFromDetailPageOpensEditor` both fail on
an unmodified tree. Both fail the same way: they long-press a shelf tile, tap
**Details** in the context menu, and the detail sheet never opens, so
`detailSchemePicker` / `detailEditButton` are never found.

Neither is covered by `ci.yml`, which runs `-only-testing:WADdleTests`
deliberately — `WADdleUITests` boots the real engine and belongs to the
manually dispatched `ui-tests` workflow. Nothing on a pull request runs them,
so they can stay red indefinitely without a red check anywhere.

**The trap is attribution, not the failure.** A change to `ShelfView` or
`PlayableDetailView` that runs these locally sees two red tests immediately
after touching the shelf, and the obvious inference — "I broke it" — is wrong.
Acting on it means "fixing" a diff that was never at fault.

**Before attributing any `WADdleUITests` failure to your own change, reproduce
it at HEAD:**

```bash
git stash push -u
mise run generate          # the .pbxproj is a generated file-list snapshot;
                           # regenerate after stashing or new files linger in it
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WADdleUITests/PlayTabTests test
git stash pop && mise run generate
```

Do not run this while another `xcodebuild` test session is live against the
same simulator (see `CLAUDE.md`).

This is a statement about HEAD on 2026-08-16, not a permanent property — if
these two go green, delete this file rather than working around it.

**Provenance:** issue #159 (the Continue hero's height cap), 2026-08-16. The
hero fix touched `ShelfView`, these two tests failed in the same run, and
five minutes went into proving they fail identically without the change.
Verified at `9740a6a`.
