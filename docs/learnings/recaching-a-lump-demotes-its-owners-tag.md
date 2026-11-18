# Re-caching a lump or patch with a weaker tag demotes a block someone else holds

`W_CacheLumpNum` does not give a second caller its own copy. If the lump is
already in `lumpcache`, it calls `Z_ChangeTag(lumpcache[lump], tag)` and
returns the same block, with the caller's tag. `V_CachePatchNum` goes the
same way for patches. So a read "just for a moment" at `PU_CACHE` turns a
block its owner cached `PU_STATIC` into a purgeable one, and the next level
load's `Z_FreeTag(PU_CACHE)` frees it under the owner. Nothing fails at the
read; the crash or the garbage comes a level later, somewhere else.

Found in review on 2026-11-17, on the weapon-select grid: copying PLAYPAL
re-cached the palette `V_InitPalette` keeps `PU_STATIC`, and copying a
weapon sprite through `V_CachePatchNum` demoted patches the status bar
caches `PU_STATIC`.

**What to do:** from shim code, read an already-cached lump in place
(`lumpcache[lump]`, or the owner's own pointer such as
`playpal_global->data`), and cache only what nobody holds yet. Never pass a
tag weaker than the one the block may already have. `WoofIOS_CopyPlaypal`
and `WoofIOS_CopyWeaponSprite` in `woof_ios.c` are the pattern.

**Provenance:** `tylervick/weapon-select-grid`, 2026-11-17.
