# developer.apple.com's documentation pages have no body; the JSON behind them does

Issue #551 was filed saying Apple's current pages for the App Groups
entitlement, `NSExtensionContext.open(_:completionHandler:)` and privacy
manifests "returned no body when fetched", and fell back to the archived App
Extension Programming Guide. The pages were there. A page under
`https://developer.apple.com/documentation/...` is an empty shell that a
script fills in a browser; a plain HTTP fetch, or a fetch tool that does not
run scripts, gets the shell and nothing to read.

The content is served as JSON at the same path under `/tutorials/data/`, with
`.json` on the end, lower case as the page's URL is:

```console
$ curl -sS https://developer.apple.com/tutorials/data/documentation/bundleresources/privacy-manifest-files.json \
    | wc -c
21639
```

`abstract` holds the summary, and `primaryContentSections[].content` the body,
as nested `inlineContent` runs of `text`, `codeVoice` and `reference` nodes.
Code listings (such as the `group.<group name>` identifier format) are
`codeListing` nodes with a `code` array of lines, so a reader that keeps only
`text` drops them. Pull request 551 quotes the pages it relies on from these
files, fetched on 2026-11-27.

Pages whose URL carries a method signature keep the parentheses and colons:
`.../nsextensioncontext/open(_:completionhandler:).json`.
