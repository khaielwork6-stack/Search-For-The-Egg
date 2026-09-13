# Implementation Status

Build label: `phase4-lobby-meta` (`src/server/BuildInfo.luau`). Config version 1.

| Phase | Status | Checkpoint |
|---|---|---|
| 1 - Architecture, networking, data, sessions, tests | Verified | `076e23d9f5dc6a8f5496023c33f2a18e83e37191` |
| 2 - Vertical slice (lobby -> party -> Chapter 1 -> collect -> sell -> upgrade -> Egg -> victory -> results -> save -> lobby) | Verified | `db1b463873533049761cfb2d5fec7583c580b6ab` |
| 3 - Progression and tools (Hand paths, Bag, Nest Rake, Confetti Charge, Feather Vac, Scout Chick, grants, modifiers) | Verified | `6e2a8e0b02ed78f7d5c08ef61b1e99498c78708f` |
| 4 - Lobby / meta (parties, chapter selection, classes, perks, daily, codes, group reward, inventory, stats, leaderboards, modals, pile rebuild) | **Verified** (headless + Studio Play Solo desktop and phone) | see git log / `docs/STUDIO_VERIFICATION.md` |
| 5 - Hard, Chapter 2, monetization | Not started | |
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
- `PileVisualController` rebuilt around `Shared/Domain/PileSurface` (A-UX-07): the 16x16 logical cells become one
  rounded-cone mound (apex `pile.maxVisualHeightStuds`, profile `1 - r^1.5`, foot at 1.15x the footprint radius =
  the nest base cylinder) whose height is the continuous profile times the interpolated smoothed remaining
  fraction. The client renders it as one runtime `EditableMesh` heightfield (64/48/32 segments by tier, per-vertex
  normals and cream vertex tints, SmoothPlastic) with an ellipsoid `SpecialMesh` fallback when the mesh API is
  unavailable; invisible per-column collider boxes keep players outside and drop with the surface; the repo Feather
  mesh is instanced by density from the tier budget and seated tangent to the surface. Deltas rebuild the field,
  move the touched vertices in place (live dents), drop colliders, and thin shingles. The server resolves aims by
  marching the same surface (`CollectionService.resolveAim`); rays that start inside the mound fall back to the
  `pile.aimPlaneHeightStuds` plane and hits on the skirt map to the nearest edge cell.
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
- `EditableMesh` needs the experience to allow runtime mesh creation; if it fails at runtime the mound falls back to
  one ellipsoid (no per-cell dents in the body, shingles still thin). `stats.domeKind` reports which path ran.
- `assets/models/Feather.rbxm` and `Egg.rbxm` lack mesh metadata (`MeshSize` 0), repaired at boot by
  `AssetManifest.warm()`; re-saving the two MeshParts from Studio would make the files self-sufficient.
- `luau-lsp analyze` is not installed on the laptop toolchain (advisory only).
- In Studio the place is unpublished, so DataStores are replaced by the in-memory store; the Play Solo place also
  contains two stray Creator Store meshes in Workspace (`feather`, `Egg`) that are not part of this repository.
