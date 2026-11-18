# Under `demo_compatibility` a weapon number above 7 arrives as the fist

At a vanilla compatibility level `P_PlayerThink` reads the weapon from
`cmd->buttons & BT_WEAPONMASK_OLD` (`p_user.c`), three bits. The super
shotgun is `wp_supershotgun` (8), so `8 << BT_WEAPONSHIFT` falls outside
the mask and the command reads `wp_fist`, which the same function then
turns into the chainsaw if one is owned. A `BT_CHANGE` built straight from
a weapon number therefore gives the player the fist or the chainsaw when
they asked for the SSG.

Woof's own `9` key never meets this: it goes through `WeaponSSG()` in
`g_game.c`, which at `demo_compatibility` sends the shotgun and lets
`P_PlayerThink`'s shotgun-to-SSG swap do the rest. And `P_SwitchWeapon`
can return `wp_supershotgun` there too, so a "best weapon" resolution is
as exposed as a direct pick.

Paid for twice on the weapon-select grid (2026-11-17): the direct pick was
fixed in review, and the select-best arm of the same expression was missed
until the final review.

**What to do:** every path that builds `BT_CHANGE` from a weapon number,
direct or resolved, translates the super shotgun at `demo_compatibility`:
`if (demo_compatibility && newweapon == wp_supershotgun) newweapon = WeaponSSG();`.
The touch latch in `G_BuildTiccmd` does it once, after both arms.

**Provenance:** `tylervick/weapon-select-grid`, 2026-11-17.
