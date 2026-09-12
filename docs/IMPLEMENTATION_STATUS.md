# Implementation Status

Build label: `phase3-progression-tools` (`src/server/BuildInfo.luau`). Config version 1.

| Phase | Status | Checkpoint |
|---|---|---|
| 1 - Architecture, networking, data, sessions, tests | Verified | `076e23d9f5dc6a8f5496023c33f2a18e83e37191` |
| 2 - Vertical slice (lobby -> party -> Chapter 1 -> collect -> sell -> upgrade -> Egg -> victory -> results -> save -> lobby) | Verified | `db1b463873533049761cfb2d5fec7583c580b6ab` |
| 3 - Progression and tools (Hand paths, Bag, Nest Rake, Confetti Charge, Feather Vac, Scout Chick, grants, modifiers) | **Verified** (headless + Studio Play Solo desktop and phone) | see git log / `docs/STUDIO_VERIFICATION.md` |
| 4 - Lobby / meta | Not started | |
| 5 - Hard, Chapter 2, monetization | Not started | |
| 6 - Release QA | Not started | |

## Phase 3 - what exists

### Shared
- `Domain/ToolSpecs`: pure resolution of every tool number from `SYSTEM_CONFIG` + round levels + resolved
  modifiers (Hand grasp/speed/hold; Rake sweep/cooldown/hold; Charge luckyBlast/speed/power + throw distance,
  cooldown, mini-charge fuse; Vac power/cooling/runtime; Chick speed/grasp/capacity + peck interval, deposit
  time, class swarm), acquisition prices (`tools.<id>.softCashPrice` in cents or `softGemPrice`), path previews
  with a discount applied exactly once, max levels from the JSON path lengths.
- `Domain/PileGrid` gains `cellsWithin` (cell radius), `cellsWithinStuds` (stud radius), and `removeSpread`
  (round-robin removal: each eligible cell loses at most one feather per pass, total never exceeds the yield).
- `Net/NetSchema`: `BundleGather` request, `ToolEvent` server event, structured upgrade ids
  (`bag`, `handGrasp`, `<tool>.<path>`, `tool:<tool>`).
- Config (ASSUMED, registered A-TOOL-01..03): `tools.confettiCharge.throwDistanceStuds/cooldownSeconds/
  miniChargeFuseSeconds`, `tools.scoutChick.collectIntervalSeconds/depositSeconds`,
  `collection.overflowBundleSeconds`; analytics events `tool_action`, `tool_overheated`, `chick_trip`.
  Validator extended for all of them.

### Server
- `RoundService` player state gains `equippedTool`, per-tool `toolLevels`, `permanentTools`, `toolRuntime`;
  runtime gains `bundles` and `charges`; projections carry bundles/charges (rejoin) and a scalar-only copy of
  the tool runtime (vac heat/overheat, chick active/unit count). Bootstrap adds the resolved bag capacity
  (`bagCapacity`, `bagInfinite`) to every player projection.
- `RoundAwards`: the single award path for every source (Hand, Rake, Charge, Vac, bundles). Bag value is
  clamped to capacity; tool overflow becomes a world bundle with `collection.overflowBundleSeconds` lifetime;
  `bagCapacity` composes level x class x Infinite Bag entitlement through `EconomyMath`.
- `CollectionService`: Hand and Rake share one validated path (owned + equipped tool, cooldown, origin
  plausibility, ray/range, capacity, target cells, atomic removal + award). Hand removes only what fits; Rake
  sweeps a 3x3 neighbourhood for the configured yield and bundles the overflow. `gatherBundle` picks up bundles
  within `interaction.defaultRangeStuds`. `resolveAim` is shared with `ToolService`.
- `UpgradeService`: previews and purchases for bag, Hand paths, tool paths (owned tools only) and soft-currency
  acquisition (`tool:<id>`; round cash or profile Gems for the Scout Chick). Rake Expert's
  `rakeUpgradeCostMultiplier` is applied once to Rake path costs. Stale level, max, insufficient funds/Gems,
  duplicate acquisition, invalid ids and wrong phase never debit.
- `ToolService` (0.1 s tick, `ServerPolicy.toolTickSeconds`): equip; Confetti Charge (throw validated by
  aim/throw distance, one live charge per player, cooldown, server-timed fuse, stud-radius removal, server RNG
  rainbow conversion, Blast Artist mini-charges only through the resolved modifier, never chaining); Feather Vac
  (continuous suction at `perSecond`, heat to `runtimeSeconds`, overheat -> forced cooling of `coolingSeconds`,
  stops on release/death/equip change/range/empty/bag full); Scout Chick (server-owned units:
  ToPile -> Collecting -> ToSeller -> Depositing -> ToPile, owner-only cash through the same sale math, Automation
  Expert swarm helpers with one trip each); round-start grants (mock/real permanent entitlements at max levels
  when `permanentIncludesMaxUpgrades`, class Scout Chick grant); `grantOneRound` (receipt interface for
  Phase 5); death / disconnect / round-end cleanup (chick loads drop as bundles); bundle expiry.
