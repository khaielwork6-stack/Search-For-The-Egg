# Search for the Egg - UI Asset Specification (redesign brief)

Purpose: a complete, redraw-ready list of every UI surface the game shows, so an artist or Codex can
produce PNG art for all of it and a developer can wire it in without guessing. Every number below is
taken from the live client code (`src/client/UI`, `src/client/Controllers`, `src/shared/Design/Tokens.luau`)
and the server world builders (`src/server/Services/WorldShellService.luau`, `ChapterShellService.luau`).

Today the entire UI is drawn from tokens (rounded frames, strokes, gradients, text). The only PNGs in the
project are three station-button faces. This document therefore specifies the PNGs that would *replace*
the token drawing, and what must stay live Roblox text so it can still change at runtime.

---

## 0. Rules that apply to every asset

### 0.1 Sizes, scale, and export

- All sizes are **logical pixels at desktop scale (UIScale 1.0)**. The game applies one `UIScale` per
  ScreenGui: **desktop 1.00, tablet 0.94, phone 0.86**. Art is never stretched by the game; it is scaled
  uniformly by these factors, so export every PNG at **2x logical size** (retina) and let Roblox scale down.
- **Maximum upload size is 1024 x 1024 px.** Anything larger must be split or exported at 1x.
- Layout class is decided by the shorter viewport edge: phone under 480 px, tablet under 1100 px with an
  aspect narrower than 1.6, otherwise desktop. Phone and tablet get the *same layout* as desktop, only
  scaled. There is no separate mobile layout to design.
- **Minimum tap target is 44 real pixels.** Because of the scale factors the pre-scale target is 44 desktop,
  47 tablet, 52 phone. Every button already gets a `UISizeConstraint` enforcing this; art must not rely on
  a smaller hit area than the frame it sits in.
- Safe area: every ScreenGui uses `CoreUISafeInsets`; the edge padding is **12 px** on all sides. Nothing
  interactive may sit in the outer 12 px.

### 0.2 Frames are 9-slice, text stays live

- Any background that has to fit variable text (chips, buttons, rows, cards, pills, toasts) must be a
  **9-slice PNG** with a transparent or flat centre. Give the slice rectangle (`SliceCenter`) with every
  such asset. Roblox needs the four slice edges as pixel coordinates of the PNG.
- **All text in the tables below stays a Roblox TextLabel** unless a row says "baked". Reason: the strings
  change at runtime (counts, names, timers, translations later). Bake text only into world signage that
  never changes and station icons.
- Fonts in use: `FredokaOne` (display/title/label/pill), `GothamBold` (headings/buttons), `GothamMedium`
  (body), `Gotham` (captions), `GothamBlack` (numerals). Sizes: display 34, title 24, label 18, heading 18,
  body 15, caption 13, numeral 20. A redesign may change fonts, but Roblox can only render its bundled
  fonts or uploaded `FontFace` assets; supply a font asset if the redraw uses a custom face.
- Transparent areas: state explicitly in each asset whether the centre is transparent (a hole the live
  text/content shows through) or opaque.

### 0.3 Palette (RGB)

Base: outline 38,26,16 - inkStrong 46,36,28 - inkMuted 139,121,103 - cream 252,246,234 -
creamDeep 241,229,206 - creamPill 255,241,200 - surface 255,252,245 - surfaceAlt 247,238,222.
Gold bevel: goldLight 255,220,92 - gold 246,182,40 - goldDeep 184,118,22 - straw 226,191,108 -
strawDeep 190,145,62. Teal panel: tealLight 38,118,134 - tealPanel 20,78,92 - tealDeep 11,50,62.
Accents: sky 129,190,220 - skyDeep 70,136,176 - leafBright 128,200,70 - leaf 116,170,92 -
leafDeep 74,128,60 - ember 228,117,70 - emberDeep 184,78,42 - gem 122,96,220 - gemDeep 86,62,176 -
success 88,160,84 - warning 214,150,40 - danger 196,74,62 - overlay 20,14,10.
Rarity (class cards): common 96,178,236 / 40,110,176 - uncommon 128,200,70 / 64,128,44 -
rare 255,208,48 / 196,132,12 - epic 176,88,236 / 104,40,160 - legendary 255,120,60 / 176,56,20.

