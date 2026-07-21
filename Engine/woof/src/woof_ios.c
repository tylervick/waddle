//
// iOS host-app entry point. Replaces i_main.c: instead of letting the
// engine exit() the process (fatal on iOS), all exits unwind back here.
//
#include "woof_ios.h"

#include <locale.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>

// SDL_MAIN_HANDLED tells SDL_main.h we are supplying our own entry point
// (SwiftUI's synthesized main) instead of letting it inject its normal
// platform trampoline (which on iOS would otherwise compile an actual
// main()/UIApplicationMain shim into this translation unit and collide
// with Swift's). We still need the header for the SDL_SetMainReady()
// declaration used in WoofIOS_Run() below.
#define SDL_MAIN_HANDLED
#include "SDL3/SDL.h"
#include "SDL3/SDL_main.h"

#include <ctype.h>

#include "config.h"
#include "d_event.h"  // event_t / ev_keydown / ev_text
#include "d_main.h"   // D_PostEvent
#include "doomdef.h"  // gamestate_t, GS_LEVEL
#include "doomkeys.h" // KEY_BACKSPACE, KEY_ENTER
#include "doomtype.h" // `boolean` typedef backing the `menuactive` extern below
#include "i_printf.h"
#include "m_argv.h"

void D_DoomMain(void);

static jmp_buf exit_env;
static int exit_env_valid;
static pthread_t session_thread;

// Previous SIGTERM disposition, saved/restored around each session (static:
// locals don't reliably survive the longjmp back into WoofIOS_Run's frame).
static struct sigaction previous_sigterm;

// Touch-control shim state (Plan 3; see the block comment further down).
// Declared here, ahead of WoofIOS_Run, because the unwind path below must
// reset them across sessions -- same stale-global hazard as the statics
// documented in WOOF_UPSTREAM.md's Task 10 section, extended to this
// module by Plan 3 Task 1's fix round 1.
static SDL_JoystickID touch_joystick_id;
static SDL_Joystick *touch_joystick;
static int touch_event_count;
static float touch_turn_accum;

// Lazily-opened gamepad-layer view of touch_joystick, used only by
// WoofIOS_DebugTriggerValue (test telemetry) to read back the value Woof's
// gamepad API reports, as opposed to the raw joystick axis the overlay
// writes. SDL ref-counts the underlying joystick per instance ID (see
// SDL_OpenJoystick), so opening this alongside touch_joystick is safe and
// closing it independently does not invalidate touch_joystick.
static SDL_Gamepad *touch_gamepad;

void WoofIOS_ExitUnwind(int rc)
{
    if (exit_env_valid)
    {
        // longjmp may only unwind the stack of the thread that called
        // setjmp. I_Error is occasionally reachable from helper threads
        // (e.g. sound callbacks); jumping from one of those into the main
        // thread's frame is undefined behavior that would corrupt both
        // stacks. Fail hard and diagnosably instead.
        if (!pthread_equal(pthread_self(), session_thread))
        {
            abort();
        }
        exit_env_valid = 0;
        // setjmp cannot distinguish 0, so shift non-negative codes up by 1.
        longjmp(exit_env, rc >= 0 ? rc + 1 : rc);
    }
    // Not running under WoofIOS_Run (should not happen on iOS).
    exit(rc);
}

void WoofIOS_RequestQuit(void)
{
    SDL_Event event = {0};
    event.type = SDL_EVENT_QUIT;
    SDL_PushEvent(&event);
}

