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

---

# Phase 2 - Verification Evidence

Environment as Phase 1 (Studio, Rojo 7.7.0 serve, MCP bridge, unpublished place -> `studio-memory` store).
Build label `phase2-vertical-slice`. The Studio-only client harness (`PlayerScripts.SFE_ClientDebug`)
drives the real controllers and remotes (`autoPlay`: walk with `Humanoid:MoveTo`, gather through
`HandController:tryCollect`, trade through the crate prompt path, buy through `UpgradePurchase`, claim through
the Egg prompt path). No debug grants were used at any point; every value below came from server responses.

## Automated

| Command | Result |
|---|---|
| `lune run lune/test` | `Tests: 207 passed, 0 failed, 0 skipped, 207 total` - exit 0 (14 spec modules) |
| `lune run lune/check` | config valid (567 checks), CSV/JSON agree (74 rows), no hard-coded prices/IDs (94 files), stylua ok, selene ok - exit 0 |
| `selene src tests lune` | 0 errors, 0 warnings |

Required Phase 2 automated evidence mapping (`tests/Gameplay.spec.luau`, 22 cases):
- Cell depletion cannot double-award under simultaneous requests -> "two hits on a one-feather cell award once".
- Invalid phase/range/cooldown/capacity requests rejected -> "rejects invalid phase, stale token, cooldown,
  out-of-range origin/aim, and wrong tool"; bag_full -> "fills the bag to capacity, and never exceeds it".
- Bag never exceeds capacity -> same case (25 hits, `carried == 25`, next hit `bag_full`).
- 25 standard feathers sell for exactly 25 cents and duplicate sale pays once -> "Selling".
- Egg node valid, concealed until condition, reveals once -> "Egg" (cover cleared but depth not reached stays
  concealed; second `checkReveal` returns false; `reveals == 1`); reveal from a real hit on the last cover cell.
- 100 simultaneous claim attempts choose one finder -> "100 simultaneous claims choose one finder".
- Base reward once per present member; finder bonus once -> "Victory" (3 members, finder 2; replay of
  `commitRewards` grants nothing more).
- Reward save retry, results replay, teleport failure do not duplicate or lose reward -> "save failure holds
  the round in CommittingRewards and a later retry commits once"; "a member who left before commit is not
  granted; teleport failure never duplicates".
- Timer and personal best use server milliseconds -> "Timer and projections"; "personal best only improves".
- Tutorial transitions valid and persist by version -> "Objectives" (strict order, resume, skip, version reset).

## Studio - Protocol A (Play Solo, desktop 1608x772)

Run 1 (12 feathers per cell) was stopped after ~50 s to retune density; run 2 (6 per cell) completed the
whole journey; run 3 (same build + harness fixes) captured the reveal/claim/results screens. Values quoted
are from the bridge responses.

1. **Fresh profile.** Server projection at boot: `gems=0 wins=0 c1normal=0 hardUnlocked=false ch2=false
   tutorialCompleted=false` (studio-memory store). Screenshot `ScreenCapture_P2_LobbyFacing`: spawn faces the
   highlighted "Sunlit Henhouse" doorway (objective highlight), banner "Step onto the henhouse path".
2. **Lobby -> party -> round.** Portal prompt path -> `PartyCreate` then `PartyStart`:
   `{"ok":true,"data":{"phase":"Countdown","countdownRemaining":2.99,...}}`; 3 s later the round exists:
   `sessionPhase=Round roundPhase=Cutscene camera=LockFirstPerson pileCells=256 objective=collect_25`
   (`enter_party` completed server-side on round creation).
3. **Cutscene / skip / countdown / timer.** Screenshot `ScreenCapture_P2_Cutscene` (vignette, story beat,
   "Skip story" button, round strip). `RoundSkipVote` -> `{"ok":true,"data":{"votes":{...}}}`; banner
   "Get ready... 3" during Countdown; Searching reached with `timer=00:00.78` then `00:02.28` 1.5 s later
   (server `searchingStartedAtMs` extrapolated locally).
4. **Collect 25 and sell for $0.25.** Harness log: `sold 25 for 25 cents` (first sale), HUD `Bag 0 / 25`,
   cash `$0.25`, toast "Traded 25 feathers for $0.25"; objective advanced `collect_25 -> sell_first_bag ->
   buy_first_upgrade -> search_for_egg`. Server after 50 s: `collection accepted=84 rejected=0`,
   `selling sales=4 rejected=1` (one `out_of_range` when the harness stood too far from the crate, then retried).
5. **Starter upgrade before/after.** Workbench preview `Grasp 1 per pull -> 2 per pull, Buy $0.25`;
   `bought handGrasp -> level 1`; server `handLevels.grasp=1 upgradeCount=1`; later hits award 2.
   Screenshot `ScreenCapture_P2_Workbench` (previews old -> new with config costs: Bag 25->50 $1.00,
   Grasp 2->3 $1.00, Speed 12.5->14.5 $0.50, Hold off->0.32s $1.00; round cash shown).
