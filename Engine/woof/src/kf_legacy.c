//
// Copyright(C) 2025 Roman Fomin
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// [Waddle] Reader for the BINARY keyframe body that Waddle releases 1.0
// through 1.3 wrote (issue #339). Those releases vendored Woof master
// 798acebd, a development snapshot between 15.3.0 and 16.0.0 whose kf_file.c
// serialised the keyframe as little-endian integers in struct order, stamped
// "Woof 16.0.0". Upstream 16.0.0 final replaced that with JSON, so no
// upstream reader for these files exists or will. This file is the read half
// of that snapshot's kf_file.c (Engine/woof/src/kf_file.c at ec6fe07^1), kept
// static so nothing here collides with the JSON reader's names, with three
// deliberate differences, each marked [Waddle]:
//   * player_t lost lastweapon/nextweapon/switching after the snapshot; the
//     three trailing enums are read and dropped.
//   * mobj_t.tint did not exist in the snapshot; it is set to NO_INDEX, as
//     p_saveg.c does for the older binary formats.
//   * nothing is written: saving stays JSON.
// The driver is P_UnArchiveKeyframeBinary(), called from g_game.c for
// saveg_waddle13 at the point the snapshot called P_UnArchiveKeyframe().
//

#include "am_map.h"
#include "d_player.h"
#include "d_think.h"
#include "doomdata.h"
#include "doomstat.h"
#include "doomtype.h"
#include "i_printf.h"
#include "i_system.h"
#include "info.h"
#include "m_arena.h"
#include "m_array.h"
#include "m_fixed.h"
#include "m_random.h"
#include "p_ambient.h"
#include "p_dirty.h"
#include "p_keyframe.h"
#include "p_map.h"
#include "p_maputl.h"
#include "p_mobj.h"
#include "p_saveg.h"
#include "p_setup.h"
#include "p_spec.h"
#include "p_tick.h"
#include "r_defs.h"
#include "r_state.h"

#include <stddef.h>
#include <stdint.h>

#define read8 saveg_read8
#define read16 saveg_read16
#define read32 saveg_read32
#define read64 saveg_read64
#define read_enum read32

enum
{
    null_index = -1,
    head_index = -2,
    dummy_index = -3,
    th_delete_index = -4,
    th_misc_index = -5,
    th_friends_index = -6,
    th_enemies_index = -7,
};

static int tclass_to_index[] = {
    [th_delete] = th_delete_index,
    [th_misc] = th_misc_index,
    [th_friends] = th_friends_index,
    [th_enemies] = th_enemies_index,
};

typedef enum
{
    tc_mobj,
    tc_mobj_del,
    tc_ceiling,
    tc_ceiling_del,
    tc_door,
    tc_door_del,
    tc_floor,
    tc_floor_del,
    tc_plat,
    tc_plat_del,
    tc_flash,
    tc_strobe,
    tc_glow,
    tc_elevator,
    tc_elevator_del,
    tc_scroll,
    tc_pusher,
    tc_flicker,
    tc_friction,
    tc_ambient,
    tc_param_scroll_floor,
    tc_param_scroll_ceiling,
    tc_none
} thinker_class_t;

static actionf_p1 actions[] = {
    [tc_mobj] = P_MobjThinker,
    [tc_mobj_del] = P_RemoveMobjThinkerDelayed,
    [tc_ceiling] = T_MoveCeilingAdapter,
    [tc_ceiling_del] = P_RemoveCeilingThinkerDelayed,
    [tc_door] = T_VerticalDoorAdapter,
    [tc_door_del] = P_RemoveDoorThinkerDelayed,
    [tc_floor] = T_MoveFloorAdapter,
    [tc_floor_del] = P_RemoveFloorThinkerDelayed,
    [tc_plat] = T_PlatRaiseAdapter,
    [tc_plat_del] = P_RemovePlatThinkerDelayed,
    [tc_flash] = T_LightFlashAdapter,
    [tc_strobe] = T_StrobeFlashAdapter,
    [tc_glow] = T_GlowAdapter,
    [tc_elevator] = T_MoveElevatorAdapter,
    [tc_elevator_del] = P_RemoveElevatorThinkerDelayed,
    [tc_scroll] = T_ScrollAdapter,
    [tc_pusher] = T_PusherAdapter,
    [tc_flicker] = T_FireFlickerAdapter,
    [tc_friction] = T_FrictionAdapter,
    [tc_ambient] = T_AmbientSoundAdapter,
    [tc_param_scroll_floor] = T_ParamScrollFloorAdapter,
    [tc_param_scroll_ceiling] = T_ParamScrollCeilingAdapter,
    [tc_none] = NULL
};