The redesign may replace the palette; keep the *roles* (a bevelled frame, a dark panel, a light pill,
one hot accent, one success, one warning, one danger, five rarities).

### 0.4 Controller and focus

- Every focusable control shows a **focus ring**: today a 4 px goldLight stroke plus a 1.05 scale.
  Supply a ring/glow variant for every button, chip, card, tab, and text box, or a single overlay PNG
  that can be drawn on top of any of them.
- Gamepad navigation is spatial (no hand-wired next-selection). Keep rows and grid cells rectangular and
  aligned so D-pad movement stays predictable.
- Input prompt glyphs shown in the HUD prompt chip: mouse `LMB` / `E`, touch `Tap`, gamepad `RT` / `X` /
  `B` / `Y`. If the redesign uses icon glyphs instead of letters, supply them (see asset H7).

### 0.5 What stays editable in Roblox (global)

Positions, sizes, visibility per phase, all text, colours of live text, the bag fill fraction, meter
fractions, count-up animations, and toast queueing all remain code-driven. Art only supplies the images.
Each asset gets a **role name**; the developer adds it to `src/shared/Design/AssetManifest.luau` and the
components read `AssetManifest.image(role)`.

---

## 1. Screen layout map (where things sit, per phase)

```
+------------------------------------------------------------------+ 12 px safe pad all round
| [Gems chip][Tokens chip]      [Objective banner]     [Settings]  |  top row, 44 px tall
|                               [  detail line     ]                |
|                              [Toasts, max 3, 440 wide]            |  y = 93
|                                                                   |
|                                  (reticle 6 px)                   |  centre, Searching only
|                                                                   |
|                              [Carried stack 220x120]              |  bottom-centre, above hotbar
|                    [Hotbar: 5 slots 96x56, 8 px gap]              |  y = bottom - 68
|                 [Timer 130][Bag 190][Cash 130] (44 tall)          |  y = bottom - 12
|  (lobby only: [8 station buttons 64x64] replace the round strip)  |
|                                              [Prompt chip 13 pt]  |  bottom-right
+------------------------------------------------------------------+
```

Phase visibility: currency chips, banner, prompt chip, settings and toasts are always present. Round strip:
Cutscene through Results. Hotbar: Cutscene, Countdown, Searching, EggRevealed. Reticle and carried stack:
Searching and EggRevealed only. Station rail: lobby only. Cutscene overlay: Cutscene only. Victory
announcement: 2.5 s at Victory. Results modal: Results. Any blocking modal dims the screen (overlay at
45 %) and blurs the world (size 14).

On phone the bottom band is crowded: hotbar (56 tall) + round strip (44 tall) + carried stack (84 tall)
stack within about 200 px above the bottom edge, and Roblox's own touch jump button sits bottom-right,
the thumbstick bottom-left. Keep all bottom-centre art inside the middle 60 % of the width.

---

## 2. Asset list

Column key: **PNG** = export size at 2x (logical size in brackets). **Slice** = 9-slice centre rectangle in
PNG pixels (left, top, right, bottom). **Hole** = transparent region. **Text** = strings, live unless
"baked". **States** = variants to deliver. **Editable** = what code keeps changing.

### A. HUD chips and strip

