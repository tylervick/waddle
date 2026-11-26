# A dropped file's copy is named after its type, not the file

Found in review of pull request 545 (#481, the shelf's drop target), measured
on an iOS 27.0 simulator with `NSItemProvider(contentsOf:)` items, which is
how Files offers a dragged file.

## The traps

- **The name.** The copy an item provider hands over
  (`loadFileRepresentation`, or a `Transferable` `FileRepresentation`, which
  is the same thing underneath) takes its name from the provider's
  `suggestedName`. With no `suggestedName` it is named after the type's
  description: `sunlust.wad` arrives as `Doom WAD.wad` and `x.zip` as
  `Zip archive.zip`. Import by that name, and the game is titled "Doom WAD".
  The file's real name is in the item's `public.file-url`, which Files and
  Finder offer.
- **Reading that URL.** `loadItem(forTypeIdentifier: "public.file-url")`
  gave nothing usable here. `loadObject(ofClass: NSURL.self)` returns the URL.
- **`.data` takes more than files.** A type the app does not declare (a
  `.pk3`) is a dynamic type, and a folder has none. Neither conforms to
  `public.data`, but both still match `.data` through `public.file-url`.
  Loading them "as data" hands over a property list of the URL, which then
  gets imported as if it were the file. Text snippets and web links match
  `.data` too.

## What the app does

`DroppedFile` in `App/Sources/UI/WADDrop.swift`:

- It takes the name from the file URL first, then from `suggestedName`, and
  only then from the copy.
- It reads only content types that are not URLs.
- It refuses anything else by name, without staging it.
- The shelf takes `public.file-url` and the picker's types, not `.data`.

`WADDropTests` is the check.

## Start every load before the drop handler returns

A drag from another process may end once the drop handler returns, and a
load first requested after that can fail. In-process providers, which are all
a test can make, keep working, so a handler that loads in a `Task` passes
every test and can still fail for a real drag from Files or Finder.
`WADDrop.handleDrop` starts both loads (the URL and the content) of every
provider before it returns, and only awaits them afterwards.
`testEveryLoadIsRequestedBeforeTheDropHandlerReturns` is the check. It
overrides `loadFileRepresentation(forTypeIdentifier:)`, because the `UTType`
overload is a Swift extension and cannot be overridden.

## Links (#550)

The shelf takes `public.url` too, and `DroppedLink.isLink` tells a link from a
file: a link offers `public.url` and neither `public.file-url` nor a type the
picker offers. Two things to know:

- **A real Safari link drag offers `public.url` and
  `public.utf8-plain-text`, with no `suggestedName`.** This was measured
  2026-11-26 with a real cross-app drag on an open iPhone Duo simulator, with
  Safari in Split View beside Waddle. The drag was made through
  `Scripts/duo-pose-device-hub.sh touch` (a held press, then a slow path).
  The `DEBUG` log in `WADDrop.handleDrop` printed it.
- **Text that merely parses as a URL is offered as `public.url` too.**
  `NSItemProvider(object: s as NSString)` registers `public.utf8-plain-text`
  *and* `public.url` for any `s` that `NSURL` parses, on iOS as on macOS.
  That includes "https://…", but also "Note: hi", "Tip:use-warp" and
  "javascript:alert(1)". "hello", "www.example.com" and text with spaces
  before any colon get no `public.url`. The first draft of pull request 555
  claimed "text that is not a URL does not light the shelf up", which was
  wrong (review of pull request 555).
- **Nothing of a drag can be read before the drop.** So the highlight
  cannot tell "Note: hi" from a link. At the drop, `DroppedLink.isWebLink`
  takes only an `http` or `https` URL with a host. Anything else is let go
  without a notice or the sheet. A URL dragged as text from Notes is taken
  as the link it is.
  `testTextOrALinkThatIsNotAWebLinkIsLetGoQuietly` and
  `testTextThatIsAnHTTPSURLIsTakenAsALink` are the checks.

## Safari's Downloads list hands over a file with no URL

This was measured 2026-11-26 the same way. A finished download dragged from
Safari's Downloads list offers only its content type
(`types=["public.zip-archive"]`) and sets `suggestedName`
(`freedoom-0.13.0.zip`). It offers no `public.file-url`. So it goes the
file's way, and its name comes from `suggestedName`, the second step of the
order above. It was imported.

## Not settled

Whether a real cross-app drag from Files (iPad) or Finder (a Designed-for-iPad
Mac window) sets `suggestedName`. Measuring that needs a real drag, which
XCUITest cannot hold across two apps.