typedef struct
{
    thinker_class_t tc;
    union
    {
        thinker_t *thinker;
        mobj_t *mobj;
        ceiling_t *ceiling;
        vldoor_t *door;
        floormove_t *floor;
        plat_t *plat;
        lightflash_t *flash;
        strobe_t *strobe;
        glow_t *glow;
        elevator_t *elevator;
        scroll_t *scroll;
        pusher_t *pusher;
        fireflicker_t *flicker;
        friction_t *friction;
        ambient_t *ambient;
        uintptr_t integer;
    } p;
} thinker_pointer_t;

static thinker_pointer_t *thinker_pointers;
static uintptr_t *msecnode_pointers;
static uintptr_t *ceilinglist_pointers;
static uintptr_t *platlist_pointers;

#define readp_index(ptr, base)                                 \
    do                                                         \
    {                                                          \
        int index = read32();                                  \
        (ptr) = (index != null_index) ? (base) + index : NULL; \
    } while (0)

inline static thinker_t *readp_thinker_index(int index)
{
    if (index == null_index)
    {
        return NULL;
    }
    else if (index == head_index)
    {
        return &thinkercap;
    }
    else if (index == dummy_index)
    {
        return (thinker_t *)P_SubstNullMobj(NULL);
    }
    else
    {
        if (index < 0 || index >= array_size(thinker_pointers))
        {
            I_Error("Wrong index: %d", index);
        }
        return thinker_pointers[index].p.thinker;
    }
}

static thinker_t *readp_thinker(void)
{
    int index = read32();
    return readp_thinker_index(index);
}

static mobj_t *readp_mobj(void)
{
    return (mobj_t *)readp_thinker();
}

static msecnode_t *readp_msecnode(void)
{
    int index = read32();
    if (index == null_index)
    {
        return NULL;
    }
    if (index < 0 || index >= array_size(msecnode_pointers))
    {
        I_Error("Wrong index: %d", index);
    }
    return (msecnode_t *)msecnode_pointers[index];
}

static ceilinglist_t *readp_activeceilings(void)
{
    int index = read32();
    if (index == null_index)
    {
        return NULL;
    }
    if (index < 0 || index >= array_size(ceilinglist_pointers))
    {
        I_Error("Wrong index: %d", index);
    }
    return (ceilinglist_t *)ceilinglist_pointers[index];
}

static platlist_t *readp_activeplats(void)
{
    int index = read32();
    if (index == null_index)
    {
        return NULL;
    }
    if (index < 0 || index >= array_size(platlist_pointers))
    {
        I_Error("Wrong index: %d", index);
    }
    return (platlist_t *)platlist_pointers[index];
}

static void read_mapthing_t(mapthing_t *str)
{
    str->x = read32();
    str->y = read32();
    str->height = read32();
    str->angle = read16();
    str->type = read16();
    str->options = read32();
}

static thinker_t *readp_thclass(void)
{
    int index = read32();
    for (int tclass = 0; tclass < NUMTHCLASS; ++tclass)
    {
        if (index == tclass_to_index[tclass])
        {
            return &thinkerclasscap[tclass];
        }
    }
    return readp_thinker_index(index);
}

static void read_thinker_t(thinker_t *str, thinker_class_t tc)
{
    str->prev = readp_thinker();
    str->next = readp_thinker();
    str->function.p1 = actions[tc];
    str->cnext = readp_thclass();
    str->cprev = readp_thclass();
    str->references = read32();
}

