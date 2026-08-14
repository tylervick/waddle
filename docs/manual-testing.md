# Manual on-device test checklist

Run before each release build (simulator can't cover physical input).

Note: `WADDLE_FORCE_TOUCH_OVERLAY` is a test-only environment variable that bypasses
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
      see `WoofIOS_SetTouchTrigger` in `Engine/woof/src/woof_ios.c`).
      Turning on the debug HUD (below) and watching `trigger` drop to `0.00`
      right after release is the fastest way to confirm this on a device.
- [ ] USE opens doors — verify it does something, not just that FIRE does
- [ ] Weapon prev/next cycles; MAP toggles automap (previously silently did
      nothing — was wired to an unbound button); ≡ opens the menu and
      the stick + FIRE/USE navigate it
- [ ] MAP is hidden/unresponsive whenever a menu is on screen (options,
      Load/Save, etc.), and reappears the instant the menu closes — MAP's
      correct gameplay button (NORTH) doubles as `input_menu_clear` in
      Woof's menu-navigation bindings, so an overlay tap on MAP followed by
      a tap on USE inside the Load/Save menu could otherwise arm and
      confirm a savegame delete with no prompt visible on the overlay.
      Specifically: open Load or Save with a populated slot, confirm MAP
      does nothing (no delete-confirmation state, slot list unchanged),
      then back out to gameplay and confirm MAP toggles the automap again
- [ ] Overlay hides/shows when a controller connects/disconnects mid-session
- [ ] "Control Feel…" in the gear menu opens the tuning sheet; the three
      sliders (accessibilityIdentifiers `turnSpeedSlider`,
      `stickDeadZoneSlider`, `moveSensitivitySlider`) persist across app
      relaunch, and Reset to Defaults restores 1.00 / 0.00 / 1.00

### Control-feel tuning procedure (on-device)

Goal: find preferred slider values interactively instead of code-tweak
loops, then report them back so the defaults can be baked in.

1. Turn on "Show Debug Info" (gear menu) so the in-session HUD shows the
   effective values as `turn <x.xx> · dz <x.xx> · move <x.xx>` — what the
   HUD shows is what the session is actually using.
2. Open "Control Feel…", adjust one slider, and start a session (values are
   read at overlay install, so mid-session changes apply to the *next*
   session — leave a session and re-enter after each adjustment).
3. Retest the feel per the scheme checklists above (classic stick turn,
   modern drag-turn, dead-zone wobble rejection, forward/strafe speed).
4. Repeat per slider until it feels right; note interactions (a larger dead
   zone shrinks the stick's active band, which makes mid-deflection turning
   in classic feel faster for the same thumb travel).
5. Report the preferred `turn`/`dz`/`move` values (screenshot of the HUD
   line is enough) so they can be baked in as defaults.

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

## Debug HUD
Turn this on for every session below: "Show Debug Info" in the same gear
menu as the touch scheme picker (accessibilityIdentifier `debugHUDToggle`,
persisted across relaunch).
- [ ] Play tab shows a footer line once enabled: `WADdle <commit> (<branch>)
      · built <date time>` (accessibilityIdentifier `buildInfoLabel`) —
      commit matches `git rev-parse --short HEAD` (with a trailing `+` if
      the tree had uncommitted changes at build time), branch matches
      `git branch --show-current`
- [ ] During an engine session, a translucent line appears along the top
      edge (accessibilityIdentifier `sessionDebugHUD`), refreshing twice a
      second, reading `build <commit> (<branch>) · <scheme> · events <n> ·
      trigger <0.00-1.00> · turn <x.xx> · dz <x.xx> · move <x.xx>`:
      - `<scheme>`: the active touch control scheme (classic/modern)
      - `events`: the shim's cumulative touch-event counter (same one
        `touchEventCountLabel` shows post-session) — should climb as you
        use the stick/buttons/turn
      - `trigger`: RIGHT_TRIGGER as Woof's gamepad layer currently sees it,
        live — `0.00` at rest/released, rises toward `1.00` while FIRE is
        held, and must drop back to `0.00` within a fraction of a second of
        releasing FIRE (this is the same telemetry that caught the FIRE
        autofire regression above, just live instead of sampled once)
      - `turn`/`dz`/`move`: the effective Control Feel tuning values this
        session is using (turnSpeed, stickDeadZone, moveSensitivity — read
        once at overlay install, see the tuning procedure above)
      - the HUD never intercepts touches and doesn't overlap the button row

## Physical controller (Xbox/PS/Switch)
- [ ] Sticks move/turn, face buttons fire/use, shoulders cycle weapons
- [ ] Rumble (if enabled in Woof! setup)
- [ ] Overlay auto-hides when controller is connected and visible when disconnected
      (requires real hardware; simulator does not test this reliably due to phantom
      GCController in XCUITest sessions)

## Keyboard & mouse (iPad)
- [ ] WASD + mouse look; overlay hidden while keyboard is connected

## Audio
Physical device only: the simulator's audio path is not the device's, and
interruptions (phone call, Siri) cannot be reproduced there. Nothing in CI or
the unit/UI suites covers any of this, and the app configures no
`AVAudioSession` of its own — sound effects come from OpenAL Soft and music
from OPL3 emulation inside the engine (`Engine/woof/src/i_oalsound.c`,
`i_oplmusic.c`), so what you hear is the system's default session behavior
rather than behavior the app asked for. Record what actually happens,
including the failures.
- [ ] Sound effects play during gameplay: firing, weapon switching, doors
      opening, monsters reacting, pain/death — checked with the silent
      switch (or Focus/ringer setting) both on and off, noting which one
      silences the game
- [ ] Title-screen music plays on the attract/demo loop, the level's own
      music starts on entering a level, and it differs between two levels
      (e.g. E1M1 vs E1M2)
- [ ] ≡ → Options → Sound Volume: the SFX and Music Volume thermometers
      change what you hear immediately, and both persist across app relaunch
- [ ] Opening and closing the ≡ menu mid-level leaves music intact — it
      neither restarts from the top nor ends up playing over a second copy
      of itself (record which of "keeps playing" or "stops and resumes
      cleanly" you observe)
- [ ] Backgrounding mid-session (home gesture / app switcher) stops audio,
      and returning to the foreground resumes both music and sound effects
      with no stuck, looping, or dead channel; locking and unlocking the
      screen behaves the same way
- [ ] Audio interruption recovery: take a phone call (or trigger Siri)
      mid-session, then end it — music *and* sound effects both come back.
      The predecessor app handled this explicitly with an interruption
      listener and this app has no equivalent, so permanent silence here is
      a plausible outcome to record, not a surprise
- [ ] Connecting or removing wired/Bluetooth headphones mid-session moves
      the audio to the new route without killing it

## Orientation & iPad multitasking
- [ ] iPhone: launcher and a session render upright in portrait (game
      letterboxed); rotating mid-session both directions re-letterboxes,
      overlay buttons follow, session survives
- [ ] iPad windowed multitasking mode (default "Windowed Apps"): app opens
      upright and playable in a resizable window
- [ ] iPad: live-resizing the window mid-session re-letterboxes the game
      without crashing; overlay controls stay usable in the resized window

## Performance
- [ ] Cold launch with a 300MB WAD in Documents: first frame < 3s,
      adoption completes in the background without UI stalls
