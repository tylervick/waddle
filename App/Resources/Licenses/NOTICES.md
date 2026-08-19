# Third-party notices

Waddle is free software under the GNU GPL v3 (see APP-LICENSE-GPL3.txt).
Complete corresponding source: https://github.com/tylervick/waddle

- Woof! (Doom engine) — GPL-2.0, © Fabian Greffrath and contributors.
  Vendored with iOS patches; see Engine/WOOF_UPSTREAM.md in the source repo.
- Freedoom (game data, and the font artwork the app mark is drawn from) —
  BSD-style license (FREEDOOM-BSD.txt), © 2001-2024 Contributors to the
  Freedoom project.
- SDL 3 — zlib license (SDL3-ZLIB.txt).
- OpenAL Soft — LGPL-2.0 (OPENALSOFT-LGPL.txt). Statically linked and
  conveyed as part of this GPL-3.0 application per LGPL §3, which permits
  conversion to GPL version 2 "or any later version", with complete source
  available at the repository above.
- SONiVOX EAS (wavetable MIDI synthesis) — Apache-2.0 (SONIVOX-APACHE2.txt),
  Copyright (c) 2004-2006 Sonic Network Inc. The upstream attribution notice is
  reproduced verbatim in SONIVOX-NOTICE.txt, to satisfy Apache-2.0 §4(d),
  which requires a readable copy of the attribution notices. This
  is the synth the predecessor per-game apps used, which is why Waddle's music
  sounds like theirs. Apache-2.0 is incompatible with GPL-2.0 and compatible
  with GPL-3.0; Woof is GPL-2.0-or-later, and exercising that "or later" grant
  is what makes this combination lawful and why this app is GPL-3.0.
- libsndfile (streamed music: OGG, FLAC, WAV) — LGPL-2.1
  (LIBSNDFILE-LGPL.txt). Statically linked and conveyed as part of this GPL-3.0
  application per LGPL §3, which permits conversion to GPL version 2 "or any
  later version", with complete source available at the repository above.
- libogg — BSD-3-Clause (LIBOGG-BSD.txt), © 2002-2020 Xiph.Org Foundation.
- libvorbis — BSD-3-Clause (LIBVORBIS-BSD.txt), © 2002-2020 Xiph.Org Foundation.
- libFLAC — BSD-3-Clause (LIBFLAC-BSD.txt), © 2000-2009 Josh Coalson,
  © 2011-2025 Xiph.Org Foundation. Only the library is built and linked; FLAC's
  command-line tools, which are GPL-2.0, are not built (BUILD_PROGRAMS=OFF).
- libopus — BSD-3-Clause (LIBOPUS-BSD.txt), © 2001-2023 Xiph.Org, Skype
  Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry and others.
  Required because libsndfile gates Ogg, Vorbis, FLAC and Opus behind a single
  build flag; it is linked whether or not any WAD uses Opus.
- ZIPFoundation — MIT (ZIPFOUNDATION-MIT.txt).
