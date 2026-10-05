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
