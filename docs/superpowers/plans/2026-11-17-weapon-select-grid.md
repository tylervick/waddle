# Weapon-Select Grid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tapping the bottom centre of the game picture opens the predecessor's 3×3 weapon grid, and lifting a finger on an owned weapon switches to exactly that weapon.

**Architecture:** A small engine shim reports weapon state, takes an exact selection, and hands out sprite art. Two pure Swift types (geometry, open/pick state machine) carry all the rules and are unit-tested without a session. A UIKit view draws the cells; `TouchOverlayView` owns it and routes touches.

**Tech Stack:** C (Woof engine, `Engine/woof/src`), Swift/UIKit (`App/Sources/Touch`), XCTest, XcodeGen via `mise`.

**Spec:** `docs/superpowers/specs/2026-11-17-weapon-select-grid-design.md` — read it first; this plan argues from it.

## Global Constraints

- Branch `tylervick/weapon-select-grid`; work lands by pull request, never on `main`.
- Conventional commits (`feat(touch):`, `engine:` subject prefix for anything under `Engine/woof/`). No AI attribution lines in commits or the PR.
- Never edit or delete an existing test to make it pass. `weaponPrev` / `weaponNext` and every `TouchOverlayControl.allCases` test stay untouched; the hotspot is **not** a `TouchOverlayControl` case.
- Engine changes are minimal and each is recorded in `Engine/WOOF_UPSTREAM.md` in the same commit.
- No gesture recognizers in the overlay; responder-chain touches only.
- Every held input released at open gets its paired up/zero write.
- After adding any file: `mise run generate`. After any engine change: `mise run build-engine`.
- Never run two `xcodebuild` test sessions against one simulator at once.
- Unit test command (referred to below as **UNIT `<Class>`**):
  `xcodebuild -project App/Waddle.xcodeproj -scheme Waddle -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WaddleTests/<Class> test`
- Every new test is shown to discriminate: break the code it covers, see it fail, restore, see it pass.

## Review Focus

1. A finger already down when the grid opens (resting stick thumb, the hotspot finger) lifts over a cell → nothing is picked. (Task 3)
2. The level ends or the player dies while a finger is down on a cell → grid closes, the later lift selects nothing. (Task 3)
3. A second finger lands on another cell while one is already tracked → ignored; only the first tracked finger can pick. (Task 3)
4. A very small or letterboxed picture (iPadOS small window, half-open fold) → cells stay inside the picture, never overlap each other, and the hotspot stays inside the picture. (Task 2)
5. An owned weapon whose sprite is missing or undecodable → name-only cell that is still pickable. (Tasks 3 and 4)

---

### Task 1: Engine shim

**Files:**
- Modify: `Engine/woof/src/woof_ios.h`, `Engine/woof/src/woof_ios.c`
- Modify: `Engine/woof/src/g_game.c` (weapon block of `G_BuildTiccmd`, near the `WS_SlotSelected()` branch; and beside `G_ResetAutoUseSession`)
- Modify: `Engine/WOOF_UPSTREAM.md`

**Interfaces — Produces** (all main-thread-only, same contract as the existing touch calls):

```c
#define WOOF_IOS_NUM_WEAPONS 9   // wp_fist .. wp_supershotgun, engine order
typedef struct { bool owned; bool can_fire; } WoofIOS_WeaponSlot;

// false (out untouched) unless a live local player is in a level:
// gamestate == GS_LEVEL, !demoplayback, playerstate == PST_LIVE.
bool WoofIOS_GetWeaponSelectState(WoofIOS_WeaponSlot out[WOOF_IOS_NUM_WEAPONS]);
void WoofIOS_SelectWeapon(int weapon);     // 0..8; out of range is ignored
void WoofIOS_SelectBestWeapon(void);
// Bytes written, or 0 if there is no sprite or cap is too small.
int  WoofIOS_CopyWeaponSprite(int weapon, unsigned char *buf, int cap);
int  WoofIOS_CopyPlaypal(unsigned char *buf, int cap);   // first 768 bytes
```

`WoofIOS_DebugTouchWrites()` gains a ` ws:<n>` field: the number of select/select-best calls accepted this session, reset at session start with the other touch counters.

