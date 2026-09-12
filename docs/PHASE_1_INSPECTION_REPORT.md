# Phase 1 - Repository Inspection Report

Date: 12 September 2026
Build pack: `Search_For_The_Egg_Claude_Code_Build_Pack/` (kept at its current path; every file was read in full, including `FINAL_GDD.pdf` via `pdftotext`, and `source/validate_pack.py`).

## 1. Repository state before Phase 1

| Item | Finding |
|---|---|
| Git | One commit (`c1181c0 Add Claude Code build pack`) on `main`, tracking `origin/main` (github.com/khaielwork6-stack/Search-For-The-Egg). |
| Untracked user files (preserved) | `default.project.json`, `README.md`, `.gitignore`, `rokit.toml`, `src/client/init.client.luau`, `src/server/init.server.luau`, `src/shared/Hello.luau` - the Rojo 7.7.0 "hello world" scaffold. Also the original `Search_For_The_Egg_Claude_Code_Build_Pack.zip` (left untracked). |
| Project format | Rojo 7.7.0 project mapping `src/shared -> ReplicatedStorage.Shared`, `src/server -> ServerScriptService.Server`, `src/client -> StarterPlayer.StarterPlayerScripts.Client`, plus a Baseplate/Lighting/SoundService tree. |
| Existing gameplay / data / network / UI / test systems | None. The three scripts only printed "Hello world". |
| Toolchain (pinned before Phase 1) | Rojo 7.7.0 via Rokit. No Wally, no test framework, no linter, no formatter, no Lune. |
| Studio | Roblox Studio open on an unsaved place ("Place1", DataModel named "Search For The Egg") with the Rojo plugin connected to `localhost:34872`. The MCP Studio bridge is available. |
| Studio place contents not in the repo | `ReplicatedStorage.LBC_UI/LBC_Shared/LBC_Config/LBC_Net`, `ServerScriptService.LBC_Tests/LBC_Server/LBC_DevTools`, `ServerStorage.LBC_ServerOnly`, `StarterPlayerScripts.LBC_Client`, and a default `SpawnLocation`. These belong to an unrelated project ("LBC") and are user-owned. They were not touched; their Output lines (`[LBC:...]`) appear during Play Solo and are unrelated to this repository. |

## 2. Conflicts and dependencies

- **Build pack vs repository:** no code conflicts (empty scaffold). The pack recommends copying itself to `docs/SearchForTheEggBuildPack/`; it already lives at a stable root path, so `SYSTEM_CONFIG.json` is referenced in place by both Rojo projects (`ServerStorage.SFE.SystemConfig`). Moving it later only requires updating two `$path` entries.
- **CSV vs JSON:** no disagreement. `lune run lune/check` compares 74 mirrored rows and passes. (`MASTER_SPEC` section 1 requires stop-and-report on conflict; none exists.)
- **Unrelated Studio content:** the LBC modules in the open place are not in git and are not synced by Rojo. They coexist because every SFE instance is namespaced (`SFE_Runtime`, `SFE_LobbyShell`, `SFE_HUD`, `Shared`, `Server`, `Client`). Recommendation: open the place built by `rojo build -o "Search For The Egg.rbxlx"` for clean verification in later phases.
- **Deployment IDs:** all 22 product/pass/place keys are unmapped (`TODO_DEPLOYMENT_IDS`). The server logs `missingDeploymentIds=22` at boot; nothing prompts or grants until the owner supplies IDs (see `docs/DEPLOYMENT_IDS.md`).
- **Multi-place travel:** `placeIds` are unset, so the teleport adapter is the same-place "local" adapter. The production adapter (`TeleportAdapter.real`) is implemented behind the same interface and selected automatically once `chapter1` has a place ID.
- **DataStores in Studio:** the open place is unpublished (PlaceId 0), so `DataStoreService` is unavailable. The bootstrap detects this and uses the in-memory mock store (`dataStoreKind=studio-memory`), which is logged and shown in the debug status. Published places use the real adapter.
- **Two-client local server:** the Studio MCP bridge can start Play Solo only. The two-client acceptance item was verified with a live player double on the running server (real ProfileStore/session/entitlement services) plus the headless suite; the manual "Start Server + 2 players" protocol is documented in `docs/STUDIO_VERIFICATION.md` for the owner to repeat.

## 3. Reusable vs added

Nothing reusable existed. Everything under `src/`, `tests/`, `lune/`, and `docs/` was added in Phase 1; the user's Rojo scaffold files were extended, not replaced (the Baseplate/Lighting tree and README structure are intact).

## 4. Phase 1 file plan (as implemented)