| Id | Asset | PNG | Slice / Hole | Text (live) | States | Editable in Roblox |
|---|---|---|---|---|---|---|
| H1 | Currency chip background (Gems, Tokens) | 176 x 88 (88 x 44), height fixed, width stretches | 9-slice, slice 40,40,136,48; centre transparent so the chip can tint | `Gems  0`, `Tokens  0` | normal; pop (same art, code scales 1.12 then settles) | text, width (AutomaticSize X), count-up, punch rotation |
| H2 | Gem icon | 64 x 64 (32 x 32) | full alpha, no slice | none | single | placed left of the Gems text at 32 px; new ImageLabel |
| H3 | Token icon | 64 x 64 (32 x 32) | full alpha | none | single | placed left of the Tokens text |
| H4 | Objective banner background | 480 x 130 (240 x 65), width stretches | 9-slice, slice 60,40,420,90; transparent centre | title line (heading 18) + detail line (caption 13); see list below | normal; countdown (`Get ready... 3`) uses the same art | both text lines, width |
| H5 | Round strip chip: Timer | 260 x 88 (130 x 44) fixed | 9-slice optional; transparent centre | `00:00.00` | single | text |
| H6 | Round strip chip: Bag (track + fill) | track 380 x 88 (190 x 44); fill 380 x 88 separate PNG | track: 9-slice 40,40,340,48, transparent centre; fill: opaque left-anchored pill, code scales its X width from 0 to 100 % | `Bag 0 / 25`, `Bag 12 / 50`, `Bag 40 / Infinite` (denominators 25, 50, 100, 200, 400, Infinite) | fill normal (straw); fill full (ember); infinite (fill 100 %) | fill fraction, squash on award (1.05 / 1.12 scale), text |
| H7 | Round strip chip: Cash | 260 x 88 (130 x 44) | as H5 | `$0.00`, `$7.20`, `-$1.00` | single | text, count-up |
| H8 | Input prompt chip | 176 x 88, width stretches | as H1 | `LMB  Gather   E  Interact` / `Tap  Gather   Tap  Interact` / `RT  Gather   X  Interact`; optional glyph icons LMB, E, RT, X, B, Y, Tap at 26 x 26 each (H8a-g) | mouse, touch, gamepad | text swaps live on input mode |
| H9 | Settings button | uses B2 (secondary button) at 160 x 44; optional gear icon 40 x 40 (H9a) | see B2 | `Settings` | see B2 | text |
| H10 | Reticle | 24 x 24 (12 x 12) | full alpha, centred dot or ring | none | idle; optional "target locked" variant (H10b) when a feather is under the crosshair | swap between H10 and H10b, colour tint |

Objective banner strings (title / detail): `Step onto the henhouse path` / `Walk to the glowing doorway and
press Interact`; `Gather 25 feathers` / `Click or tap the nest to pull feathers into your bag`; `Sell your
bag` / `Carry your feathers to the trading crate`; `Buy your first upgrade` / `Visit the workbench and
improve your grasp or bag`; `Search the nest for the Egg` / `Keep clearing. Any patch could hide it`;
`Claim the Egg!` / `Hold Interact on the Egg before anyone else`; `Round complete` / `Securing rewards...`;
`Ready for another search` / `Enter the henhouse doorway when you like`; `Sunlit Henhouse` / `Story`;
`Get ready... N` / `The nest opens in a moment`; boot: `Loading your nest...`.

### B. Buttons (shared component, six variants)

Every button is one 9-slice PNG per variant per state. Logical default 160 x 44; buttons in modals go
from 60 x 44 (class-card Equip) to full width x 44, so the slice must stretch horizontally and (for two-line
destination cards) vertically.

| Id | Variant | Used for | PNG | Slice / Hole | States (deliver each) |
|---|---|---|---|---|---|
| B1 | primary (ember) | Done in Settings, Search again, Workbench Buy | 320 x 88 (160 x 44) | slice 44,40,276,48; transparent centre | normal, hover (1.05 handled by code), pressed, disabled (35 % washed), focus ring |
| B2 | secondary (straw) | Settings, Open a party, Auto roll, Back to the lobby, Workbench Done | same | same | same |
| B3 | ghost (teal) | Settings toggles, Leave party, destination cards, Sealed chest, Skip story | same | same | same, plus "selected" (gold fill) for destination cards |
| B4 | gold (bevel) | Set off alone, Start, Join, Roll, Claim, Redeem, perk Buy | same | same | same |
| B5 | pill (cream) | slot chips, tabs, class Equip, inventory Equip, station fallback | 320 x 88 fully rounded ends | slice 44,40,276,48 | normal, selected (gold), disabled, focus ring |
| B6 | danger (red) | Cancel countdown | same | same | normal, pressed, disabled, focus ring |
| B7 | Close "X" button | every modal | 88 x 88 (44 x 44) round | full alpha, no slice | normal, pressed, focus ring | glyph may be baked; keep a TextLabel fallback |
| B8 | Ripple | press feedback overlay | 128 x 128 soft white disc | full alpha | single | code scales 0.2 to 2.4 and fades |

