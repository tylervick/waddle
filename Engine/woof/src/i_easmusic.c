//
// Copyright(C) 2026 Tyler Vick
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// DESCRIPTION:
//      MIDI music via SONiVOX EAS wavetable synthesis (#116).
//
//      This is the synth the per-game apps WADdle replaces used, so its
//      instruments are the ones long-time players know every track by.
//      Structured after i_oplmusic.c: both are software synths feeding the
//      OpenAL streaming path rather than driving an external device.
//

#include "config.h"

#ifdef HAVE_SONIVOX

#include <stdlib.h>
#include <string.h>

#include "eas.h"
#include "eas_types.h"

#include "doomtype.h"
#include "i_oalstream.h"
#include "i_printf.h"
#include "i_sound.h"
#include "m_array.h"
#include "memio.h"
#include "mus2mid.h"

static EAS_DATA_HANDLE eas_data;
static EAS_HANDLE eas_stream;
static const S_EAS_LIB_CONFIG *eas_config;
static boolean music_initialized;

// The song, in memory, owned by this module. EAS reads it LAZILY through the
// callbacks below while rendering -- it does not parse up front the way
// MIDI_LoadFile does -- so this must outlive OpenStream and be freed in
// CloseStream. Pointing EAS at a MEMFILE that OpenStream closed is a
// use-after-free that still makes plausible noise.
static unsigned char *song_data;
static int song_length;

static const char *music_format;

static int SongReadAt(void *handle, void *buf, int offset, int size)
{
    (void)handle;
    if (offset >= song_length)
    {
        return 0;
    }
    if (offset + size > song_length)
    {
        size = song_length - offset;
    }
    memcpy(buf, song_data + offset, size);
    return size;
}

static int SongSize(void *handle)
{
    (void)handle;
    return song_length;
}

static void FreeSong(void)
{
    if (song_data)
    {
        free(song_data);
        song_data = NULL;
    }
    song_length = 0;
}

static boolean I_EAS_InitStream(int device)
{
    (void)device; // one device; the menu index is resolved by the caller

    if (music_initialized)
    {
        return true;
    }

    eas_config = EAS_Config();
    if (eas_config == NULL)
    {
        I_Printf(VB_ERROR, "I_EAS_InitStream: EAS_Config returned nothing.");
        return false;
    }

    if (EAS_Init(&eas_data) != EAS_SUCCESS)
    {
        I_Printf(VB_ERROR, "I_EAS_InitStream: EAS_Init failed.");
        return false;
    }

    music_initialized = true;
    return true;
}

static boolean I_EAS_OpenStream(void *data, ALsizei size, ALenum *format,
                                ALsizei *freq, ALsizei *frame_size)
{
    EAS_FILE locator;

    if (!IsMid(data, size) && !IsMus(data, size))
    {
        return false;
    }

    if (!music_initialized)
    {
        return false;
    }

    FreeSong();

    if (IsMid(data, size))
    {
        song_data = malloc(size);
        if (song_data == NULL)
        {
            return false;
        }
        memcpy(song_data, data, size);
        song_length = size;
        music_format = "MIDI (EAS)";
    }
    else
    {
        MEMFILE *instream;
        MEMFILE *outstream;
        void *outbuf;
        size_t outbuf_len;

        instream = mem_fopen_read(data, size);
        outstream = mem_fopen_write();

        if (mus2mid(instream, outstream) == 0)
        {
            mem_get_buf(outstream, &outbuf, &outbuf_len);
            // Copy, do not alias: mem_fclose below frees outbuf, and EAS
            // reads this buffer lazily for the whole song.
            song_data = malloc(outbuf_len);
            if (song_data != NULL)
            {
                memcpy(song_data, outbuf, outbuf_len);
                song_length = (int)outbuf_len;
            }
        }

        mem_fclose(instream);
        mem_fclose(outstream);
        music_format = "MUS (EAS)";
    }

    if (song_data == NULL)
    {
        I_Printf(VB_ERROR, "I_EAS_OpenStream: Failed to load MID.");
        return false;
    }

    memset(&locator, 0, sizeof(locator));
    locator.handle = &song_length; // any non-NULL handle; the buffer is static
    locator.readAt = SongReadAt;
    locator.size = SongSize;

    if (EAS_OpenFile(eas_data, &locator, &eas_stream) != EAS_SUCCESS)
    {
        I_Printf(VB_ERROR, "I_EAS_OpenStream: EAS_OpenFile failed.");
        FreeSong();
        return false;
    }

    if (EAS_Prepare(eas_data, eas_stream) != EAS_SUCCESS)
    {
        I_Printf(VB_ERROR, "I_EAS_OpenStream: EAS_Prepare failed.");
        EAS_CloseFile(eas_data, eas_stream);
        eas_stream = NULL;
        FreeSong();
        return false;
    }

    // Report what the library is actually configured for rather than
    // hard-coded constants, so a build-option change cannot silently
    // desynchronise this module from the synth.
    *format = AL_FORMAT_STEREO16;
    *freq = eas_config->sampleRate;
    *frame_size = eas_config->numChannels * sizeof(short);

    return true;
}

