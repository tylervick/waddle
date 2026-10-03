//
// iOS host-app entry points for Woof! (WOOF_IOS builds only).
//
#ifndef WOOF_IOS_H
#define WOOF_IOS_H

// Runs a complete engine session on the calling thread (must be the app's
// main thread; SDL on iOS requires it). Blocks until the engine quits or
// aborts via I_Error. Returns the engine exit code (0 = clean quit,
// negative = error). May be called again after it returns.
int WoofIOS_Run(int argc, char **argv);

// Asks the running engine to quit, as if the user chose Quit in the menu.
// Safe to call from any thread. No-op if the engine is not running.
void WoofIOS_RequestQuit(void);

// Internal: called by I_SafeExit instead of exit(). Unwinds to WoofIOS_Run.
void WoofIOS_ExitUnwind(int rc);

// --- Touch-control shim (Plan 3) ---
// The native overlay drives a virtual SDL gamepad; the engine consumes it
// through its normal, user-remappable gamepad bindings. Turn is injected
// into a shim-owned accumulator (there is no SDL event path from a pushed
// SDL_EVENT_MOUSE_MOTION to I_ReadMouse's polled SDL_GetRelativeMouseState
// -- see WoofIOS_ConsumeTouchTurn below and the i_input.c patch documented
// in WOOF_UPSTREAM.md). All functions are main-thread-only (same thread as
// WoofIOS_Run; SDL pumps the run loop, so UIKit callbacks qualify).

#include <stdbool.h>

bool WoofIOS_AttachTouchGamepad(void);
void WoofIOS_DetachTouchGamepad(void);
void WoofIOS_SetTouchAxis(int sdl_axis, float value);
void WoofIOS_SetTouchButton(int sdl_button, bool down);

// Drives a trigger axis (SDL_GAMEPAD_AXIS_LEFT_TRIGGER/RIGHT_TRIGGER) as a
// digital press/release rather than a scaled float. Required because the
// virtual joystick auto-maps both trigger inputs as FULL-RANGE axes (plain
// "a4"/"a5", no "+" half-axis prefix -- see the fix-round comment on this
// function in woof_ios.c for the full citation trail), so writing a scaled
// float through WoofIOS_SetTouchAxis leaves the gamepad-layer trigger value
// stuck around 50% on release instead of 0%, permanently above
// trigger_threshold (i_gamepad.c) -- the FIRE-autofires-forever regression.
// `down` true writes SDL_JOYSTICK_AXIS_MAX; false writes SDL_JOYSTICK_AXIS_MIN.
void WoofIOS_SetTouchTrigger(int sdl_axis, bool down);

void WoofIOS_InjectRelativeTurn(float dx_points);
void *WoofIOS_GetUIWindowPointer(void);
int WoofIOS_DebugTouchEventCount(void);

// Debug/test telemetry only (issue #48): the writes behind that count, per
// control. How many times the overlay wrote a given SDL gamepad button
// (SDL_GAMEPAD_BUTTON_*), a given axis (SDL_GAMEPAD_AXIS_*; triggers are
// axes), or injected a turn, this session. Out-of-range indices read 0.
int WoofIOS_DebugTouchButtonWrites(int sdl_button);
int WoofIOS_DebugTouchAxisWrites(int sdl_axis);
int WoofIOS_DebugTouchTurnWrites(void);
int WoofIOS_DebugTouchKeyWrites(int key); // keys from WoofIOS_InjectKey
// The same as one line, non-zero entries only:
//   "touchWrites: b<button>:<n> ... a<axis>:<n> ... k<key>:<n> ... turn:<n>"
// so one USE tap reads "touchWrites: b0:2 turn:0" and a stick drag lists
// axes and no button. Shown after a session under WADDLE_DEBUG_INPUT_COUNTS.
const char *WoofIOS_DebugTouchWrites(void);

// Last engine error text (Woof!'s i_system.c errmsg buffer). Empty string
// when the previous session exited cleanly. Reset at each session start.
const char *WoofIOS_LastErrorMessage(void);