Button labels (all live text): `Settings`, `Done`, `Search again`, `Back to the lobby`, `Skip story`,
`Set off alone`, `Open a party`, `Start`, `Cancel countdown`, `Leave party`, `Join`, `Roll  -  40 Gems`,
`Rolling...`, `Auto roll: off`, `Auto roll: on (tap to stop)`, `Equip`, `Equipped`, `Claim 50 Gems`,
`Come back soon`, `Opening...`, `Redeem`, `Sealed for now`, `Buy $0.25`, `Buy 40 Gems`, `120 Gems`,
`Reduced motion: On/Off`, `Camera shake: On/Off`, `Haptics: On/Off`, `Quality: auto/low/medium/high`, `...`.

### C. Modal chrome (shared by all eleven modals)

| Id | Asset | PNG | Slice / Hole | Text | States | Editable |
|---|---|---|---|---|---|---|
| C1 | Card frame (gold bevel + teal panel in one) | 1024 x 1024 max; design at 560 x 500 (2x = 1120, so export 1x 560 x 500 or 2x at 1024 cap) | 9-slice with 8 px bevel + 12 px inner padding: slice 44,44,516,456 at 1x; centre **opaque teal** (content draws on it) | none | standard; wide (same slice stretches to 820 wide) | size: 92 % x 90 % of viewport capped 560 x 900 (wide 820), open/close scale animation |
| C2 | Leaf accents (pair) | 52 x 28 each (26 x 14) | full alpha | none | left (rotated -28) and right (+28); may be baked into C1 corners instead | position |
| C3 | Title pill | 9-slice 320 x 88 as B5 | transparent centre | modal titles: `Sunlit Henhouse`, `Daily Nest`, `Class Cards`, `Perk Bench`, `Tool Rack`, `Forager Ledger`, `Nest Mailbox`, `Moonlit Chest`, `Workbench`, `Settings`, `Round complete` | single | text, width = card width minus 52 |
| C4 | Scrollbar thumb and track | thumb 12 x 48, track 12 x 48 | 9-slice vertical | none | single | height by content |
| C5 | Row card (list rows) | 9-slice 320 x 88 (160 x 44), used at heights 38, 44, 52, 100 | slice 24,20,296,68; semi-transparent centre | row text | normal (35 % teal), muted (70 %, for "Open seat" and unowned skins), focus | height, transparency |
| C6 | Meter (track + fill) | track 200 x 20 (100 x 10); fill 200 x 20 | 9-slice horizontal | none | fill gold; fill green (maxed) | fill fraction |
| C7 | Text box | 9-slice 320 x 88 as B5 | transparent centre | placeholder `Enter a code` | idle, focused (ring), error | text |
| C8 | Grid cell (daily calendar) | 240 x 120 (120 x 60) | 9-slice 24,24,216,96; transparent centre | `Day 3`, `Day 2  -  done`, `120 Gems` | claimed (green), current (gold ring 4 px), future (dark) | text, pop scale on claim |
| C9 | Class card | 2x 560 x 200 (280 x 100) | 9-slice 32,32,528,168; centre transparent over rarity fill | name pill, `40.0% chance`, `Bag x1.5`, `Steady and dependable` | five rarities x {locked, owned, equipped (gold ring)}, plus "rolling highlight" (1.04 scale, code) | all text, Equip button |
| C10 | Party destination card | uses B3 at 50 % x 68 | as B3 | `Sunlit Henhouse\nNormal`, sub `Opens in a later update`, `Locked - win Sunlit Henhouse`, `Chosen` | normal, selected/chosen (gold), locked, unavailable | text |
| C11 | Tab pill (leaderboards) | uses B5 at 170 x 44 | as B5 | `Most Eggs Won`, `Fastest Henhouse`, `Feathers Gathered`, `Eggs Found` | selected / unselected | text |
| C12 | Slot chip (classes) | uses B5 at 150 x 44 | as B5 | `Slot 1: empty`, `Slot 2: Nest Carrier` | selected / unselected / hidden | text |
| C13 | Overlay scrim | none needed (flat colour) | - | - | - | transparency 0.45 |
| C14 | Optional per-modal header icon | 64 x 64 each, eleven icons | full alpha | none | one per modal title | shown left of the title |

