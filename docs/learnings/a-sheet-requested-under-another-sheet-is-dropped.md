# A sheet asked for while another sheet is up is dropped, and the work behind it runs unseen

Found by the review of pull request 561 (#551). Waddle picked up a link shared
from Safari when it returned to the foreground, started its download, and set
the shelf's `showLinkImport` to show the From a Link sheet. With the Settings
sheet still open from before the player left, SwiftUI logged the fault
"Currently, only presenting a single sheet is supported" and presented nothing.
The download ran anyway, its end-of-queue notice was posted under the open
sheet and had expired by the time Settings closed, and the player never saw
what happened to the link.

Nothing in the app reports the refused sheet: the `Bool` binding stays `true`,
and the fault reaches only the unified log.

## What to do

Work that is started by something other than the player's tap on the shelf
(a foreground event, a timer, a notification) and that needs a sheet to be
seen must not start until the sheet can be shown. `SharedLinkPickup` checks
the key window's root controller and every child for a
`presentedViewController` (SwiftUI presents from inside navigation stacks, so
the root alone is not enough), that no game session is running, and that the
app is active; while any of these says no, the link stays in its inbox and the
pick-up looks again every second. `SharedLinkUITests` is the check.

A drop cannot hit this: the drop target is the shelf, which a sheet covers.