- [ ] **Step 1: Add the latch in `g_game.c`.** `void G_TouchSelectWeapon(int weapon)`, `void G_TouchSelectBestWeapon(void)`, `void G_ResetTouchWeaponSession(void)`; state is two statics (pending weapon, default `wp_nochange`; pending-best flag). In `G_BuildTiccmd`, add a branch **ahead of** the existing auto-switch `if`: pending-best → `newweapon = P_SwitchWeapon(&players[consoleplayer])`; else pending weapon → `newweapon` is that weapon; clear both. It must not pass through `AdjustWeaponSelection`, and must fall into the existing `if (newweapon != wp_nochange)` block so `BT_CHANGE` and `G_NextWeaponReset` happen as for any direct selection. Guard all of it with `#ifdef WOOF_IOS`.
- [ ] **Step 2: Implement the five calls and the counter in `woof_ios.c`,** declared in `woof_ios.h` with comments in the file's existing style.
  - `can_fire` mirrors `P_CheckAmmo`'s test for that weapon (ammo type and per-shot cost from `weaponinfo[]`), without its weapon-switch side effect. Read `P_CheckAmmo` first.
  - Sprite: `states[weaponinfo[n].readystate].sprite` → frame 0, rotation 0 → `firstspritelump + lump` → `V_CachePatchNum(…, PU_CACHE)`, so a PNG arrives converted. Byte length is found by walking the patch's column table to the furthest post terminator; a walk that would leave sane bounds returns 0.
  - Call `G_ResetTouchWeaponSession()` and zero the counter where `touch_key_writes` is reset at session start.
- [ ] **Step 3: Record the patch in `Engine/WOOF_UPSTREAM.md`** under the current patch list: which files, what each hook does, why key injection was not enough (`AdjustWeaponSelection` toggles fist/chainsaw and shotgun/SSG).
- [ ] **Step 4: Verify.** Run `mise run build-engine`. Expected: builds with no new warnings in the touched files. Then `Scripts/check-engine-fresh.sh`. Expected: passes.
- [ ] **Step 5: Commit.** `engine: weapon-select shim for the touch overlay`

---

### Task 2: Grid geometry

**Files:**
- Create: `App/Sources/Touch/WeaponSelectGeometry.swift`
- Test: `App/Tests/WeaponSelectGeometryTests.swift`

**Interfaces — Produces:**

```swift
struct WeaponSelectGeometry: Equatable {
    static let cellCount = 9
    init(pictureRect: CGRect)
    let hotspot: CGRect
    func cellFrame(_ index: Int) -> CGRect      // index 0..<9
    func cell(at point: CGPoint) -> Int?        // nil in gaps and outside
}
```

Values, as fractions of the picture rect `P`: hotspot is `P.width/6` wide, `P.height/4` tall, centred on `P.midX`, bottom on `P.maxY`. Cell *i* (column `i % 3`, row `i / 3`): x = `P.minX + (col*160 + 20)/480 * P.width`, y = `P.minY + row*88/320 * P.height`, size `120/480 * P.width` × `80/320 * P.height`.

- [ ] **Step 1: Write the failing tests** (accuracy 0.01):

```swift
func testReferencePicture() {
    let g = WeaponSelectGeometry(pictureRect: CGRect(x: 0, y: 0, width: 480, height: 320))
    assertRect(g.cellFrame(0), 20, 0, 120, 80)
    assertRect(g.cellFrame(4), 180, 88, 120, 80)
    assertRect(g.cellFrame(8), 340, 176, 120, 80)
    assertRect(g.hotspot, 200, 240, 80, 80)
}
func testLetterboxedPictureIsOffsetAndScaled() {
    let g = WeaponSelectGeometry(pictureRect: CGRect(x: 0, y: 100, width: 400, height: 250))
    assertRect(g.cellFrame(8), 283.33, 237.5, 100, 62.5)
    assertRect(g.hotspot, 166.67, 287.5, 66.67, 62.5)
}
func testPointToCell() {
    let g = WeaponSelectGeometry(pictureRect: CGRect(x: 0, y: 0, width: 480, height: 320))
    XCTAssertEqual(g.cell(at: CGPoint(x: 80, y: 40)), 0)
    XCTAssertEqual(g.cell(at: CGPoint(x: 240, y: 200)), 7)
    XCTAssertNil(g.cell(at: CGPoint(x: 150, y: 40)))   // column gap
    XCTAssertNil(g.cell(at: CGPoint(x: 80, y: 84)))    // row gap
    XCTAssertNil(g.cell(at: CGPoint(x: 240, y: 300)))  // status bar
}
func testSmallAndOddPicturesStayInsideAndDisjoint() {
    // Review Focus 4. For each of: (0,0,160,100), (37,12,402,251), (0,0,1366,854):
    // every cellFrame and the hotspot lie inside the picture rect, and no two
    // cell frames intersect.
}
```

