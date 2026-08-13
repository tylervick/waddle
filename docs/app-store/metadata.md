# App Store metadata — WADdle

**Status: APPROVED at the Plan 4 Task 7 user gate (2026-07-18).**
Decisions recorded in the log at the bottom.

---

## 1. App name (30 chars max) — DECIDED

**Store name: "WADdle: WAD Player"** (18 chars). **The bare "WADdle" is not
available** — see the availability finding below. Everything internal (bundle
ID, target, repo) stays plain `WADdle`; only the App Store *display name*
carries the suffix.

**Availability (tested 2026-07-30, against the live ASC record).** Renaming
the App Store Connect record to plain "WADdle" was attempted via the API —
`PATCH /v1/appInfoLocalizations/{id}` on the **en-US** localization, which is
the only one the record has — and **rejected**:

> `409 ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE.DIFFERENT_ACCOUNT` — "The app
> name you entered is already being used. If you have trademark rights to this
> name and would like it released for your use, submit a claim."

App Store display names are globally unique and matched case-insensitively, so
one of the unrelated *Waddle* apps catalogued below already holds it. Name
availability is per-locale, so if further localizations are ever added the
same check has to be repeated for each. The
claim route is not open to us: the knock-out research found the registered
WADDLE mark belongs to Waddle IP Pty Ltd, so there are no trademark rights
here to assert. The suffix is therefore forced, not chosen — but *which*
suffix is still open, and any 30-char-max variant that avoids "Doom" would
work equally well if the owner prefers a different one.

The original naming rationale stands otherwise: "WADdle" hides **WAD** — the
Doom file format the app plays — inside *waddle*, in the whimsical spirit of
the source-port lineage it belongs to (its engine is **Woof!**, alongside
*Crispy Doom* and *Chocolate Doom*). The suffix does double duty against the
crowding risk noted below: it separates us from the *Waddle* cluster and makes
the listing searchable on "wad player", while the subtitle still carries the
plain description.

**Scope note:** this was a full rename, done pre-submission while it was
still free to change. Everything moved to the new name — the bundle ID
(`com.tylervick.waddle`, lowercase), the Xcode target/scheme/project
(`WADdle`), the GitHub repo (`tylervick/waddle`), the UTI identifiers
(`com.tylervick.waddle.*`), and the `WADDLE_*` test-seam env vars. Nothing
user- or developer-facing retains "BoomBox".

**Knock-out checks (2026-07-20):**
- **Trademark — clear for this use.** A live registered "WADDLE" mark exists
  in Nice Class 9 (software), but it is owned by Waddle IP Pty Ltd, an
  Australian invoice-lending fintech (now part of Commonwealth Bank).
  Confusion turns on related goods; a B2B lending platform and a retro FPS
  game do not overlap.
- **App Store — crowded but category-separated.** Several unrelated "Waddle"
  apps exist (couples, family activities, navigation, a drawing game), none
  an FPS/source-port. Similar names coexist commonly on the store and the
  Games category separates us; a similarity rejection is possible but
  unlikely. The crowding was explicitly accepted by the owner.

The earlier "BoomBox" research and alternatives are kept below for the record.

**Research (2026-07-18):** the bare name "BoomBox" is crowded on the App
Store — *Boombox.io*, *Boombox: Social Music Recs*, *The Boombox*, and
*BoomBoxx* all exist as music apps. The exact name may be rejected for
similarity to existing apps, and on its own it mis-signals the category
(music, not games).

**Hard constraint:** the name must **not** contain "Doom" — id Software /
Bethesda trademark. ("Doom" used *descriptively* in the subtitle,
description, and keywords is nominative use and is how comparable approved
apps — GenZD, for example — describe themselves; the risk concentrates in
the app *name*.)

