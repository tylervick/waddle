//
// Copyright(C) 2024 Roman Fomin
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

#include <stdlib.h>

#include "doomtype.h"
#include "i_printf.h"
#include "m_array.h"
#include "m_misc.h"
#include "m_swap.h"
#include "w_wad.h"
#include "w_internal.h"

#include "miniz.h"

typedef struct
{
    int index;
    const char *filename;
} record_t;

struct archive_s
{
    mz_zip_archive *zip;
    record_t *directory;
};

static archive_t *archives;

static void ConvertSlashes(char *path)
{
    for (char *p = path; *p; ++p)
    {
        if (*p == '\\')
        {
            *p = '/';
        }
    }
}

#ifdef WOOF_IOS
// Debug seam for WoofIOS_DebugZipWadBuffers (issue #38): decompressed WADs
// AddWadInMem has allocated and not yet freed, and how many it has
// allocated in this process. Counted at the malloc and free sites
// themselves and never reset, so a buffer a session abandons stays counted.
static int live_wad_buffers, total_wad_buffers;

// Upstream never frees a zip's decompressed WADs: its lumps point into
// them (lumpinfo_t.data) until the process exits. Here a process runs many
// sessions, so W_ZIP_Close frees the buffers once the session's lumps are
// gone (issue #38). Only W_ReadLump reads lumpinfo_t.data, and only this
// file sets it, so nothing reads a buffer after W_Close.
static byte **wad_buffers;

static void FreeWadBuffer(byte *data)
{
    free(data);
    live_wad_buffers--;
}

void W_ZIP_DebugWadBuffers(int *live, int *total)
{
    *live = live_wad_buffers;
    *total = total_wad_buffers;
}
#endif

static void AddWadInMem(w_handle_t handle, const char *name, int index,
                        size_t data_size)
{
    I_Printf(VB_INFO, " - adding %s", name);

    mz_zip_archive *zip = handle.p1.archive->zip;

    byte *data = malloc(data_size);
#ifdef WOOF_IOS
    live_wad_buffers++;
    total_wad_buffers++;
#endif

    if (!mz_zip_reader_extract_to_mem(zip, index, data, data_size, 0))
    {
#ifdef WOOF_IOS
        // I_Error ends the session, not the process: free before it (#38).
        FreeWadBuffer(data);
#endif
        I_Error("mz_zip_reader_extract_to_mem failed");
    }

    wadinfo_t header;

    if (sizeof(header) > data_size)
    {
#ifdef WOOF_IOS
        // I_Error ends the session, not the process: free before it (#38).
        FreeWadBuffer(data);
#endif
        I_Error("Error reading header from %s", name);
    }

    memcpy(&header, data, sizeof(header));

    if (strncmp(header.identification, "IWAD", 4)
        && strncmp(header.identification, "PWAD", 4))
    {
#ifdef WOOF_IOS
        // I_Error ends the session, not the process: free before it (#38).
        FreeWadBuffer(data);
#endif
        I_Error("Wad file %s doesn't have IWAD or PWAD id", name);
    }

    header.numlumps = LONG(header.numlumps);
    if (header.numlumps == 0)
    {
        I_Printf(VB_WARNING, "Wad file %s is empty", name);
#ifdef WOOF_IOS
        FreeWadBuffer(data);
#else
        free(data);
#endif
        return;
    }

    header.infotableofs = LONG(header.infotableofs);
    if (header.infotableofs + header.numlumps * sizeof(filelump_t) > data_size)
    {
        I_Printf(VB_WARNING, "Error seeking offset from %s", name);
#ifdef WOOF_IOS
        FreeWadBuffer(data);
#else
        free(data);
#endif
        return;
    }

#ifdef WOOF_IOS
    // Owned from here on by W_ZIP_Close, which also covers the lump-range
    // I_Error below: by then lumpinfo already points into the buffer.
    array_push(wad_buffers, data);
#endif

    filelump_t *fileinfo = (filelump_t *)(data + header.infotableofs);

    const char *wadname = M_StringDuplicate(name);
    array_push(wadfiles, wadname);

    numlumps += header.numlumps;

    for (int i = 0; i < header.numlumps; i++)
    {
        lumpinfo_t item = {0};
        M_CopyLumpName(item.name, fileinfo[i].name);
        int size = LONG(fileinfo[i].size);
        int position = LONG(fileinfo[i].filepos);
        if (position + size > data_size)
        {
            I_Error("Error reading lump %d from %s", i, wadname);
        }
        item.size = size;
        item.data = data + position;

        item.handle = handle;
 
        // [FG] WAD file that contains the lump
        item.wad_file = wadname;
        array_push(lumpinfo, item);
    }
}

