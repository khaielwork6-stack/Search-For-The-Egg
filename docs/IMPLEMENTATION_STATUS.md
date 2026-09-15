# Implementation Status

Build label: `phase5-live-shops` (`src/server/BuildInfo.luau`). Config version 1.

| Phase | Status | Checkpoint |
|---|---|---|
| 1 - Architecture, networking, data, sessions, tests | Verified | `076e23d9f5dc6a8f5496023c33f2a18e83e37191` |
| 2 - Vertical slice (lobby -> party -> Chapter 1 -> collect -> sell -> upgrade -> Egg -> victory -> results -> save -> lobby) | Verified | `db1b463873533049761cfb2d5fec7583c580b6ab` |
| 3 - Progression and tools (Hand paths, Bag, Nest Rake, Confetti Charge, Feather Vac, Scout Chick, grants, modifiers) | Verified | `6e2a8e0b02ed78f7d5c08ef61b1e99498c78708f` |
| 4 - Lobby / meta (parties, chapter selection, classes, perks, daily, codes, group reward, inventory, stats, leaderboards, modals, pile rebuild) | **Verified** (headless + Studio Play Solo desktop and phone) | see git log / `docs/STUDIO_VERIFICATION.md` |
| 4b - Feather pile rebuild (per-feather pickup, terrain collision, carried stack) | **Verified** (headless + Studio Play, 13 Sep 2026) | see `docs/STUDIO_VERIFICATION.md` |
| 5 - Monetization, lobby queue, Farmer delivery, Rainbow Feathers, barn inspection, upgrade book | **Wrapped** (14 Sep 2026: CommerceService wired with live pass/product ids, Studio test purchases; Hard mode and Chapter 2 stay behind feature flags) | see `docs/STUDIO_VERIFICATION.md` |
| 6 - Release QA | Not started | |

## Phase 4 - what exists

### Configuration (SYSTEM_CONFIG.json, all ASSUMED and registered in ASSUMPTIONS.md)
- `lobby`: class roll animation (2.4 s, 0.9 s with Fast Rolls), server roll minimum interval (0.5 s), auto-roll
  remote rate (30/min), ambient actor budgets by tier (12/24/40), station prompt range (10 studs). A-LOBBY-01..04.
- `codePolicy`: normalization (trim, uppercase, strip separators), 24-character cap, 6 attempts/min burst 3. A-META-07.
- `leaderboards`: refresh 60 s, one write per player per board per 120 s, top 25, four boards. A-META-08.
- `chapters.<key>.availableDifficulties`: content availability separate from the unlock policy (Chapter 2 off
  until Phase 5). A-LOBBY-05.
- `polishBudgets.maximumUiTweenSeconds` raised to 0.45 so the owner's motion recipes run uncapped. A-UX-06.
- Five new enumerated analytics events (`perk_purchased`, `group_reward_claimed`, `skin_equipped`, `party_joined`,
  `class_equipped`). Validator covers every new block (608 checks).

### Shared
- `Design/Tokens`: the owner's station-button language (gold bevel, deep teal panel, cream pill, chunky rounded
  lettering, leaf accents), rarity tints, and `Tokens.recipes` (hover Back-out 0.18 s, press Sine 0.08 s, release
  Elastic 0.4 s, panel open Back-out 0.45 s + Quad fade 0.3 s, close Quad-in 0.3 s + fade 0.25 s, blur 0.3/0.25 s,
  notification grow Back 0.4 s + pop Elastic 0.45 s + shrink Quad-in 0.28 s, rotation punch, click ripple).
- `Design/Motion.recipe` resolves a recipe against the tween cap and reduced motion; `Design/AssetManifest` is
  the one image/model manifest (the three owner PNGs uploaded as image assets; Feather/Egg meshes).
- `Domain/ClassRoll` (weights, 2x Luck transform, odds, rarity bands, slots from entitlements, roll, single-slot
  placement), `Domain/DailyRewards` (pure timing: ready / early / reset, day-8 loop, transaction keys),
  `Domain/Perks` (cost curve, previews), `Domain/SkinCatalog` (defaults + event skins by category),
  `Domain/ChapterLayout.lobby.stations` (eight station positions and facings).