int WoofIOS_Run(int argc, char **argv)
{
    // Because the host app's main() is SwiftUI's synthesized entry point
    // rather than SDL_main, SDL never saw the readiness registration its
    // SDL_main shim normally performs; SDL_Init would otherwise refuse
    // with "Application didn't initialize properly, did you include
    // SDL_main.h...". This is SDL3's documented escape hatch for
    // embedding it in a host-owned app. Safe to call more than once
    // (idempotent flag set), which matters since WoofIOS_Run may run
    // again for a later session.
    SDL_SetMainReady();

    // Allow every interface orientation for the SDL-owned game window
    // (Plan 4 Task 7b, all-orientations + iPadOS windowed multitasking).
    // Without this hint, UIKit_GetSupportedOrientations
    // (Vendor/src/SDL/src/video/uikit/SDL_uikitwindow.m) falls back to the
    // window's aspect ratio -- Woof's window is wider than tall, so every
    // session forced the interface to landscape and device rotation was
    // ignored. SDL intersects this hint with the app's Info.plist
    // UISupportedInterfaceOrientations (and strips upside-down on iPhone
    // itself), so the plist remains the source of truth for what the app
    // as a whole allows.
    SDL_SetHint(SDL_HINT_ORIENTATIONS,
                "Portrait PortraitUpsideDown LandscapeLeft LandscapeRight");

    // Ignore SIGTERM for the duration of the session. SDL's default signal
    // handling (SDL_quit.c) turns SIGTERM into SDL_EVENT_QUIT -- a desktop
    // convention with no counterpart on iOS, where apps are never asked to
    // quit via SIGTERM (the OS uses lifecycle callbacks and SIGKILL).
    // Observed concretely: the XCUITest harness (xcodebuild, verified via a
    // SA_SIGINFO probe: si_pid = xcodebuild's pid, si_code = SI_USER)
    // delivers a stray SIGTERM to the app-under-test moments after the
    // second engine session's SDL window appears, which SDL converted to a
    // quit and silently ended the session ~2 s in, exit code 0 -- a "dead"
    // second session masquerading as a clean run (Task 10, fix round 1).
    // Installing SIG_IGN *before* SDL_Init also keeps SDL from installing
    // its own converter: SDL_EventSignal_Init only claims a signal whose
    // disposition is SIG_DFL. Explicit in-app quits are unaffected (they
    // are pushed directly as SDL_EVENT_QUIT by WoofIOS_RequestQuit or the
    // in-game menu). The previous disposition is restored on unwind so
    // process teardown outside a session (e.g. the test harness's normal
    // end-of-test terminate) behaves normally.
    struct sigaction ignore_term;
    memset(&ignore_term, 0, sizeof(ignore_term));
    sigemptyset(&ignore_term.sa_mask);
    ignore_term.sa_handler = SIG_IGN;
    sigaction(SIGTERM, &ignore_term, &previous_sigterm);

    int code = setjmp(exit_env);
    if (code != 0)
    {
        sigaction(SIGTERM, &previous_sigterm, NULL);

        // The session that just unwound already tore down every open
        // gamepad/joystick -- including our virtual one -- via Woof's own
        // I_ShutdownGamepad (i_input.c:411-415, `SDL_QuitSubSystem(SDL_INIT_GAMEPAD)`),
        // registered as an I_AtExit handler (i_input.c:486) that runs as
        // part of I_SafeExit's normal exit sequence, before it ever
        // unwinds back here. SDL_QuitSubSystem(GAMEPAD) itself cascades
        // into SDL_QuitSubSystem(JOYSTICK) too ("game controller implies
        // joystick", Vendor/src/SDL/src/SDL.c:614-619). So these statics
        // are stale/dangling now, not merely "detached" -- same
        // stale-global hazard as the module statics in WOOF_UPSTREAM.md's
        // Task 10 section. Reset them so the next session's
        // WoofIOS_AttachTouchGamepad attaches fresh instead of trusting a
        // pointer from a torn-down subsystem.
        touch_joystick = NULL;
        touch_joystick_id = 0;
        touch_turn_accum = 0.0f;
        // Same dangling-pointer hazard as touch_joystick above: the same
        // I_ShutdownGamepad-driven teardown already freed every open
        // gamepad along with every joystick, so touch_gamepad is stale,
        // not merely detached.
        touch_gamepad = NULL;

        return code > 0 ? code - 1 : code;
    }
    exit_env_valid = 1;
    session_thread = pthread_self();

    // Drop any error text accumulated by a previous session in this
    // process (see I_ResetErrorMessages in i_system.c).
    extern void I_ResetErrorMessages(void);
    I_ResetErrorMessages();

    myargc = argc;
    myargv = argv;

    setlocale(LC_TIME, "");
    I_Printf(VB_ALWAYS, "%s (iOS)\n", PROJECT_STRING);

    D_DoomMain();

    // D_DoomMain never returns; quits funnel through I_SafeExit -> unwind.
    return 0;
}