Modal body copy that must stay live (examples): Shop `Gems 120`, `Level 3 / 10  -  +30% -> +40% bag capacity`,
`Level 10 / 10  -  +100% bag capacity  -  FULLY POLISHED`; Daily `Day 4 is ready: 50 Gems`, `Day 5 opens in
03:12:44`, `Your streak rested - the nest restarts on Day 1 with 10 Gems`; Codes `Found a code from the
community? Post it here for a nest gift.`, `Type a code first`, `Gift received: 100 Gems, 0 Event Tokens`;
Event `Event Tokens 0`, `Gems Small  -  25 to 75 Gems`, `60.0%`; Stats `Time in the nest\n1h 04m`, `Eggs
won\n3`, `Best Henhouse (Normal)\n04:12.37`, `Refreshed 12s ago  -  updates every 60s`, `1.  Wren`, `No
entries yet - be the first forager on this board`; Results `You found the Egg  -  Sunlit Henhouse  -  normal`,
`Time 04:12.37   NEW BEST`, `Your contribution: 184 feathers, 96 patches cleared, $7.20 cash`, `Party reward:
120 Gems`, `Finder bonus: 40 Gems`, `Unlocked: Sunlit Henhouse - Hard`; Party `Where to?`, `Your party`,
`Wren  -  leader`, `Open seat`, `Set off in 3...`, `Parties forming`, `Wren's party  -  Sunlit Henhouse
Normal  -  2/4`, `No open parties right now. Open one and friends can join from here.`

### D. Hotbar and tools

| Id | Asset | PNG | Slice / Hole | Text | States | Editable |
|---|---|---|---|---|---|---|
| D1 | Hotbar slot background | 192 x 112 (96 x 56) | 9-slice 24,24,168,88; transparent centre | tool name (13 pt), hint `1`-`5` / `LB/RB`, status `Ready`, `Pulling`, `Overheated`, `Throw`, `Cooling`, `Docked`, `Out foraging` | idle, equipped (accent ring), disabled/locked, focus | text, equip pop (1.06) |
| D2 | Slot status bar (track + fill) | 168 x 8 (84 x 4) | horizontal 9-slice | none | fill straw (info), warning (heat over 70 %), danger (overheated), green (chick out) | fill fraction, hidden when not applicable |
| D3 | Tool icons: Hand, Nest Rake, Confetti Charge, Feather Vac, Scout Chick | 80 x 80 each (40 x 40) | full alpha | none (name stays live text) | normal; greyed (unowned) | new ImageLabel in the slot; keep the Hand slot |
| D4 | Carried feather stack (cosmetic bag) | currently a 3D ViewportFrame 220 x 120 (mobile 150 x 84) rendering feather meshes; if replaced by 2D art: five PNGs 440 x 240 (220 x 120), one per tier empty / low / medium / high / full | full alpha, no slice; bottom-centre anchored | none | five tiers by bag fullness | tier swap, settle bounce (scale 1.08 -> 1), hidden in menus |
| D5 | Flying feather sprite (pick feedback) | optional; today uses the 3D feather mesh | - | - | - | - |

