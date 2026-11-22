# A menu row's press rect is not what it draws

Woof gives every menu item a `rect`, and the pointer code tests a press
against it. It is tempting to read that rect as "where the item is". For
three kinds of item it is not:

| Item | `rect` | What is drawn |
|---|---|---|
| Main menu, Options, episode, skill | the whole width of the screen (`MAIN_MENU_RECT`) | a graphic in the middle |
| A setup row (on/off, choice, number, key binding) | the whole width (`rect->x = 0; rect->w = SCREENWIDTH` in `DrawItem`) | a label ending at `m_x` and a setting beginning there |
| A setup slider | the slider itself, but `MN_SetupCursorPostion` widens it to the whole width to place the cursor, and a press off the slider is then eaten | label, slider, figure |
| A Load or Save slot | the slot's frame | the same frame |

So only a save slot's rect can answer "is this drawn under my finger". The
touch overlay needs that answer, because in landscape its buttons sit over
the right of the picture: a touch on a button has to go to the menu where the
menu draws something there, and stay the button's where the row is empty, or
steering with the stick and confirming with USE stops working.

Issue 430 used the slot rects. For the setup screens (issue 440)
`mn_setup.c` records what each item draws (`setup_menu_t.drawn`), and the
seam is `drawn` within `rect`: all of a row's text, and for a slider the
slider only.

## Measure it; the arithmetic was wrong in both directions

Issue 440 was filed on arithmetic: "the last 40 pt of a slider would sit
under USE on a closed-landscape Duo", from an assumed centre and scale.
Measured 2026-11-21, every row of every tab of the seven screens (22 tabs,
265 rows on the iPhone 18 Pro):

- iPhone 18 Pro, landscape: nothing. The nearest touchable drawn part is 3 pt
  short of a button's cushion.
- iPhone Duo, closed, landscape: 26 places over five screens. Sliders under
  USE (a touch began changing the *cursor's* row), a long setting under the
  weapon buttons (a touch turned the tab), and the sixth tab of General and
  of Key Bindings inside ≡'s cushion, where a touch did nothing at all: those
  two tabs could not be opened by touch.

`DuoLayoutSweepTests.testM_SetupScreens` is the measurement, and prints one
`SETUP440` line per row into an attachment of its result bundle.

## Two things about testing it

- **The overlap does not exist on the phone CI can turn.** A test of the
  shipped layout there passes with or without the fix. `SetupScreenOverlapTests`
  moves USE onto a row with the layout editor's stored offsets, given for one
  launch as a launch argument. The value is `Data`, and the argument domain
  parses an old-style property list, so `-touchOverlayLayoutOffsets
  '<7b22...>'` (the JSON's bytes in hex, in angle brackets) arrives as `Data`
  and nothing is written to the app's defaults.
- **A drawn rect depends on the setting's current value.** A choice whose
  longest string is not the current one draws shorter today than it can. The
  measurement is of the defaults.

## Found on the way

After the reset button, a touch anywhere answered "reset to defaults?" yes:
`default_verify` was not in `MN_MenuMessageShowing`. Issue 447, fixed since;
`menu-click-answers-prompt-yes.md` has it.

**Provenance:** issue 440, 2026-11-21.