// --- Touch-control shim (Plan 3) ---
//
// The native overlay creates a single virtual SDL gamepad shaped like a
// standard controller (SDL_JOYSTICK_TYPE_GAMEPAD, full axis/button counts,
// no explicit button_mask/axis_mask -- SDL's virtual-joystick driver fills
// both in from naxes/nbuttons when they're left zero, covering every
// SDL_GAMEPAD_BUTTON_*/SDL_GAMEPAD_AXIS_* index 1:1). Woof! then picks it up
// through its normal SDL_EVENT_GAMEPAD_ADDED handling -- see Step 3's
// verification in Engine/WOOF_UPSTREAM.md / the commit body for the exact
// code path -- so the overlay never touches Woof!'s input tables directly;
// it just drives the gamepad Woof! already knows how to read (respecting
// the user's own gamepad bindings).
//
// Turn is different: there is no SDL event path from a pushed
// SDL_EVENT_MOUSE_MOTION into Woof!'s mouse handling. I_ReadMouse polls
// SDL_GetRelativeMouseState() once per tic, which reads SDL's internal
// accumulator that only SDL_SendMouseMotion (not part of the public API)
// updates, and i_video.c's ProcessEvent has no motion case to relay a
// pushed event into that accumulator either. So turn is delivered through
// a shim-owned accumulator instead: WoofIOS_InjectRelativeTurn adds to
// touch_turn_accum, and a small WOOF_IOS-guarded hook added to
// I_ReadMouse (documented as an i_input.c patch in WOOF_UPSTREAM.md)
// drains it via WoofIOS_ConsumeTouchTurn every tic.

bool WoofIOS_AttachTouchGamepad(void)
{
    if (touch_joystick)
    {
        return true;
    }
    if (!SDL_WasInit(SDL_INIT_JOYSTICK))
    {
        return false; // engine hasn't initialized input yet; caller retries
    }

    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.naxes = SDL_GAMEPAD_AXIS_COUNT;
    desc.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
    desc.name = "WADdle Touch Controls";

    touch_joystick_id = SDL_AttachVirtualJoystick(&desc);
    if (touch_joystick_id == 0)
    {
        return false;
    }
    touch_joystick = SDL_OpenJoystick(touch_joystick_id);
    if (!touch_joystick)
    {
        SDL_DetachVirtualJoystick(touch_joystick_id);
        touch_joystick_id = 0;
        return false;
    }

    // A virtual joystick's axes default to 0 on attach. Under the
    // full-range trigger mapping (see WoofIOS_SetTouchTrigger), a raw axis
    // of 0 reads as ~50% pulled at the gamepad layer -- both triggers would
    // start every session already above trigger_threshold (i_gamepad.c),
    // an instant latent autofire before any touch. Initialize both to
    // released up front.
    SDL_SetJoystickVirtualAxis(touch_joystick, SDL_GAMEPAD_AXIS_LEFT_TRIGGER,
                               SDL_JOYSTICK_AXIS_MIN);
    SDL_SetJoystickVirtualAxis(touch_joystick, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER,
                               SDL_JOYSTICK_AXIS_MIN);

    // Open the debug-telemetry gamepad view now rather than waiting for
    // WoofIOS_DebugTriggerValue's first call. Empirically, a freshly opened
    // SDL_Gamepad's very first SDL_GetGamepadAxis read after an axis change
    // can observe a stale value (observed returning 0 immediately after a
    // write that should read back ~0.5) -- opening it here, well before any
    // FIRE press/release, means the first *measurement* is never also the
    // first *open*, so telemetry reflects reality instead of this
    // early-access artifact.
    touch_gamepad = SDL_OpenGamepad(touch_joystick_id);
    return true;
}

void WoofIOS_DetachTouchGamepad(void)
{
    if (!touch_joystick)
    {
        return;
    }
    if (!SDL_WasInit(SDL_INIT_JOYSTICK))
    {
        // The joystick subsystem has already torn down (e.g. mid-quit,
        // via the exit handlers I_SafeExit runs before unwinding back to
        // WoofIOS_Run) and freed every open joystick/gamepad along with
        // it. touch_joystick/touch_gamepad are dangling pointers at this
        // point; closing or detaching through them would be a
        // use-after-free. Just drop our references -- WoofIOS_Run's
        // unwind path resets them too, but a caller may invoke this
        // directly before that happens.
        touch_joystick = NULL;
        touch_joystick_id = 0;
        touch_gamepad = NULL;
        return;
    }
    // Defensive: unreachable in the current production call graph. The
    // only caller (TouchGamepad.detach(), via OverlayPresenter.end()) only
    // ever runs after WoofIOS_Run has returned, by which point
    // I_ShutdownGamepad has already torn the subsystem down (see the
    // WoofIOS_Run unwind branch above) -- so SDL_WasInit(SDL_INIT_JOYSTICK)
    // is always false by the time we'd get here today, and this branch
    // never executes. Kept for a caller that might one day detach while a
    // session is still fully live.
    if (touch_gamepad)
    {
        // Ref-counted alongside touch_joystick (see the touch_gamepad
        // declaration above); closing this first just drops the debug
        // telemetry's own reference, it does not close touch_joystick.
        SDL_CloseGamepad(touch_gamepad);
        touch_gamepad = NULL;
    }
    SDL_CloseJoystick(touch_joystick);
    SDL_DetachVirtualJoystick(touch_joystick_id);
    touch_joystick = NULL;
    touch_joystick_id = 0;
}