| # | Name | Chars | Pros | Cons |
|---|------|-------|------|------|
| 1 | **BoomBox: WAD Player** *(recommended)* | 19 | Keeps the working name, bundle ID (`com.tylervick.BoomBox`), icon, and repo branding; the suffix disambiguates from the music apps and states the function; searchable by both "boombox" and "wad" | "BoomBox" prefix still sits adjacent to the music-app cluster; a strict similarity reviewer could still object |
| 2 | **WADBox** | 6 | Short, functional, no music-app collision found; opaque only to people outside the target audience (who know exactly what a WAD is) | Generic "-box" construction; abandons existing branding; less memorable |
| 3 | **Boomslayer** | 10 | Punchy, game-flavored, nods to the Boom engine lineage; clearly not a music app | "Slayer" is adjacent to Bethesda's "Doom Slayer" marketing — low but nonzero trademark-adjacency risk; says nothing about function (subtitle has to work hard) |
| 4 | **Boomport** | 8 | Portmanteau of *Boom* + *source port* — names the exact engine family; unique in research; zero music collision | Reads as "boom port" (shipping?) to laypeople; drier than the alternatives |

All four avoided "Doom", as does the chosen name **WADdle**. The knock-out
search called for here was run on WADdle on 2026-07-20 (results recorded
above). The App Store *display name* is independent of the bundle ID, so
WADdle does not require a bundle-ID change.

## 2. Subtitle (30 chars max)

> **Play classic Doom WADs** *(22 chars)*

Uses "Doom" descriptively (nominative use — the file format/ecosystem being
played). Fallback if App Review objects: **"Classic FPS WAD player"** (22
chars).

## 3. Promotional text (170 chars max)

> Freedoom out of the box - or import your own WADs. A faithful
> Boom/MBF21 source port with touch controls, game controllers, and
> keyboard support. *(151 chars)*

## 4. Description

> **Play the classic-Doom-engine games you own, anywhere.**
>
> WADdle is a source port of the classic Doom engine for iPhone and iPad,
> built on Woof! - the modern continuation of the Boom and MBF ports that
> faithfully preserves original gameplay while supporting today's mods, up
> through the MBF21 standard.
>
> **Ready to play out of the box.** WADdle bundles Freedoom Phase 1 and
> Phase 2: two complete, freely licensed games built by the Freedoom
> project for this engine family. Tap and play - nothing to configure.
>
> **Bring your own WADs.** Import WAD files you own from the Files app,
> iCloud Drive, or the share sheet - commercial IWADs you've purchased, or
> any of thousands of community-made maps and megawads. Zip archives and
> DeHackEd patches are supported.
>
> **Presets.** Combine a base game with mods and patches, set the load
> order and compatibility level (vanilla, Boom, MBF, MBF21 - or auto), and
> save the combination as a one-tap preset. Saves are kept per preset.
>
> **Play your way.** Touch controls with two schemes (classic twin-stick
> and modern drag-to-turn) and adjustable feel - plus full support for
> game controllers and hardware keyboards.
>
> **Open source.** WADdle is free software under the GPL-2.0, like the
> engine it descends from. Source code for the entire app is available on
> GitHub.
>
> WADdle includes no copyrighted commercial game content. Only the freely
> licensed Freedoom data is bundled; commercial WADs must be imported by
> you, from copies you own. This app is not affiliated with or endorsed by
> id Software or Bethesda.

## 5. Keywords (100 chars max)

> `doom,wad,fps,retro,source port,freedoom,boom,classic` *(52 chars — room
> for more; candidates: `megawad`, `shooter`, `90s`)*

## 6. URLs

- **Support URL:** https://github.com/tylervick/waddle/issues — the issue
  tracker, not the repo root: it is where a user with a problem should
  actually land, and it is what the live ASC record has been set to
  (reconciled 2026-07-30). The repo is **public**, which is what the GPL
  source-availability requirement needs — though "public repo" alone is not
  the whole of it: compliance is about the *corresponding* source for the
  binary actually shipped, so the release process still has to put the
  submitted build's commit, its build materials and the licence notices
  within reach. That is gated by the "GPL posture check" in
  `docs/app-store/submission-checklist.md`, not by this line.
- **Marketing URL (optional):** same repo, or none.
- **Privacy Policy URL:**
  https://github.com/tylervick/waddle/blob/main/PRIVACY.md — `PRIVACY.md`
  at the repo root (decided 2026-07-18). The app collects nothing (see
  `App/PrivacyInfo.xcprivacy`); the policy says so in plain language.

