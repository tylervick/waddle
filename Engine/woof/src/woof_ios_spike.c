// Temporary architecture spike (removed once WoofIOS_Run is proven):
// verifies SDL3 video init + window + renderer + clean shutdown inside a
// host UIKit app, twice in a row.
// SDL_MAIN_HANDLED tells SDL_main.h we are supplying our own entry point
// (SwiftUI's synthesized main) instead of letting it inject its normal
// platform trampoline (which on iOS would otherwise compile an actual
// main()/UIApplicationMain shim into this translation unit and collide
// with Swift's). We still need the header for the SDL_SetMainReady()
// declaration below.
#define SDL_MAIN_HANDLED
#include "SDL3/SDL.h"
#include "SDL3/SDL_main.h"

int spike_run(int seconds)
{
    // Because the host app's main() is SwiftUI's synthesized entry point
    // rather than SDL_main, SDL never saw the readiness registration its
    // SDL_main shim normally performs; SDL_Init would otherwise refuse
    // with "Application didn't initialize properly, did you include
    // SDL_main.h...". This is SDL3's documented escape hatch for
    // embedding it in a host-owned app. Safe to call more than once
    // (idempotent flag set), which matters since spike_run may run again.
    SDL_SetMainReady();
    if (!SDL_Init(SDL_INIT_VIDEO))
    {
        SDL_Log("spike: SDL_Init failed: %s", SDL_GetError());
        return -1;
    }
    SDL_Window *window = NULL;
    SDL_Renderer *renderer = NULL;
    if (!SDL_CreateWindowAndRenderer("spike", 0, 0, SDL_WINDOW_FULLSCREEN,
                                     &window, &renderer))
    {
        SDL_Log("spike: window/renderer failed: %s", SDL_GetError());
        SDL_Quit();
        return -2;
    }
    Uint64 end = SDL_GetTicks() + (Uint64)seconds * 1000;
    int frames = 0;
    while (SDL_GetTicks() < end)
    {
        SDL_Event e;
        while (SDL_PollEvent(&e))
        {
            if (e.type == SDL_EVENT_QUIT)
            {
                end = 0;
            }
        }
        float t = (float)(SDL_GetTicks() % 1000) / 1000.0f;
        SDL_SetRenderDrawColorFloat(renderer, t, 0.2f, 1.0f - t, 1.0f);
        SDL_RenderClear(renderer);
        SDL_RenderPresent(renderer);
        frames++;
    }
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    SDL_Log("spike: rendered %d frames", frames);
    return frames > 0 ? 0 : -3;
}