// True whenever Woof's escape-menu system (mn_menu.c) is overlaying the
// game -- title/demo state does not count, only an actually-open menu
// screen (main menu, options, Load/Save, etc.). A thin wrapper around the
// engine's own `menuactive` global (doomstat.h) so the overlay can suppress
// controls whose gameplay binding collides with a *menu-context* binding
// on the same physical button -- see the fix-round comment on
// WoofIOS_IsMenuActive's implementation in woof_ios.c for the MAP/NORTH
// case this was added for.
bool WoofIOS_IsMenuActive(void);

// Debug/test telemetry only: returns the RIGHT_TRIGGER axis value as Woof's
// *gamepad* layer (not the raw joystick axis) reports it, normalized to
// 0..1, or -1 if the touch gamepad isn't attached / can't be opened. Lets a
// UITest verify the MAPPED value actually seen by TriggerToButton
// (i_input.c), not just the raw value the overlay wrote.
float WoofIOS_DebugTriggerValue(void);

// Debug/test telemetry only: the main-menu and episode-menu table values
// ("main=<numitems>@<y> epi=<numitems>@<y>") as mn_menu.c holds them right
// now. The tables are process-lifetime statics, so read after a session
// ends this is what the next session inherits (issue #253).
const char *WoofIOS_DebugMenuGeometry(void);

// Debug/test telemetry only: the values issue #266 found a session
// inheriting from the one before it, as they stood when the most recent
// session reached its game loop (after init and the first tic, before the
// first frame) --
//   "exit=<fast_exit> wipe=<wipegamestate>/<screen_wipe_internal>
//    oldgs=<D_Display's oldgamestate> view=<viewactivestate>
//    demoprev=<demoloop_prev set> autoload=<autoload dirs> states=<n>
//    mobj=<n> sfx=<n> spr=<n> colors=<colorized messages>
//    faces=<status-bar face patches> music=<songs started this session>
//    arenas=<MB of address space reserved by live arenas>
//    compdb=<compatibility database records>"
// Two sessions of one game must report the same string. Empty before the
// first session reaches its game loop.
const char *WoofIOS_DebugSessionStartState(void);

// Debug/test telemetry only: KB of PU_STATIC zone memory with no owner
// pointer (module-owned tables, not cached lumps) when the most recent
// session reached its game loop. Two title-only sessions of one game should
// report about the same; every session used to add ~1.4 MB (issue #269).
int WoofIOS_DebugSessionStartZoneKB(void);

// Debug/test telemetry only: KB of PU_STATIC and PU_CACHE zone memory that
// does have an owner pointer (cached lumps and patches) at the same point.
// Two title-only sessions of one game should report about the same; the
// previous session's lump cache used to stay behind (issue #269).
int WoofIOS_DebugSessionStartLumpsKB(void);

// Debug/test telemetry only: "zipwads=<live>/<total>", the decompressed WADs
// that w_zip.c's AddWadInMem (a .wad at the root of a zip or pk3) holds right
// now, and how many it has allocated in this process. Read after a session;
// every session used to leave its buffers behind, and a load that failed
// part-way its one buffer (issue #38).
const char *WoofIOS_DebugZipWadBuffers(void);

// Debug/test telemetry only: "bgsave=<n> bgpause=<n> bglt=<leveltime>", how
// many times the app's lifecycle has made the engine write the suspend save
// (background entry in a live level) and open the menu (resign-active in a
// live level) in this process, and the leveltime the last such save captured
// (issue #111). Counted where the acts happen, never reset.
const char *WoofIOS_DebugBackgroundState(void);

// Debug/test telemetry only: "win=<w>x<h>", the engine's SDL window size in
// points right now (0x0 before it exists). In the in-game debug HUD so a UI
// test can compare it with the screen: a session started with the device in
// landscape kept the portrait size (issue #291).
const char *WoofIOS_DebugWindowState(void);