## 7. Category

- **Primary:** Games → Action
- **Secondary:** none (optional; Games → Adventure would fit if desired)

## 8. Age-rating questionnaire

These are the answers for the **current (2025) questionnaire**, which the
App Store Connect API exposes as the 29-field `ageRatingDeclaration` on
the app's `appInfo`. Every field below has either a documented answer or
an explicit "leave unset" decision, so the form can be filled straight
from this table without re-deriving anything at the form. Rows are
grouped in the order the ASC questionnaire presents them.

Reading the **Answer** column:

- Frequency fields are three-state: **`NONE`, `INFREQUENT`,
  `FREQUENT`**. Use those if writing via the API — `INFREQUENT_OR_MILD`
  and `FREQUENT_OR_INTENSE` are still accepted but are **deprecated**
  (App Store Connect API 4.1 release notes). The Answer column below
  spells them the long way (Infrequent/Mild, Frequent/Intense) to match
  the questionnaire's own prose; they mean `INFREQUENT` and `FREQUENT`.
- Yes/No fields are booleans in the API (`true`/`false`).

### In-app controls

| Questionnaire item | API field | Answer | Rationale |
|---|---|---|---|
| Parental Controls | `parentalControls` | **No** | The app ships no parental-control feature of its own, and there is nothing to gate: no purchases, no accounts, no network. OS-level Screen Time still applies, but that is not the app offering controls |
| Age Assurance | `ageAssurance` | **No** | No age gate, age estimation, or ID check anywhere in the app |

### Capabilities

| Questionnaire item | API field | Answer | Rationale |
|---|---|---|---|
| Unrestricted Web Access | `unrestrictedWebAccess` | **No** | The app makes no network requests at all and embeds no browser or web view |
| User-Generated Content | `userGeneratedContent` | **No** | Imported WADs are local files the user chooses; they stay on device and are never uploaded, shared, or hosted, so no user's content can reach another user |
| Social Media | `socialMedia` | **No** | No feeds, profiles, follows, or sharing |
| Age-Restricted Social Media | `socialMediaAgeRestricted` | **No** | N/A — follows from Social Media = No |
| Messaging and Chat | `messagingAndChat` | **No** | No chat, no comments, no networked or local multiplayer (the port exposes no netgame surface) |
| Advertising | `advertising` | **No** | No ads and no ad SDKs; `App/PrivacyInfo.xcprivacy` declares no tracking and no collected data types |

### Mature themes

| Questionnaire item | API field | Answer | Rationale |
|---|---|---|---|
| Profanity or Crude Humor | `profanityOrCrudeHumor` | **None** | Freedoom's text, level names, and art contain none |
| Horror or Fear Themes | `horrorOrFearThemes` | **None** | Monster combat is declared under fantasy violence; Freedoom adds no horror framing, jump scares, or dread-building presentation of its own |
| Alcohol, Tobacco, or Drug Use or References | `alcoholTobaccoOrDrugUseOrReferences` | **None** | No such content or references |

### Medical or wellness

| Questionnaire item | API field | Answer | Rationale |
|---|---|---|---|
| Medical or Treatment Information | `medicalOrTreatmentInformation` | **None** | Medkit and stimpack pickups are an abstract score mechanic, not medical or treatment information |
| Health or Wellness Topics | `healthOrWellnessTopics` | **No** | The app presents no health, fitness, nutrition, or wellness content |

### Sexuality or nudity

| Questionnaire item | API field | Answer | Rationale |
|---|---|---|---|
| Mature or Suggestive Themes | `matureOrSuggestiveThemes` | **None** | — |
| Sexual Content or Nudity | `sexualContentOrNudity` | **None** | Freedoom's sprites and art contain none |
| Graphic Sexual Content and Nudity | `sexualContentGraphicAndNudity` | **None** | Distinct API field from the row above (the form asks the graphic variant separately); same answer for the same reason |

### Violence

