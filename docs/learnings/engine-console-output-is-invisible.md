# Engine console output does not reach `log stream`

The engine's diagnostics are `fprintf`-based, so they never enter the unified
logging system. `log stream` shows nothing no matter how the filters are set,
which reads as "the engine printed nothing" when it printed plenty.

**What to do instead:** export stdout from the `.xcresult` bundle, or launch
with `simctl launch --console-pty`.

**Provenance:** Plan 1 diagnosis, after time was lost assuming silence meant
the engine had not reached the failing code.