static int I_EAS_FillStream(void *buffer, int buffer_samples)
{
    EAS_I32 rendered = 0;
    EAS_I32 total = 0;
    EAS_PCM *out = (EAS_PCM *)buffer;

    if (!music_initialized || eas_stream == NULL)
    {
        return 0;
    }

    // EAS renders a fixed mixBufferSize per call; the caller asks for an
    // arbitrary count, so loop until filled or the song ends.
    while (total + (int)eas_config->mixBufferSize <= buffer_samples)
    {
        if (EAS_Render(eas_data, out + total * eas_config->numChannels,
                       eas_config->mixBufferSize, &rendered) != EAS_SUCCESS)
        {
            break;
        }
        if (rendered <= 0)
        {
            break;
        }
        total += rendered;
    }

    return total;
}

static void I_EAS_PlayStream(boolean looping)
{
    if (!music_initialized || eas_stream == NULL)
    {
        return;
    }
    EAS_SetRepeat(eas_data, eas_stream, looping ? -1 : 0);
}

static void I_EAS_CloseStream(void)
{
    if (eas_stream != NULL)
    {
        EAS_CloseFile(eas_data, eas_stream);
        eas_stream = NULL;
    }
    FreeSong();
}

static void I_EAS_ShutdownStream(void)
{
    if (!music_initialized)
    {
        return;
    }
    I_EAS_CloseStream();
    EAS_Shutdown(eas_data);
    eas_data = NULL;
    music_initialized = false;
}

static const char **I_EAS_DeviceList(void)
{
    static const char **devices = NULL;
    if (array_size(devices))
    {
        return devices;
    }
    // This exact string is API: i_sound.c's migration and Woof's own
    // restore-by-name both match on it. Do not reword it.
    array_push(devices, "SONiVOX EAS Wavetable");
    return devices;
}

static void I_EAS_BindVariables(void)
{
    // No tunables. The 22 kHz 8-bit reverb/chorus configuration is fixed at
    // build time by Scripts/build-deps.sh and enforced by
    // Scripts/check-eas-bank.sh, because it is what reproduces the
    // predecessor apps' sound rather than a preference.
}

static const char *I_EAS_MusicFormat(void)
{
    return music_format;
}

stream_module_t stream_eas_module =
{
    I_EAS_InitStream,
    I_EAS_OpenStream,
    I_EAS_FillStream,
    I_EAS_PlayStream,
    I_EAS_CloseStream,
    I_EAS_ShutdownStream,
    I_EAS_DeviceList,
    I_EAS_BindVariables,
    I_EAS_MusicFormat,
};

#endif // HAVE_SONIVOX
