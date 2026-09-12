# Implementation Status

Build label: `phase1-architecture` (`src/server/BuildInfo.luau`). Config version 1.

| Phase | Status | Checkpoint |
|---|---|---|
| 1 - Architecture, networking, data, sessions, tests | **Verified** (headless + Studio Play Solo) | see git log / `docs/STUDIO_VERIFICATION.md` |
| 2 - Vertical slice | Not started | |
| 3 - Progression and tools | Not started | |
| 4 - Lobby / meta | Not started | |
| 5 - Hard, Chapter 2, monetization | Not started | |
| 6 - Release QA | Not started | |

## Phase 1 - what exists

### Configuration
- `SYSTEM_CONFIG.json` is mapped by Rojo into `ServerStorage.SFE.SystemConfig` (never copied). `Config.get()`
  validates (557 checks: weights total 100, IDs, contiguous levels, monotonic curves, terminal null costs,
  references, flags) and deep-freezes it. Clients receive a sanitized projection (`codes`, `analytics`,
  `$schema` removed) published as `ReplicatedStorage.SFE_Runtime.ClientConfig`.
- `lune run lune/check` also proves `ECONOMY_TABLES.csv` agrees with the JSON (74 rows) and that no service,
  controller, or UI module hard-codes a Robux price or product ID.

### Deployment mapping
- `src/server/Deployment/ProductIds.luau` (server-only) holds every live ID; all 22 are `nil`
  (`TODO_DEPLOYMENT_IDS`). `ProductMap` derives expected keys from config, rejects unknown keys / duplicate /
  non-integer IDs, and reports missing keys. Unknown receipts return `NotProcessedYet`.

### Shared domain
- `Clock` (real/fake), `WeightedRandom` (deterministic PRNG, half-open interval boundaries, ASSUMED 2x-Luck
  transform isolated in one function), `EconomyMath` (integer cents, half-up rounding, sale formula, bag
  capacity with explicit infinite state), `ModifierResolver` (named sources, no double application,
  class/perk/difficulty/entitlement builders), `Domain/UnlockPolicy` (policy objects, never `wins >= 1`).
- Pure reducers matching `STATE_MACHINES.md`: `PartyReducer`, `RoundReducer`, `SessionReducer`, `ModalReducer`.
- `Net/NetSchema`: 22 client requests (RemoteFunctions) and 16 server events (RemoteEvents), each with
  direction, strict schema, byte/depth bounds, and a config-driven rate limit. No generic dispatch remote.
- `Design/Tokens` + `Design/Motion`: typography, colour, spacing, radius, stroke, shadow, motion, sound
  semantics, input prompts, layout breakpoints; motion capped by `polishBudgets.maximumUiTweenSeconds` and
  scaled by `reducedMotionScale`.

### Server
- `ProfileStore`: session lock (job id + timestamp, stale after `ServerPolicy.sessionLockTimeoutSeconds`),
  defaults, reconciliation/clamping, ordered idempotent migrations, dirty tracking, autosave tick, shutdown
  flush, load-failure hold (never a writable default; player held in `LoadRetry` then removed with a friendly
  message). Injected DataStore adapter (`DataStoreAdapter` real / `MockDataStore` with failure injection).
- `TransactionLedger` (victory key `roundId:userId:chapter:difficulty`, receipt key `receipt:<purchaseId>`)
  and `ReceiptService` (single ProcessReceipt: ledger lookup -> product map -> profile -> idempotent grant ->
  save -> secondary ledger -> `PurchaseGranted`). Grant handlers are registered by kind; none are live yet.
- `EntitlementService` + `MarketplaceAdapter` (real/mock): ownership is canonical from Roblox; unconfigured
  passes are never owned; failed checks never grant.
- `RemoteRegistryCore` pipeline: unknown -> size/depth -> rate -> schema -> handler -> envelope, with
  `SecurityService` counters and sampled structured logs. `RemoteRegistry` binds instances.
- `SessionService`, `PartyService`, `RoundService`: lifecycle skeletons with tokens, per-member unlock
  validation, server countdown deadlines, reservation via `TeleportAdapter` (real / local same-place),
  Egg node selection with repeat protection (placeholder node catalogue), atomic first claim, commit/results/return.
