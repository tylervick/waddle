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

#include "config.h"
#include "i_printf.h"
#include "m_argv.h"

void D_DoomMain(void);

static jmp_buf exit_env;
static int exit_env_valid;
static pthread_t session_thread;

// Previous SIGTERM disposition, saved/restored around each session (static:
// locals don't reliably survive the longjmp back into WoofIOS_Run's frame).
static struct sigaction previous_sigterm;

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

static SDL_JoystickID touch_joystick_id;
static SDL_Joystick *touch_joystick;
static int touch_event_count;

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
    desc.name = "BoomBox Touch Controls";

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
    return true;
}

void WoofIOS_DetachTouchGamepad(void)
{
    if (!touch_joystick)
    {
        return;
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

void WoofIOS_InjectRelativeTurn(float dx_points)
{
    SDL_Event event = {0};
    event.type = SDL_EVENT_MOUSE_MOTION;
    event.motion.xrel = dx_points;
    event.motion.yrel = 0.0f;
    if (SDL_PushEvent(&event))
    {
        touch_event_count++;
    }
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

int WoofIOS_DebugTouchEventCount(void)
{
    return touch_event_count;
}