- [ ] **Step 2:** `mise run generate`, then UNIT `WeaponSelectGeometryTests`. Expected: FAIL to compile (type missing).
- [ ] **Step 3: Implement `WeaponSelectGeometry`.**
- [ ] **Step 4:** UNIT `WeaponSelectGeometryTests`. Expected: PASS. Show discrimination by changing the 88 row pitch, then restore.
- [ ] **Step 5: Commit.** `feat(touch): geometry for the weapon-select grid`

---

### Task 3: Open/pick state machine

**Files:**
- Create: `App/Sources/Touch/WeaponSelectModel.swift`
- Test: `App/Tests/WeaponSelectModelTests.swift`

**Interfaces — Produces:**

```swift
struct WeaponSlotState: Equatable { var owned: Bool; var canFire: Bool }

enum WeaponCellAppearance: Equatable { case unowned, ready, empty, pressed }

struct WeaponSelectModel {
    static let names = ["fist", "pistol", "shotgun", "chaingun", "rockets",
                        "plasma", "BFG", "chainsaw", "dblshotgun"]
    enum Effect: Equatable { case releaseHeldInputs, select(Int), selectBest }

    private(set) var isOpen: Bool                 // starts false
    var slots: [WeaponSlotState]                  // 9 entries, starts all unowned

    /// A touch that began inside the hotspot. Closed + canOpen → opens,
    /// [.releaseHeldInputs]. Open → closes, [.selectBest]. Otherwise [].
    mutating func hotspotTouchBegan(canOpen: Bool) -> [Effect]
    /// Any other touch that began while open; `cell` is where it landed.
    mutating func touchBegan(_ id: AnyHashable, cell: Int?)
    mutating func touchMoved(_ id: AnyHashable, cell: Int?)
    mutating func touchEnded(_ id: AnyHashable, cell: Int?) -> [Effect]
    mutating func touchCancelled(_ id: AnyHashable)
    /// Polled: the engine's "grid may be open" answer. false closes and forgets.
    mutating func availabilityChanged(canOpen: Bool)

    func isSelectable(_ index: Int) -> Bool       // owned, nothing else
    func appearance(_ index: Int) -> WeaponCellAppearance
}
```

Rules the signatures leave open: at most one touch is tracked — the first that begins inside any cell after opening. Only the tracked touch can pick; it picks the cell it **lifts** in, if that cell is selectable (it may differ from where it began). `appearance` is `.pressed` only for a selectable cell the tracked touch is currently over; otherwise `.unowned` / `.empty` (owned, cannot fire) / `.ready`. A caller checks the hotspot before cells for began-touches (they overlap under cell 7).

- [ ] **Step 1: Write the failing tests.** One test per line; each asserts the returned effects and `isOpen`:
  - `testOpensAndReleasesHeldInputs` — closed, `hotspotTouchBegan(canOpen: true)` → `[.releaseHeldInputs]`, open.
  - `testDoesNotOpenWhenUnavailable` — `canOpen: false` → `[]`, closed.
  - `testReTapClosesAndSelectsBest` — open, hotspot again → `[.selectBest]`, closed.
  - `testLiftInOwnedCellSelectsAndCloses` — slot 4 owned; began 4, ended 4 → `[.select(4)]`, closed.
  - `testLiftPicksTheCellItLiftsIn` — 1 and 4 owned; began 1, moved 4, ended 4 → `[.select(4)]`.
  - `testLiftInUnownedCellOrGapKeepsGridOpen` — began 4, ended in cell 2 (unowned) → `[]`, open; same for `cell: nil`.
  - `testOutOfAmmoWeaponIsStillSelectable` — owned, `canFire: false` → selectable, appearance `.empty`, lift selects.
  - `testTouchThatNeverBeganCannotPick` (Review Focus 1) — open; `touchEnded("stick", cell: 6)` with slot 6 owned and no `touchBegan` for that id → `[]`, open.
  - `testSecondFingerIsIgnored` (Review Focus 3) — began "a" in 1, began "b" in 4, ended "b" in 4 → `[]`, open; ended "a" in 1 → `[.select(1)]`.
  - `testForcedCloseForgetsTheFinger` (Review Focus 2) — began "a" in 1, `availabilityChanged(canOpen: false)` → closed; ended "a" in 1 → `[]`.
  - `testCancelledTouchPicksNothing` — began, cancelled, ended → `[]`, open.
  - `testAppearanceTable` — unowned → `.unowned`; owned+canFire → `.ready`; owned+!canFire → `.empty`; tracked touch over owned → `.pressed`; tracked touch over unowned stays `.unowned`.
  - `testSelectabilityIgnoresArt` (Review Focus 5) — the model has no sprite input; an owned slot is selectable. (Pins that nobody adds one.)
