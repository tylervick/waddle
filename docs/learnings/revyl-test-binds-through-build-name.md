# A Revyl test binds to the app through `build.name`, and can carry launch variables

Two things about `.revyl/tests/*.yaml` that the CLI's own errors do not say,
learned on 2026-09-20 while pushing `menu-state-across-sessions`.

**`revyl test push` refuses a definition with no app binding**, and the message
names a field that does not exist: `a test must be associated with an app:
provide an app_id before creating a test`. There is no `app_id` field, and
`revyl test create --app <id> --from-file` does not supply it either (the flag
is honoured for `--from-session` only). What binds a test to the app is the
build profile:

```yaml
test:
  build:
    name: development      # a profile under .revyl/config.yaml build.profiles
```

The profile carries the `app_id`. A definition pushed this way links back to its
remote through a top-level `_meta.remote_id` line that the CLI writes on the
first successful push; keep it in the file.

**A test can carry a launch environment variable even though proof-of-changes
cannot.** `docs/learnings/revyl-proof-cannot-set-launch-env.md` is about
`pr_review.proof_of_changes`, which has no such field. An ordinary test does:

```sh
revyl global launch-var create WADDLE_AUTOQUIT_SECONDS=120
revyl test launch-var attach menu-state-across-sessions WADDLE_AUTOQUIT_SECONDS
```

That is how the device test ends each engine session without driving Doom's
menu, which the farm device could not do through the overlay's stick or USE
button (recorded in `.revyl/tests/README.md`). The variable only works on a
Debug build, which is what CI uploads.

**A plain `revyl test run` installs the app's *current* build**, and the CI
upload deliberately does not promote (`--no-set-current`, because it runs before
the tests finish). Until a green `main` build is promoted, pass `--build-id`
from `revyl build list --app <id>`, or the run lands on whatever was last
promoted by hand -- which on 2026-09-20 was a build from before the touch
overlay was forced visible, and the agent had nothing to tap.

**Update 2026-09-23 (CLI v0.1.119): `build.name: development` no longer binds
a *new* test.** Pushing `session-start-state` with the same `build:` block as
`menu-state-across-sessions` failed with the same "provide an app_id" message,
through both `revyl test create --from-file` (with or without `--app`) and
`revyl test push`. What worked: `revyl test create <name> --platform ios --app
<app id>` with no `--from-file`, which creates an empty remote test and writes
a local file whose `build.name` is the Revyl *app's* name (`Waddle`) plus its
`_meta.remote_id`; copy the blocks into that file and `revyl test push`.
Existing tests that say `development` keep working, because they already have
a remote.
