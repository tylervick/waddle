# App Store metadata — WADdle

**Status: APPROVED at the Plan 4 Task 7 user gate (2026-07-18).**
Decisions recorded in the log at the bottom.

---

## 1. App name (30 chars max) — DECIDED

**Final name: "WADdle"** (chosen 2026-07-20, superseding the earlier
"BoomBox: WAD Player" pick). "WADdle" hides **WAD** — the Doom file format
the app plays — inside *waddle*, in the whimsical spirit of the source-port
lineage it belongs to (its engine is **Woof!**, alongside *Crispy Doom* and
*Chocolate Doom*). No descriptor is needed in the name; the subtitle carries
the plain description.

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

> Freedoom out of the box — or import your own WADs. A faithful
> Boom/MBF21 source port with touch controls, game controllers, and
> keyboard support. *(151 chars)*

## 4. Description

> **Play the classic-Doom-engine games you own, anywhere.**
>
> WADdle is a source port of the classic Doom engine for iPhone and iPad,
> built on Woof! — the modern continuation of the Boom and MBF ports that
> faithfully preserves original gameplay while supporting today's mods, up
> through the MBF21 standard.
>
> **Ready to play out of the box.** WADdle bundles Freedoom Phase 1 and
> Phase 2: two complete, freely licensed games built by the Freedoom
> project for this engine family. Tap and play — nothing to configure.
>
> **Bring your own WADs.** Import WAD files you own from the Files app,
> iCloud Drive, or the share sheet — commercial IWADs you've purchased, or
> any of thousands of community-made maps and megawads. Zip archives and
> DeHackEd patches are supported.
>
> **Loadouts.** Combine a base game with mods and patches, set the load
> order and compatibility level (vanilla, Boom, MBF, MBF21 — or auto), and
> save the combination as a one-tap loadout. Saves are kept per loadout.
>
> **Play your way.** Touch controls with two schemes (classic twin-stick
> and modern drag-to-turn) and adjustable feel — plus full support for
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

- **Support URL:** https://github.com/tylervick/waddle
  ⚠️ Repo is currently **private** — must flip public before submission
  (also a GPL-compliance requirement; already a Plan 4 ledger item).
- **Marketing URL (optional):** same repo, or none.
- **Privacy Policy URL:** `PRIVACY.md` at the repo root (decided
  2026-07-18). Once the repo is public the URL is
  https://github.com/tylervick/waddle/blob/main/PRIVACY.md. The app
  collects nothing (see `App/PrivacyInfo.xcprivacy`); the policy says so
  in plain language.

## 7. Category

- **Primary:** Games → Action
- **Secondary:** none (optional; Games → Adventure would fit if desired)

## 8. Age-rating questionnaire

Answers to document into App Store Connect (each row is the questionnaire
prompt → answer):

| Questionnaire item | Answer | Rationale |
|---|---|---|
| Cartoon or Fantasy Violence | **Frequent/Intense** | Core gameplay: shooting fantasy monsters (Freedoom's demons-replacement bestiary), pixelated gibs |
| Realistic Violence | **Infrequent/Mild** | Low-res 1993-era sprites; combat is against fantasy creatures, but weapons are gun-shaped |
| Prolonged Graphic or Sadistic Realistic Violence | None | — |
| Profanity or Crude Humor | None | Freedoom content contains none |
| Mature/Suggestive Themes | None | — |
| Horror/Fear Themes | None | Monster combat is covered by fantasy violence; no horror framing in Freedoom |
| Medical/Treatment Information | None | — |
| Alcohol, Tobacco, or Drug Use or References | None | — |
| Simulated Gambling | None | — |
| Sexual Content or Nudity | None | — |
| Unrestricted Web Access | No | App makes no network requests at all |
| Gambling and Contests | No | — |
| User-Generated Content | No | Imported WADs are local files chosen by the user; nothing is shared or hosted |

**Expected resulting rating:** 12+ under the classic questionnaire;
under the revised (2025) age-rating tiers (4+/9+/13+/16+/18+),
Frequent/Intense Cartoon or Fantasy Violence is expected to land at
**13+**. If the questionnaire resolves higher (16+/17+), accept it —
comparable ports (GenZD) ship at 17+ without issue. Note: users importing
their own commercial WADs does not change the rating (same policy position
as GenZD/RetroArch: rate the shipped content).

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
> lineage). It includes ONLY the freely-licensed Freedoom game data —
> no copyrighted commercial game content is bundled. Users may import WAD
> files they own via the Files app; these stay on device. The app makes no
> network requests. Comparable approved apps: GenZD, RetroArch.
>
> On iPad the app supports all orientations and windowed multitasking.
>
> To demo: no account or setup needed — tap the "Freedoom Phase 1" tile on
> the Play tab.