- `ModifierResolver` fully wired: classes (profile), perks, difficulty, verified entitlements (plus Studio-only
  debug overrides) feed every service through `RoundModifiers`.
- Studio hooks (labelled `DEBUG_*` warnings, never remotes): `debugGrantCash`, `debugGrantGems`,
  `setClasses`, `setEntitlement` (mock entitlement adapter), `grantWins`, `grantTool`, `tools`, `pileRemaining`.

### Client
- `ToolController` replaces `HandController`: hotbar selection (click/tap, number keys, bumpers), viewmodel per
  tool, Hand/Rake collect with hold-to-gather once the hold path is unlocked, Charge throw with cooldown gate,
  Vac press/release (release, focus loss and modals end suction), Chick deploy/recall toggle, walk-over bundle
  gathering (skipped while the bag is full), local heat interpolation between server events, insufficient
  funds / overheated / bag-full feedback.
- `ToolVisualController`: server `ToolEvent` presentation - charges (arc in, fuse pulse, burst), vac puffs,
  chick units smoothed toward the server's announced target at the server's speed, bundles with count labels;
  rebuilt from snapshots on rejoin; cleared outside Searching.
- `UI/ToolHotbar` (owned tools only, hints per input mode, heat/cooldown/trip status), `UpgradeModal` grouped
  by tool with acquisition rows (cash or Gems), permanent/max states.

### Tests
- `tests/Tools.spec.luau` (17 cases) + `tests/Helpers/GameplayHarness.luau` (shared with `Gameplay.spec`):
  15 modules, 225 cases headless and in Studio.

## Phase 2 / Phase 1 - what exists

Unchanged; see the Phase 2 and Phase 1 checkpoints. Phase 2's `HandController` is superseded by
`ToolController` (same `tryCollect` entry point, so the Phase 2 automation harness still works).

## ASSUMED infrastructure values (not gameplay tunables)

`src/server/ServerPolicy.luau`: DataStore names/keys from `DATASTORE_SCHEMA.md`; session lock timeout 90 s;
5 load attempts with 1.5 s exponential backoff capped at 10 s; 3 save attempts; autosave every 60-120 s with
jitter; shutdown flush budget 25 s; committed transaction marker retention 500; entitlement cache 120 s;
rate-limiter sweep 120 s / idle 300 s; security log sample rate 10%; tool tick 0.1 s.
`src/shared/Domain/ChapterLayout.luau`: same-place world coordinates (lobby at the origin, Chapter 1 at
z = 400) - presentation constants, not economy values. Client-only presentation constants: bundle walk-over
radius 6 studs, chick arrive threshold 1.5 studs, tool tick clamp 0.5 s.

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

## Known limitations and placeholders

- All world geometry, tool viewmodels, chick/charge/bundle parts, VFX emitters, and the audio manifest are
  labeled placeholders (`SFE_Placeholder` = `PHASE_4_ART` / `PHASE_6_ART` / `PHASE_6_VFX`; tool sounds reuse the
  existing silent stand-in roles).
- Robux one-round / permanent packaging goes live in Phase 5 through `ToolService.grantOneRound` and the
  entitlement snapshot; in Studio the mock entitlement adapter (`setEntitlement`) stands in for pass ownership.
- Class selection is debug-only until Phase 4 (`setClasses`); the Gem roll is Phase 4.
- Hard difficulty is reachable through the existing party route once a Normal win exists (`grantWins` in
  Studio); no dedicated Hard content yet (Phase 5).
- Number keys 1-5 select hotbar slots in play; Studio's virtual keyboard refuses some of those keys as
  core-bound, so the Studio evidence uses a real GUI click on a slot plus one accepted key press.
- Multiplayer edge cases (late join, rejoin restore, death during claim) remain Phase 6; bundles and live
  charges are already carried in the round snapshot for rejoin.
- `luau-lsp analyze` still reports advisory type errors (unknown-require paths without a sourcemap, generated
  JSON module).
- In Studio the place is unpublished, so DataStores are replaced by the in-memory store; persistence is proven
  through `reloadProfile` and the headless suite.
- The Rojo plugin must be reconnected after `rojo serve` restarts; during this phase the last edits were pushed
  into the open place by fingerprint-verified source patches (see `docs/STUDIO_VERIFICATION.md`).
- The open Studio place contains unrelated user content (`LBC_*`); it is not part of this repository.