- [ ] **Step 2:** `mise run generate`, UNIT `WeaponSelectModelTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement `WeaponSelectModel`.**
- [ ] **Step 4:** UNIT `WeaponSelectModelTests`. Expected: PASS. Show discrimination by letting an untracked touch pick, then restore.
- [ ] **Step 5: Commit.** `feat(touch): open and pick rules for the weapon-select grid`

---

### Task 4: Sprites and the grid view

**Files:**
- Modify: `App/Sources/WAD/DoomGraphics.swift` (add `Bitmap.silhouette()`)
- Modify: `App/Sources/Touch/TouchGamepad.swift` (thin wrappers over Task 1)
- Create: `App/Sources/Touch/WeaponSelectView.swift`
- Test: `App/Tests/DoomGraphicsTests.swift` (add cases), `App/Tests/WeaponSelectViewTests.swift`

**Interfaces:**
- Consumes: Task 1 C calls; `WeaponSelectGeometry`; `WeaponSelectModel`, `WeaponCellAppearance`.
- Produces:

```swift
extension DoomGraphics.Bitmap {
    /// Same alpha, every colour channel zero: the "not owned" sprite.
    func silhouette() -> DoomGraphics.Bitmap
}

extension TouchGamepad {
    func weaponSlots() -> [WeaponSlotState]?           // nil when the engine says false
    func selectWeapon(_ index: Int)
    func selectBestWeapon()
    func weaponSprites() -> [DoomGraphics.Bitmap?]     // 9 entries; nil where none decodes
}

