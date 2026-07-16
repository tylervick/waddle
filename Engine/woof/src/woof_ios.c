//
// iOS host-app entry point. Replaces i_main.c: instead of letting the
// engine exit() the process (fatal on iOS), all exits unwind back here.
//
#include "woof_ios.h"

#include <locale.h>
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

// Previous SIGTERM disposition, saved/restored around each session (static:
// locals don't reliably survive the longjmp back into WoofIOS_Run's frame).
static struct sigaction previous_sigterm;

void WoofIOS_ExitUnwind(int rc)
{
    if (exit_env_valid)
    {
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
    ignore_term.sa_handler = SIG_IGN;
    sigaction(SIGTERM, &ignore_term, &previous_sigterm);

    int code = setjmp(exit_env);
    if (code != 0)
    {
        sigaction(SIGTERM, &previous_sigterm, NULL);
        return code > 0 ? code - 1 : code;
    }
    exit_env_valid = 1;

    myargc = argc;
    myargv = argv;

    setlocale(LC_TIME, "");
    I_Printf(VB_ALWAYS, "%s (iOS)\n", PROJECT_STRING);

    D_DoomMain();

    // D_DoomMain never returns; quits funnel through I_SafeExit -> unwind.
    return 0;
}
