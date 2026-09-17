# `MARKETING_VERSION` has to be bumped before the build, not with the metadata

Creating App Store version **1.1** in App Store Connect does nothing to the
binary. `CFBundleShortVersionString` comes from `MARKETING_VERSION` in
`App/project.yml`, and if that still says the previously approved version the
submission is rejected by automated validation:

```text
ITMS-90062: This bundle is invalid - The value for key
CFBundleShortVersionString [1.0] in the Info.plist file must contain a higher
version than that of the previously approved version [1.0].
```

Measured 2026-09-16. Version 1.1 was submitted at 23:16:40 UTC with build 247
attached, reached `WAITING_FOR_REVIEW` at 23:16:46, and was
`INVALID_BINARY` by 23:17:09 — **23 seconds**. No human saw it.

**The failure is silent everywhere you would look for it beforehand.** Build
247 was `processingState: VALID`, had been through TestFlight, and passed a
nine-field submission preflight that checked the attached build, the What's
New text, the description, the app name, every screenshot and the review
notes. None of that touches the binary's marketing version, because
`MARKETING_VERSION` is not App Store Connect state — it is a build setting
baked in when the build was cut, weeks earlier.

`CURRENT_PROJECT_VERSION` misleads by analogy. CI derives the *build* number
automatically ([[testflight-upload-procedure]], `Scripts/release-due.sh`), so
it is easy to assume versioning is handled. It is not: the build number is
automatic, the marketing version is a deliberate edit.

**The ordering that actually works:**

1. Bump `MARKETING_VERSION` in `App/project.yml` and merge it.
2. *Then* cut the build — `gh workflow run testflight.yml --ref main`. The
   binary now carries the new version.
3. Create the App Store version, attach **that** build, submit.

Doing 3 before 1 is the trap, and it is easy because the App Store Connect
side is where the version number feels like it lives. A build cut before the
bump can never be used for the new version, whatever its build number — 247
was fine in every other respect and was still unusable.

**Cost when you get it wrong:** the version drops to `INVALID_BINARY`, the
review submission goes to `UNRESOLVED_ISSUES`, and recovering needs a brand
new build. The already-released version is untouched — 1.0 stayed
`READY_FOR_SALE` throughout — so this costs a build and a review cycle, not a
live app.

**This is a candidate for an executable check** (`CLAUDE.md`: a learning that
can be one should become one), but not a PR-time one. The invariant compares a
build setting against live App Store Connect state, and
`Scripts/check-substrate.sh` records why PR guards here are deliberately
offline — a guard that needs a token and a network fails for reasons unrelated
to the diff under review. The right home is the release path, where
credentials already exist: refuse to attach a build to an App Store version
whose `versionString` is not greater than the binary's
`CFBundleShortVersionString`. Not yet built.
