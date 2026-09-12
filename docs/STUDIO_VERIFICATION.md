# Phase 1 - Verification Evidence

Environment: Windows 11, Roblox Studio (version-93202a13414c4131), Rojo 7.7.0 serve on `localhost:34872`
with the Rojo plugin connected, Studio MCP bridge for Play control / Luau execution / screenshots / input.
The open place is unpublished (PlaceId 0), so DataStores are replaced by the in-memory store
(`dataStoreKind=studio-memory`). Unrelated `LBC_*` user content in the place emits `[LBC:...]` Output lines.

## Automated

| Command | Result |
|---|---|
| `lune run lune/test` | `Tests: 185 passed, 0 failed, 0 skipped, 185 total` - exit 0 (13 spec modules, 62 ModuleScripts loaded through the harness) |
| `lune run lune/check` | config valid (557 checks), CSV/JSON agree (74 rows), no hard-coded prices/IDs (73 files), stylua ok, selene ok - exit 0 |
| `stylua --check src tests lune` | clean |
| `selene src tests lune` | 0 errors, 0 warnings |
| `rojo build test.project.json` / `default.project.json` | builds |
| `luau-lsp analyze --definitions build/globalTypes.d.luau src tests` | 15 advisory type errors in strict modules + 21 in the Rojo-generated JSON config module (heterogeneous arrays); documented in IMPLEMENTATION_STATUS.md |

Per-suite counts (identical headless and in Studio): Config 21, Design 7, EconomyMath 14, ModifierResolver 11,
Net 17, Profile 21, Reducers 22, Registry 9, Services 18, Transactions 14, UnlockPolicy 7, Util 11,
WeightedRandom 13.

Required automated evidence mapping:
- Config parses/validates; class and chest weights total 100 -> `Config.spec`, `lune/check`.
- Server/client projections expose no server-only/product secrets -> `Config.spec` "client projection",
  `Services.spec` "sanitized projections", live check below (`clientConfigHasCodes=false`).
- Malformed/oversized/unknown remote requests rejected and rate-limited -> `Registry.spec`, `Net.spec`, live fuzz below.
- Profile default/reconcile/clamp/migration idempotency/session lock/save failure/release -> `Profile.spec`.
- Victory/receipt replay grants exactly once (100x) -> `Transactions.spec`.
- Party/session/round skeleton rejects invalid states and duplicate start -> `Reducers.spec`, `Services.spec`.
- Modifier resolver never double-applies -> `ModifierResolver.spec`.
- Headless command exits 0 with a count -> `lune run lune/test`.

## Studio - Play Solo (desktop viewport 1279x720)