- `Net/NetSchema`: `PartyCancel`, `PerkPurchase`, `LeaderboardRequest` requests; `PartyListProjection`,
  `LeaderboardProjection`, `RewardGranted` events; `ClassRoll` and `CodeRedeem` rates from config (47 remotes).

### Server
- `ClassService`: Gem roll with server RNG committed before the answer, 2x Luck / Fast Rolls / extra slot from
  verified entitlements (mock adapter in Studio), duplicate re-equip (A-CLS-05), minimum interval, lobby-phase gate,
  equip of owned classes into entitlement-backed slots.
- `PerkService`: permanent perk purchases (expected level, server cost, atomic debit + level, cap).
- `RewardService`: daily claim (server time, cooldown / grace / reset / loop, one `TransactionLedger` transaction,
  replay on retry), code redemption (normalized, active/expiry, one-account, replay-safe, codes never echoed),
  group reward (adapter-checked membership, one-time, replay-safe). Gem grants apply the Gem Value perk once.
- `InventoryService`: owned-only skin equips validated against the catalog and category.
- `LeaderboardService` + `OrderedStoreAdapter` (real ordered stores / mock): bounded writes (unchanged skipped,
  inside the interval deferred with latest-wins, forced on leave), bounded refresh, sanitized rows.
- `GroupAdapter` (real `IsInGroup` through `ProductIds.social.groupId`, mock for Studio/tests).
- `PartyService`: destination availability (`chapter_unavailable`), validity + locked member ids in the projection,
  open party list, `party_joined` analytics; `PartyCancel` handler.
- `PlayerDataService` projection extras (daily evaluation, effective slot count, live session playtime);
  `ProfileProjection` carries the daily evaluation, roll count, and the remaining personal stats without leaking
  claim history or transaction ids. `rewards.lastDailyClaimTxId` added to the schema (optional string).
- `WorldShellService`: the compact lobby with eight purposeful stations (portal ahead, Daily left / Classes right,
  Shop and Moonlit Chest flanking, Tool Rack by the path, Ledger and Mailbox on the secondary sightline), each with
  a sign, a prompt that opens its modal, motion tags, an audio anchor, party silhouettes, and a ledger surface.
- Studio hooks: `rollClass`, `equipClass`, `classView`, `buyPerk`, `perkPreviews`, `claimDaily`, `shiftDailyClock`,
  `redeemCode`, `setGroupMember`, `claimGroup`, `equipSkin`, `grantSkin`, `inventoryView`, `leaderboards`,
  `partyList`, `party`, `simJoinParty`, `simLeaveParty`, `metaStats`. `setClasses` now looks classes up correctly
  (it compared against an array before) and respects the slot cap.

### Client
- `Components/Frame` (gold panel, pill, meter, row, leaves), `Components/Tween` (recipe tweens, rotation punch,
  ripple, notification envelope, count-up), `Button` (variants incl. gold/pill/image faces, touch press feedback,
  disabled/pending states, ripple, selection styling), `ModalShell` (gold card, scrolling content, footer,
  selection group, recipe open/close), `Toast` (notification recipes, reward count-ups).
- `ModalController`: world blur behind blocking modals, initial focus on the builder's control (falls back to the
  first selectable control, never nil), focus restore on close, Studio-only debug actions.
- `PartyController` (projection + open list + typed requests), `LobbyController` (station rail with the owner's
  art, prompt routing, `ModalDirective`, leaderboard snapshot, silhouettes/ledger hooks, HUD reward celebration,
  Menu action opens the party modal), `InteractionController` routes `SFE_Station_*` prompts.
- Modals: Party (destinations with lock/availability copy, members, leader actions, countdown, open party list,
  one-tap "Set off alone"), Classes (rarity cards with odds, slots, roll with a decelerating highlight that lands on
  the committed class before any result text, auto roll with stop, terms line), Shop (perks with meters and
  old -> new), Daily (calendar, countdown, grace note, claim), Codes, Inventory, Stats (personal + boards), Event
  (chest contents and odds; opening lands in Phase 5).