static void read_mobj_t(mobj_t *str, thinker_class_t tc)
{
    read_thinker_t(&str->thinker, tc);
    str->x = read32();
    str->y = read32();
    str->z = read32();
    // Done in UnArchiveThingList
    // str->snext;
    // str->sprev;
    str->angle = read32();
    str->sprite = read_enum();
    str->frame = read32();
    // Done in UnArchiveBlocklinks
    // str->bnext;
    // str->bprev;
    readp_index(str->subsector, subsectors);
    str->floorz = read32();
    str->ceilingz = read32();
    str->dropoffz = read32();
    str->radius = read32();
    str->height = read32();
    str->momx = read32();
    str->momy = read32();
    str->momz = read32();
    str->validcount = read32();
    str->type = read_enum();
    readp_index(str->info, mobjinfo);
    str->tics = read32();
    readp_index(str->state, states);
    str->flags = read32();
    str->flags2 = read32();
    str->flags_extra = read32();
    str->intflags = read32();
    str->health = read32();
    str->tid = read32();
    str->special = read32();
    str->args[0] = read32();
    str->args[1] = read32();
    str->args[2] = read32();
    str->args[3] = read32();
    str->args[4] = read32();
    str->movedir = read16();
    str->movecount = read16();
    str->strafecount = read16();
    str->target = readp_mobj();
    str->reactiontime = read16();
    str->threshold = read16();
    str->pursuecount = read16();
    str->gear = read16();
    readp_index(str->player, players);
    str->lastlook = read16();
    read_mapthing_t(&str->spawnpoint);
    str->tracer = readp_mobj();
    str->lastenemy = readp_mobj();
    str->above_thing = readp_mobj();
    str->below_thing = readp_mobj();
    str->friction = read32();
    str->movefactor = read32();
    str->touching_sectorlist = readp_msecnode();
    str->interp = read32();
    str->oldx = read32();
    str->oldy = read32();
    str->oldz = read32();
    str->oldangle = read32();
    str->bloodcolor = read32();
    // [Waddle] Not in the snapshot's layout; same default p_saveg.c gives
    // the older binary formats.
    str->tint = NO_INDEX;
}

static void read_ticcmd_t(ticcmd_t *str)
{
    str->forwardmove = read8();
    str->sidemove = read8();
    str->angleturn = read16();
    str->consistancy = read16();
    str->chatchar = read8();
    str->buttons = read8();
}

static void read_pspdef_t(pspdef_t *str)
{
    readp_index(str->state, states);
    str->tics = read32();
    str->sx = read32();
    str->sy = read32();
    str->sx2 = read32();
    str->sy2 = read32();
    str->oldsx2 = read32();
    str->oldsy2 = read32();
    str->sxf = read32();
    str->syf = read32();
}

static void read_player_t(player_t *str)
{
    str->mo = readp_mobj();
    str->playerstate = read_enum();
    read_ticcmd_t(&str->cmd);
    str->viewz = read32();
    str->viewheight = read32();
    str->deltaviewheight = read32();
    str->bob = read32();
    str->momx = read32();
    str->momy = read32();
    str->health = read32();
    str->armorpoints = read32();
    str->armortype = read32();
    for (int i = 0; i < NUMPOWERS; ++i)
    {
        str->powers[i] = read32();
    }
    for (int i = 0; i < NUMCARDS; ++i)
    {
        str->cards[i] = read32();
    }
    str->backpack = read32();
    for (int i = 0; i < MAXPLAYERS; ++i)
    {
        str->frags[i] = read32();
    }
    str->readyweapon = read_enum();
    str->pendingweapon = read_enum();
    for (int i = 0; i < NUMWEAPONS; ++i)
    {
        str->weaponowned[i] = read32();
    }
    for (int i = 0; i < NUMAMMO; ++i)
    {
        str->ammo[i] = read32();
    }
    for (int i = 0; i < NUMAMMO; ++i)
    {
        str->maxammo[i] = read32();
    }
    str->attackdown = read32();
    str->usedown = read32();
    str->cheats = read32();
    str->refire = read32();
    str->killcount = read32();
    str->itemcount = read32();
    str->secretcount = read32();
    str->message = NULL;
    str->damagecount = read32();
    str->bonuscount = read32();
    str->attacker = readp_mobj();
    str->extralight = read32();
    str->fixedcolormap = read32();
    str->colormap = read32();
    for (int i = 0; i < NUMPSPRITES; ++i)
    {
        read_pspdef_t(&str->psprites[i]);
    }
    str->secretmessage = NULL;
    str->didsecret = read32();
    str->oldviewz = read32();
    str->pitch = read32();
    str->oldpitch = read32();
    str->slope = read32();
    str->maxkilldiscount = read32();
    str->num_visitedlevels = read32();
    array_clear(str->visitedlevels);
    for (int i = 0; i < str->num_visitedlevels; ++i)
    {
        level_t level = {0};
        level.episode = read32();
        level.map = read32();
        array_push(str->visitedlevels, level);
    }
    // [Waddle] The snapshot's player_t ended with lastweapon, nextweapon and
    // switching (the weapon-switch rework that 16.0.0 final moved out of the
    // player). The fields are gone; the twelve bytes are not.
    (void)read_enum();
    (void)read_enum();
    (void)read_enum();
}