6. **Visible pile deformation.** Screenshots `ScreenCapture_P2_Pile_Early` (mounds, strands streaming to the
   bag, cleared patch showing straw, puff VFX) and `ScreenCapture_P2_Pile_Mid` (half the nest cleared to the
   base). Client `pileStats.dents=571 streamed=975` after 6 min; `pileInstances` fell 1024 -> 559 as cells
   emptied (strands returned to the pool: `pilePooled=467`).
7. **Egg reveal and claim.** Run 2: server `removedFraction` crossed `eggDepthFraction=0.376` at 3:40 while
   `eggCoverCleared=false`; the reveal fired once the cover cells were cleared, the harness claimed
   (`claimed=true`), client `victoryStats {reveals=1, victories=1, results=1}`. Run 3 (harness halted at the
   reveal): server `phase=EggRevealed reveals=1 eggCoverCleared=true removedFraction=0.855` (node 23, depth
   roll 0.344 passed at ~3:16, cover cleared at 9:48); client `objective=claim_or_complete_round`, banner
   "Claim the Egg!", `audioState=Discovery`, Egg part with PointLight, `SFE_EggGlow` highlight, and the
   hold prompt (`HoldDuration=0.65` from config) 2.9 studs away. Screenshot `ScreenCapture_P2_Reveal`.
   Claim through the prompt path: `{"ok":true,"data":{"finderUserId":2588317770,"elapsedMs":618000}}`;
   an immediate second claim: `{"ok":false,"message":"already_won","code":"invalid_state"}`
   (server `egg claims=1 rejected=1`).
8. **Winner / rewards / results / lobby return.** Run 3 screenshot `ScreenCapture_P2_Results`: "You found
   the Egg - Sunlit Henhouse - normal", "Time 10:18.00 NEW BEST", contribution (1360 feathers, 216 patches,
   $13.25 cash), "Party reward: 10 Gems" and "Finder bonus: 5 Gems" on separate rows, "Unlocked: Sunlit
   Henhouse - Hard, Moonlit Cellar", "Search again" / "Back to the lobby". Client `phase=Results
   modalsOpen=1 audio=Results gemsChip="Gems 15"`; server `victory commits=1`, projection
   `gems=15 wins=1 bestMs=618000 hard=true ch2=true eggsFound=1`, store record `saveCount=3 gems=15`
   (saved before the results projection was sent). After the 15 s auto-continue (run 2 and run 3):
   `sessionPhase=Lobby`, `cameraMode=Classic`, HUD `Gems 15`, banner "Ready for another search", objective
   `complete`, Egg part destroyed, `rounds=0`.
   Server projection: `gems=15 (10 base + 5 finder) wins=1 c1normal=1 bestMs=401000 hardUnlocked=true
   ch2=true eggsFound=1 roundsCompleted=1 feathers=1033 tutorialCompleted=true`; store record
   `saveCount=2 gems=15` (saved before results); `committedTransactions=1`.
9. **Replay, second and third wins, personal best.** Round 4 (same session, same profile) started with
   `gems=15` persistent and round state reset (`cashCents=0 bagLevel=1 grasp=0`), finished in 3:15 through
   the auto-claim harness: projection `gems=30 wins=2 bestMs=195000` (best improved from 618000),
   `saveCount=4`. A Replay press 6 s after results was refused by the server minimum-display guard
   (`{"code":"rate_limited","message":"results_minimum"}`) and auto-continue returned the party. Round 5
   (node 21, depth 0.499) finished in 7:12; Replay pressed 4.5 s after results:
   `{"ok":true,"data":{"action":"replay"}}` -> lobby (`sessionPhase=Party`, camera Classic, modal closed)
   -> new round created automatically (`roundPhase=Cutscene`, `pileCells=256`, `cashCents=0`), `Gems 45`.
10. **Persistence proof (in place of a Play restart).** `reloadProfile`: `released=true
   lockClearedInStore=true`, before == after for gems/wins/best/unlocks/eggsFound/tutorial; a new round starts
   with `cashCents=0 bagLevel=1 grasp=0` (round state resets; run 3 snapshot).
11. **Output.** Zero errors across the runs. Roblox's own `AnalyticsService: LogCustomEvent event fired.`
    line was printed per event in run 2 (real adapter); the bootstrap now uses the counting adapter in Studio.

Session totals at the end of the final run (server status): `registry accepted=1889 rejected=12
handlerErrors=0`, `securityRejections=0`, `profile saves=5 saveFailures=0`, analytics `sent=346
sampledOut=1674 rejected=0` (feather_collected sampled at the configured 5%), final projection `gems=45
wins=3 bestMs=195000 eggsFound=3 roundsCompleted=3 feathersCollected=3011`. The 12 registry rejections are
harness misses (`out_of_range` when the character had not fully reached a nest-edge cell or the crate); the
server authority refused them and the harness retried. No security-pipeline rejections occurred.
