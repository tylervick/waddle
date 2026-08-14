# `-loadgame` takes a composite number, and the newest save is usually the autosave

Booting straight into a save looks like "list the `.dsg` files, take the newest,
pass its number to `-loadgame`". Both halves of that are wrong, and the second
one fails on the *common* case rather than an edge case.

**The argument is `10 * page + slot`, not a slot index.** Woof addresses 8 pages
of 8 slots and encodes both into one number, 0-77, so 12 means page 1 slot 2 and
78 is rejected outright. It is also the filename's own number:
`woofsav<n>.dsg`, where the `woofsav` prefix comes from `PROJECT_SHORTNAME` via
`"%.4ssav"` — a value this project happens to pin, so the prefix is *not* the
`doomsav` every DOOM-lineage reference will tell you to expect.

**The autosave is a separate sentinel, 255, under the fixed name
`autosave.dsg`** — and autosave defaults to *on*, saving at every level start.
So on a real device the newest file in a saves directory is very often the
autosave, not a manual save. Resuming it is right (it is where the player
actually walked away from), but code that assumes every save name carries a
parseable number will either crash, skip the newest file, or resume the wrong
one. Test the autosave-is-newest case explicitly; it is the default path, not a
corner.

`App/Sources/Library/EngineSaveSlot.swift` holds the mapping, with the four Woof
source sites each rule is read out of cited inline; `App/Tests/EngineSaveSlotTests.swift`
pins the behaviour. Change the mapping there, not at a call site.

**Provenance:** #112 (one-tap Continue), 2026-08-14.