static void read_ceiling_t(ceiling_t *str, thinker_class_t tc)
{
    read_thinker_t(&str->thinker, tc);
    str->type = read_enum();
    readp_index(str->sector, sectors);
    str->bottomheight = read32();
    str->topheight = read32();
    str->speed = read32();
    str->oldspeed = read32();
    str->crush = read32();
    str->newspecial = read32();
    str->oldspecial = read32();
    str->texture = read16();
    str->direction = read32();
    str->tag = read32();
    str->olddirection = read32();
    str->list = readp_activeceilings();
}

static void read_vldoor_t(vldoor_t *str, thinker_class_t tc)
{
    read_thinker_t(&str->thinker, tc);
    str->type = read_enum();
    readp_index(str->sector, sectors);
    str->topheight = read32();
    str->speed = read32();
    str->direction = read32();
    str->topwait = read32();
    str->topcountdown = read32();
    readp_index(str->line, lines);
    str->lighttag = read32();
}

static void read_floormove_t(floormove_t *str, thinker_class_t tc)
{
    read_thinker_t(&str->thinker, tc);
    str->type = read_enum();
    str->crush = read32();
    readp_index(str->sector, sectors);
    str->direction = read32();
    str->newspecial = read32();
    str->oldspecial = read32();
    str->texture = read16();
    str->floordestheight = read32();
    str->speed = read32();
}

static void read_plat_t(plat_t *str, thinker_class_t tc)
{
    read_thinker_t(&str->thinker, tc);
    readp_index(str->sector, sectors);
    str->speed = read32();
    str->low = read32();
    str->high = read32();
    str->wait = read32();
    str->count = read32();
    str->status = read_enum();
    str->oldstatus = read_enum();
    str->crush = read32();
    str->tag = read32();
    str->type = read_enum();
    str->list = readp_activeplats();
}

static void read_lightflash_t(lightflash_t *str)
{
    read_thinker_t(&str->thinker, tc_flash);
    readp_index(str->sector, sectors);
    str->count = read32();
    str->maxlight = read32();
    str->minlight = read32();
    str->maxtime = read32();
    str->mintime = read32();
}

static void read_strobe_t(strobe_t *str)
{
    read_thinker_t(&str->thinker, tc_strobe);
    readp_index(str->sector, sectors);
    str->count = read32();
    str->minlight = read32();
    str->maxlight = read32();
    str->darktime = read32();
    str->brighttime = read32();
}

static void read_glow_t(glow_t *str)
{
    read_thinker_t(&str->thinker, tc_glow);
    readp_index(str->sector, sectors);
    str->minlight = read32();
    str->maxlight = read32();
    str->direction = read32();
}

static void read_fireflicker_t(fireflicker_t *str)
{
    read_thinker_t(&str->thinker, tc_flicker);
    readp_index(str->sector, sectors);
    str->count = read32();
    str->maxlight = read32();
    str->minlight = read32();
}