void WoofIOS_SetTouchAxis(int sdl_axis, float value)
{
    if (!touch_joystick)
    {
        return;
    }
    if (value > 1.0f) value = 1.0f;
    if (value < -1.0f) value = -1.0f;
    SDL_SetJoystickVirtualAxis(touch_joystick, sdl_axis,
                               (Sint16)(value * 32767.0f));
    touch_event_count++;
}

void WoofIOS_SetTouchButton(int sdl_button, bool down)
{
    if (!touch_joystick)
    {
        return;
    }
    SDL_SetJoystickVirtualButton(touch_joystick, sdl_button, down);
    touch_event_count++;
}

// Fix round (user device-testing): FIRE autofired forever after a single
// press, working only once as a menu-select. Root cause: Woof!'s default
// gamepad bindings read FIRE through the *gamepad* layer's RIGHT_TRIGGER,
// but the virtual joystick's auto-generated mapping exposes both trigger
// inputs as FULL-RANGE axes -- plain "a4"/"a5", no "+" half-axis prefix.
// VIRTUAL_JoystickGetGamepadMapping sets each trigger's mapping .kind to
// EMappingKind_Axis without setting a half_axis_positive/negative flag
// (Vendor/src/SDL/src/joystick/virtual/SDL_virtualjoystick.c:953-961), and
// the mapping-string serializer only emits a "+"/"-" prefix when one of
// those flags is set (Vendor/src/SDL/src/joystick/SDL_gamepad.c:2285-2290)
// -- so the generated input mapping is a bare "a5", full-range. SDL then
// linearly maps that full raw range (SDL_JOYSTICK_AXIS_MIN..MAX) onto the
// trigger's gamepad-axis output range (0..SDL_JOYSTICK_AXIS_MAX): a raw
// axis of 0 (what WoofIOS_SetTouchAxis's `down ? 1.0 : 0.0` wrote on
// release) reads back as ~50% pulled at the gamepad layer -- permanently
// above trigger_threshold (i_gamepad.c), which is exactly what
// TriggerToButton (i_input.c) polls to synthesize the FIRE button event.
// Released must therefore write the raw axis all the way to
// SDL_JOYSTICK_AXIS_MIN (maps to gamepad-axis 0); pressed writes
// SDL_JOYSTICK_AXIS_MAX (maps to gamepad-axis max). Digital press/release
// only -- there is no partial-pull touch gesture to preserve here.
void WoofIOS_SetTouchTrigger(int sdl_axis, bool down)
{
    if (!touch_joystick)
    {
        return;
    }
    SDL_SetJoystickVirtualAxis(touch_joystick, sdl_axis,
                               down ? SDL_JOYSTICK_AXIS_MAX : SDL_JOYSTICK_AXIS_MIN);
    touch_event_count++;
}

void WoofIOS_InjectRelativeTurn(float dx_points)
{
    touch_turn_accum += dx_points;
    touch_event_count++;
}

float WoofIOS_ConsumeTouchTurn(void)
{
    float value = touch_turn_accum;
    touch_turn_accum = 0.0f;
    return value;
}

void *WoofIOS_GetUIWindowPointer(void)
{
    int count = 0;
    SDL_Window **windows = SDL_GetWindows(&count);
    void *result = NULL;
    if (windows && count > 0)
    {
        result = SDL_GetPointerProperty(SDL_GetWindowProperties(windows[0]),
                                        SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER,
                                        NULL);
    }
    SDL_free(windows);
    return result;
}