static boolean W_ZIP_AddDir(w_handle_t handle, const char *path,
                            const char *start_marker, const char *end_marker)
{
    archive_t *archive = handle.p1.archive;

    mz_zip_archive *zip = archive->zip;

    boolean is_root = (path[0] == '.');

    char *dir = M_StringDuplicate(path);
    ConvertSlashes(dir);

    int startlump = numlumps;

    for (int i = 0; i < mz_zip_reader_get_num_files(zip); ++i)
    {
        const record_t record = archive->directory[i];

        mz_zip_archive_file_stat stat;
        mz_zip_reader_file_stat(zip, record.index, &stat);

        if (stat.m_is_directory)
        {
            continue;
        }

        char *name = M_DirName(record.filename);
        if (strcasecmp(name, dir))
        {
            free(name);
            continue;
        }
        free(name);

        if (is_root && M_StringCaseEndsWith(record.filename, ".wad"))
        {
            AddWadInMem(handle, M_BaseName(record.filename), record.index,
                        stat.m_uncomp_size);
            continue;
        }

        if (W_SkipFile(record.filename))
        {
            continue;
        }

        if (startlump == numlumps && start_marker)
        {
            W_AddMarker(start_marker);
        }

        lumpinfo_t item = {0};

        W_ExtractFileBase(stat.m_filename, item.name);
        item.size = stat.m_uncomp_size;

        item.module = &w_zip_module;
        w_handle_t local_handle = {.p1.archive = archive,
                                   .p2.index = record.index,
                                   .priority = handle.priority};
        item.handle = local_handle;

        array_push(lumpinfo, item);
        numlumps++;
    }

    if (numlumps > startlump && end_marker)
    {
        W_AddMarker(end_marker);
    }

    free(dir);
    return true;
}

static int compare_records(const void *a, const void *b)
{
    const record_t *arg1 = a;
    const record_t *arg2 = b;

    return strcasecmp(arg1->filename, arg2->filename);
}

static w_type_t W_ZIP_Open(const char *path, w_handle_t *handle)
{
    mz_zip_archive *zip = calloc(1, sizeof(*zip));

    if (!mz_zip_reader_init_file(zip, path, MZ_ZIP_FLAG_DO_NOT_SORT_CENTRAL_DIRECTORY))
    {
        free(zip);
        return W_NONE;
    }

    const int num_files = mz_zip_reader_get_num_files(zip);
    record_t *directory = malloc(num_files * sizeof(*directory));
    for (int i = 0; i < num_files; ++i)
    {
        directory[i].index = i;
        int size = mz_zip_reader_get_filename(zip, i, NULL, 0);
        char *filename = malloc(size);
        mz_zip_reader_get_filename(zip, i, filename, size);
        directory[i].filename = filename;
    }
    qsort(directory, num_files, sizeof(*directory), compare_records);

    I_Printf(VB_INFO, " adding %s", path);

    archive_t archive = {zip, directory};
    array_push(archives, archive);
    handle->p1.archive = array_end(archives) - 1;

    return W_DIR;
}

static void W_ZIP_Read(w_handle_t handle, void *dest, int size)
{
    boolean result = mz_zip_reader_extract_to_mem(
        handle.p1.archive->zip, handle.p2.index, dest, size, 0);

    if (!result)
    {
        I_Error("mz_zip_reader_extract_to_mem failed");
    }
}

static void W_ZIP_Close(void)
{
    for (int i = 0; i < array_size(archives); ++i)
    {
#ifdef WOOF_IOS
        // A second engine session in the same process calls W_ZIP_Open()
        // again for the same base pk3, array_push()-ing a new archive_t
        // onto this same array. Left uncleared, `archives` (and every
        // lumpinfo_t.handle.p1.archive pointing into it) would still
        // reference this already-mz_zip_reader_end()-ed entry, and a
        // duplicate-named lump lookup landing on the stale entry instead
        // of the fresh one fails extract_to_mem against a torn-down
        // reader. Free everything this module owns so the array (and any
        // realloc it triggers) starts clean next session.
        int num_files = mz_zip_reader_get_num_files(archives[i].zip);
#endif
        mz_zip_reader_end(archives[i].zip);
#ifdef WOOF_IOS
        free(archives[i].zip);
        for (int j = 0; j < num_files; ++j)
        {
            free((void *)archives[i].directory[j].filename);
        }
        free(archives[i].directory);
#endif
    }

#ifdef WOOF_IOS
    array_free(archives);

    for (int i = 0; i < array_size(wad_buffers); ++i)
    {
        FreeWadBuffer(wad_buffers[i]);
    }
    array_free(wad_buffers);
#endif
}

w_module_t w_zip_module =
{
    W_ZIP_AddDir,
    W_ZIP_Open,
    W_ZIP_Read,
    W_ZIP_Close
};