// Debug/test telemetry only: "gs=<level|demo|inter|finale|title|none>
// load=<-loadgame argument, -1 without> lt=<leveltime, 0 outside a level>",
// as they stand right now; demo is a level under demo playback. In the
// in-game debug HUD, so a test can tell a resumed save (load=254, gs=level)
// from the title a failed command-line load falls back to (whose demo loop
// reaches a level within seconds), and from a -warp (load=-1).
const char *WoofIOS_DebugGameState(void);
// Debug/test telemetry only: the state the most recent session was handed at
// entry, before D_DoomMain (issue #268) --
//   "amlvl=<AM_Start's last map>/<episode> amstop=<automap stopped>
//    amdef=<AMAPDEF parsed> amcol=<AM_ApplyColors first call pending>
//    msg=<message tics left>/<centred message element set>
//    sbar=<statusbar set> rewind=<keyframes queued> pad=<stale gamepad>
//    rumble=<stale rumble gamepad> tex=<stale video texture>
//    cmap=<colormaps set> skipbl=<skipblstart>
//    dehtab=<hash of the weapon/ammo/misc tables DEHACKED patches>
//    dehstr=<string replacements> dehfiles=<-deh files listed>
//    cheats=<cheat codes replaced> pars=<par times changed>
//    dloop=<default demo-loop entries edited>
//    dirtylv=<levels in p_dirty's archive> compres=<COMPDB restore pending>"
// A fresh process reads "amlvl=-1/-1 amstop=1 amdef=0 amcol=1 msg=0
// sbar=0 rewind=0 pad=0 rumble=0 tex=0 cmap=0 skipbl=0 dehtab=<its own>
// dehstr=0 dehfiles=0 cheats=0 pars=0 dloop=0 dirtylv=0 compres=0 pcheats=0",
// and so must every later
// session; dehtab must equal the first session's.
const char *WoofIOS_DebugSessionEntryState(void);

// Debug/test telemetry only: "pcheats=<flags>", the console player's cheat
// flags (d_player.h cheat_t: CF_NOCLIP 1, CF_GODMODE 2) right now. Read after
// a session that typed iddqd, it shows the cheat took; the statics outlive
// the session (issue #304). Shown on the post-session zone line.
const char *WoofIOS_DebugPlayerCheatsNow(void);

// Debug/test telemetry only: the DEHACKED-patched state as it stands right
// now -- "now dehtab=<hash> dehfiles=<n> cheats=<n> pars=<n>" (fields as in
// WoofIOS_DebugSessionEntryState). Read after a session that loaded a patch,
// it shows the patch took (issue #270).
const char *WoofIOS_DebugDehNow(void);

// Debug/test telemetry only: "now dirtylv=<n> compres=<0|1>", p_dirty's
// archived levels and the COMPDB restore flag as they stand right now. Read
// after a session run with WADDLE_DEBUG_ARCHIVE_LEVEL/_COMPDB_MATCH, it shows
// the hooks fired (issue #268).
const char *WoofIOS_DebugLevelStateNow(void);

// Debug/test telemetry only: "ambox=<min x>,<min y>,<max x>,<max y>", the
// map bounds the automap last computed (AM_LevelInit), in map units. Read
// after a session that opened the automap, it is that session's map's.
const char *WoofIOS_DebugAutomapBounds(void);

// Debug/test telemetry only: what the engine sees of the overlay's input,
// for the in-game debug HUD --
//   "pad=<name> <virtual|foreign|none> pads=<count> btn=<events> menu=<item|off>"
// where virtual means the gamepad the engine has open IS the overlay's
// virtual pad (so its axes are read), foreign means some other controller
// got there first (buttons still arrive, axes do not), btn counts gamepad
// button events the engine has turned into its own events this session, and
// menu is the cursor item while a menu is up. Built so a Revyl device run
// can read from a screenshot why a USE tap or a stick drag did nothing.
const char *WoofIOS_DebugInputState(void);

// Make the engine read its gamepad input from the overlay's virtual pad even
// if another controller was opened first. The host app calls this whenever
// the overlay is the intended input (visible, or forced by the proof
// harness); with a real controller in use the overlay hides and this is not
// called, so the engine keeps that controller. No-op before the pad exists.
void WoofIOS_SelectTouchGamepad(void);