- `AnalyticsService`: enumerated events only, config/build stamping, sampling for `feather_collected`,
  free-text rejection. `AnalyticsAdapter` real (Roblox AnalyticsService) / mock.
- `WorldShellService`: labeled placeholder lobby shell (`SFE_Placeholder = PHASE_4_ART`).
- `Debug/StudioDebug`: Studio-only hooks (status, dump/reset profile, run tests, lifecycle simulation, player
  double join/leave, flush) exposed via `shared.SFE_Debug` and `ServerStorage.SFE_DebugInvoke`.

### Client
- Bootstrap waits for the runtime folder and projection, then starts: `NetClient` (client-side schema check,
  one in-flight request per message), `ProfileController`, `AccessibilityController`, `QualityController`
  (tiers + budgets), `InputController` (ContextActionService actions, input-mode detection, release on focus
  loss/menu), `ModalController` (priority stack, input suspension, focus restore), `AudioDirector` (four
  SoundGroup buses, cross-faded music states, one-shot cap, pooling), `VFXDirector` (pooled emitters within
  budget), `AmbientScheduler` (single Heartbeat, seeded, distance-culled, tier-capped), `CameraFeedback`,
  `HapticsController`, `HUDController` (currency chips, session banner, prompt chip, settings modal round-trip,
  toast queue), `LobbyShellController` (ambient actors from server tags).
- UI: `SafeArea` (UIScale by breakpoint, CoreUISafeInsets), `Button`, `ModalShell`, `Toast`.

### Tests
- `tests/*.spec.luau`: 13 modules, 185 cases. Same files run headlessly (`lune run lune/test`) and in Studio
  (`shared.SFE_Debug.runTests()` / `SFE_DebugInvoke:Invoke("runTests")`).

## ASSUMED infrastructure values (not gameplay tunables)

`src/server/ServerPolicy.luau`: DataStore names/keys from `DATASTORE_SCHEMA.md`; session lock timeout 90 s;
5 load attempts with 1.5 s exponential backoff capped at 10 s; 3 save attempts; autosave every 60-120 s with
jitter; shutdown flush budget 25 s; committed transaction marker retention 500; entitlement cache 120 s;
rate-limiter sweep 120 s / idle 300 s; security log sample rate 10%; friendly kick messages.

## Deviations from the pack

| Item | Deviation | Reason | Tests affected |
|---|---|---|---|
| Test framework | Minimal `Testing/Spec` runner instead of TestEZ | No framework existed; the pack allows a minimal compatible runner. Same spec files run headless and in Studio. | all |
| Studio 2-client acceptance | Verified with a live player double on the running server plus the headless suite; the real "Start Server + 2 players" run is documented for the owner | The Studio MCP bridge can only start Play Solo | `Services.spec` "two players", Studio evidence |
| Build pack location | Left at repository root instead of `docs/SearchForTheEggBuildPack/` | Already stable; referenced by both Rojo projects | none |
| Rate limiting order | Rate limit is checked before schema validation | Cheap rejection of spam before parsing | `Registry.spec` advances the clock between malformed payloads |

## Known limitations and placeholders

- Lobby shell geometry, feather strands, VFX emitters, and the audio manifest are labeled placeholders
  (`SFE_Placeholder` attributes: `PHASE_4_ART`, `PHASE_6_VFX`; audio manifest entries are empty strings).
- Egg spawn nodes are synthetic ids (`chapter1:node_N`); authored nodes with cover cells arrive in Phase 2.
- No gameplay handlers (collect/sell/upgrade/claim) are registered; those requests validate and return
  `unavailable`.
- `luau-lsp analyze` reports 15 advisory type errors in strict modules (option-table defaults and self
  typing) plus 21 from the Rojo-generated JSON module (heterogeneous arrays). Runtime and tests are unaffected.
- In Studio the place is unpublished, so DataStores are replaced by the in-memory store (logged as
  `dataStoreKind=studio-memory`).
- The open Studio place contains unrelated user content (`LBC_*`); it is not part of this repository.
