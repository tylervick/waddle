# A simulator named in a hand-run script does not fail when CI's pin moves

`ci.yml` pins the iPhone simulator in `SIMULATOR_DEVICE` and `SIMULATOR_OS`,
and a bump there is proven by the next CI run. The same phone is also named in
places only a person runs: `mise run test`, the README's copy of that command,
the default destination of `Scripts/check-red-green.sh`, and the default
device of `Scripts/provision-test-wads.sh`. Nothing runs those in CI, so
nothing fails when they are left behind.

The Xcode 27.1 bump (PR #349, 2026-11-09) moved CI to iPhone 18 Pro because
the `xcode-27` runner image has no iPhone 17 Pro, and left all four on the old
phone (issue #360). The fix eleven days later (PR #404) was written from the
issue's list, which named three of them, and it merged without
`provision-test-wads.sh` — so the documented provisioning step put
`RealWADTests`' fixtures on a different simulator from the one `mise run test`
then ran the tests on. A review caught it after the merge; a grep for the old name would have too, but the old name
also appears in dozens of comments that are correct history, so the grep is
not something anyone reads to the end.

**The check:** `Scripts/check-simulator-pins.sh` reads the two pins from
`ci.yml` and refuses a tree where `ui-tests.yml` or any of those four places
says something else. Its header lists exactly what is compared. A new hand-run
command that names the CI phone belongs in that script, not in a comment
asking the next person to remember.

Not covered, on purpose: the iPad and Duo pins (each has one owner already),
and one-off reproduction commands in `docs/`, where the device is incidental.

**Provenance:** issue #360, PR #404 and the review that followed it, 2026-11-20.
