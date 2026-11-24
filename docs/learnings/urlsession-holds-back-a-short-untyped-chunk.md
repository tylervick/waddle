# URLSession holds back a short body chunk with no Content-Type

**Symptom.** A `URLProtocol` stub sends a response and a first chunk of a
few dozen bytes, then stalls (to test cancelling a download mid-way). The
data delegate's `didReceive data` never fires, so a test waiting for
progress times out with "the download never started" (#500,
`LinkImportTests.testACancelledDownloadLeavesNoFileAndNoNotice`).

**Cause.** With no `Content-Type` header, URLSession sniffs the MIME type
from the body and holds a short first chunk back while it does. A stub that
finishes the response straight away hides this: the end of the body
releases the chunk. Measured on the iOS 27.0 simulator: the same short chunk
with `Content-Type: application/octet-stream` arrives at once. (How much
untyped body it waits for was not measured.)

**Fix.** Give a stub that stalls a `Content-Type`. Production code is
unaffected: `LinkDownloader`'s web-page check reads the first body bytes
whenever they arrive.
