# libsndfile's external codecs are all-or-nothing

Wanting OGG music support costs five pinned libraries, not one. libsndfile
vendors no codecs, and it does not let you pick among them: a single
`HAVE_EXTERNAL_XIPH_LIBS` gates Ogg, Vorbis, FLAC **and** Opus together. There
is no `ENABLE_VORBIS` or `ENABLE_FLAC` option in 1.2.2 — `grep 'option(ENABLE_'`
its `CMakeLists.txt` returns nothing.

With `ENABLE_EXTERNAL_LIBS` on and FLAC absent, configure does not degrade
gracefully; it fails:

```console
CMake Error at CMakeLists.txt:391 (target_link_libraries):
    FLAC::FLAC
```

Turning `ENABLE_EXTERNAL_LIBS` off instead drops Ogg and Vorbis with it, leaving
only the built-in formats — which defeats the point, since WAV was never the
problem.

So `Scripts/build-deps.sh` pins libogg, libvorbis, libFLAC, libopus and
libsndfile, in that order: vorbis needs ogg, and libsndfile needs all four.
libopus is linked whether or not any WAD uses Opus.

Two things that bite while building them for iOS:

- **CMake 4 refuses their minimum-version declarations.** libvorbis and
  libsndfile both declare `cmake_minimum_required` below 3.5, which CMake 4
  rejects outright, and `mise.toml` pins cmake 4.4.2. Both need
  `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`. libogg, libFLAC and libopus do not.
- **Each library must be able to find the ones before it.** `build()` passes
  `CMAKE_PREFIX_PATH` and `CMAKE_FIND_ROOT_PATH` for this reason. Under
  `CMAKE_SYSTEM_NAME=iOS`, `find_package` will not look outside the root path,
  so without them vorbis cannot see ogg and libsndfile cannot see any of them —
  and libsndfile's failure is the confusing one, because it reports the codecs
  as simply "NOT found" rather than as unreachable.

Licensing is clean but not uniform: the four codecs are BSD-3-Clause while
libsndfile is LGPL-2.1, conveyed under the GPL exactly as OpenAL Soft already
is. FLAC ships GPL command-line tools alongside its BSD library; `BUILD_PROGRAMS=OFF`
keeps them out, and `App/Resources/Licenses/LIBFLAC-BSD.txt` is its
`COPYING.Xiph`, not its `COPYING.GPL`.