### E. Toasts

| Id | Asset | PNG | Slice / Hole | Text | States | Editable |
|---|---|---|---|---|---|---|
| E1 | Toast card | 880 x 96 (440 x 48), width stretches 60 % of screen capped 440 | 9-slice 40,32,840,64; opaque or 90 % centre | body 15 pt; reward toasts add a numeral line `+120` | tones: info (sky), success (green), warning (amber), danger (red), reward (gold) - five edge-tint variants | text, count-up, grow/pop/shrink animation, max 3 stacked |
| E2 | Toast tone icons (optional) | 40 x 40 x 5 | full alpha | none | one per tone | left of the text |

Toast strings in code: `Traded 25 feathers for $1.40`, `Could not save setting`, `Someone in the party has not
unlocked that yet`, `Party is not ready yet`, `Your bag is empty`, `Trade unavailable`, `Get closer to the Egg`,
`Could not form a party`, `The Egg is uncovered!`, `Take a breath...`, `Feather Vac overheated - cooling`,
`Scout Chick traded 12 feathers`, `Nest Rake ready`, `Bag full - trade your feathers`, `Feather Vac is still
cooling`, `Bag full - trade at the crate`, `One charge at a time`, `Aim at the nest`, `Finish the search
first`, `That chapter opens in a later update`, `That party is full`, `That party has already set off`, `Only
the party leader can do that`, `Leave your current party first`, `The party is not ready to start`, `One
moment...`, `Party action unavailable`, `Unlocked Nest Carrier`, `Nest Carrier (duplicate) equipped`, `Roll to
unlock this class first`, `Could not equip`, `Not enough Gems for a roll`, `Rolling too fast`, `Rolls happen
between searches`, `Roll unavailable`, `Auto roll stopped: out of Gems`, `Auto roll stopped`, `Bigger Bag
reached level 4`, `Not enough Gems`, `Levels changed - try again`, `Already at the top`, `Perks change between
searches`, `Purchase unavailable`, `Day 3 nest opened`, `Today's Gems are already in your pouch`, `The nest is
still resting`, `Could not claim right now`, `Code accepted`, `You do not own that skin yet`, `Grasp improved`,
`Nest Rake acquired`, `Not enough round cash`, `Stand at the workbench`, `Prices changed - try again`,
`Upgrade unavailable`.

### F. Lobby station rail (eight square buttons, 64 x 64 logical)

