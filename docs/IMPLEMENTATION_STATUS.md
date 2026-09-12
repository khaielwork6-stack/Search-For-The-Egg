# Implementation Status

Build label: `phase2-vertical-slice` (`src/server/BuildInfo.luau`). Config version 1.

| Phase | Status | Checkpoint |
|---|---|---|
| 1 - Architecture, networking, data, sessions, tests | Verified | `076e23d9f5dc6a8f5496023c33f2a18e83e37191` |
| 2 - Vertical slice (lobby -> party -> Chapter 1 -> collect -> sell -> upgrade -> Egg -> victory -> results -> save -> lobby) | **Verified** (headless + Studio Play Solo, Protocol A) | see git log / `docs/STUDIO_VERIFICATION.md` |
| 3 - Progression and tools | Not started | |
| 4 - Lobby / meta | Not started | |
| 5 - Hard, Chapter 2, monetization | Not started | |
| 6 - Release QA | Not started | |

## Phase 2 - what exists

### Round runtime (server)
- `RoundService` now owns a runtime per round: the logical `PileGrid` (16x16 cells from `pile.*`,
  difficulty `pileHealthMultiplier`, cover cells at `coverDepthMultiplier`), the immutable Egg node
  (`EggNodes` catalogue of `spawnNodeCountTarget` nodes, weighted selection with `repeatProtectionRounds`),
  the node's depth fraction (uniform inside `eggSpawn.minimumRemovalFraction..maximumRemovalFraction`, or
  the difficulty's own window), per-player round state (cash cents, bag, Hand levels, tools, contribution,
  cooldown deadline), batched pile deltas flushed at `collection.pileRepresentation.replicationHz`, results,
  and results votes / auto-continue (`round.resultScreenAutoContinueSeconds`).
- `CollectionService`: STATE_MACHINES section 4 order (token/phase -> alive -> tool -> cooldown -> origin
  plausibility `serverPositionToleranceStuds` -> ray/plane + `defaultRangeStuds` -> bag capacity via
  `EconomyMath.bagCapacity` and `RoundModifiers` -> target cell (`PileGrid.findTarget`) -> atomic removal +
  award). Yields come from `handUpgrades.grasp[level].amount` x resolved multipliers; cooldown from
  `collection.baseHandCooldownSeconds` (or the hold path interval).
- `SellingService`: whole-bag exchange at `sellRangeStuds` from the crate; `EconomyMath.computeSale` with the
  resolver's composed sell multiplier; duplicate sale finds an empty bag (`already_done`).
- `UpgradeService`: data-driven previews (old -> new, cost in cents) and purchases for `bag`, `handGrasp`,
  `handSpeed`, `handHold`; request carries the expected level, never a price; stale level, funds, range,
  and max level all refuse without debit.
- `EggService`: reveal when the node's cover cells are cleared AND the removed fraction reaches the node's
  depth (ASSUMED A-EGG-03/07); reveal once; claim requires `claimRadiusStuds` and the first valid claim wins
  (`RoundReducer.claim`). The Egg part is created only at reveal (no early position leak).
- `VictoryService`: per present member one idempotent transaction (`roundId:userId:chapter:difficulty`):
  base reward x `difficulty.rewardMultiplier`, finder bonus `victory.finderBonusGems`, wins/chapter wins/best
  time (server ms)/stats/unlock recompute; every profile is saved before results; a failed save keeps the
  round in `CommittingRewards` and `tick()` retries.
- `ObjectiveService`: strict-ordered tutorial steps persisted by version; `ObjectiveChanged { step }` ids only.
- `ChapterShellService`: Sunlit Henhouse arena (barn, windows, rafters, fan, cloth, birds, nest base
  collider, aim plane, crate + workbench prompts, round spawn) at `ChapterLayout.chapter1`.
- Bootstrap wiring: party -> round hand-off, character placement (round spawn / lobby spawn, respawn
  preserves round state per A-RND-07), `RoundSnapshot`/`RoundDelta`/`SaleResult`/`UpgradeResult`/
  `EggRevealed`/`VictoryStarted`/`RewardsCommitted`/`ResultsProjection`/`ObjectiveChanged` events, and the
  `RoundSkipVote`, `CollectAction`, `SellRequest`, `UpgradePurchase`, `EggClaim`, `ResultsAction`,
  `TutorialAction` handlers.

### Client
- `RoundController` (state, timer from server timestamps, first-person lock, cutscene overlay with skip
  vote, audio state changes), `PileVisualController` (256 mound parts + pooled strands, coherent dents from
  authoritative deltas, tug -> release -> stream to bag, reveal spiral), `HandController` (viewmodel hand,
  windup/contact/reward/recovery, server cooldown gating, puff + SFX + haptic + camera impulse + bag squash),
  `InteractionController` (portal / crate / workbench / Egg prompts -> typed requests), `ObjectiveController`
  (copy + one world highlight), `VictoryController` (reveal chime/glow/spiral/camera framing with the
  reduced-motion static cut, winner announcement with input lock, results modal with separated party reward
  and finder bonus count-ups, Replay / Lobby), `RoundHud` (bag meter, cash count-up, timer), `UpgradeModal`,
  `CutsceneOverlay` (original three-beat story, 18 s from config).