static void read_elevator_t(elevator_t *str, thinker_class_t tc)
{
    read_thinker_t(&str->thinker, tc);
    str->type = read_enum();
    readp_index(str->sector, sectors);
    str->direction = read32();
    str->floordestheight = read32();
    str->ceilingdestheight = read32();
    str->speed = read32();
}

static void read_scroll_t(scroll_t *str, thinker_class_t tc)
{
    read_thinker_t(&str->thinker, tc);
    str->dx = read32();
    str->dy = read32();
    str->affectee = read32();
    str->control = read32();
    str->last_height = read32();
    str->vdx = read32();
    str->vdy = read32();
    str->accel = read32();
    str->type = read_enum();
}

static void read_pusher_t(pusher_t *str)
{
    read_thinker_t(&str->thinker, tc_pusher);
    str->type = read_enum();
    str->source = readp_mobj();
    str->x_mag = read32();
    str->y_mag = read32();
    str->magnitude = read32();
    str->radius = read32();
    str->x = read32();
    str->y = read32();
    str->affectee = read32();
}

static void read_friction_t(friction_t *str)
{
    read_thinker_t(&str->thinker, tc_friction);
    str->friction = read32();
    str->movefactor = read32();
    str->affectee = read32();
}

static void read_ambient_data_t(ambient_data_t *str)
{
    str->type = read_enum();
    str->mode = read_enum();
    str->close_dist = read32();
    str->clipping_dist = read32();
    str->min_tics = read32();
    str->max_tics = read32();
    str->volume_scale = read32();
    str->sfx_id = read32();
}

static void read_ambient_t(ambient_t *str)
{
    read_thinker_t(&str->thinker, tc_ambient);
    str->source = readp_mobj();
    str->origin = readp_mobj();
    read_ambient_data_t(&str->data);
    str->update_tics = AMB_UPDATE_NOW;
    str->wait_tics = read32();
    str->active = read32();
    str->playing = false;
    str->offset = (float)FixedToDouble(read32());
    str->last_offset = (float)FixedToDouble(read32());
    str->last_leveltime = read32();
}

static void read_rng_t(rng_t *str)
{
    for (int i = 0; i < NUMPRCLASS; ++i)
    {
        str->seed[i] = read32();
    }
    str->rndindex = read32();
    str->prndindex = read32();
}

static void read_button_t(button_t *str)
{
    readp_index(str->line, lines);
    str->where = read_enum();
    str->btexture = read32();
    str->btimer = read32();
}

static void read_msecnode_t(msecnode_t *str)
{
    readp_index(str->m_sector, sectors);
    str->m_thing = readp_mobj();
    str->m_tprev = readp_msecnode();
    str->m_tnext = readp_msecnode();
    str->m_sprev = readp_msecnode();
    str->m_snext = readp_msecnode();
    str->visited = read32();
}

static void read_divline_t(divline_t *str)
{
    str->x = read32();
    str->y = read32();
    str->dx = read32();
    str->dy = read32();
}

static void read_partial_side_t(partial_side_t *str)
{
    str->textureoffset = read32();
    str->rowoffset = read32();
    str->toptexture = read16();
    str->bottomtexture = read16();
    str->midtexture = read16();
}

static void UnArchiveDirty(void)
{
    int count = read32();
    int oldcount = array_size(dirty_lines);
    for (int i = count; i < oldcount; ++i)
    {
        P_CleanLine(&dirty_lines[i]);
    }
    array_resize(dirty_lines, count);
    array_foreach_type(dl, dirty_lines, dirty_line_t)
    {
        dl->line = lines + read32();
        dl->line->dirty = true;
        dl->clean_line.special = read16();
    }

    count = read32();
    oldcount = array_size(dirty_sides);
    for (int i = count; i < oldcount; ++i)
    {
        P_CleanSide(&dirty_sides[i]);
    }
    array_resize(dirty_sides, count);
    array_foreach_type(ds, dirty_sides, dirty_side_t)
    {
        ds->side = sides + read32();
        ds->side->dirty = true;
        read_partial_side_t(&ds->clean_side);
    }
}