| Id | Role name | Label baked in the art | Modal it opens | Status |
|---|---|---|---|---|
| F1 | `station.party` | Play | Sunlit Henhouse (party) | needs PNG |
| F2 | `station.daily` | Daily | Daily Nest | needs PNG |
| F3 | `station.classes` | Classes | Class Cards | exists (rbxassetid://107137366563970), redraw to match |
| F4 | `station.shop` | Shop | Perk Bench | exists (rbxassetid://77310855238760), redraw to match |
| F5 | `station.inventory` | Rack | Tool Rack | needs PNG |
| F6 | `station.stats` | Stats | Forager Ledger | exists (rbxassetid://95977114214993), redraw to match |
| F7 | `station.codes` | Codes | Nest Mailbox | needs PNG |
| F8 | `station.event` | Chest | Moonlit Chest | needs PNG |

Spec for each: **PNG 256 x 256 (64 x 64 logical), full alpha, no slice, self-contained** (frame, icon and
label all in the art because the button hides its own frame and text when an image face is set). Deliver
three states per station: normal, pressed/hover, disabled (or let code dim to 45 % transparency). Focus ring
comes from B-series ring overlay. The label may be baked because these eight words never change; if the
game is localised later, deliver a label-less version too.

### G. Cutscene, victory, results

| Id | Asset | PNG | Slice / Hole | Text | States | Editable |
|---|---|---|---|---|---|---|
| G1 | Cutscene vignette | 1024 x 576 gradient frame, transparent centre, or flat colour (current) | full-screen stretch is acceptable for a vignette only | caption 24 pt, three beats (live) | single | caption swaps every 6 s |
| G2 | Cutscene caption plate (optional) | 9-slice 960 x 180 (480 x 90) | transparent centre | `Every spring the henhouse keeps one golden Egg safe beneath the great nest.` / `This year the flock scattered in the night, and the nest grew wild and deep.` / `Clear the feathers, fill your bag, and be the first to lift the Egg into the light.` | single | text |
| G3 | Victory announcement plate (optional) | 9-slice 1024 x 160 (80 % width x 80) | transparent centre | `You found the Egg!` / `Wren found the Egg!` | single | text, fade and scale |
| G4 | Confetti particle sprite | 64 x 64 | full alpha | none | 2-3 colour variants | emitted by VFXDirector |
| G5 | Skip story button | B3 at 160 x 44 | - | `Skip story` | see B3 | - |

### H. World-space signage (SurfaceGui / part textures)

These are textures on parts. Sizes are given in SurfaceGui pixels (part studs x PixelsPerStud).

| Id | Asset | Part size (studs) | Pixels | Text | Notes |
|---|---|---|---|---|---|
| W1 | Station sign board (7, greybox lobby only) | 7 x 2.4 | 224 x 77 (export 448 x 154) | baked or live: `Daily Nest`, `Class Cards`, `Perk Bench`, `Moonlit Chest`, `Tool Rack`, `Forager Ledger`, `Nest Mailbox` | owner map supplies its own signs; only needed if greybox is kept |
| W2 | Portal lintel | 15 x 1.6 | 600 x 64 (export 1024 x 109) | `Sunlit Henhouse` | greybox only |
| W3 | Sell crate top | 7 x 7 | 280 x 280 (export 560 x 560) | `Trade Feathers` | greybox only |
| W4 | Workbench sign | 9 x 4 | 360 x 160 (export 720 x 320) | `Workbench` | greybox only |
| W5 | Leaderboard board (greybox) | 4.6 x 5.6 | 184 x 224 | header `Most Eggs Won` 18 pt + 5 rows 14 pt `1. Wren  47`; empty `Be the first forager here` | background PNG only; rows live |
| W6 | Party pad queue sign (owner map, 4 pads) | map-authored `QueueSign.Display` | as authored | live two-line: `Join Match\n0/4`, `Join Match\n2/4  Henhouse`, `Join Match\n3/4  Cellar (Hard)`, `Setting off\nin 3`, `Good luck!` | edit the map model, not code; keep a TextLabel named `Display` |
| W7 | Leaderboard boards (owner map, 3 boards x 5 rows) | map-authored `Board1..3.Row1..5.Display` | as authored | live: `01  Wren   47`; empty `01    —` | Board1 Eggs Found, Board2 Most Eggs Won, Board3 Feathers Gathered; keep the row TextLabels |
| W8 | Proximity prompt style | Roblox default prompt UI; optional custom: key badge 64 x 64, action plate 9-slice 320 x 88 | - | action / object pairs: `Trade` / `Feather crate` or `Feather processor`, `Upgrade` / `Workbench` or `Feather supplies`, `Claim the Egg` / `Hidden Egg` (0.65 s hold ring), `Form a party` or `Set off to search` / `Sunlit Henhouse`, `Set off` / `Party nest 1..4`, `Open the nest` / `Daily Nest`, `Browse classes` / `Class Cards`, `Open the shop` / `Perk Bench`, `Peek inside` / `Moonlit Chest`, `Open the rack` / `Tool Rack`, `Read the ledger` / `Forager Ledger`, `Enter a code` / `Nest Mailbox` | custom prompts need `ProximityPrompt.Style = Custom` and a small client renderer (not built yet) |
| W9 | Pick chevron glyph | 60 x 26 billboard, three stacked | white `︿` today; optional PNG 120 x 52 | none | single | rises and fades 0.38 s |
| W10 | Feather bundle count billboard | 80 x 24 | count numeral | - | live text |

### I. Icons still missing entirely (nothing in code today)

Gem (H2), Token (H3), five tool icons (D3), eleven modal header icons (C14), five toast tone icons (E2),
gear for Settings (H9a), seven input glyphs (H8a-g), five station faces (F1, F2, F5, F7, F8), Egg icon for
the results row, feather icon for the bag chip. All are optional except the station faces, which the rail
already expects.

---

## 3. Fit check per device (what the code guarantees, what art must respect)

| Surface | Desktop 1280 x 720+ | Tablet (scale 0.94) | Phone landscape (scale 0.86, short edge < 480) | Controller |
|---|---|---|---|---|
| Top row chips | 12 px pad; banner centred, auto width | same, scaled | same; banner text wraps at title width, keep the plate 9-slice | Settings focusable |
| Toasts | 60 % width capped 440 | capped 440 x 0.94 | 60 % of a 800 px phone = 480 -> capped 440 x 0.86 = 378 | non-interactive |
| Hotbar | 5 x 96 wide, bottom - 68 | same | 5 x 96 x 0.86 = 413 px; fits a 720 px width with the thumbstick and jump button outside the centre 60 % | LB/RB hint shown |
| Round strip | 450 wide at bottom - 12 | scaled | 387 wide; sits between the touch controls | - |
| Carried stack | 220 x 120 above the hotbar | 150 x 84 | 150 x 84 x 0.86 | - |
| Modals | 92 % x 90 % capped 560 x 900; wide 820 | same, scaled | 92 % of a 360 px-tall phone is 324 px tall: content scrolls; keep action buttons inside the scroller or wire the shell footer | focus trapped in the card; Close and every button ring |
| Station rail | 8 x 64 + 7 x 8 = 568 px | 534 px | 488 px, still fits 720 wide | Y opens the party modal |
| World signs | fixed studs | same | same | same |

Art must not assume more than 44 x 44 real px for any control, must keep 12 px away from screen edges,
and must not paint anything inside the centre 20 % of the screen during Searching except the 6 px reticle.

---

## 4. Integration notes for the developer (or Codex)

1. Add every new role to `AssetManifest.images` (`hud.chip`, `hud.banner`, `hud.bag.track`, `hud.bag.fill`,
   `button.primary.normal`, `button.primary.pressed`, ... , `modal.card`, `modal.row`, `hotbar.slot`,
   `hotbar.slot.equipped`, `tool.hand`, `tool.nestRake`, `tool.confettiCharge`, `tool.featherVac`,
   `tool.scoutChick`, `toast.info`, ... , `station.*`, `stack.empty` ... `stack.full`).
2. In `Button.build`, `Frame.goldPanel`, `Frame.pill`, `Frame.row`, `Frame.meter`, `Toast`, `RoundHud`,
   `ToolHotbar`, and the HUD `chip()` factory: when `AssetManifest.image(role)` returns an id, create an
   `ImageLabel`/`ImageButton` with `ScaleType = Slice` and the `SliceCenter` from this document behind the
   existing content and set the drawn `BackgroundTransparency = 1` and `UIStroke.Enabled = false`.
   Keep the token drawing as the fallback when a role is empty.
3. Keep all `TextLabel`s; art never replaces text except station faces and greybox signage.
4. State swaps are image-id swaps (normal / pressed / disabled / selected). Focus ring stays a `UIStroke`
   or becomes an overlay `ImageLabel` per control.
5. The carried stack can stay 3D; if 2D tiers are supplied, `CarriedStack.setBag` swaps images by tier.
6. Custom proximity prompts require `ProximityPrompt.Style = Custom` plus a client renderer that reads
   `ActionText`, `ObjectText`, `HoldDuration` and the input glyph; none exists yet.
7. Two contrast bugs to fix while re-skinning: Results rows and the Workbench cash line use dark ink on
   the teal panel. Use cream/creamDeep like every other modal.
