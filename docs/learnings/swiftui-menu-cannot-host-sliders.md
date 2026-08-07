# SwiftUI `Menu` cannot render `Slider` rows

`UIMenu` has no slider element, so a `Slider` placed in a `Menu` silently fails
to appear. This is a UIKit limitation surfacing through SwiftUI, not a layout
bug to be worked around.

**What to do instead:** the touch-tuning sliders live in the Control Feel sheet
(`ControlFeelView`), opened from the gear menu.

**Provenance:** PR #3 (touch tuning), where the sliders were first attempted
inside the gear `Menu`.
