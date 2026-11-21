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
  the panel's row at the largest size. `lineLimit` set to the number of
  words, with `minimumScaleFactor`, shrinks the text only then: with a line
  per word a text runs out of lines only when a word has been broken.
  `WholeWordText` in `Theme.swift` is that. A `minimumScaleFactor` with no
  line limit does nothing, because the text is never short of lines.
- **An icon or a control beside the text.** A `Label`'s icon in Settings, and
  the delete and reorder controls of an always-editing list on the game page,
  come out of the same width. Settings drops the icons at the accessibility
  sizes (`WaddleRowLabelStyle`); the file rows use `WholeWordText`.

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

What did: at the accessibility sizes only, build the row by hand, a title
over a `Menu` whose label is an ordinary `Text` and whose content is the same
`Picker` (`MenuPickerRow` in `GamePageView.swift`). At the ordinary sizes it
is still the system's picker, so nothing there moved.

## "Wider than tall" is also a narrow page that lost its height

The game page puts its art beside its title when the page is wider than it
is tall, which was written for a landscape phone. The panel is about 340 pt of
content, and with the rename prompt's keyboard up it is shorter than that:
the title got a column two letters wide ("SC" / "YT" / "HE").
`PlayableDetailLayout.arrangement` now also takes the widest word the
caption holds and stacks when the column beside the art is narrower.