// The converse: a physical controller connected and the host app hid its
// overlay, so the engine should read that controller. Picks the first
// gamepad SDL lists that is not the overlay's virtual pad; no-op when there
// is none. The virtual pad stays attached, so WoofIOS_SelectTouchGamepad can
// take input back when the controller goes away.
void WoofIOS_SelectPhysicalGamepad(void);

// Debug/test telemetry only, engine-internal (called from d_main.c at the top
// of the game loop): with WADDLE_DEBUG_GLOBALS_DIFF in the environment,
// snapshots the writable data sections of the image the engine is linked
// into and, from the second call on, prints one GLOBALDIFF line per byte
// range that changed since the previous call. Scripts/globals-diff.py names
// the variables. This is how the stale-static family behind issue #253 gets
// enumerated instead of found one crash at a time.
void WoofIOS_DebugGlobalsCheckpoint(void);

// Engine-internal: called only from i_input.c's I_ReadMouse (WOOF_IOS
// build), not part of the overlay-facing API above. Returns the turn
// accumulated since the last call and resets it to 0.
float WoofIOS_ConsumeTouchTurn(void);

// --- Soft-keyboard text injection (touch cheat/text entry) ---
// The overlay summons the iOS system keyboard on a four-finger tap and
// funnels each keystroke here. These post synthesized events directly onto
// the engine queue via D_PostEvent, bypassing SDL text input (which is
// stopped on iOS and flaky on the simulator). Main-thread-only, same
// contract as the touch-control functions above.

// Which text-entry context the engine is in right now, so the overlay can
// gate the keyboard: only summon during live gameplay (cheats) or while the
// save-name field is capturing input -- never at the title or in menus.
typedef enum
{
    WOOF_TEXT_CTX_NONE = 0,   // title, menus, intermission/finale, demo, etc.
    WOOF_TEXT_CTX_GAMEPLAY,   // in a live level, no menu, not paused (cheats)
    WOOF_TEXT_CTX_SAVENAME,   // menu save-name entry is active
} WoofIOS_TextInputContext;

WoofIOS_TextInputContext WoofIOS_GetTextInputContext(void);

// Inject one typed character. Posts BOTH an ev_keydown (data2 = lowercased
// char) that the cheat matcher (m_cheat.c M_FindCheats) reads, AND an
// ev_text (data1 = char) that menu save-name entry (mn_menu.c) reads -- so
// one call serves cheats and save-name typing wherever the responder chain
// currently is.
void WoofIOS_InjectChar(char c);

// One edge of a held key, by Doom key code (doomkeys.h): ev_keydown when
// `down`, ev_keyup otherwise. The overlay's automap gestures use it (issue
// #113), since the automap pans and zooms while the arrows, '=' and '-' are
// held; the caller pairs every down with an up. Not gated on the text
// context, unlike WoofIOS_InjectChar. Main-thread-only.
void WoofIOS_InjectKey(int key, bool down);

// Auto-use (issue #114): when on, a usable line within use range ahead of a
// forward-moving player presses USE for them, once per line. Off by default;
// the host app turns it on for touch input and off while a physical
// controller or hardware keyboard drives the session. Main-thread-only.
void WoofIOS_SetAutoUse(bool enabled);

// Debug/test telemetry only: "autoUse: enabled=<0|1> presses=<n>", the
// switch as it stands and how many times auto-use pressed USE this session
// (counted at the press, reset at session start).
const char *WoofIOS_DebugAutoUseState(void);

// True while the engine's automap is up (doomstat's `automapactive`), so the
// overlay can route free-area touches to the map instead of the sticks.
bool WoofIOS_IsAutomapActive(void);

// Inject a Backspace keypress (ev_keydown, KEY_BACKSPACE) -- edits the
// save-name field.
void WoofIOS_InjectBackspace(void);

// Inject an Enter keypress (ev_keydown, KEY_ENTER) -- commits the save-name
// field (input_menu_enter -> MENU_ENTER). Harmless during gameplay.
void WoofIOS_InjectMenuConfirm(void);

#endif
