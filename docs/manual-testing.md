# Manual on-device test checklist

Run before each release build (simulator can't cover physical input).

Note: `BOOMBOX_FORCE_TOUCH_OVERLAY` is a test-only environment variable that bypasses
the automatic overlay hide policy on physical controllers and keyboards, forcing the
overlay to remain visible even when input devices are connected.

## Touch (iPhone + iPad)
- [ ] Movement stick appears where the left thumb lands; releases to neutral
- [ ] Drag-to-turn on the right half; sensitivity comfortable
- [ ] FIRE holds down (continuous fire with chaingun), USE opens doors
- [ ] Weapon prev/next cycles; MAP toggles automap; ≡ opens the menu and
      the stick + FIRE/USE navigate it
- [ ] Overlay hides/shows when a controller connects/disconnects mid-session

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
