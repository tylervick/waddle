# `curl --retry` covers less than it says, and `-f` hides what it would skip

A release download with no retry failed the TestFlight job on one DNS blip on
the runner (`curl: (6) Could not resolve host: github.com`, issue #531), after
seven minutes of dependency and engine builds.

What plain `--retry N` retries is a short, fixed list: a timeout (28), a
resolve failure (6), and HTTP 408, 429, 500, 502, 503 and 504. A refused
connection (7) needs `--retry-connrefused`, and a connection dropped during the
TLS handshake or the transfer (35, 52, 56) needs `--retry-all-errors` -- which
also retries a 404 under `-f`, so a permanent failure is bounded rather than
immediate. With `--retry 5 --retry-delay 2` that bound is six attempts in about
10 s, each printing curl's own message.

Two things make this easy to get wrong by testing it once:

- curl 8.7.1 reports `-f` on a 404 as exit 22 over HTTP/1.1 but exit 56
  over HTTP/2, which is what github.com answers with -- the message, "The
  requested URL returned error: 404", is the same. Match the message, not
  the exit code.
- A stub curl can only echo the flags back. Whether a resolve failure is
  retried is curl's behaviour, so the check runs the real curl.

`Scripts/test-fetch-freedoom.sh` is the check: the real `fetch-freedoom.sh`
and the real curl against a `.invalid` host (exactly six attempts), a
localhost 404 (bounded) and a bad checksum (same message, no retry). `git
clone` has no retry flag at all; `Scripts/build-deps.sh` loops three times
around it, and `Scripts/test-build-deps.sh` cases 12 and 13 pin that.

Left without a retry on purpose: App Store Connect writes (not idempotent;
`Scripts/asc-api.sh` retries only a 429, when Apple says when),
`Scripts/whats-to-test.sh`'s lookup (it already falls back when unavailable),
and `Scripts/check-deps-current.sh`'s header fetch (a failure there is
reported, not fatal).