inline static void UnArchiveThingList(sector_t *sector)
{
    sector->thinglist = NULL;
    int count = read32();
    if (!count)
    {
        return;
    }
    mobj_t *mobj, **sprev;
    sprev = &sector->thinglist;
    while (count--)
    {
        mobj = readp_mobj();
        *sprev = mobj;
        mobj->sprev = sprev;
        mobj->snext = NULL;
        sprev = &mobj->snext;
    }
}

static void UnArchiveWorld(void)
{
    int i;
    sector_t *sector;

    // do sectors
    for (i = 0, sector = sectors; i < numsectors; i++, sector++)
    {
        sector->floorheight = read32();
        sector->ceilingheight = read32();
        sector->floor_xoffs = read32();
        sector->floor_yoffs = read32();
        sector->ceiling_xoffs = read32();
        sector->ceiling_yoffs = read32();
        sector->floor_rotation = read32();
        sector->ceiling_rotation = read32();
        sector->tint = read32();
        sector->floorpic = read16();
        sector->ceilingpic = read16();
        sector->lightlevel = read16();
        sector->special = read16();
        sector->tag = read16();
        // Woof!
        sector->soundtarget = readp_mobj();
        sector->floordata = readp_thinker();
        sector->ceilingdata = readp_thinker();
        UnArchiveThingList(sector);
        sector->touching_thinglist = readp_msecnode();
    }

    line_t *line;
    for (i = 0, line = lines; i < numlines; i++, line++)
    {
        line->flags = read16();
        line->special = read16();
        for (int j = 0; j < 2; j++)
        {
            if (line->sidenum[j] != NO_INDEX)
            {
                side_t *side = &sides[line->sidenum[j]];
                // killough 10/98: load full sidedef offsets, including
                // fractions
                side->textureoffset = read32();
                side->rowoffset = read32();
                side->toptexture = read16();
                side->bottomtexture = read16();
                side->midtexture = read16();
            }
        }
    }
}

//
// Thinkers
//

static void PrepareUnArchiveThinkers(void)
{
    int count = read32();
    while (count--)
    {
        thinker_pointer_t pointer;
        pointer.tc = read8();
        switch (pointer.tc)
        {
            case tc_mobj:
            case tc_mobj_del:
                pointer.p.mobj = arena_alloc(thinkers_arena, mobj_t);
                break;
            case tc_ceiling:
            case tc_ceiling_del:
                pointer.p.ceiling = arena_alloc(thinkers_arena, ceiling_t);
                break;
            case tc_door:
            case tc_door_del:
                pointer.p.door = arena_alloc(thinkers_arena, vldoor_t);
                break;
            case tc_floor:
            case tc_floor_del:
                pointer.p.floor = arena_alloc(thinkers_arena, floormove_t);
                break;
            case tc_plat:
            case tc_plat_del:
                pointer.p.plat = arena_alloc(thinkers_arena, plat_t);
                break;
            case tc_flash:
                pointer.p.flash = arena_alloc(thinkers_arena, lightflash_t);
                break;
            case tc_strobe:
                pointer.p.strobe = arena_alloc(thinkers_arena, strobe_t);
                break;
            case tc_glow:
                pointer.p.glow = arena_alloc(thinkers_arena, glow_t);
                break;
            case tc_elevator:
            case tc_elevator_del:
                pointer.p.elevator = arena_alloc(thinkers_arena, elevator_t);
                break;
            case tc_scroll:
            case tc_param_scroll_floor:
            case tc_param_scroll_ceiling:
                pointer.p.scroll = arena_alloc(thinkers_arena, scroll_t);
                break;
            case tc_pusher:
                pointer.p.pusher = arena_alloc(thinkers_arena, pusher_t);
                break;
            case tc_flicker:
                pointer.p.flicker = arena_alloc(thinkers_arena, fireflicker_t);
                break;
            case tc_friction:
                pointer.p.friction = arena_alloc(thinkers_arena, friction_t);
                break;
            case tc_ambient:
                pointer.p.ambient = arena_alloc(thinkers_arena, ambient_t);
                break;
            case tc_none:
                pointer.p.thinker = arena_alloc(thinkers_arena, thinker_t);
                break;
            default:
                I_Error("Unknown class: %d", pointer.tc);
                break;
        }
        array_push(thinker_pointers, pointer);
    }
}