// Fix round (device testing): MAP's gameplay default is correct
// (GAMEPAD_NORTH, see the TouchButton doc comment in TouchGamepad.swift /
// the wiring audit in TouchOverlayView.swift), but NORTH is *also*
// input_menu_clear's default binding (m_input.c:624-628) -- see the audit
// block's second table for the menu-context collision this causes with
// USE (SOUTH = gamepad_confirm, m_input.c:564,576): in the Load/Save menu,
// MENU_CLEAR on a populated slot arms a delete confirmation
// (`delete_verify`, mn_menu.c:3368-3378, gated on AnyLoadSaveMenu() +
// AllowDeleteSaveGame()), and a subsequent MENU_ENTER (USE) confirms
// M_DeleteGame (mn_menu.c:2806-2814) -- two overlay taps silently delete a
// save. Rather than rebind MAP away from its correct gameplay default,
// the overlay (TouchOverlayView) polls this to hide/disable the automap
// button whenever a menu is on screen. `menuactive` (doomstat.h:251,
// defined mn_menu.c:104) is only true while an actual menu screen -- main
// menu, options, Load/Save, etc. -- is overlaying the game; the title/demo
// state does not set it.
extern boolean menuactive;

bool WoofIOS_IsMenuActive(void)
{
    return menuactive != 0;
}

// --- Soft-keyboard text injection (see woof_ios.h) ---
// Post synthesized events directly onto the engine queue via D_PostEvent,
// bypassing SDL text input entirely. Cheats read ev_keydown.data2
// (m_cheat.c's M_FindCheats); the menu save-name field reads ev_text.data1
// plus the KEY_BACKSPACE/KEY_ENTER keydowns (mn_menu.c). D_ProcessEvents
// runs M_InputTrackEvent then the responder chain on each queued event, so
// a KEY_ENTER keydown activates input_menu_enter -> MENU_ENTER exactly as a
// real key would (m_input.c M_InputActivated matches ev_keydown.data1).
// Main-thread-only, same as the touch functions.
extern gamestate_t gamestate; // doomstat.h
extern int paused;            // doomstat.h
boolean MN_SaveStringEntering(void); // mn_menu.c (saveStringEnter is static)

WoofIOS_TextInputContext WoofIOS_GetTextInputContext(void)
{
    if (MN_SaveStringEntering())
    {
        return WOOF_TEXT_CTX_SAVENAME;
    }
    if (gamestate == GS_LEVEL && !menuactive && !paused)
    {
        return WOOF_TEXT_CTX_GAMEPLAY;
    }
    return WOOF_TEXT_CTX_NONE;
}

void WoofIOS_InjectChar(char c)
{
    int lower = tolower((unsigned char)c);

    event_t key = {0};
    key.type = ev_keydown;
    key.data1.i = lower; // Doom key id; letters == lowercase ASCII
    key.data2.i = lower; // cheat matcher reads data2 (lowercase ASCII)
    D_PostEvent(&key);

    event_t text = {0};
    text.type = ev_text;
    text.data1.i = (unsigned char)c; // save-name reads data1; menu uppercases
    D_PostEvent(&text);
}

void WoofIOS_InjectBackspace(void)
{
    event_t ev = {0};
    ev.type = ev_keydown;
    ev.data1.i = KEY_BACKSPACE; // mn_menu save-name reads ch (= data1)
    D_PostEvent(&ev);
}

void WoofIOS_InjectMenuConfirm(void)
{
    event_t ev = {0};
    ev.type = ev_keydown;
    ev.data1.i = KEY_ENTER; // input_menu_enter -> MENU_ENTER commits the save
    D_PostEvent(&ev);
}

int WoofIOS_DebugTouchEventCount(void)
{
    return touch_event_count;
}

const char *WoofIOS_LastErrorMessage(void)
{
    // Declared locally rather than in i_system.h, same as the
    // I_ResetErrorMessages extern in WoofIOS_Run above — both live in
    // i_system.c's WOOF_IOS-only patch block.
    extern const char *I_GetErrorMessage(void);
    return I_GetErrorMessage();
}

float WoofIOS_DebugTriggerValue(void)
{
    if (!touch_joystick || touch_joystick_id == 0)
    {
        return -1.0f;
    }
    if (!touch_gamepad)
    {
        // Lazily open a gamepad-layer view of the same instance;
        // ref-counted alongside touch_joystick, see the declaration above.
        touch_gamepad = SDL_OpenGamepad(touch_joystick_id);
        if (!touch_gamepad)
        {
            return -1.0f;
        }
    }
    Sint16 raw = SDL_GetGamepadAxis(touch_gamepad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER);
    return (float)raw / (float)SDL_JOYSTICK_AXIS_MAX;
}