Steps performed through the MCP bridge (each step's captured output is quoted):

1. **Build/sync.** `rojo serve` + plugin: full tree present in Studio (`ReplicatedStorage.Shared`,
   `ServerScriptService.Server`, `ServerStorage.SFE.SystemConfig`, `ServerStorage.Tests`, client folder).
2. **Boot.** Output: `server_ready {bootMs=2 buildLabel=phase1-architecture configVersion=1 dataStoreKind=studio-memory
   debugHooks=true missingDeploymentIds=22 remotes=38}` then `profile_loaded {attempt=1 created=true issues=0 migrations=0
   userId=2588317770}`; client: `[SFE][Lobby] ambient actors=67 strands=60 tier=high`, `[SFE][Client] ready in 1417 ms`.
3. **Default test profile into the lobby shell.** Screenshot `ScreenCapture_PlaySolo_2`: cream floor disc with straw
   rim, "Sunlit Henhouse" portal frame with shimmering diorama straight ahead of spawn, Daily/Classes/Perk pedestals on
   the primary sightlines, drifting feather strands, HUD chips (Gems 0 / Tokens 0), session banner, prompt chip, Settings button.
   Server status: `activeProfiles=1 sessions=1 remotes=38`, session `phase=Lobby`, projection keys
   `classes,currencies,entitlements,inventory,permanentPerks,progression,rewards,settings,stats,tutorial`
   (no `pendingTransactions`, no `entitlementsCache`). `clientConfigBytes=14693 clientConfigHasCodes=false clientConfigHasAnalytics=false`.
4. **In-Studio tests.** `SFE_DebugInvoke:Invoke("runTests")` -> `{"total":184,"passed":184,"failed":0}` in 0.07 s
   (`workspace` attributes `SFE_TestsPassed=true`, `SFE_TestsTotal=184`).
5. **Modal / input / design-token foundation.** Settings modal opened (screenshot `ScreenCapture_SettingsModal`):
   close button 44x44, five rows 488x44, controller selection on Close. Real clicks through the input bridge toggled
   Haptics then Reduced motion via the `SettingsUpdate` RemoteFunction: server `registry accepted=2 rejected=0
   handlerErrors=0`, profile `reducedMotion=true haptics=false dirty=true`; client snapshot `reducedMotion=true
   modalsOpen=0`, selection restored (nil, as before opening). Screenshot `ScreenCapture_AfterDone`.
6. **Lifecycle skeleton on the live server.** `simulateLifecycle` trace:
   `start:Lobby, party_created:Party, countdown:Party, reserved:Round, cutscene_skipped:Round, round:Searching,
   claim:Victory, results:Results, returned:Lobby` (6.5 s wall time: two real 3 s countdowns). Analytics sent 4.
7. **Ambient scheduler / audio bus / pooled VFX cleanup.** Snapshots: before `actors=67 strands=60 heartbeat=1
   ambientInstances=60 vfxInstances=4`; after `stopLobby` `actors=0 strands=0 folderExists=false vfxInstances=4`;
   after `startLobby` `actors=67 strands=60 ambientInstances=60 vfxInstances=4`. 30 one-shot plays peaked at
   `24` active (= `polishBudgets.maximumConcurrentOneShotSounds`) and drained to `0`; camera impulse bound and
   settled. VFX instance count stayed at 4 across all snapshots (emitted 60, dropped 0).
8. **Live remote fuzz from the client.** `PartyCreate` bad enum / extra key / non-table -> `invalid_payload`;
   5 KB string -> `payload_too_large`; `EggClaim` valid schema -> `unavailable` (no Phase 1 handler);
   `SellRequest` NaN token -> `invalid_payload`; `DoAnything` -> no such remote; 12x `PartyLeave` -> 7 `rate_limited`
   (burst 5). Server: `securityRejections=13`, sampled warn `remote_rejected {code=rate_limited ...}`.
9. **Autosave.** Output: `autosave {attempted=1 saved=1}` twice during the session.
10. **Output.** Zero errors. Warnings: the sampled `remote_rejected` line (expected) and
    `[SFE][RemoteRegistry] handler error in PartyLeave: ...secret internal stack detail` emitted by the
    Registry.spec test that deliberately throws inside a handler to prove clients only receive `internal`.

## Studio - Play Solo on iPhone 17 Pro preset (874x402, viewport 750x361)

1. Device set before Play via `StudioDeviceSimulatorService` (landscape). Client: `inputMode=touch qualityTier=low
   layoutClass=phone uiScale=0.86 strands=18 actors=25` (mobile budgets applied). Screenshot `ScreenCapture_Phone_HUD`:
   HUD chips, banner, prompt (`Tap Look around / Tap Interact`), Settings button all inside the safe area, no overlap
   with the Roblox joystick.
2. Settings modal (screenshot `ScreenCapture_Phone_Modal`): on-screen sizes `X=45x45`, rows `420x45`, Done visible.
   Observation: the card uses most of the 361 px height; Phase 4 modals with more rows must use a scrolling content frame.
3. **Two profiles on one live server.** `simulatePlayerJoin(1001)` and `(1002)` through the real services:
   `outcome=loaded`, keys `player:1001` / `player:1002`, `activeProfiles=3 sessions=3`; duplicate join refused
   (`already_simulated`). Store records for the real player, 1001, and 1002 each held a lock for job
   `studio-67d0...`. `simulatePlayerLeave(1001)` -> `released=true`, record `hasLock=false saveCount=1`; same for 1002.
   Output: `profile_loaded ... userId=1001`, `... userId=1002`, `profile_released {ok=true userId=1001}`, `{ok=true userId=1002}`.
4. Stop Play. Output: `profile_released {ok=true userId=2588317770}` (PlayerRemoving path) followed by
   `shutdown_flush {failed=0 released=0}` (BindToClose found no remaining active profiles). Zero errors in Output.

## Not performed by the agent (owner protocol)

A real local server with two Studio clients ("Test > Start Server, 2 Players") was not started because the Studio
MCP bridge only drives Play Solo. To repeat the acceptance item manually:

1. Test tab -> Local Server, Players = 2 -> Start.
2. In the server window's command bar: `print(game.ServerStorage.SFE_DebugInvoke:Invoke("status"))` -> expect
   `activeProfiles=2 sessions=2`.
3. In each client window's command bar:
   `print(game.Players.LocalPlayer.PlayerScripts.SFE_ClientDebug:Invoke("snapshot"))` -> `profileLoaded=true`,
   `sessionPhase=Lobby`, distinct user ids.
4. Stop the server -> Output shows `shutdown_flush {released=2 failed=0}` (with a published place, the DataStore
   records lose their `lock` field; in Studio-memory mode the records are in-process).

## Screenshot index

| Id | Content |
|---|---|
| ScreenCapture_PlaySolo_1 | First boot (before floor/ambient fixes) |
| ScreenCapture_PlaySolo_2 | Lobby shell, HUD, drifting feathers (desktop) |
| ScreenCapture_SettingsModal | Settings modal, controller focus on Close |
| ScreenCapture_AfterDone | Modal closed, lobby idle |
| ScreenCapture_Phone_HUD | iPhone 17 Pro HUD |
| ScreenCapture_Phone_Modal | iPhone 17 Pro settings modal |

Screenshots were captured through the Studio MCP bridge and reviewed in-session; they are not stored in the
repository.
