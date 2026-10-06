# UI test fixtures

## `freedoom-e1m1-znod.wad`

Freedoom Phase 1's E1M1 (`App/Resources/GameData/freedoom1.wad`, Freedoom
0.13.0, BSD licence in `App/Resources/Licenses/FREEDOOM-BSD.txt`) as a
single-map PWAD whose nodes were rebuilt by ZDBSP in the **compressed
extended format** (`ZNOD`), with an empty REJECT. It exists so
`WaddleUITests/CompressedNodesTests` can drive `P_LoadNodes_ZDBSP`'s inflate
path (Woof upstream `cc1d13e9`, the buffer-reallocation fix issue #79 was
opened for) and, with its BLOCKMAP lump emptied in the test, the
blockmap-presence check (`42470994`) on a map that is free to redistribute.
Nothing in CI loads a modern PWAD otherwise.

Lumps: `E1M1 THINGS LINEDEFS SIDEDEFS VERTEXES SEGS(0) SSECTORS(0)
NODES(ZNOD, 25715 bytes) SECTORS REJECT(0) BLOCKMAP`.

Regenerate (ZDBSP 1.19, `rheit/zdbsp` `f324e34`, built with the repo's
cmake; its `getopt.c` needs `#include <stdlib.h>` added at the top on
current clang):

```sh
python3 - <<'PY'   # extract E1M1 from freedoom1.wad into freedoom-e1m1.wad
import struct
d=open('App/Resources/GameData/freedoom1.wad','rb').read()
_,n,off=struct.unpack('<4sii',d[:12])
L=[(struct.unpack('<ii',d[off+i*16:off+i*16+8]),d[off+i*16+8:off+i*16+16].rstrip(b'\0').decode()) for i in range(n)]
i=[l[1] for l in L].index('E1M1'); sel=[L[i]]; j=i+1
while L[j][1] in ('THINGS','LINEDEFS','SIDEDEFS','VERTEXES','SEGS','SSECTORS','NODES','SECTORS','REJECT','BLOCKMAP'): sel.append(L[j]); j+=1
out=bytearray(b'PWAD'+struct.pack('<ii',len(sel),0)); ents=[]
for (pos,size),name in sel: ents.append((len(out),size,name)); out+=d[pos:pos+size]
out[8:12]=struct.pack('<i',len(out))
for pos,size,name in ents: out+=struct.pack('<ii',pos,size)+name.encode().ljust(8,b'\0')
open('freedoom-e1m1.wad','wb').write(out)
PY
zdbsp -z -r -t -o App/UITests/Fixtures/freedoom-e1m1-znod.wad freedoom-e1m1.wad
```

## `suspend-waddle-1.3.dsg`

A background-suspend save written by Waddle 1.3 (commit `d943691`, App Store
build 277) on Freedoom Phase 1 E1M1, skill 1, a few seconds into the level.
It is the save format every release through 1.3 wrote: binary, stamped
`Woof 16.0.0` at offset 24, with the body in the keyframe layout of the
development snapshot those releases vendored (Woof master `798acebd`). Woof
16.0.0 final, vendored since PR #328, writes JSON instead and its legacy
loader recognises nothing newer than `Woof 15.0.0`, so this file is what an
upgrading player's save looks like to the current engine. Nothing loads it
yet; it is here so the fix for that has a real file to prove itself against.

SHA-256 `2025093b9f8699435c103a005c08fd8e265061c960d58dcce119bcda16386d9f`,
171481 bytes. The only path it embeds is the string `freedoom1.wad`.

Regenerate (needs an engine build matching `d943691`; the engine inputs are
unchanged between `d943691` and any pre-#328 commit, so a `Vendor/out` built
there passes `Scripts/check-engine-fresh.sh`):

```sh
git worktree add --detach ../waddle-1.3 d943691 && cd ../waddle-1.3
# provide Vendor/out, App/Resources/GameData and woof.pk3, then:
(cd App && xcodegen generate)
xcodebuild -project App/Waddle.xcodeproj -scheme Waddle \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:WaddleUITests/BackgroundSuspendTests/testBackgroundingALiveLevelOpensTheMenuAndWritesASave test
# the save is left in the app's data container:
find ~/Library/Developer/CoreSimulator/Devices/<udid>/data/Containers/Data/Application \
  -name suspend.dsg
```
