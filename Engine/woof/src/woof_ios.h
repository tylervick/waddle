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

#endif
