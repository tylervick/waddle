// Timed pointer path posted to one app (no real pointer movement, window not raised).
//   timed-drag <pid> <windowNumber> <winOriginX> <winOriginY> [--option] x,y,ms [x,y,ms ...]
// x,y are global screen points. First waypoint = mouse-down, then held for its ms; each later
// waypoint is reached over its ms (same point = pause). Mouse-up at the last waypoint.
// See docs/learnings/driving-device-hub-by-desktop-control.md. Private interfaces: same delivery as Orca's computer-use helper: mark the window key for its app with
// SLPSPostEventRecordTo, then CGEventPostToPid with a window-local location.
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
extern CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
extern void CGEventSetWindowLocation(CGEventRef e, CGPoint p);
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
extern OSStatus GetProcessForPID(pid_t pid, ProcessSerialNumber *psn);

static pid_t pid; static uint32_t win; static double ox, oy; static CGEventFlags flags = 0;
static void make_key(void) {
    ProcessSerialNumber psn; if (GetProcessForPID(pid, &psn) != 0) { fprintf(stderr, "no psn\n"); return; }
    uint8_t b[0xf8]; memset(b, 0, sizeof b);
    b[0x04] = 0xF8; b[0x3a] = 0x10; memcpy(b + 0x3c, &win, sizeof(uint32_t)); memset(b + 0x20, 0xFF, 0x10);
    b[0x08] = 0x01; SLPSPostEventRecordTo(&psn, b);
    b[0x08] = 0x02; SLPSPostEventRecordTo(&psn, b);
}
static void post(CGEventType t, CGPoint p) {
    CGEventRef e = CGEventCreateMouseEvent(NULL, t, p, kCGMouseButtonLeft);
    CGEventSetFlags(e, flags);
    CGEventSetIntegerValueField(e, kCGMouseEventClickState, 1);
    CGEventSetLocation(e, p);
    CGEventSetIntegerValueField(e, 51, win); // undocumented: the event's window number
    CGEventSetWindowLocation(e, CGPointMake(p.x - ox, p.y - oy));
    CGEventPostToPid(pid, e); CFRelease(e);
}
int main(int argc, char **argv) {
    static const char *usage = "usage: timed-drag <pid> <window-id> <origin-x> <origin-y> [--option] x,y,ms [x,y,ms ...]\n";
    if (argc < 6) { fputs(usage, stderr); return 2; }
    pid = atoi(argv[1]); win = (uint32_t)atoi(argv[2]); ox = atof(argv[3]); oy = atof(argv[4]);
    int i = 5; if (!strcmp(argv[i], "--option")) { flags |= kCGEventFlagMaskAlternate; i++; }
    if (i >= argc) { fputs(usage, stderr); return 2; }
    // Parse every waypoint before posting anything, so a typo cannot leave a button down.
    double x, y, ms;
    for (int k = i; k < argc; k++) {
        char tail;
        if (sscanf(argv[k], "%lf,%lf,%lf%c", &x, &y, &ms, &tail) != 3 || ms < 0) {
            fprintf(stderr, "bad waypoint '%s' (want x,y,ms)\n", argv[k]); return 2;
        }
    }
    sscanf(argv[i++], "%lf,%lf,%lf", &x, &y, &ms);
    CGPoint cur = CGPointMake(x, y);
    make_key(); usleep(30000);
    if (flags & kCGEventFlagMaskAlternate) { CGEventRef k = CGEventCreateKeyboardEvent(NULL, 58, true); CGEventSetFlags(k, flags); CGEventPostToPid(pid, k); CFRelease(k); usleep(150000);
        CGEventRef m = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, cur, kCGMouseButtonLeft); CGEventSetFlags(m, flags); CGEventSetIntegerValueField(m, 51, win); CGEventSetWindowLocation(m, CGPointMake(cur.x - ox, cur.y - oy)); CGEventPostToPid(pid, m); CFRelease(m); usleep(150000); }
    post(kCGEventLeftMouseDown, cur); usleep((useconds_t)(ms * 1000));
    for (; i < argc; i++) {
        sscanf(argv[i], "%lf,%lf,%lf", &x, &y, &ms);
        int steps = (int)(ms / 16); if (steps < 1) steps = 1;
        for (int s = 1; s <= steps; s++) {
            double t = (double)s / steps;
            post(kCGEventLeftMouseDragged, CGPointMake(cur.x + (x - cur.x) * t, cur.y + (y - cur.y) * t));
            usleep(16000);
        }
        cur = CGPointMake(x, y);
    }
    post(kCGEventLeftMouseUp, cur);
    if (flags & kCGEventFlagMaskAlternate) { usleep(50000); CGEventRef k = CGEventCreateKeyboardEvent(NULL, 58, false); CGEventPostToPid(pid, k); CFRelease(k); }
    return 0;
}