final class WeaponSelectView: UIView {
    /// Cell subviews carry accessibilityIdentifier "weaponCell0"…"weaponCell8",
    /// accessibilityLabel = name, value = "not owned" / "ready" / "out of ammo".
    /// isUserInteractionEnabled is false on the view and its cells: the overlay
    /// owns the touches.
    func update(geometry: WeaponSelectGeometry, model: WeaponSelectModel,
                sprites: [DoomGraphics.Bitmap?])
    func cellFrameForTesting(_ index: Int) -> CGRect
}
```

Drawing, per the spec's table: a dark panel per cell (dark grey unowned, full/white-tinted ready, red empty, mid grey pressed), name centred near the top (half opacity for unowned and empty), sprite bottom-centre pinned at 1.25× native size scaled by `pictureRect.width / 480` (the predecessor's virtual width, so a sprite keeps its old proportion to the cell), nearest-neighbour (`magnificationFilter = .nearest`), silhouette when unowned. No blur, no system materials. Colours and font are the builder's, inside "looks like the game".

- [ ] **Step 1: Write the failing tests.**

```swift
// DoomGraphicsTests
func testSilhouetteKeepsAlphaAndBlacksColour() {
    let b = DoomGraphics.Bitmap(width: 2, height: 1, rgba: [10, 20, 30, 255, 40, 50, 60, 0])
    XCTAssertEqual(b.silhouette().rgba, [0, 0, 0, 255, 0, 0, 0, 0])
}
// WeaponSelectViewTests
func testCellsFollowGeometry()        // after update(), cellFrameForTesting(i) == geometry.cellFrame(i) for all 9
func testNilSpriteCellStillRenders()  // Review Focus 5: sprites all nil → 9 cells, each label == WeaponSelectModel.names[i]
func testAccessibilityValueFollowsState() // unowned / ready / empty → the three strings above
```

- [ ] **Step 2:** `mise run generate`, UNIT `WeaponSelectViewTests` and UNIT `DoomGraphicsTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement** `silhouette()`, the four `TouchGamepad` wrappers (sprite copy uses a 64 KB buffer per weapon and `DoomGraphics.palette` / `decodePicture`), and `WeaponSelectView`.
- [ ] **Step 4:** Run both test classes. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(touch): draw the weapon-select grid`

---

### Task 5: Wire it into the overlay

**Files:**
- Modify: `App/Sources/Touch/TouchOverlayView.swift` (`touchesBegan`, `touchesMoved`, `endTouches`, `layoutSubviews`, `startMenuPolicyTimer`, and `OverlayButton`)
- Modify: `App/UITests/TouchControlsTests.swift` (add one test; change none)
- Modify: `docs/manual-testing.md`

**Interfaces — Consumes:** everything from Tasks 1–4.

Decisions:
- The overlay holds a `WeaponSelectModel`, a `WeaponSelectView` (hidden while closed), lazily loaded sprites (once per session, on first open), and a clear, non-interactive subview with `accessibilityIdentifier = "weaponSelectHotspot"`, label "Weapons", framed to `geometry.hotspot`.
- Geometry is rebuilt in `layoutSubviews` from `enginePictureRect`, falling back to the same predicted rect the layout uses.
- `canOpen` = `gamepad.weaponSlots() != nil` and no menu, no prompt, no automap, not attract mode, soft keyboard not active.
- In `touchesBegan`, after the keyboard guard and before menu routing: a touch inside the hotspot goes to `hotspotTouchBegan(canOpen:)` when the grid is open or `canOpen` is true, and is consumed. When neither holds it falls through to today's routing unchanged (the hotspot is inert). While open, every other began-touch goes to `model.touchBegan` and is consumed.
- `.releaseHeldInputs` → `releaseStick()`, `releaseTurn()`, `gamepad.setFireTrigger(down: false)`, drop automap/menu/pending touches as their existing "closed under a finger" paths do, and for each `OverlayButton` a new `forceRelease()` that sends its up immediately (cancelling any delayed release). Buttons have `isUserInteractionEnabled = false` while the grid is open and get it back on close.
- `.select(n)` → `gamepad.selectWeapon(n)`; `.selectBest` → `gamepad.selectBestWeapon()`.
- The policy timer, each tick: refresh `model.slots` while open, and call `availabilityChanged(canOpen:)`.

- [ ] **Step 1: Write the UI test** `testWeaponGridPicksAnOwnedWeapon` in `TouchControlsTests`, following `testAutomapDragPansAndPinchZooms` for launch environment and readout: start Freedoom with `WADDLE_TEST_WARP`, wait for `fireButton`, tap `weaponSelectHotspot`, assert `weaponCell0` exists, tap `weaponCell2` (shotgun, not owned at start) and assert `weaponCell0` still exists, tap `weaponCell0`, assert `weaponCell0` no longer exists; after the session assert `writeFields(...)["ws"] == 1`.
- [ ] **Step 2: Implement the wiring above.**
- [ ] **Step 3: Run the unit suite.** `xcodebuild … -only-testing:WaddleTests test` (iPhone 17 Pro). Expected: PASS, including every pre-existing touch test unmodified.
- [ ] **Step 4: Run the UI test.** First take the `main` baseline per `docs/learnings/ui-test-failures-need-a-main-baseline.md`, then `-only-testing:WaddleUITests/TouchControlsTests/testWeaponGridPicksAnOwnedWeapon`. Expected: PASS. Show discrimination by skipping the `selectWeapon` call, then restore.
- [ ] **Step 5: Add manual steps to `docs/manual-testing.md`** under the touch section: open with a stick thumb held and relax it over the bottom row (nothing picked, player stops); pick each owned weapon; red cell at zero ammo is still pickable; re-tap closes and switches to the best weapon; grid closes on ≡, MAP and death; rotate with the grid open (cells follow the picture); a PWAD with replaced weapon sprites shows its own art; at a vanilla compatibility level "shotgun" may give the super shotgun (expected).
- [ ] **Step 6: Commit.** `feat(touch): open the weapon-select grid from the status bar`
- [ ] **Step 7: Push and open the pull request**, then dispatch `gh workflow run ui-tests.yml --ref tylervick/weapon-select-grid` and link the run in the PR.
