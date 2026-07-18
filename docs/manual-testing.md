# Manual on-device test checklist

Run before each release build (simulator can't cover physical input).

Note: `BOOMBOX_FORCE_TOUCH_OVERLAY` is a test-only environment variable that bypasses
the automatic overlay hide policy on physical controllers and keyboards, forcing the
overlay to remain visible even when input devices are connected.

## Touch (iPhone + iPad)
- [ ] "Touch Controls" gear menu on the Play tab toggles Classic/Modern and
      persists across app relaunch (accessibilityIdentifier
      `touchSchemePicker`)
- [ ] FIRE actually fires (continuous fire with chaingun held down), **and
      releasing FIRE actually stops the fire** — this app previously shipped
      a bug where FIRE autofired forever after a single press (fixed: the
      virtual joystick's trigger axis is now driven digitally, MIN/MAX only;
      see `WoofIOS_SetTouchTrigger` in `Engine/woof/src/woof_ios.c`)
- [ ] USE opens doors — verify it does something, not just that FIRE does
- [ ] Weapon prev/next cycles; MAP toggles automap (previously silently did
      nothing — was wired to an unbound button); ≡ opens the menu and
      the stick + FIRE/USE navigate it
- [ ] Overlay hides/shows when a controller connects/disconnects mid-session

### Classic scheme (default)
- [ ] Movement stick appears where the left thumb lands; releases to neutral
- [ ] Stick's horizontal deflection turns the player (no strafe); vertical
      deflection moves forward/back
- [ ] Right side of the screen has no drag-to-turn gesture and shows no
      stick visuals — only the buttons respond there

### Modern scheme
- [ ] Movement stick strafes + moves forward/back (twin-stick, no turn on
      the stick)
- [ ] Drag-to-turn on the right half shows the same base/knob visuals as
      the movement stick, knob follows the finger's x-drag, and recenters
      on release; turn sensitivity comfortable

## Physical controller (Xbox/PS/Switch)
- [ ] Sticks move/turn, face buttons fire/use, shoulders cycle weapons
- [ ] Rumble (if enabled in Woof! setup)
- [ ] Overlay auto-hides when controller is connected and visible when disconnected
      (requires real hardware; simulator does not test this reliably due to phantom
      GCController in XCUITest sessions)

## Keyboard & mouse (iPad)
- [ ] WASD + mouse look; overlay hidden while keyboard is connected

## Performance
- [ ] Cold launch with a 300MB WAD in Documents: first frame < 3s,
      adoption completes in the background without UI stalls
