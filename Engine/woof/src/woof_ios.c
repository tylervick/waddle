//
// iOS host-app entry point. Replaces i_main.c: instead of letting the
// engine exit() the process (fatal on iOS), all exits unwind back here.
//
#include "woof_ios.h"

#include <locale.h>
#include <setjmp.h>
#include <stdlib.h>

#include "SDL3/SDL.h"

#include "config.h"
#include "i_printf.h"
#include "m_argv.h"

void D_DoomMain(void);

static jmp_buf exit_env;
static int exit_env_valid;

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
    int code = setjmp(exit_env);
    if (code != 0)
    {
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
