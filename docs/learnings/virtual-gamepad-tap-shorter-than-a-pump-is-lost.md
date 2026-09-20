# A virtual-gamepad press shorter than one engine pump never happens

Measured 2026-09-20 on Revyl's farm iPhone with the in-game debug strip,
`menu-input-telemetry` run 790cfacc: across one USE tap the overlay's own
touch-event count went from 9 to 11 while the engine's gamepad button-event
count stayed at 2, and the menu did not react. On the previous run the same
tap had opened the skill screen. Same build, same button, same agent.

The overlay's buttons drive an SDL *virtual* joystick:
`SDL_SetJoystickVirtualButton` writes a state, and SDL turns that state into
events only when the engine pumps (`SDL_PumpEvents`, at best once per rendered
frame and at worst once per 35 Hz tic, about 29 ms). A down followed by an up
between two pumps leaves the sampled state unchanged, so neither edge is
ever reported. The farm's taps are short enough that whether a press survives
depends on where it falls relative to the pump, which is why USE worked in
one run and not the next, and why START, on the same path, sometimes did.
XCUITest taps in the simulator last long enough to straddle several pumps,
so no simulator test ever saw it.

`OverlayPressTiming` holds a button's release back until the press has lasted
`minimumHold` (two pumps at 35 Hz), and `OverlayButton` forwards the up after
that delay; a new press arriving first flushes the pending release. This is
the sibling of `soft-keyboard-keydown-keyup-pairing.md`: there every down
needs its up, here every down needs to be *seen* before its up.
