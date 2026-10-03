# A called workflow gets no secrets unless the caller says `secrets: inherit`

PR #317 made TestFlight builds ship on merge by having `ci.yml` call
`testflight.yml` through `workflow_call` after the unit tests pass. The first
merge-path release (run 37060983966, 2026-10-02) built the engine, resolved
build number 277, and then failed in "Install signing assets":

```
security: SecKeychainItemImport: One or more parameters passed to a function were not valid.
```

That is what `security import` says about a `.p12` decoded from an empty
string. A reusable workflow invoked with `uses:` does **not** see the
caller's repository or organization secrets unless the calling job carries
`secrets: inherit` (or passes them one by one under `secrets:`). The
`workflow_dispatch` and `schedule` paths run `testflight.yml` directly, with
the secrets in scope, which is why the dispatch the day before signed and
uploaded fine and why the gap was invisible until a real merge took the new
path.

Where the signing values live matters, and the failure is itself the
evidence. The called `testflight` job declares `environment: app-store`, and
GitHub's reusable-workflows documentation says that when the called job
names an environment, *that environment's* secrets are used -- the caller
cannot pass environment secrets at all, because `on.workflow_call` has no
`environment` keyword. So if `BUILD_CERTIFICATE_BASE64` and the rest were
secrets of the `app-store` environment, the called job would have had them
with or without `secrets: inherit`, and the run would have signed. It did
not, so they are repository secrets, and `secrets: inherit` is the line that
reaches them. If they are ever moved into the environment, the job's own
`environment:` covers them and `inherit` becomes harmless.

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
