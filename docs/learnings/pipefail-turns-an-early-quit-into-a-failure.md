# `pipefail` turns a downstream early-quit into a failure — above 64K

`sed -n 'N,$p' file | sed -n '/^};/q;p'` is a natural way to slice a block out of
a file. Under `set -o pipefail` it is a bug, and a size-dependent one.

The downstream `sed` quits at the closing brace and closes the pipe. The upstream
`sed` is still writing, takes SIGPIPE, and exits 141. `pipefail` propagates that,
so the pipeline fails even though the extraction succeeded and the correct text
was produced.

It only bites when the text left unwritten exceeds the pipe buffer, about 64K.
Below that the upstream finishes into the buffer and exits 0. So the failure is
invisible on small inputs and appears on large ones — in
`Scripts/check-eas-bank.sh` every array extracted cleanly except the 13,000-line
`eas_samples`, which is precisely the one that matters.

Read one file once with `awk` instead of chaining two early-quitting readers:

```bash
awk -v start="$start" 'NR > start { if ($0 ~ /^};/) { exit } print }' "$file"
```

`awk` exits after its own `exit`, with nothing upstream still writing. The same
applies to `head` and to `grep -m1` as the downstream end of a pipe whose
upstream is long-running. Reach for `|| true` here and the real failures go with
it; the fix is to stop building a pipeline that kills its own producer.
