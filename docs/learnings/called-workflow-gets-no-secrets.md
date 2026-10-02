# A called workflow gets no secrets unless the caller says `secrets: inherit`

PR #317 made TestFlight builds ship on merge by having `ci.yml` call
`testflight.yml` through `workflow_call` after the unit tests pass. The first
merge-path release (run 37060983966, 2026-10-02) built the engine, resolved
build number 277, and then failed in "Install signing assets":

```
security: SecKeychainItemImport: One or more parameters passed to a function were not valid.
```

That is what `security import` says about a `.p12` decoded from an empty
string. `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, the provisioning profile
and the App Store Connect key are all repository secrets, and a reusable
workflow invoked with `uses:` does **not** see the caller's secrets unless
the calling job carries `secrets: inherit` (or passes them one by one under
`secrets:`). The `workflow_dispatch` and `schedule` paths run `testflight.yml`
directly, with the secrets in scope, which is why the dispatch the day before
signed and uploaded fine and why the gap was invisible until a real merge
took the new path.

Two things made it slow to read. The step's own error is a Security
framework message with no mention of an empty input, and `gh run view
--log-failed` buries it under thousands of lines of engine build output; the
job's step list (step 5 failed, steps 6-10 skipped) was the faster signal.
And no build number was consumed: the tag step is after the upload, so
`build-276` stayed the newest tag and the next run derives 277 again.

**The check is the line itself** -- `secrets: inherit` on the `testflight`
job in `ci.yml`, with this file named beside it -- and the proof is the
first merge-path run that reaches "Upload to TestFlight". A reusable
workflow added later that needs secrets needs the same line; there is no
guard for it, because the failure mode is a signing error on a protected
path and the fix is one line in a file the loop may not touch.

**Provenance:** found while preparing the 1.3 submission, the first merge
after #317 landed.
