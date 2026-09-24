# SwiftUI `Text("…\(n)")` prints 1500 as "1,500"

Found 2026-09-23 adding the `zowned=<KB>` debug label for #269.

`Text("zowned=\(value)")` takes a `LocalizedStringKey`, and its interpolation
formats integers for the current locale, with a grouping separator. The label
read `zowned=1,500`, and the UI test's `Int("1,500")` was nil. The test first
reported that as "label missing", which cost a red run: the label was there,
it just did not parse.

For any label a test parses, use `Text(verbatim: "zowned=\(value)")`, which
uses the plain `description`. The other debug labels in `ContentView` build a
`String` first (`Text(String(cString: ...))`), which is also safe.