### Config additions
- `pile` (ASSUMED A-EGG-07): grid 16x16 x 2.5 studs, 6 feathers per cell +-25%, cover x2 in a 1-cell radius,
  visual height 3.5. Validator extended (grid size must equal `serverGridCells`).

### Tests
- `tests/Gameplay.spec.luau` (22 cases) + existing suites: 14 modules, 207 cases. Same files run headlessly
  and in Studio.

## Phase 1 - what exists

(unchanged; see the Phase 1 checkpoint) Configuration facade + validator + client projection, deployment ID
map, shared domain math/RNG/resolver/unlock policy, pure reducers, typed remote registry with rate limits,
profile store with session locks/migrations/autosave/flush, transaction + receipt ledgers, entitlement /
teleport / analytics adapters, session/party/round services, analytics + security services, lobby shell,
client foundations (net, profile, accessibility, quality, input, modal, audio buses, pooled VFX, ambient
scheduler, camera feedback, haptics, HUD, design tokens), Spec runner + Lune harness + check script.

## ASSUMED infrastructure values (not gameplay tunables)

`src/server/ServerPolicy.luau`: DataStore names/keys from `DATASTORE_SCHEMA.md`; session lock timeout 90 s;
5 load attempts with 1.5 s exponential backoff capped at 10 s; 3 save attempts; autosave every 60-120 s with
jitter; shutdown flush budget 25 s; committed transaction marker retention 500; entitlement cache 120 s;
rate-limiter sweep 120 s / idle 300 s; security log sample rate 10%; friendly kick messages.
`src/shared/Domain/ChapterLayout.luau`: same-place world coordinates (lobby at the origin, Chapter 1 at
z = 400) - presentation constants, not economy values.

## Deviations from the pack

| Item | Deviation | Reason | Tests affected |
|---|---|---|---|
| Test framework | Minimal `Testing/Spec` runner instead of TestEZ | No framework existed; the pack allows a minimal compatible runner. | all |
| Studio multi-client acceptance | Verified with live player doubles on the running server plus the headless suite; the "Start Server + N players" run is documented for the owner | The Studio MCP bridge only drives Play Solo | Studio evidence |
| Build pack location | Left at repository root | Already stable; referenced by both Rojo projects | none |
| Rate limiting order | Rate limit is checked before schema validation | Cheap rejection of spam | `Registry.spec` |
| Pile density | New ASSUMED `pile` block; `baseFeathersPerCell` set to 6 after measuring 12 (~14 min solo Hand round) | Keeps the first-run loop inside a few minutes with Hand only; tools (Phase 3) accelerate further | `Gameplay.spec` reads config |
| Egg reveal rule | Cover cells cleared AND removed fraction >= node depth | Realises A-EGG-03 without leaking the node early | `Gameplay.spec` "Egg" |
| Protocol A automation | A Studio-only client harness (`SFE_ClientDebug:Invoke("autoPlay")`) walks the character and drives the same controllers/remotes a player uses | Repeatable evidence without debug grants; nothing bypasses server validation | none |

## Known limitations and placeholders

- All world geometry, the feather strands, the hand viewmodel, VFX emitters, and the audio manifest are
  labeled placeholders (`SFE_Placeholder` = `PHASE_4_ART` / `PHASE_6_ART` / `PHASE_6_VFX`; sound roles map to
  silent stand-ins, so audio calls exercise pooling and state changes but produce no sound yet).
- Cutscene is a static three-beat overlay; the animated storyboard is a Phase 6 item.
- Egg spawn nodes are generated on an interior grid; authored node transforms/camera anchors are Phase 2+
  content work that Phase 3-6 refine.
- Only the Hand tool exists; Rake/Charge/Vac/Chick, hold-to-gather input, and remaining curves are Phase 3.
- Multiplayer edge cases (late join, rejoin restore, death during claim) are Phase 6; the reducers already
  enforce join closure at reveal and present-member reward policy.
- `luau-lsp analyze` still reports advisory type errors (option-table defaults, generated JSON module).
- In Studio the place is unpublished, so DataStores are replaced by the in-memory store; persistence across a
  Play restart therefore cannot be shown in Studio - it is proven by releasing and reloading the profile
  through the real `ProfileStore` (`SFE_DebugInvoke:Invoke("reloadProfile")`) and by the headless suite.
- The open Studio place contains unrelated user content (`LBC_*`); it is not part of this repository.