## 12. Screenshots

Captured by `Scripts/capture-screenshots.sh` into
`docs/app-store/screenshots/<device>/` (see the script header for how).

| Slot | Shot | File |
|------|------|------|
| 1 | In-game (Freedoom, touch overlay) | `05-ingame.png` |
| 2 | Loadout grid (Play tab) | `01-loadout-grid.png` |
| 3 | WAD library | `02-library.png` |
| 4 | Loadout editor | `03-loadout-editor.png` |
| 5 | Automap | `06-automap.png` |
| 6 | Control Feel sheet | `04-control-feel.png` |

Device classes:

- **iPhone 6.9" (required):** iPhone 17 Pro Max simulator — 2868×1320
  landscape.
- **iPad 13" (required for iPad):** iPad Pro 13-inch (M4) simulator —
  2752×2064 landscape. (The pre-existing "iPad (A16)" simulator is
  11-inch class and cannot produce 13-inch-class images, so the script
  creates the 13-inch device on demand.)

**iPadOS 26 windowing (resolved — fix landed, Plan 4 Task 7b):** the
owner decided at the gate to fix windowed-mode support rather than ship it
as a limitation. The app now supports portrait + both landscapes on
iPhone and all four orientations on iPad (`UIRequiresFullScreen`
removed), and in iPadOS 26's default Windowed Apps mode it opens upright
and playable in a resizable window; mid-session rotation and live window
resizing re-letterbox the game without crashing (verified on iPhone and
iPad simulators — the engine-side half of the fix is an
`SDL_HINT_ORIENTATIONS` hint in `woof_ios.c`, without which SDL locked
sessions to landscape). The App Review notes state this support.
Screenshots were captured in Full Screen Apps mode and remain valid.

Technical background (kept for the record): at capture time, iPadOS 26's
default "Windowed Apps" multitasking style rendered the then
landscape-only + `UIRequiresFullScreen` app sideways in a letterboxed
portrait window; the capture script switched the simulator to Settings →
"Full Screen Apps" to photograph it. Xcode also emitted the runtime
warning "`UIRequiresFullScreen` will soon be ignored; support for all
orientations will soon be required," which motivated fixing this
properly. With the fix landed, re-running
`Scripts/capture-screenshots.sh` should work without the Settings
workaround (its temp test tolerates either mode). Note the Task 7b
verification left the iPad Pro 13-inch simulator back in the default
Windowed Apps mode.

## 13. Decisions log (filled at the user gate)

| Decision | Choice | Date |
|----------|--------|------|
| Final app name | ~~BoomBox: WAD Player~~ → **WADdle** (superseded) | 2026-07-18 → 2026-07-20 |
| Subtitle wording | Approved as drafted ("Play classic Doom WADs") | 2026-07-18 |
| Description tone | Approved as drafted (incl. promotional text and keywords) | 2026-07-18 |
| Age-rating answers confirmed | Approved as drafted (§8 table) | 2026-07-18 |
| Export compliance answers | Approved as drafted (§9) | 2026-07-18 |
| Privacy policy URL approach | `PRIVACY.md` in repo root (GitHub URL once public) | 2026-07-18 |
| iPadOS windowing | Fix before shipping (support all orientations/windowed mode), not ship-as-limitation | 2026-07-18 |