```
default.project.json         extended: ServerStorage.SFE.SystemConfig (build pack JSON), ServerStorage.Tests
test.project.json            headless build used by lune/test and lune/check
rokit.toml                   rojo 7.7.0, selene 0.31.0, StyLua 2.5.2, lune 0.10.5, luau-lsp 1.69.0
stylua.toml / selene.toml / lune.yml / .luaurc
lune/harness.luau            builds the place, loads it with @lune/roblox, custom require for ModuleScripts
lune/test.luau               headless test command (exit code + counts)
lune/check.luau              config validation, CSV/JSON consistency, forbidden-literal scan, stylua, selene
src/shared/                  Config (Validator, Projection), Types, Clock, WeightedRandom, EconomyMath,
                             ModifierResolver, Domain/UnlockPolicy, Net (Schema, Envelope, RateLimiter, NetSchema),
                             Reducers (Party, Round, Session, Modal), Design (Tokens, Motion), Util, Testing/Spec
src/server/                  init.server.luau bootstrap, Log, ServerPolicy, BuildInfo,
                             Deployment (ProductIds, ProductMap, DebugAllowlist),
                             Data (ProfileSchema, Migrations, ProfileStore, TransactionLedger, ReceiptLedger,
                             ProfileProjection, DataStoreAdapter, MockDataStore),
                             Adapters (Marketplace, Teleport, Analytics), Net (RemoteRegistryCore, RemoteRegistry),
                             Services (PlayerData, Entitlement, Receipt, Session, Party, Round, Analytics,
                             Security, WorldShell), Debug (StudioDebug, TestRunner)
src/client/                  init.client.luau bootstrap, Controllers (NetClient, Profile, Accessibility, Quality,
                             Input, Modal, AudioDirector, VFXDirector, AmbientScheduler, CameraFeedback, Haptics,
                             HUD, LobbyShell), UI (SafeArea, Components/Button, ModalShell, Toast)
tests/*.spec.luau            13 spec modules, 185 cases, run headlessly and inside Studio from the same files
docs/                        this report, IMPLEMENTATION_STATUS.md, STUDIO_VERIFICATION.md, DEPLOYMENT_IDS.md
```

## 5. Test and Studio verification route

- Headless: `lune run lune/test` (Rojo build -> Lune loads the place -> every `*.spec` under `ServerStorage.Tests`).
- Checks: `lune run lune/check`; `luau-lsp analyze` with Roblox definitions (advisory).
- Studio: Rojo serve + plugin sync, Play Solo through the Studio MCP bridge, evidence via the Studio-only
  `ServerStorage.SFE_DebugInvoke` / `PlayerScripts.SFE_ClientDebug` bridges, screenshots, and Output capture.
  Full evidence in `docs/STUDIO_VERIFICATION.md`.

---

# Phase 2 addendum - inspection before the vertical slice

Date: 12 September 2026. Inspected from the Phase 1 checkpoint `076e23d9f5dc6a8f5496023c33f2a18e83e37191`.

- Git: clean tree apart from the user's untracked zip; 185 headless tests green; Rojo serve and the Studio
  plugin still connected; Studio in Edit mode.
- Conflicts: none new. `SYSTEM_CONFIG.json` had no pile density / grid values, so an ASSUMED `pile` block
  was added (registered as A-EGG-07 in `ASSUMPTIONS.md`); no economy value in the CSV changed.
- Dependencies used from Phase 1: config facade + validator, reducers (party/round/session/modal), remote
  registry, profile store + transaction ledger, entitlement/teleport adapters, HUD/modal/audio/VFX/ambient
  foundations, Studio debug bridges.
- Phase 2 file plan (implemented): shared `Domain/PileGrid`, `Domain/EggNodes`, `Domain/Objectives`,
  `Domain/ChapterLayout`; server `RoundService` runtime, `RoundModifiers`, `CollectionService`,
  `SellingService`, `UpgradeService`, `EggService`, `VictoryService`, `ObjectiveService`,
  `ChapterShellService`, bootstrap wiring; client `RoundController`, `PileVisualController`, `HandController`,
  `InteractionController`, `ObjectiveController`, `VictoryController`, `RoundHud`, `UpgradeModal`,
  `CutsceneOverlay`, HUD/ambient extensions; `tests/Gameplay.spec.luau`.
- Verification route: headless suite + `lune run lune/check`; Studio Play Solo Protocol A driven by the
  Studio-only client harness through the real controllers and remotes (see `docs/STUDIO_VERIFICATION.md`).

# Phase 3 addendum - inspection before progression and tools

Date: 12 September 2026. Inspected from the Phase 2 checkpoint `db1b463873533049761cfb2d5fec7583c580b6ab`.

- Git: clean tree apart from the user's untracked zip; 207 headless tests green; Rojo serve and the Studio
  plugin connected; Studio in Edit mode.
- Conflicts: none new. `SYSTEM_CONFIG.json` had no charge throw distance / cooldown / mini-charge fuse, no
  chick peck interval / deposit time, and no overflow-bundle lifetime, so ASSUMED values were added and
  registered as A-TOOL-01..03 in `ASSUMPTIONS.md`; no economy value in the CSV changed. The `UpgradePurchase`
  id validator only allowed word characters, so it now accepts the structured ids (`nestRake.sweep`,
  `tool:scoutChick`).
- Dependencies used from Phase 2: round runtime + pile grid, collection validation order, upgrade previews,
  selling math, resolver, entitlement service, Studio bridges, client round/pile/HUD/modal foundations.
- Phase 3 file plan (implemented): shared `Domain/ToolSpecs`, `PileGrid` area helpers, `NetSchema`
  additions; server `Services/ToolService`, `Services/RoundAwards`, generalized `CollectionService`,
  `UpgradeService` tool paths + acquisition, `RoundService` tool state, `StudioDebug` grant hooks, bootstrap
  wiring; client `ToolController` (replaces `HandController`), `ToolVisualController`, `UI/ToolHotbar`,
  grouped `UpgradeModal`; `tests/Tools.spec.luau` + `tests/Helpers/GameplayHarness.luau`.
- Verification route: headless suite + `lune run lune/check`; Studio Play Solo on desktop and the iPhone 17
  Pro preset with labelled debug funds through the secured hooks (see `docs/STUDIO_VERIFICATION.md`).