| Questionnaire item | API field | Answer | Rationale |
|---|---|---|---|
| Cartoon or Fantasy Violence | `violenceCartoonOrFantasy` | **Frequent/Intense** | Core gameplay: shooting fantasy monsters (Freedoom's demons-replacement bestiary), pixelated gibs |
| Realistic Violence | `violenceRealistic` | **Infrequent/Mild** | Conservative. Combat is against fantasy creatures in low-res 1993-era sprites, but a few enemies read as humanoid and blood is depicted. Infrequent/Mild and None both land the app at 13+, so the cautious answer costs nothing — see the outcome note below before ever raising this one |
| Prolonged Graphic or Sadistic Realistic Violence | `violenceRealisticProlongedGraphicOrSadistic` | **None** | Combat is instantaneous hitscan/projectile fire against monsters; nothing is prolonged, torture-themed, or sadistic |
| Guns or Other Weapons | `gunsOrOtherWeapons` | **Frequent/Intense** | New field, and the only new one that is a real judgement call. This is a first-person shooter: a gun-shaped weapon (pistol, shotgun, chaingun, rocket launcher) is drawn on screen for essentially all of playtime and firing it is the primary verb. "Infrequent" would be indefensible regardless of how stylised the 1993-era sprites are, and under-declaring it would contradict the Frequent/Intense fantasy-violence answer directly above it |

### Chance-based activities

| Questionnaire item | API field | Answer | Rationale |
|---|---|---|---|
| Gambling | `gambling` | **No** | No real-money gambling, wagering, or casino content. (Split from Contests in the current questionnaire — both are answered) |
| Simulated Gambling | `gamblingSimulated` | **None** | No slot, card, or casino minigames; nothing simulates wagering |
| Contests | `contests` | **None** | No contests, sweepstakes, tournaments, or leaderboards; there is no Game Center integration |
| Loot Boxes | `lootBox` | **No** | No purchases of any kind and no randomized-reward mechanic — item pickups sit at fixed, level-designer-placed positions |

### Situational and administrative fields

| Questionnaire item | API field | Answer | Rationale |
|---|---|---|---|
| Kids Age Band | `kidsAgeBand` | **Leave unset** (`null`) | N/A — the app is not and never was Made for Kids (`isOrEverWasMadeForKids` = `false`) |
| Developer age-rating info URL | `developerAgeRatingInfoUrl` | **Leave unset** | Optional. Nothing here needs an explanation beyond the App Review notes in §11 |
| Age rating override | `ageRatingOverride` (deprecated) | **NONE** | Already `NONE` on the record. Take the computed rating rather than forcing one |
| Age rating override (V2) | `ageRatingOverrideV2` | **NONE** | Same — no manual override; 18+ / Unrated overrides do not apply |
| Korea age rating override | `koreaAgeRatingOverride` | **NONE** | Already `NONE`; no Korea-specific override needed |

**Expected resulting rating: 13+ on iOS/iPadOS 26 and later**, unchanged
by the newly answered fields. Under the 2025 tiers (4+/9+/13+/16+/18+)
each of the app's three non-`None` answers maps to 13+ on its own:
frequent cartoon or fantasy violence, frequent guns or other weapons, and
infrequent realistic violence are all 13+ descriptors. So answering
`gunsOrOtherWeapons` at Frequent/Intense — the honest answer for a
shooter — does **not** push the app above 13+, and the earlier "accept a
higher tier if it resolves there" hedge is no longer expected to be
needed (17+, which that note named, is not even a tier any more). If the
form still computes higher, accept it.

**13+ is not what every device shows.** Apple states that "age ratings
for an app may vary based on the OS version": the 4+/9+/13+/16+/18+
tiers apply on iOS/iPadOS 26 and later, while devices on earlier OS
versions are shown a *legacy* rating, listed in App Store Connect under
"Operating Systems Earlier than Version 26". Expect the legacy value to
be **12+** — that is what GenZD shows in the storefront today on the same
Frequent/Intense fantasy-violence profile (see the table below) — but
read the actual pair off ASC after submitting the questionnaire rather
than trusting that inference. Both values are ours; don't be surprised by
the 12+ when it appears.

The one answer that *would* move the result is `violenceRealistic`:
frequent realistic violence is an 18+ descriptor. Keep it at
Infrequent/Mild — the gun-shaped-weapons concern that originally
motivated that answer now has its own dedicated field.

### Shipped content vs. imported content

Users importing their own WADs does not raise the rating: rate the
content the app ships. Verified against comparable apps on 2026-07-30
via the iTunes lookup API (tier labels are the legacy ones the storefront
API still reports; 12+ maps to 13+ under the 2025 tiers):

| App | Ships game content? | Rating | Declared descriptors |
|---|---|---|---|
| Delta | No — user supplies all ROMs | **4+** | none |
| PPSSPP | No | **4+** | none |
| Provenance | No | **9+** | Infrequent/Mild Cartoon or Fantasy Violence |
| RetroArch | Some free/homebrew | **9+** | Infrequent/Mild Cartoon or Fantasy Violence, Infrequent/Mild Profanity |
| GenZD | No — "does not include content" | **12+** | **Frequent/Intense Cartoon or Fantasy Violence**, Infrequent/Mild Horror, Profanity, Mature/Suggestive |

Two things follow, and they matter more than the raw numbers:

- **The precedent is inconsistent, so don't lean on it.** Delta and GenZD
  are structurally identical — neither ships a single byte of game
  content, both run whatever the user side-loads — yet Delta is 4+ with
  no descriptors and GenZD declares Frequent/Intense fantasy violence.
  Both are approved and shipping. Apple is clearly not enforcing one line
  here, so "app X got away with Y" is not a defence for anything.
- **WADdle can't take Delta's route regardless.** Delta's 4+ is only
  available to an app that ships nothing. WADdle bundles Freedoom, so
  there *is* shipped content, and it has frequent fantasy violence and
  guns in it. 13+ is the floor for us on the shipped content alone,
  independent of what anyone imports.

GenZD is the closest comparable — same idTech 1 engine family, same
"import WADs via the Files app" model — and it lands at 12+ (≙ 13+)
while declaring Frequent/Intense fantasy violence. That is our exact
profile, which corroborates the 13+ expectation above.

Note that GenZD also declares infrequent horror, profanity, and
mature/suggestive themes despite shipping no content — i.e. it rates for
*anticipated* user content rather than shipped content. §8 does not
follow that posture, and it costs nothing either way: all three of those
descriptors top out at 13+, so adopting GenZD's answers wholesale would
not change our result. Only `violenceRealistic` at Frequent would.

**The one thing that would genuinely change this analysis** is adding an
in-app WAD browser or downloader. Guideline 4.7 covers emulator apps that
"offer to download games", and 4.7.5 then requires the app to flag
software exceeding its age rating *and* to gate it behind a verified or
declared-age mechanism — which would flip `ageAssurance` and
`parentalControls` from No to a feature we'd have to build. Import via
the system Files app is the user bringing their own file to the app, not
the app offering software, so 4.7 does not attach today. Keep it that
way, or re-open this section if an in-app content browser is ever
proposed.

## 9. Export compliance

The app makes **no network connections** and implements no encryption; the
only cryptography linked is Apple's OS frameworks (and a SHA-1 file hash
for deduplication, which is exempt hashing, not encryption).

