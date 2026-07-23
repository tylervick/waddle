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

// Inject a Backspace keypress (ev_keydown, KEY_BACKSPACE) -- edits the
// save-name field.
void WoofIOS_InjectBackspace(void);

// Inject an Enter keypress (ev_keydown, KEY_ENTER) -- commits the save-name
// field (input_menu_enter -> MENU_ENTER). Harmless during gameplay.
void WoofIOS_InjectMenuConfirm(void);

#endif
