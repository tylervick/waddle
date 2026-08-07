# Every injected keydown must be paired with a keyup

`WoofIOS_InjectChar` posts `ev_keydown`, then `ev_text`, then `ev_keyup`. The
final keyup is not optional: an unconsumed cheat letter whose keyup never
arrives latches in `gamekeydown[]`, and the player then walks in that direction
forever with no visible cause.

Injection is gated by `WoofIOS_GetTextInputContext`, which returns
`GAMEPLAY`, `SAVENAME`, or `NONE`. Each inject function context-guards
individually — characters are dropped in `NONE`, and backspace/confirm are
honoured only in `SAVENAME` — because the context is polled at 0.25s and a
naive single check races against it.

**Provenance:** PR #7 (soft keyboard), merged as `4e6868e`. The latching bug was
found on device via `iddqd`.