- "Does your app use encryption?" → **Yes** (conservative: OS-provided
  HTTPS capability exists via frameworks) → "Does your app qualify for any
  of the exemptions?" → **Yes — only uses encryption within Apple's
  operating system / exempt purposes.**
- Algorithm question: **"None of the algorithms mentioned."**
- Recommend also setting `ITSAppUsesNonExemptEncryption = NO` in
  Info.plist so the question never blocks a build upload.

## 10. Copyright line

> © 2026 Tyler Vick; engine GPL-2.0

(Engine lineage: Woof! © its contributors, descending from Boom/MBF/id's
GPL release — all GPL-2.0; full attribution is in the app's About screen
and the repo's COPYING.)

## 11. App Review notes

> This app is a GPL source port of the classic Doom engine (Woof!/Boom
> lineage). It includes ONLY the freely-licensed Freedoom game data -
> no copyrighted commercial game content is bundled. Users may import WAD
> files they own via the Files app; these stay on device. The app makes no
> network requests. Comparable approved apps: GenZD, RetroArch.
>
> On iPad the app supports all orientations and windowed multitasking.
>
> To demo: no account or setup needed - tap the "Freedoom Phase 1" tile on
> the Play tab.
>
> WAD files are game data, not executable code: they contain maps, sprites,
> sounds and music. DeHackEd patches are data tables the engine interprets.
> Nothing is compiled or executed, and no code is loaded at runtime.
>
> Importing is optional for review - both bundled base games (Freedoom
> Phase 1 and Phase 2) play immediately with no setup. To exercise import,
> any .wad or .zip added via the Files app works.
>
> One non-obvious control: a four-finger tap during gameplay summons the
> iOS keyboard for classic cheat codes and save-name entry. It is
> intentionally undiscoverable in the UI, matching the original games.

**Entered in App Store Connect 2026-08-13** (1113 chars). The three closing
paragraphs were added then; the original three are unchanged from the
2026-07-18 approval. Each addition closes a gap a reviewer would otherwise
have to resolve by guessing:

- **Data, not code.** A source port that loads user files sits near
  Guidelines 4.7 and 2.5.2. Saying plainly that WADs and DeHackEd patches
  are interpreted data pre-empts the question rather than waiting for a
  rejection to raise it.
- **Import is not exercisable.** "Bring your own WADs" is a headline claim
  in §4, but a reviewer has no `.wad` on the device. The note makes clear
  the app is fully evaluable without one. If a sample is ever wanted,
  App Store Connect supports review attachments
  (`appStoreReviewAttachments`); none is attached today.
- **The cheat keyboard is invisible.** The four-finger tap is documented
  only in source comments — there is no in-app hint surface — so a
  reviewer who found it by accident would be looking at an undisclosed
  hidden gesture.

The diagnostics export deliberately gets no paragraph here: `AboutView`
already discloses it in-app ("Nothing leaves your device unless you share
this file"), which is stronger than a note, and the app links no networking
APIs at all.

## 12. Screenshots

Captured by `Scripts/capture-screenshots.sh` into
`docs/app-store/screenshots/<device>/` (see the script header for how).

**Re-captured 2026-07-30** against the reworked UI (#8/#9/#10). The
original 2026-07-18 set photographed the retired loadout grid and the
pre-rework library and has been replaced wholesale; two files were renamed
to match what they now show (`01-loadout-grid.png` → `01-play-tab.png`,
`03-loadout-editor.png` → `03-preset-editor.png`).

**Re-captured 2026-07-31** for #31, which renamed the preset editor's
navigation title from "New Loadout" to "New Preset". Slot 4 photographs
that title, so both device sets were re-shot. Slot 4 is the only shot that
changed by design; the remaining deltas are the status-bar date (iPad, all
shots) and a ~130 px in-game HUD counter caught on a different frame
(slots 1 and 5).

One exception is worth an eye before the next App Store Connect upload:
iPhone slot 2 now renders the below-the-fold Base Games tiles washed out,
where the 2026-07-30 shot had them fully saturated (~16% of the frame, all
of it below y=986; the iPad slot 2 is unaffected because all three
sections fit above the fold there). It reproduced pixel-identically across
two independent capture runs, so it is deterministic under the current
build rather than a settle-time flake, and #31's diff is five string
literals with nothing in a rendering path — it does not originate there.
Cause not yet identified; most likely an OS/runtime difference against the
scroll edge effect under the floating tab bar.

| Slot | Shot | File |
|------|------|------|
| 1 | In-game (Freedoom Phase 1, touch overlay) | `05-ingame.png` |
| 2 | Play tab — Recently Played / Base Games / Presets, TITLEPIC tile art | `01-play-tab.png` |
| 3 | Library — grouped into Base Games / Mods / Patches | `02-library.png` |
| 4 | Preset editor — base game, mod load order, compatibility level | `03-preset-editor.png` |
| 5 | Automap | `06-automap.png` |
| 6 | Control Feel sheet | `04-control-feel.png` |

Slot 2 is shot at the top of the Play list — what a user sees on launch.
All three sections fit on iPad; a landscape iPhone shows Recently Played
and the head of Base Games, because a tile is ~207 pt tall in a 440 pt
viewport and three sections cannot fit however the shot is framed.

**EXIF orientation (fixed 2026-07-30 — do not reintroduce).** `sips
--rotate 270`, which the export step uses to right the portrait pixel
buffer XCUIScreen hands back, rewrites the raster *and* leaves an EXIF
Orientation tag of 8 ("rotate 90° CCW") behind. The pixels are already
upright, so anything that honours EXIF rotates them a second time. Git,
GitHub and Preview all ignore the chunk, so the files look correct
everywhere you would normally check — but **App Store Connect honours it**
and stored the first upload sideways, reporting the dimensions transposed
(1320×2868 for a 2868×1320 file) while still returning
`assetDeliveryState: COMPLETE` with no errors. The export step now strips
the chunk (lossless — IHDR and IDAT are untouched). When uploading, verify
by rendering the asset back from its `imageAsset.templateUrl`: `COMPLETE`
is not evidence the image is the right way up.

Device classes:

- **iPhone 6.9" (required):** iPhone 17 Pro Max simulator — 2868×1320
  landscape.
- **iPad 13" (required for iPad):** iPad Pro 13-inch (M4) simulator —
  2752×2064 landscape. (The pre-existing "iPad (A16)" simulator is
  11-inch class and cannot produce 13-inch-class images, so the script
  creates the 13-inch device on demand.)

**iPadOS 26 windowing (fix landed in Plan 4 Task 7b; re-verified
2026-07-30):** the owner decided at the gate to fix windowed-mode support
rather than ship it as a limitation. The app now supports portrait + both
landscapes on iPhone and all four orientations on iPad
(`UIRequiresFullScreen` removed), and in iPadOS 26's default Windowed Apps
mode it opens upright and playable in a resizable window; mid-session
rotation and live window resizing re-letterbox the game without crashing
(the engine-side half of the fix is an `SDL_HINT_ORIENTATIONS` hint in
`woof_ios.c`, without which SDL locked sessions to landscape). The App
Review notes state this support, and that statement still holds.

**The Settings workaround survives the fix, for a different reason.** The
2026-07-18 notes predicted that re-running the capture script would no
longer need the switch to Settings → "Full Screen Apps". That prediction
was tested on 2026-07-30 and is wrong. The fix does remove the old
failure — the app no longer lands sideways in a letterboxed portrait
window — but in Windowed Apps mode iPadOS draws a window-resize grabber
over the app's bottom-right corner, and it does not fade (still in frame
minutes after launch, on an otherwise clean full-screen Play tab). It has
no place in a marketing shot, so the script's
`test0_ConfigureIPadFullScreenMode` step still flips the simulator to
Full Screen Apps before capturing. Historical note, since it no longer
applies: at the original capture the app was landscape-only and
`UIRequiresFullScreen`, and Xcode warned that the latter "will soon be
ignored; support for all orientations will soon be required" — which is
what motivated fixing this properly.

## 13. Decisions log (filled at the user gate)

| Decision | Choice | Date |
|----------|--------|------|
| Final app name | ~~BoomBox: WAD Player~~ → ~~WADdle~~ → **WADdle: WAD Player** — plain "WADdle" is taken on the App Store by another account (§1) | 2026-07-18 → 2026-07-20 → 2026-07-30 |
| Subtitle wording | Approved as drafted ("Play classic Doom WADs") | 2026-07-18 |
| Description tone | Approved as drafted (incl. promotional text and keywords) | 2026-07-18 |
| Age-rating answers confirmed | Approved as drafted (§8 table, 13 items, older questionnaire) | 2026-07-18 |
| Age-rating answers re-confirmed for the 2025 questionnaire | Approved as drafted — full 29-field `ageRatingDeclaration` (§8), incl. `gunsOrOtherWeapons` = Frequent/Intense; target 13+, no override | 2026-07-30 |
| Export compliance answers | Approved as drafted (§9) | 2026-07-18 |
| Privacy policy URL approach | `PRIVACY.md` in repo root (GitHub URL once public) | 2026-07-18 |
| iPadOS windowing | Fix before shipping (support all orientations/windowed mode), not ship-as-limitation | 2026-07-18 |
