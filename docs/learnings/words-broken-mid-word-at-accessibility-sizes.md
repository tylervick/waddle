# A word broken in the middle at an accessibility text size: four causes, four fixes

Measured 2026-11-21 on the iPhone Duo simulator (iOS 27.1) at
`accessibility-extra-extra-extra-large`, closed (466x678) and with the game
page and Settings in the shelf's panel on the open device, for issue #425.
Body text is 53 pt there, and a row in the panel has about 280 pt for it.

SwiftUI never refuses to lay text out. A `Text` given less width than its
longest word breaks the word, with a hyphen where the system's hyphenation
knows one ("Bun-" / "dled", "Hid-" / "den") and without where it does not
("freedoom1.wa" / "d", "SCYTH" / "E"). Nothing is logged and no test fails,
so each of these has to be seen. What produced them, and what removed them:

- **An `HStack` of several `Text`s.** The stack shares its width out, and a
  child can get less than its longest word although the row has room for the
  whole line wrapped. `28.8 MB`, `·` and `Bundled` as three texts broke
  "Bundled" in a row that fits it. One `Text` built by interpolation
  (`Text("\(a) · \(b)")`, each part keeping its own colour) wraps at its
  spaces instead. A no-break space in front of the dot keeps a line from
  starting with it.
- **A string with nowhere to wrap.** A file name is one word to the line
  breaker, dot and all. A zero-width space (`U+200B`) in front of the
  extension gives it one place to end a line, and draws nothing. Give the
  text its plain name as `accessibilityLabel`, or the invisible character is
  in what VoiceOver and XCUITest read.
- **A word wider than any line the row has.** "Compatibility" is wider than
  the panel's row at the largest size, and so is "Eviternity" beside a list's
  delete and reorder controls. A SwiftUI `Text` has no "do not hyphenate",
  so the only sure way to keep a word whole is never to hand it a line
  narrower than the word. `WholeWordText` in `Theme.swift` picks the size
  itself: it measures its widest piece with `UIFont` (text alone, which a
  font does measure exactly) and offers `ViewThatFits` the same text at
  1, 0.9 ... 0.5 of its size, each declaring that piece's width at that size
  through `.frame(idealWidth:)`. The first that fits is drawn, and every
  break the system then makes falls between pieces. Below half size it gives
  up and wraps as plain text does, broken but never cut.

  A piece is a word, or a part of one ending at a hyphen or an underscore or
  starting at a dot, with a zero-width space between the parts: a file's
  name is usually one unspaced token ("sunlust_final_v13").

  **Do not do this with `lineLimit` and `minimumScaleFactor`.** Two versions
  did: a line per piece, on the reasoning that the text only runs out of
  lines when a piece has been broken, and shrinks then. It is true of one
  piece and false of two. "Eviter-" / "nity II" is two lines for two pieces,
  because the broken word's tail shares a line with the next word; the limit
  is never reached and nothing shrinks (second review of pull request 435).
  It also cut a long unspaced name with an ellipsis once it had shrunk as far
  as it could. A render on macOS did not show either, because macOS does not
  hyphenate where iOS does: check this kind of thing in the app.
- **An icon or a control beside the text.** A `Label`'s icon in Settings, and
  the delete and reorder controls of an always-editing list on the game page,
  come out of the same width. Settings drops the icons at the accessibility
  sizes (`WaddleRowLabelStyle`); the file rows use `WholeWordText`.

## Three things `WholeWordText` got wrong the first time it met a title

Found 2026-11-21 putting it under the game page's title (issue #441), which
is bold and sits in an `HStack` beside a pencil. Each was invisible in the
file rows it was written for.

- **`.font(nil)` is not "no font".** It replaces the font the caller set
  with the default. The full-size child was written
  `.font(scale == 1 ? nil : …)`, and a title given `.title2.bold()` from
  outside came out regular, at every text size. Leave the modifier off
  instead. The rows never showed it because their font is the default.
- **A weight is part of the measurement.** A bold piece is wider than a
  regular one, so a title measured in the text style's own font is passed
  as fitting when it does not. The type takes a weight for measuring and
  for the smaller sizes it draws.
- **A wrapped text beside something else can be offered one line's height.**
  On the closed iPhone Duo the title, wrapped to two lines, was cut to
  "sunlust_fina…": nothing had a line limit. `.fixedSize(horizontal: false,
  vertical: true)` on the text makes it take the height its lines need.
  A wider or narrower row did not do it, so one pose looking right proves
  nothing about the next.

The page also measures the title to decide whether the art may sit beside
it (`captionProbe`). It has to split the name where the title may now end
a line, at `WholeWordText.pieces`, or a landscape page stacks for a name
that would have fitted.

## A menu `Picker` in a `Form` is sized for a one-line value

At an accessibility size a `Picker` with `.pickerStyle(.menu)` in a `Form`
puts its title over its value. When the value wraps to two lines
("Freedoom" / "Phase 2") the row is still the height of a title and one
line, and the content is centred in it: the title rises out of the top of
the row, against the card's edge under the section header, and the value's
second line runs out of the bottom. It looks like a missing inset on the
first row; it is every row whose value wraps.

Two things that did not fix it:

- `.fixedSize(horizontal: false, vertical: true)` on the picker put the
  title back and clipped the value top and bottom.
- Leaving the style to the `Form`'s default gave a correct row with the
  value on one line, truncated in the middle ("Free…ase 2").

What did: at the accessibility sizes only, build the row by hand: a `Menu`
whose label is the whole row, the title over the value as ordinary text, and
whose content is the same `Picker` (`MenuPickerRow` in `GamePageView.swift`). At the ordinary sizes it
is still the system's picker, so nothing there moved.

## "Wider than tall" is also a narrow page that lost its height

The game page puts its art beside its title when the page is wider than it
is tall, which was written for a landscape phone. The panel is about 340 pt of
content, and with the rename prompt's keyboard up it is shorter than that:
the title got a column two letters wide ("SC" / "YT" / "HE").
`PlayableDetailLayout.arrangement` now also takes the widest word the
caption holds and stacks when the column beside the art is narrower.

Both sides of that comparison have to be measured, not worked out. The first
version got them from `UIFont` and from the form's width, and stacked a
closed iPhone Duo held sideways at the largest size, where `main` drew the
page side by side with every word whole (review of pull request 435):

- A font cannot say how wide a symbol is drawn or how far a `Label` sets it
  from its title. The page now draws a hidden copy of each word with its
  pencil or icon at its natural size (`.lineLimit(1).fixedSize().hidden()`
  in a `.background`) and reads the width with `onGeometryChange`.
- The hero row is not always the form's width less the insets the art is
  sized from. On that device it is about 11 pt wider, and the caption fitted
  in the difference. The row's own width is measured too.

`GamePageTests.testTheHeroIsSideBySideOnALandscapePhone` is the check that
the measurement arrives at all: until it does the page stacks.

## What the system's menu picker tells VoiceOver

Read off the row with XCUITest: its label is the title and the choice
together, "Touch layout, Default (Classic)", and its value is empty. A
hand-built replacement that sets a label and a separate value is therefore
not "what the system does". `GamePageTests` reads the system's row at the
default size and holds the hand-built one to the same label and value, and
taps the row's empty end to prove the whole row opens the menu.

A UI test gets an accessibility text size for one launch with the launch
arguments `-UIPreferredContentSizeCategoryName
UICTContentSizeCategoryAccessibilityXXXL`; the simulator's own setting is
not touched.