- HUD currency chips count up only from acknowledged projections and punch on `RewardGranted`.
- `PileVisualController` rebuilt around `Shared/Domain/PileSurface` (A-UX-07) as a major feature: the 16x16
  logical cells become one rounded-cone mound (apex `pile.maxVisualHeightStuds`, profile `1 - r^1.5`, foot at
  1.15x the footprint radius = the nest base cylinder) whose height is the continuous profile times the
  interpolated smoothed remaining fraction, plus low-frequency fluff noise so the silhouette is uneven. The client
  renders a warm beige `EditableMesh` body that is never meant to show (ellipsoid `SpecialMesh` fallback) under a
  coat of 9,000 desktop / 3,200 mobile anchored clones of the repo Feather mesh: planned per cell (deterministic
  hashes, no repeats), weighted by surface area with a rim boost that dresses the skirt, in four kinds - flat on
  the coat, half-buried, upright/crossed, and stacked clumps of 6-12 - with sizes 1.9-4.4 studs and cream-to-beige
  tints. Clones share one mesh (renderer batching), have no physics, collisions, or queries, and are placed 400
  per frame. Deltas rebuild the field, dent the body vertices in place, drop the per-column colliders, and thin /
  re-seat only the touched cells' feathers. The server resolves aims by marching the same surface
  (`CollectionService.resolveAim`); rays that start inside the mound fall back to the `pile.aimPlaneHeightStuds`
  plane and hits on the skirt map to the nearest edge cell. Baking the coat into runtime `EditableMesh` chunks was
  tried and rejected: the Play client's editable-mesh memory budget allowed 7 of 64 chunks.
- `AssetManifest.warm()` (server bootstrap and client bootstrap) repairs mesh templates whose mesh metadata never
  loaded: the Rojo-synced `Feather.rbxm`/`Egg.rbxm` ship without `MeshSize`, which made every feather render at the
  mesh's native ~322-stud size (the "feathers cover the whole map" bug). Warm-up recreates the mesh through
  `InsertService:CreateMeshPartAsync` and applies it to the template in place (replicated to clients).
- `LobbyShellController`: new ambient kinds (sway, moonPulse, pageFlip, flagWave), looped station hums bounded by
  the tier budget, Feather-mesh drift strands, party silhouettes, ledger surface. `AmbientScheduler` now slows the
  shared time base under reduced motion; ambient actor budgets come from config.

### Tests
- `tests/Meta.spec.luau` (18 cases), `tests/Party.spec.luau` (6 cases) and `tests/PileSurface.spec.luau` (5 cases:
  dome field, hollows, continuous surface, ray march, server aim from the rim and on the skirt); `Design.spec`
  covers the recipes, the asset manifest and the mesh warm-up; `Net.spec` lists the new remotes; the gameplay
  harness aims straight down at each target column's surface point. 18 modules, 256 cases headless.

## Feather pile rebuild (13 Sep 2026)

Owner requirements: no smooth dome, a dense layered feather mound; invisible solid collision; no hands, arms,
tools, or the yellow oval; one click = exactly one targeted feather; a cosmetic carried stack; visible local
depression; the Egg hidden until its cover is dug out; everything server-authoritative.

- **Logical pile** (`src/shared/Domain/PileGrid.luau`): each cell holds `base` individually collectible feather
  records (slots 1..base) with a `taken` bitmask; `removeFeather` removes exactly one record, area tools take
  the top of the stack. Ids are `cell * 64 + slot` (`FeatherLayout.featherId`). Snapshots and deltas carry the
  mask (`{ i, r, m }`).
- **Collision core** (`src/server/Services/PileTerrainService.luau`): the mound is written into Roblox Terrain
  (Snow, custom colour) as a pure function of the depleted field plus a dent map of accepted strikes; every
  accepted pick re-writes the neighbourhood (never raising a voxel), the Egg reveal opens a hollow, round end
  clears it. No decorative part is ever collidable.
- **Collection** (`CollectionService._collectFeather`): the hand names one `featherId`; the server checks the
  record exists, is untaken, and is exposed (one of the top `visibleSlotsPerCell` records), range, aim
  (closest approach within `interaction.aimMissToleranceStuds`), line of sight, bag space, request-id
  duplicates and cooldown; removes exactly that record and awards exactly one. A hand click ignores the grasp
  `amount` (owner rule "exactly one"; grasp levels currently buy nothing on the click path - flagged below).
  Feather positions never sit below the owner map's stepped pit floor (`floorHeight` probe in `init.server`).
