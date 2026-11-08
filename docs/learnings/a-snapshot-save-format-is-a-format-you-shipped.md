# A development snapshot's save format is a format you shipped

Waddle 1.0 through 1.3 vendored Woof master `798acebd`, a snapshot between
the 15.3.0 and 16.0.0 releases. Its savegames were binary, in the keyframe
layout `kf_file.c` had at that commit, stamped `"Woof 16.0.0"`. Woof 16.0.0
final (PR #328) writes compressed JSON under the same stamp, and its legacy
loader's version table ends at `"Woof 15.0.0"`. So every save a player made
through 1.3 became `saveg_indetermined` overnight: Continue showed
"Different Savegame Version!!! Are you sure?", and answering yes ended the
session with `The -beta option is required to play back beta emulation
demos`, because the forced parse skipped the `demo_version` byte and read
every later field one byte off (issue #339, TestFlight build 281).

Upstream never shipped the binary `"Woof 16.0.0"` format, so no upstream
fix was ever coming. Waddle shipped it, so Waddle owns a reader for it for
as long as a 1.3 save can exist on a device:

- `Engine/woof/src/kf_legacy.c` is the snapshot's binary keyframe reader,
  kept as its own file so the re-vendor three-way merge never touches it.
  Its three differences from the snapshot are marked `[Waddle]`: the
  `player_t` weapon-switch fields the final release removed are read and
  dropped, `mobj_t.tint` (which the snapshot lacked) is set to `NO_INDEX`,
  and nothing is written.
- `saveg_waddle13` in `p_saveg.h` names the format; `g_game.c` reads its
  five custom-skill bytes and routes its body to the new reader.
- A stamp the table does not know is now refused outright, forced or not.
  The "Are you sure?" prompt only made sense when forcing could succeed.

`WaddleUITests/LegacySaveLoadTests` loads a real 1.3 save
(`App/UITests/Fixtures/suspend-waddle-1.3.dsg`) through Continue and checks
the HUD reports `load=254`, `gs=level` and the saved leveltime; a second
case overwrites the stamp and checks the session ends on the title screen
with exit 0 and no engine-error alert.

Two lessons. First, a re-vendor's release notes describe the API change
("savegame overhaul"), not what it does to files already on players'
devices; when a pin moves across a format change, open a save from the
previous release before merging. Second, a format a release wrote is a
compatibility obligation whether or not upstream ever named it, so pin the
engine to tagged releases where there is a choice (`Engine/WOOF_UPSTREAM.md`).
