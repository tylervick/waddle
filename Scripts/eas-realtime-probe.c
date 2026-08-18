/* Renders a MIDI fixture through SONiVOX EAS and reports the ratio of audio
 * produced to wall clock spent. Feeds the MIDI from MEMORY via the EAS_FILE
 * reader callbacks, which is the same path Engine/woof/src/i_easmusic.c uses,
 * so this measures the arrangement the engine actually runs.
 *
 * Prints one line:  frames=<n> seconds=<s> wall=<w> rtf=<r>
 * Exits non-zero if nothing was rendered or the output is silent -- a probe
 * that measures silence would report a spectacular real-time factor. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "eas.h"
#include "eas_types.h"

typedef struct { const unsigned char *data; int len; } MemLump;

static int mem_read_at(void *h, void *buf, int offset, int size)
{
    MemLump *m = (MemLump *)h;
    int n = size;
    if (offset >= m->len) return 0;
    if (offset + n > m->len) n = m->len - offset;
    memcpy(buf, m->data + offset, n);
    return n;
}

static int mem_size(void *h) { return ((MemLump *)h)->len; }

int main(int argc, char **argv)
{
    FILE *f;
    long len;
    unsigned char *buf;
    const S_EAS_LIB_CONFIG *cfg;
    EAS_DATA_HANDLE eas = NULL;
    EAS_HANDLE stream = NULL;
    EAS_FILE locator;
    MemLump lump;
    EAS_PCM *pcm;
    long frames = 0;
    int peak = 0, i, s;
    struct timespec t0, t1;
    double wall, seconds;

    if (argc < 2) { fprintf(stderr, "usage: %s <midi>\n", argv[0]); return 2; }
    f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
    fseek(f, 0, SEEK_END); len = ftell(f); fseek(f, 0, SEEK_SET);
    buf = malloc(len);
    if (fread(buf, 1, len, f) != (size_t)len) { fprintf(stderr, "short read\n"); return 2; }
    fclose(f);

    cfg = EAS_Config();
    if (EAS_Init(&eas) != EAS_SUCCESS) { fprintf(stderr, "EAS_Init failed\n"); return 2; }

    lump.data = buf; lump.len = (int)len;
    memset(&locator, 0, sizeof(locator));
    locator.handle = &lump;
    locator.readAt = mem_read_at;
    locator.size   = mem_size;

    if (EAS_OpenFile(eas, &locator, &stream) != EAS_SUCCESS) {
        fprintf(stderr, "EAS_OpenFile from memory failed\n"); return 2;
    }
    if (EAS_Prepare(eas, stream) != EAS_SUCCESS) {
        fprintf(stderr, "EAS_Prepare failed\n"); return 2;
    }

    pcm = malloc(cfg->mixBufferSize * cfg->numChannels * sizeof(EAS_PCM));
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (i = 0; i < 100000; i++) {
        EAS_I32 got = 0;
        EAS_STATE st;
        if (EAS_Render(eas, pcm, cfg->mixBufferSize, &got) != EAS_SUCCESS) break;
        for (s = 0; s < got * cfg->numChannels; s++) {
            int a = pcm[s] < 0 ? -pcm[s] : pcm[s];
            if (a > peak) peak = a;
        }
        frames += got;
        EAS_State(eas, stream, &st);
        if (st == EAS_STATE_STOPPED || st == EAS_STATE_ERROR) break;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    wall = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;

    EAS_CloseFile(eas, stream);
    EAS_Shutdown(eas);
    free(pcm); free(buf);

    if (frames == 0) { fprintf(stderr, "rendered nothing\n"); return 1; }
    if (peak < 1000) { fprintf(stderr, "rendered silence (peak %d)\n", peak); return 1; }
    if (wall <= 0.0) wall = 1e-9;

    seconds = (double)frames / cfg->sampleRate;
    printf("frames=%ld seconds=%.3f wall=%.4f rtf=%.1f\n",
           frames, seconds, wall, seconds / wall);
    return 0;
}