- **Client coat** (`src/client/Controllers/PileVisualController.luau`): the exposed records of every cell are
  pooled feather parts placed by the shared `FeatherLayout` and seated on the live terrain (or the pit earth
  where it is higher); a non-targetable fluff bed fills between them and leaves only when a cell's last
  record is gone. Targeting is a camera-centre raycast; the first feather part hit gets a Highlight; on an
  accepted pick that part detaches and flies to the carried stack (streaks, chevrons, rustle/pickup audio).
  Quality tiers change only the fluff density (22 / 7 per cell) and cull distance.
- **Carried stack** (`src/client/UI/CarriedStack.luau`): ViewportFrame feathers in tiers empty/low/medium/
  high/full (0/1/3/6/9 feathers) from bag fullness, settle animation on growth, cleared on sale, hidden while a
  modal blocks or outside Searching/EggRevealed. No hands: the old viewmodel is deleted from `ToolController`.
- **Input**: one press = at most one request (in-flight guard, `interaction.collectDebounceSeconds`, server
  cooldown); a refused request holds the debounce before the next try.

Owner decision needed: hand grasp upgrades (`handUpgrades.grasp[*].amount` 2..8) no longer change the click
yield because every click collects exactly one feather. Options: re-purpose grasp (cooldown, rake yield) or
remove it from the shop. The config and shop are untouched pending that call.

## Crate sale run and precise picks (13 Sep 2026)

- The nest mound sits on the open yard centre (`ChapterLayout.chapter1.nestCenter` 0, 52, 372); the
  map's earth pit is the black hole and the conveyor exit path is clear.
- Selling is the map's `Crates.CollectionCrate`: server `ClickDetector`s on its slats (trusted sale, no
  token) plus the `SFE_Sell` prompt; `CrateService` gates one run at a time (`crate_busy`), broadcasts
  `CrateRun`, and frees the crate after the timeline (`selling.crate`, ASSUMED). `CrateController`
  replays the run on every client: lift, front belt, processor, turn, side belt, pit approach, tip,
  fall, vanish, reset; rollers spin and belt stripes scroll; sold feathers ride inside.
- A pick changes only its own cell: the record leaves, the next is exposed, that cell's fluff settles
  one layer; seats come from the mound as built (`_seatField`); terrain re-writes every
  `pile.collision.rewriteEveryRecords` records. Pick animation: lift + enlarge (0.09 s) then arc to the
  bundle (0.16 s). A reticle on the fluff bed targets that cell's top feather.
- Held bundle (`CarriedStack`): lower-right, stems gathered, heads fanned, walk bob and turn sway,
  hidden behind menus. Permanent first person; blocking menus and the cutscene free the cursor
  (`ModalController._applyMouseLock`).

## Map integration (13 Sep 2026)

The owner placed two final environments in the place file: `Workspace.SearchForTheEgg_Lobby` (fenced farm
courtyard) and `Workspace.SearchForTheEgg_Map2` (fenced farmyard with an earth pit). Both are place assets, not
repository files; the code detects them by name and otherwise falls back to the greybox shells, so headless tests
and an older place keep working.

- `Shared/Domain/ChapterLayout` now carries coordinates measured from the maps (A-LOBBY-04, A-UX-09): spawn pads,
  the barn doorway portal, the four "Join Match" nest pads, station anchors on the map's props, the three
  leaderboard boards, and for Chapter 1 the pit centre, the processor's green button (selling) and the FEATHER
  SUPPLIES counter (upgrades).
- `WorldShellService.buildFromMap` creates only functional and ambient instances in `SFE_LobbyShell`: prompt
  anchors on the map's counters/boards/coops, the barn-door threshold (`SFE_Portal`), the two props the map lacks
  (Daily Nest ring with eggs, Moonlit Chest with a moon glow) on the barn floor, pad zones and `SFE_PadStart_<n>`
  sign-post prompts, feather-drift anchors. It also writes the map's queue signs and leaderboard boards
  (`setPadSign`, `applyLeaderboards`) and disables the map's bundled `LobbyRuntime` script, which otherwise
  fights over the same signs.
- `ChapterShellService.buildFromMap` creates the invisible aim plane over the pit, `SFE_Sell` on the processor's
  green button, `SFE_Upgrade` on the supplies counter, and drift anchors. The map's `MapSpawn` pad is the round spawn.
