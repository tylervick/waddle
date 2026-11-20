# altool prints `ERROR:` for an App Store Connect lookup it then retries, and uploads anyway

`Scripts/upload.sh` treats any `ERROR:` line in altool's transcript as a
failed upload, because altool exits 0 on real rejections (issue 240). On
2026-11-17 that rule failed a release whose upload had worked (issue 390,
run 44155695412, build 293):

```
2026-11-17 19:57:32.140 ERROR: [CDASCAPI.7BD1045340] APP STORE CONNECT API list-apps: received status code 500; internal server error. (…) (500)
2026-11-17 19:57:37.184 ERROR: [CDASCAPI.7BD1045340] APP STORE CONNECT API list-apps: received status code 500; internal server error. (…) (500)
…
UPLOAD SUCCEEDED with no errors
Delivery UUID: 2b3803a9-1144-4110-aa1f-a180096dd901
```

altool's own `list-apps` call got two 500s, it retried, and the delivery
went through; App Store Connect listed build 293 as VALID 43 seconds after
the success line.

**The cost is not the red run, it is the missing tag.** The job stopped at
the upload step, so "Tag the shipped build" never ran. App Store Connect held
a build that no `build-*` tag recorded, and the next merge would have derived
293 again and been refused as a duplicate. The step's message said only
"Verify in App Store Connect"; the tag repair is printed by the tag step,
which is exactly the step that did not run. The tag was pushed by hand
before the next release job started, a day later.

**A fail-closed guard has two ways to be wrong, and this one only counted
one.** Refusing a real upload is not the safe direction here: it leaves the
release in a state that needs a hand repair before the next merge, just as
accepting a failed one leaves a phantom tag.

`Scripts/upload.sh` now forgives an `ERROR:` line only when every
error-shaped line is a 5xx from an App Store Connect API call, nothing in
the transcript is an ITMS code or a FAILED summary, and exactly one
`UPLOAD SUCCEEDED with no errors` follows them with a `Delivery UUID:` on
the next line. Every other refusal that comes after an `UPLOAD SUCCEEDED`
line now says the build may be uploaded and names the tag repair.
`Scripts/test-upload.sh` pins the transcript above and one variant per
condition.

**What this rests on:** one transcript. It assumes altool does not print
`UPLOAD SUCCEEDED with no errors` and a Delivery UUID for a delivery that
did not happen. The Xcode 26 lie the guard was first written for used
different words ("Successfully uploaded.") beside an ITMS code, which is
still refused. If the assumption turns out false, the notes step fails
loudly a few minutes later (it polls for the build and reports that it
never appeared), but the tag will already be pushed.