static void UnArchiveThinkers(void)
{
    array_foreach_type(pointer, thinker_pointers, thinker_pointer_t)
    {
        switch (pointer->tc)
        {
            case tc_mobj:
            case tc_mobj_del:
                read_mobj_t(pointer->p.mobj, pointer->tc);
                P_AddThingTID(pointer->p.mobj, pointer->p.mobj->tid);
                break;
            case tc_ceiling:
            case tc_ceiling_del:
                read_ceiling_t(pointer->p.ceiling, pointer->tc);
                break;
            case tc_door:
            case tc_door_del:
                read_vldoor_t(pointer->p.door, pointer->tc);
                break;
            case tc_floor:
            case tc_floor_del:
                read_floormove_t(pointer->p.floor, pointer->tc);
                break;
            case tc_plat:
            case tc_plat_del:
                read_plat_t(pointer->p.plat, pointer->tc);
                break;
            case tc_flash:
                read_lightflash_t(pointer->p.flash);
                break;
            case tc_strobe:
                read_strobe_t(pointer->p.strobe);
                break;
            case tc_glow:
                read_glow_t(pointer->p.glow);
                break;
            case tc_elevator:
            case tc_elevator_del:
                read_elevator_t(pointer->p.elevator, pointer->tc);
                break;
            case tc_scroll:
            case tc_param_scroll_floor:
            case tc_param_scroll_ceiling:
                read_scroll_t(pointer->p.scroll, pointer->tc);
                break;
            case tc_pusher:
                read_pusher_t(pointer->p.pusher);
                break;
            case tc_flicker:
                read_fireflicker_t(pointer->p.flicker);
                break;
            case tc_friction:
                read_friction_t(pointer->p.friction);
                break;
            case tc_ambient:
                read_ambient_t(pointer->p.ambient);
                break;
            case tc_none:
                read_thinker_t(pointer->p.thinker, pointer->tc);
                break;
        }
    }
}

//
// MSecNodes
//

static void PrepareUnArchiveMSecNodes(void)
{
    int count = read32();
    array_resize(msecnode_pointers, count);
    for (int i = 0; i < count; ++i)
    {
        msecnode_t *node = arena_alloc(msecnodes_arena, msecnode_t);
        msecnode_pointers[i] = (uintptr_t)node;
    }
}

static void UnArchiveMSecNodes(void)
{
    int count = array_size(msecnode_pointers);
    for (int i = 0; i < count; ++i)
    {
        read_msecnode_t((msecnode_t *)msecnode_pointers[i]);
    }
}

//
// Players
//

static void UnArchivePlayers(void)
{
    for (int i = 0; i < MAXPLAYERS; i++)
    {
        if (playeringame[i])
        {
            read_player_t(&players[i]);
        }
    }
}

//
// Blocklinks
//

static void UnArchiveBlocklinks(void)
{
    int blocklinks_count = bmapwidth * bmapheight;
    for (int i = 0; i < blocklinks_count; ++i)
    {
        blocklinks[i] = NULL;
        int count = read32();
        if (count)
        {
            mobj_t *mobj;
            mobj_t **bprev = &blocklinks[i];
            while (count--)
            {
                mobj = readp_mobj();
                *bprev = mobj;
                mobj->bprev = bprev;
                mobj->bnext = NULL;
                bprev = &mobj->bnext;
            }
        }
    }
}

//
// CeilingList
//

static void PrepareUnArchiveCeilingList(void)
{
    int count = read32();
    array_resize(ceilinglist_pointers, count);
    for (int i = 0; i < count; ++i)
    {
        ceilinglist_t *cl = arena_alloc(activeceilings_arena, ceilinglist_t);
        ceilinglist_pointers[i] = (uintptr_t)cl;
    }
}