- `PartyPadService` (A-LOBBY-06): standing inside a pad zone joins/creates that pad's party, stepping off leaves,
  a full pad sets off after `lobby.padFullAutoStartSeconds`, and the sign mirrors the party ("Join Match 1/4 -
  Henhouse Normal", "Setting off in 3"). Modal-formed parties keep their own rules.
- The nest is the pit: cells are 1.8 studs (28.8 x 28.8 footprint) and the mound apex is 16 so the feather
  mountain fills the pit and rises about 11 studs above the yard; scout chicks path at ground level.
- `ObjectiveController` highlights resolve through path lists (map prop first, greybox part second).

## ASSUMED infrastructure values (not gameplay tunables)

`src/server/ServerPolicy.luau`: DataStore names/keys from `DATASTORE_SCHEMA.md` (profiles, receipts, and
`SFE_GlobalStats_v1` ordered stores); session lock timeout 90 s; 5 load attempts with 1.5 s exponential backoff
capped at 10 s; 3 save attempts; autosave every 60-120 s with jitter; shutdown flush budget 25 s; committed
transaction marker retention 500; entitlement cache 120 s; rate-limiter sweep 120 s / idle 300 s; security log
sample rate 10%; tool tick 0.1 s; leaderboard tick 5 s.
`src/shared/Domain/ChapterLayout.luau`: same-place world coordinates (lobby at the origin, Chapter 1 at z = 400)
and the eight lobby station positions - presentation constants, not economy values. Client-only presentation
constants: bundle walk-over radius 6 studs, chick arrive threshold 1.5 studs, tool tick clamp 0.5 s, feather mesh
scale 1.35, clump overlap 1.85 x cell.

ASSUMED pile values (`SYSTEM_CONFIG.json`): `pile.collision` (Snow terrain, colour 246/236/214, voxel 4, dig
radius 2.2, strike dent 0.45, sweep dent 0.25, egg hollow 6.0 r / 6.0 deep (a 3.2 hollow left a marching-cubes skin over the Egg on 4-stud voxels), rewrite margin 2 cells, surface
inset 0.35, line-of-sight tolerance 1.5); `pile.visual` (part budgets 9000 / 3200, 2 visible slots per cell,
feather length 2.6-4.2, width 1.0-1.5, spread 0.8, tilt 6-30, roll 60, layer step 0.5, lift 0.12, fluff
0.9-2.0 x 0.35-0.7, tilt 2-22, 22 / 7 per cell, palette of five warm whites, cull 220 / 120, target rate 20 Hz,
pull 0.34 s, 3 streaks, 3 chevrons); `interaction.aimMissToleranceStuds` 2.0, `collectDebounceSeconds` 0.12;
`pile` is a 32x32 grid of 0.9-stud columns with every rendered strand a collectible record (no cosmetic strands); `hud.carriedStack` (maxVisibleFeathers 12 scaled by bag fullness, infiniteCapCount 200 for the logarithmic infinite-bag curve, bounce 0.28 s).

## Deviations from the pack

| Item | Deviation | Reason | Tests affected |
|---|---|---|---|
| Test framework | Minimal `Testing/Spec` runner instead of TestEZ | No framework existed; the pack allows a minimal compatible runner. | all |
| Studio multi-client acceptance | Verified with live player doubles on the running server plus the headless suite; the "Start Server + N players" run is documented for the owner | The Studio MCP bridge only drives Play Solo | Studio evidence |
| Build pack location | Left at repository root | Already stable; referenced by both Rojo projects | none |
| Rate limiting order | Rate limit is checked before schema validation | Cheap rejection of spam | `Registry.spec` |
| Pile density | ASSUMED `pile` block; `baseFeathersPerCell` 6 | Keeps the first-run loop inside a few minutes | `Gameplay.spec` |
| Egg reveal rule | Cover cells cleared AND removed fraction >= node depth | Realises A-EGG-03 without leaking the node early | `Gameplay.spec` "Egg" |
| Protocol automation | Studio-only client harness drives the same controllers/remotes a player uses | Repeatable evidence; nothing bypasses server validation | none |
| Gameplay stops at reveal | Tools, collection and purchases accept only `Searching` (as Phase 2) | Reveal starts the claim race; tool runtimes are cleared at that moment | `Tools.spec` "wrong phase" |
| Scout Chick deposit | Trips end at the crate and credit the owner's round cash through the sale math (no bag) | The pack's Depositing state is at the seller; owner-only awards | `Tools.spec` "Scout Chick" |
| Vac and overflow | The Vac pulls only what fits (pauses at a full bag); Rake and Charge overflow become bundles | `collection.overflowPolicy`: bag value clamped, tool output only as world pickups | `Tools.spec` "overflow" |
| Mini-charges | Same yield/radius as the parent charge, fuse `miniChargeFuseSeconds`, scattered inside the parent radius, never chain | No configured mini-charge yield; no invented number | `Tools.spec` "Blast Artist" |
| Four-player stress | Headless (4 fake players, 600 ticks) plus a single-client Studio scene with Chick + Charge + Vac + Rake running together | Studio MCP drives one client | `Tools.spec` "Stress" |
| UI tween cap | Raised from 0.35 s to 0.45 s (A-UX-06) | The owner's motion recipes (0.4-0.45 s) are an explicit instruction and outrank the ASSUMED budget | `Design.spec` |
| Class/perk changes mid-round | `ClassRoll`, `ClassEquip`, and `PerkPurchase` are accepted only in the Lobby/Party session phases | The resolver reads the profile live; changing classes mid-search would swap modifiers inside a round | `Meta.spec` |
| Daily retry semantics | A retry inside the cooldown replays the last committed claim (`replayed = true`) instead of failing | "One claim transaction; idempotent after retries" - the client shows "already in your pouch" | `Meta.spec` "Daily" |
| Gem Value perk | Applies once to daily/code/group Gem grants, never below the base amount (A-META-10) | The perk had no consumer before Phase 5 | `Meta.spec` |
| Chapter availability | `chapters.<key>.availableDifficulties` gates content separately from unlock policy (A-LOBBY-05) | The selector must show locked future destinations without letting a party start into unbuilt content | `Party.spec` |
| Group reward in Studio | Mock group adapter (`setGroupMember`) until `ProductIds.social.groupId` is set | No group id is configured; the real adapter refuses to grant without one | `Meta.spec` |

## Known limitations and placeholders

- Lobby station geometry, tool viewmodels, chick/charge/bundle parts, VFX emitters, the mound body, and the audio
  manifest are labeled placeholders (`SFE_Placeholder` = `PHASE_6_ART` / `PHASE_6_VFX`; sounds are silent stubs).
  The three station buttons with owner art are the shop, classes, and stats faces; the other five rail buttons use
  the token-drawn gold pill until art arrives (`AssetManifest.images`).
- Robux surfaces (Gem bundles, passes, one-round tools, event chest openings) land in Phase 5; the Event modal shows
  the chest contents and odds only. Live product/pass/place/group IDs remain `TODO_DEPLOYMENT_IDS`.
- Roblox-native party invites are not integrated; parties are formed from the open party list or by sharing a
  server. The client sees `PartyProjection` only for its own party.
- Leaderboard writes happen on victory commit and on leave; in Studio the ordered store is the in-memory mock.
- Controller navigation uses Roblox's automatic selection between selectable controls inside the modal selection
  group; explicit `NextSelection*` chains are not authored. Focus is proven (initial focus, restore, never nil);
  full D-pad traversal is an owner protocol on a real gamepad (Studio's virtual gamepad does not activate buttons).
- Studio's virtual mouse activated rail buttons but not buttons inside modal cards on the verification laptop;
  in-modal presses were driven through the modal's own routines (`modalAction`), which call the same client
  functions the buttons call. Real clicks on modal buttons are an owner checkpoint.
- Play-mode screenshots could not be captured through the MCP bridge on the verification laptop (edit-mode captures
  of the server-built lobby are recorded instead); UI evidence is recorded as measurements.
- The mound's colliders are per-column boxes, so the flank reads as invisible steps (2-5 studs at the rim): a
  player cannot walk in, but can jump up the mound. A smooth collider that follows the dug surface is a Phase 6
  polish item (the mesh's own convex hull cannot follow dents).
- The body is one runtime `EditableMesh`; if creation fails the body falls back to one ellipsoid (no per-cell
  dents in the body, the coat still thins). `stats.domeKind` reports which path ran. The coat never depends on
  the mesh API.
- The published place has "Allow Mesh & Image APIs" off, so the mound body uses the ellipsoid fallback there
  (`EditableMesh is not accessible`); the feather coat hides it either way. Enabling the API in Game Settings >
  Security restores the deformable body.
- The maps live only in the place file. The bundled `LobbyRuntime` script was disabled in the place and is also
  disabled at boot; the place must be saved/published for other machines to pick that up.
- Studio throttles rendering to 15 fps while its window is unfocused, so frame times sampled through the MCP bridge
  read 66.7 ms regardless of scene cost (the 60 Hz heartbeat confirms the simulation is unthrottled); the owner
  should read the in-game frame rate with the window focused. 9,000 anchored clones of one mesh is within what the
  renderer batches, but the mobile tier (3,200) should be checked on a real phone in Phase 6.
- `assets/models/Feather.rbxm` and `Egg.rbxm` lack mesh metadata (`MeshSize` 0), repaired at boot by
  `AssetManifest.warm()`; re-saving the two MeshParts from Studio would make the files self-sufficient.
- Studio join fix (13 Sep): the DataStore availability probe now performs a real read, so a Studio session
  without API access (the usual case for a shared or published place opened by a collaborator) uses the in-memory
  store instead of failing five real loads and kicking the player; and a lock left behind by a closed Studio
  session (`studio-*` job ids) is taken over immediately instead of holding the profile for 90 s. Live server
  locks are still respected.
- `luau-lsp analyze` is not installed on the laptop toolchain (advisory only).
- In Studio the place is unpublished, so DataStores are replaced by the in-memory store; the Play Solo place also
  contains two stray Creator Store meshes in Workspace (`feather`, `Egg`) that are not part of this repository.


## UI system (13 Sep 2026)

Every ScreenGui has a `Stage` frame from `SafeArea.applyScale` that carries the responsive UIScale and
can be shrunk to a device size (`emulate(w, h)` debug action / `SafeArea.setViewportOverride`). Art
comes from `Shared/Design/AssetManifest.luau` (`images`, `slices`, `sliceScale`) through
`UI/Components/Skin.luau`; every component keeps its token-drawn fallback when a role has no art.
Components: Button (variants primary / secondary / ghost / teal / pill / danger, states, art per
state), Tabs, Switch, Dialog, Confetti, Toast, ModalShell, Frame kit, Icons. UI sounds are Roblox
built-ins mapped in `AudioDirector` with per-role pitch / volume / minimum gap; world and music roles
remain silent stubs for the audio pass.

**v2 re-skin (14 Sep 2026).** The pack's frame art is retired (`Skin.frameArtEnabled = false`) in
favour of vector "cookie" surfaces drawn by `UI/Components/Frame.luau`: cocoa outline, bottom lip,
cream panel with a studs weave, gold header bands (`FrameKit.headerBand`) with outlined titles,
lipped buttons (`Button.luau`, face drops on press) and chips (`FrameKit.chip`). Pack icons, station
tiles, glyphs and the rays / studs textures are still used. The owner's dropped pack ScreenGui and
its LocalScript are disabled in the place, not deleted.

**Phase 5 systems (14 Sep 2026).** Queue pads (`PartyPadService` prompts the party screen on an
empty pad; `PartyCreate` takes a `size`; a full pad sets off after 0.5 s into the 5 s
`round.countdownSeconds`; pad glow / posts / board built in `WorldShellService.buildFromMap`).
Farmer delivery (`EggService.claim` = pick up, `EggService.deliver` at the Farmer = win,
`drop` on death / leave; Farmer is a clone of the Cow Boy rig spawned by
`ChapterShellService.spawnFarmer`). Rainbow Feathers (`FeatherLayout.isRainbow` from
`runtime.rainbowSeed` + `pile.rainbowChance` ASSUMED 0.015; `selling.rainbowFeatherMultiplier` 10;
client colour flow in `PileVisualController`). Barn inspection (`InspectController`), the upgrade
book (`UpgradeBookController`, Tab / book button / supplies counter), nameplates
(`NameplateController` + `SFE_BestTimeMs` player attribute), pickup floats (`HUDController.floatPickup`).
Known gaps: bag level 6 and a one-round Infinite Bag product are not in the config (owner input
needed); real Robux prompts have only been exercised through the mock in Play Solo.

**Lobby vendors and shops (14 Sep 2026).** The permanent menu is a right-hand stack (Stats,
Inventory, Codes); Classes and the Perk Shop open only through the owner's Cow Boy vendors
(`ChapterLayout.lobby.npcs`, prompts hosted by `WorldShellService.buildFromMap`, presentation in
`LobbyShellController._presentVendor` + `UI/NpcPlate.luau`). The supplies barn shows the owner's
item models as displays (`ChapterShellService.placeDisplays`, client `DisplayController`) that buy
through `UpgradePurchase` / `PurchasePromptRequest` via `UI/UpgradeActions.luau`. `CommerceService`
is wired in `init.server` (mock Marketplace + synthetic ids in Studio). `ShopModal` (perk tiles +
Robux column) and `ClassesModal` (deck / spotlight / slots) were rebuilt to the owner's reference.

**Tool feel (14 Sep 2026).** First-person viewmodels (`ToolViewmodelController`: the owner's
Pitchfork / Dynamite / Vacuum staged script-free by `ChapterShellService.stageToolModels` into
`ReplicatedStorage.SFE_ToolModels`; sway, look-lag spring, rake thrust + eased return, dynamite
light-then-throw, vac recoil / jitter / intake particles / wind streaks / motor loop; no hands). The
Feather Vac follows the reticle (`ToolActionAim` every `toolFeel.featherVac.aimUpdateHz`; an aim off
the nest stops it) and every pulled record is announced as `vac_pull` and animated into the nozzle;
the HUD shows a vertical heat meter with a flame. Confetti Charge blasts remove only what fits in the
bag (a full bag destroys nothing) and are drawn as the Dynamite model arcing to the target, fuse
sparks, flash / fire / smoke / debris / distance-scaled shake and a persistent scorch crater. The
Scout Chick is the owner's DodoBird (bones animated procedurally: hop, head turns, flaps, pecks) and
its trade toast reads the `chick_deposit` count. All timings live in `SYSTEM_CONFIG.toolFeel`
(ASSUMED: the owner's clips were not attached). Sound roles `tool.*` use bundled placeholders; the
fuse hiss is a silent stub until the owner supplies ids.

**Polish pass (14 Sep 2026).** Vendor prompts say Talk at chest height with an outline in reach
(`WorldShellService`, `LobbyShellController._presentVendor`, `NpcPlate` on top). `ClassesModal`
lists exact bonuses per class (Master Forager expands every passive), with a mythic tier for the
0.1 % card (rainbow border, aura, reveal). `GemShopModal` (HUD `+`, Perk Shop `+`) sells the gem
bundles including the 1,500 POPULAR bundle (`gemBundle1500` product id pending from the owner).
`DialogueController` frames NPC lines (the Farmer). `ChapterShellService` adds the SELL sign and
the Scout Chick crate display (`scoutChick` in `DisplayController` / `InspectController`). Level
pips sort by level. Rainbow feathers glow locally (no lights). The record nameplate pill is lobby-only.

**Fix pass (14 Sep 2026).** The mound is 48x48 x 0.6-stud cells with records every 0.15 studs
(32-record cap per cell, ~59k records; snapshot / delta payload caps raised) so the silhouette
changes slowly and the coat stays ten records deep; ambient strands around the mound are off.
Tab binds `Menu` above the core scripts (player list core GUI disabled) with a raw-key fallback.
`ToolController` resets every request gate on swap / phase / refusal and runs a 3 s watchdog.
Tool displays hang on the barn's left wall. The Scout Chick waits (`Waiting` unit state, server
`crateBusy`) while the crate is away and flies between `ChapterLayout.chapter1.chickPerches`.
Hard difficulty's pile multiplier now shows mostly at the rim because crown cells sit at the cap.

**Fix pass 2 (14 Sep 2026).** Tool removal shapes: `PileGrid.removeFocused` / `focusWeights`
(rake sweep disc with re-centring on bare ground, vac suction disc) and `PileGrid.removeBowl`
(blast crater), all sized in studs from `tools.*` config. Vac ticks and blasts send a targeted
`tool_award` ToolEvent so the HUD floats `+N`; blast records animate out of the crater. A fixed
front skirt of strands (`pile.visual.frontSkirt*`, owner request) covers the mound's front foot.