static void UnArchiveCeilingList(void)
{
    int count = array_size(ceilinglist_pointers);
    ceilinglist_t *cl, **prev;
    prev = &activeceilings;
    for (int i = 0; i < count; ++i)
    {
        cl = (ceilinglist_t *)ceilinglist_pointers[i];
        cl->ceiling = (ceiling_t *)readp_thinker();
        *prev = cl;
        cl->prev = prev;
        cl->next = NULL;
        prev = &cl->next;
    }
}

//
// PlatList
//

static void PrepareUnArchivePlatList(void)
{
    int count = read32();
    array_resize(platlist_pointers, count);
    for (int i = 0; i < count; ++i)
    {
        platlist_t *pl = arena_alloc(activeplats_arena, platlist_t);
        platlist_pointers[i] = (uintptr_t)pl;
    }
}

static void UnArchivePlatList(void)
{
    int count = array_size(platlist_pointers);
    platlist_t *pl, **prev;
    prev = &activeplats;
    for (int i = 0; i < count; ++i)
    {
        pl = (platlist_t *)platlist_pointers[i];
        pl->plat = (plat_t *)readp_thinker();
        *prev = pl;
        pl->prev = prev;
        pl->next = NULL;
        prev = &pl->next;
    }
}

//
// Buttons
//

static void UnArchiveButtons(void)
{
    for (int i = 0; i < MAXBUTTONS; ++i)
    {
        read_button_t(&buttonlist[i]);
    }
}

//
// Automap
//

static void UnArchiveAutoMap(void)
{
    automapactive = read32();
    viewactive = read32();
    followplayer = read32();
    automap_grid = read32();

    if (automapactive)
    {
        AM_Start();
    }

    markpointnum = read32();
    if (markpointnum)
    {
        while (markpointnum >= markpointnum_max)
        {
            markpointnum_max = markpointnum_max ? markpointnum_max * 2 : 16;
            markpoints =
                Z_Realloc(markpoints, sizeof(*markpoints) * markpointnum_max,
                          PU_STATIC, 0);
        }
        for (int i = 0; i < markpointnum; ++i)
        {
            markpoints[i].x = read64();
            markpoints[i].y = read64();
        }
    }
}

static void StartUnArchive(void)
{
    M_ArenaClear(thinkers_arena);
    M_ArenaClear(msecnodes_arena);
    M_ArenaClear(activeceilings_arena);
    M_ArenaClear(activeplats_arena);
}

static void EndUnArchive(void)
{
    array_free(thinker_pointers);
    array_free(msecnode_pointers);
    array_free(ceilinglist_pointers);
    array_free(platlist_pointers);
}

void P_UnArchiveKeyframeBinary(void)
{
    StartUnArchive();

    PrepareUnArchiveThinkers();

    read_thinker_t(&thinkercap, tc_none);
    for (int i = 0; i < NUMTHCLASS; ++i)
    {
        read_thinker_t(&thinkerclasscap[i], tc_none);
    }

    PrepareUnArchiveMSecNodes();

    headsecnode = readp_msecnode();

    UnArchiveDirty();
    UnArchiveWorld();

    // p_map.h
    floatok = read32();
    felldown = read32();
    tmfloorz = read32();
    tmceilingz = read32();
    hangsolid = read32();

    readp_index(ceilingline, lines);
    readp_index(floorline, lines);
    linetarget = readp_mobj();
    sector_list = readp_msecnode();
    readp_index(blockline, lines);

    for (int i = 0; i < arrlen(tmbbox); ++i)
    {
        tmbbox[i] = read32();
    }

    // p_maputil.h
    opentop = read32();
    openbottom = read32();
    openrange = read32();
    lowfloor = read32();

    read_divline_t(&trace);

    // p_setup.h
    UnArchiveBlocklinks();

    // p_spec.h
    PrepareUnArchiveCeilingList();
    PrepareUnArchivePlatList();

    UnArchivePlayers();
    UnArchiveThinkers();
    UnArchiveMSecNodes();

    activeceilings = readp_activeceilings();
    UnArchiveCeilingList();
    activeplats = readp_activeplats();
    UnArchivePlatList();

    read_rng_t(&rng);

    UnArchiveButtons();
    UnArchiveAutoMap();

    EndUnArchive();
}
