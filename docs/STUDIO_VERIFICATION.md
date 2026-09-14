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

# Phase 3 - Verification Evidence

Environment as Phase 2 (Studio Play Solo, MCP bridge, unpublished place -> `studio-memory` store), build
label `phase3-progression-tools`. Debug funds and mock entitlements came only from the secured server hooks
(`SFE_DebugInvoke`: `debugGrantCash`, `debugGrantGems`, `setEntitlement`), each one printed as a labelled
`DEBUG_*` warning in Output. Every purchase, equip, action and pickup went through the real remotes from the
client harness (`SFE_ClientDebug`: `buy`, `equip`, `toolBegin`, `toolEnd`, `sweepTest`, `sell`, `moveTo`).
Studio user id `2588317770`.

Rojo note: `rojo serve` was restarted mid-phase and the Studio plugin dropped its connection. The last edits
(network schema, spec, bootstrap, three client controllers) were pushed into the open place by source patches
whose fingerprints (byte hash + length) were compared against the files on disk after each push - all matched
- and the in-Studio suite was re-run on the patched build (see Automated).

## Automated

| Command | Result |
|---|---|
| `lune run lune/test` | `Tests: 225 passed, 0 failed, 0 skipped, 225 total` - exit 0 (15 spec modules) |
| `lune run lune/check` | config valid (576 checks), CSV/JSON agree (74 rows), no hard-coded prices/IDs (99 files), stylua ok, selene ok - exit 0 |
| In-Studio `runTests` (patched build, phone session) | `Tests: 225 passed, 0 failed, 0 skipped, 225 total (0.12s)` |

Required Phase 3 automated evidence mapping (`tests/Tools.spec.luau`, 17 cases):
- Every path purchasable to max with injected funds matching the JSON -> "acquires every tool and buys every
  path to max" (each level funded with exactly `dollarsToCents(nextCash)`, cash ends at 0, previews maxed).
- Stale / max / insufficient / duplicate / invalid tool / wrong phase never debit -> "stale level, max,
  insufficient funds, duplicate acquisition, invalid ids, and wrong phase never debit".
- Rake removes eligible cells once, discount and yield applied once -> "sweeps a 3x3 neighbourhood once per
  action" and "Rake Expert discounts Rake path costs once and boosts Rake yield once".
- Charge validates throw/fuse/radius, server RNG, no duplicate awards -> "validates throws, honours the fuse
  and radius, rolls rainbow on the server, and never double-awards"; mini-charges only from the class ->
  "Blast Artist mini-charges come only from the resolved class modifier".
- Vac blocked while overheated, config cooling/runtime -> "pulls continuously ... overheats at runtime, and
  cools for coolingSeconds"; cleanup -> "stops on death, on equip change, and when the bag fills".
- Chick cleanup on round end/death/disconnect, never awards others -> "runs server-owned trips ... pays only
  its owner in exact cents" and "cleans up on death, disconnect, and round end".
- One-round grants reset next round, mock permanent grants max upgrades -> "one-round grants vanish next
  round; mock permanent entitlements grant max upgrades every round" (also Infinite Bag through the resolver).
- Overflow policy exact -> "overflow policy: the bag is clamped and the remainder becomes a short-lived world
  bundle" (awarded 5, bundle 7, gather after selling, expiry at `overflowBundleSeconds`).
- Integer cents drift-free -> cents asserted integral in the chick, purchase and stress cases.
- Four-player stress within acceptance, no unbounded tasks -> "four players running every tool for a
  simulated minute" (600 ticks under 3 s wall, charges and chick units bounded, pile bookkeeping exact).
- Normal/Hard through config -> "Hard difficulty modifiers flow from config through the resolver".

## Studio - desktop (Play Solo, 1608x772)

1. **Funds.** `DEBUG_GRANT_CASH {before=0 after=72749}`, `DEBUG_GRANT_GEMS {before=0 after=40}` (72749 cents =
   the sum of every acquisition and path cost in `SYSTEM_CONFIG`).
2. **Purchase every path to max through `UpgradePurchase`.** 51 accepted purchases (4 acquisitions + 47 path
   levels), each `paidCents` equal to the JSON cost (e.g. `nestRake.sweep 100/200/400/800`, `featherVac.power
   600/1400/3200/7000`, `tool:featherVac 6999`, `tool:scoutChick 40 Gems`), 12 "maxed" refusals with no debit,
   cash `72749 -> 0` exactly, profile Gems `40 -> 0`, HUD `Gems 0`. Server `toolLevels` all at the JSON
   maxima; `upgrades purchases=47 acquisitions=4`. The purchase rate limit (3/s from config) throttled a
   first, unpaced loop with `rate_limited` and no debit. Screenshot `P3_workbench_maxed` (rows grouped per
   tool, "MAXED" / "OWNED" states).
3. **Nest Rake (max paths, mock Infinite Bag).** `sweepTest` from the nest centre: 23 sweeps in 16 s,
   508 feathers, cadence min/median/mean `0.650 / 0.663 / 0.665 s` against the configured hold interval
   0.62 s (network round trip on top); an earlier edge run gave 8 sweeps at `0.657-0.665 s` before the
   neighbourhood ran dry (`no_feathers`).
4. **Confetti Charge (max, then base).** 20 throws total, 20 explosions, 20 immediate re-throws refused
   (`cooldown`), one live charge at a time. Fuse measured client-side from the accepted throw to the visual
   burst: max paths `1.42-1.47 s` (config 1.40), base `2.53-2.61 s` (config 2.50). Max-power throws removed
   115 each; 36 of 230 feathers came back rainbow (15.7% against the 16% Lucky Blast max). Two max blasts
   pushed the removed fraction past the Egg depth, the round left `Searching`, and further throws were refused
   with `phase` - the Egg was then claimed through the prompt path (`elapsedMs=263000`) and Replay started
   round 2.
5. **Round reset vs permanent grant.** `DEBUG_SET_ENTITLEMENT {key=nestRakePermanent owned=true}` before
   Replay; round 2 started with `roundTools={hand,nestRake}`, `permanentTools={nestRake}`, Rake levels
   `sweep=4 cooldown=4 hold=3`, Charge/Vac/Chick levels 0 and not owned, cash `$0.00`, equipped `hand`,
   hotbar 2 slots. Screenshot `P3_workbench_acquire` (Rake rows "PERMANENT", other tools "Buy $25.00" /
   "Buy $69.99" / "Buy 40 Gems").
6. **Feather Vac (base).** `toolBegin` -> `{perSecond=8, runtimeSeconds=8, coolingSeconds=20}`; heat sampled
   every second `0.94, 1.98, 3.01, 3.95, 4.89, 6.04, 7.09, 8.00`; overheated at `8.06 s`, 63 feathers pulled
   (7.8/s), retry refused `overheated`. Server `overheatedAt=44021.02`, next accepted start `44042.64`
   (20 s cooling plus the client reacting to the `ready` event). Release stops suction with heat retained
   (`wasRunning=true heat=1.47`). Screenshot `P3_vac_running` (heat bar full, "Overheated", toasts).
7. **Scout Chick (base) + concurrent Charge.** Deploy `{moveSpeed=12.5, grasp=1, capacity=10}`; server trace
   over 22 s: `Collecting load 2..10 -> ToSeller -> Depositing -> ToPile`, trips `7 -> 8 -> 9`, owner cash
   `70 -> 80 -> 90` cents (10 feathers x 1 cent per trip) while 10 charges were thrown and exploded on top;
   21 trips by the end of the session. Screenshot `P3_charge_chick` (hotbar "Out foraging", `$0.20`).
8. **Overflow bundle (normal 25 bag).** `DEBUG_SET_ENTITLEMENT {infiniteBag false}`; one Rake sweep on a fresh
   corner: `removed=27 awarded=25 overflow=2 bag=25/25 bundles=1`, later sweeps `bag_full`, the walk-over
   gather refused while full; after selling 25 for 25 cents the walk-over gather took exactly 2 (`gathers=1`,
   bundle removed, bag `2 / 25`); server `bundlesGathered=1`.
9. **Death cleanup.** With the Vac running (heat 1.55) and the Chick out: `Humanoid.Health = 0` -> server
   `vac.running=false`, `chick.active=false units=[]`; after respawn `phase=Searching`, 5 tools still owned,
   equipped tool restored, bag `14 / 25` and cash preserved (A-RND-07).
10. **Input.** Hotbar slot `Slot_nestRake` (96x64 px) clicked through the GUI -> `equipped=nestRake`; a
    virtual `Five` key press equipped the Scout Chick before Studio refused a core-bound key.
11. **Stress scene (single client: Chick out, Charge in flight, Vac pulling, then Rake).** Client `40 fps`,
    worst frame `28 ms`, workspace `698 parts (20 unanchored)`, `3 enabled emitters`, `1046 descendants`,
    tool visual instances 6, VFX `402 emitted 0 dropped`, `2080 MB` Studio memory; server `158 Hz` heartbeat,
    `handlerErrors=0`, `securityRejections=0`. The 22 rejected remotes in the 8 s window were the walk-over
    gather retrying against a full bag; that client loop now skips a full bag (fix verified in the phone
    session: `rejected=0`).
12. **Output.** No errors across the session; only the labelled `DEBUG_*` warnings, autosaves, and the known
    `GuiService.SelectedObject` notice on modal close.

## Studio - iPhone 17 Pro preset (874x402, viewport 750x361)

Client `layoutClass=phone inputMode=touch qualityTier=low`. In-Studio suite 225/225 on the patched build.
Purchases of the three tools through the touch-scaled workbench; every visible TextButton at least 44 px
(`Buy 113x44`, `Done 419x44`, `Close 44x44`, hotbar slots `82x55`). Screenshot `P3_phone_workbench`
(grouped rows fit the safe area). Chick deployed and Vac started on the nest: `heat=2.98 running=true`
then the Vac stopped itself at `Bag 25 / 25`; screenshot `P3_phone_hud_vac` (hotbar with "Out foraging" /
"Ready", ember bag meter, touch prompts). Server `registry rejected=0 handlerErrors=0`. Device simulator reset
to default afterwards.

## Screenshot index (Phase 3)

| Id | Content |
|---|---|
| P3_lobby | Lobby at boot with the Phase 3 build |
| P3_workbench_maxed | Workbench, every tool owned and every path maxed |
| P3_workbench_acquire | Round 2: permanent Rake rows, acquisition rows with config prices |
| P3_vac_running | Feather Vac overheated: heat bar, hotbar status, toasts |
| P3_charge_chick | Charge viewmodel, Chick "Out foraging", chick cash |
| P3_phone_workbench | iPhone 17 Pro workbench |
| P3_phone_hud_vac | iPhone 17 Pro HUD with hotbar during Vac/Chick |

# Phase 4 - lobby, meta, and the feather mound

Environment: Mac laptop, Roblox Studio (Play Solo, unpublished place -> `studio-memory` store), Rojo 7.7.0 serve,
Studio MCP bridge (`ServerStorage.SFE_DebugInvoke`, `PlayerScripts.SFE_ClientDebug`). Build label
`phase4-lobby-meta`. Play-mode screen captures return blank on this laptop, so UI evidence is recorded as
measurements and the mound is photographed in edit mode from the same `PileVisualController` source (cloned
module, stubbed deps, full 16x16 grid, one delta applied).

## Automated

| Command | Result |
|---|---|
| `lune run lune/test` | `Tests: 256 passed, 0 failed, 0 skipped, 256 total` - exit 0 (18 spec modules) |
| `lune run lune/check` | config valid (609 checks), CSV/JSON agree (74 rows), no hard-coded prices/IDs (124 files), stylua ok, selene ok - exit 0 |

Phase 4 evidence mapping: `Meta.spec` (class roll odds/pity/duplicates/slots, perk levels and stale-level refusal,
daily calendar/streak/grace, code normalisation/rate/one-per-account, group reward once, inventory equip,
leaderboard bounds) and `Party.spec` (create/join/leave/leader handoff/availability/projection validity);
`PileSurface.spec` (dome field, hollows, continuous surface, ray march from outside only, server aim from the rim,
skirt hits mapped to the edge cell); `Design.spec` (motion recipes within `maximumUiTweenSeconds`, image ids,
mesh warm-up is a no-op headless); `Net.spec` (47 remotes including `PartyCancel`, `PerkPurchase`,
`LeaderboardRequest`, `PartyListProjection`, `LeaderboardProjection`, `RewardGranted`).

## Studio - desktop (Play Solo, viewport 1223x658)

1. **Boot.** Server `server_ready {bootMs=1275 meshesRepaired=1 remotes=47}`, client `ready in 2109 ms
   (meshesRepaired 1)`, lobby `actors=124 strands=80 loops=8 tier=high`, `layoutClass=desktop inputMode=mouse`,
   objective `enter_party`, HUD prompt `LMB Gather / E Interact`, station rail 8 buttons at 64x64 px.
2. **Every station modal opens through the real prompt path** (`openStation`/`stationPrompt`): party, daily,
   classes, shop, event, inventory, stats, codes each reported `blocking=true blur=14` (recipe `blurIn`), an
   initial selection inside the card (e.g. `Modal_Daily Nest...Button_Claim`, `Modal_Forager Ledger...Tabs.Button_Most
   Eggs Won`, `Modal_Sunlit Henhouse...Button_Set off alone`, `Modal_Nest Mailbox...CodeBox`), every visible
   button at least 44x44 px except the classes "Auto roll" toggle at 156x40 px (touch target check covers phones
   through the `SafeArea` scale). After closing all: `modalsOpen=0 blur=0 selected=nil`, ambient connections back to 1.
3. **Rewards through the real remotes** (`Gems 400` injected with `DEBUG_GRANT_GEMS`): `DailyClaim` day 1
   `+10` (`gemsBalance 410`), replay `replayed=true` with no second grant; `CodeRedeem ALIEN` `+200` and
   `eventTokens 200`, second redeem `already_done`, garbage code `not_found`; `GroupRewardClaim` `+25` then
   `replayed=true`; `PerkPurchase bagSize` level 1 `paidGems=25` (`1.0 -> 1.1`), level 2 `paidGems=43`
   (`1.1 -> 1.2`), the HUD chip counted up `Gems 400 -> 567` only from acknowledged projections. Server
   `rewards {daily=1 codes=1 group=1 replays=3 rejected=2}`, `perks {purchases=2 rejected=0}`.
4. **Classes.** `ClassRoll` x3 from the Class Cards modal: `rollCount=3`, owned `newcomer, eggTrader,
   blastArtist`, one duplicate refunded per policy (`duplicates=1`), equipped slot 1 `blastArtist`, odds table
   served from config (`newcomer 40% ... masterForager 0.1%`, `rollGemCost 40`, `animationSeconds 2.4`).
5. **Parties.** Three simulated members: leader handoff `1001 -> 1002 -> 1003` on successive leaves, projection
   versions `12 -> 14 -> 16 -> 17`, the party closed when the last member left; open party list emptied.
   Leaderboards refreshed 8 times on the config cadence with `writes=0 failures=0` (nothing to write in Studio).
6. **Mound (rebuilt as a dense feather mountain).** Round started from the party modal (`Countdown -> Cutscene
   -> Countdown -> Searching`). Client pile: `domeKind=mesh`, `coatKind=mesh`, 256 cells, 9,002 planned and
   placed Feather-mesh clones (`clones=9002`, 256 colliders, 1 body mesh), placed 400 per frame with no hitch,
   Feather template `MeshSize 121.97 x 322.34 x 29.05` after repair (was `0,0,0`: the cause of the giant
   feathers); lobby drift strands `0.71 x 1.87` studs. Heartbeat `16.66 ms` (60 Hz); the render sample read
   `66.7 ms` because Studio throttles an unfocused window to 15 fps (same value with the pile removed), so the
   owner reads the real frame rate in the focused window. Studio memory 4909 MB.
7. **Digging the flank.** From `z=383` four `CollectAction`s aimed at the flank (`0, 5, 390`): `sent=4 accepted=4
   rejected=0`, dents `0 -> 4`, visible feathers `9002 -> 8970` (thinned in the touched cells only, 10,047
   re-seats total), 4 streamed feathers, bag `4 / 25`; server `registry rejected=0 handlerErrors=0
   securityRejections=0`, `removedFraction 0.0025`. Walking into the mound stops at the colliders; the crown is
   reachable only by jumping the collider steps (limitation).
8. **Output.** No errors; only the labelled `DEBUG_*` warnings and autosaves.

## Mound captures (edit mode, same client source)

| Id | Content |
|---|---|
| ScreenCapture_coat_v6_front | Final coat: 6,500-budget build, feathers spill over the nest base edge |
| ScreenCapture_coat_v6_eye | Eye level: screen filled with stacked, crossed, buried and upright feathers |
| ScreenCapture_coat_v5_close | Close range: real Feather meshes stacked on each other, no body visible |
| ScreenCapture_coat_v3_eye | Rejected: procedural baked feathers (paper-shard look) |
| ScreenCapture_dome_v4_front | Rejected: smooth body with sparse shingles (owner feedback) |
| ScreenCapture_mesh_liveupdate | EditableMesh live vertex update test (body dents) |

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

# Phase 3 - Verification Evidence

Environment as Phase 2 (Studio Play Solo, MCP bridge, unpublished place -> `studio-memory` store), build
label `phase3-progression-tools`. Debug funds and mock entitlements came only from the secured server hooks
(`SFE_DebugInvoke`: `debugGrantCash`, `debugGrantGems`, `setEntitlement`), each one printed as a labelled
`DEBUG_*` warning in Output. Every purchase, equip, action and pickup went through the real remotes from the
client harness (`SFE_ClientDebug`: `buy`, `equip`, `toolBegin`, `toolEnd`, `sweepTest`, `sell`, `moveTo`).
Studio user id `2588317770`.

Rojo note: `rojo serve` was restarted mid-phase and the Studio plugin dropped its connection. The last edits
(network schema, spec, bootstrap, three client controllers) were pushed into the open place by source patches
whose fingerprints (byte hash + length) were compared against the files on disk after each push - all matched
- and the in-Studio suite was re-run on the patched build (see Automated).

## Automated

| Command | Result |
|---|---|
| `lune run lune/test` | `Tests: 225 passed, 0 failed, 0 skipped, 225 total` - exit 0 (15 spec modules) |
| `lune run lune/check` | config valid (576 checks), CSV/JSON agree (74 rows), no hard-coded prices/IDs (99 files), stylua ok, selene ok - exit 0 |
| In-Studio `runTests` (patched build, phone session) | `Tests: 225 passed, 0 failed, 0 skipped, 225 total (0.12s)` |

Required Phase 3 automated evidence mapping (`tests/Tools.spec.luau`, 17 cases):
- Every path purchasable to max with injected funds matching the JSON -> "acquires every tool and buys every
  path to max" (each level funded with exactly `dollarsToCents(nextCash)`, cash ends at 0, previews maxed).
- Stale / max / insufficient / duplicate / invalid tool / wrong phase never debit -> "stale level, max,
  insufficient funds, duplicate acquisition, invalid ids, and wrong phase never debit".
- Rake removes eligible cells once, discount and yield applied once -> "sweeps a 3x3 neighbourhood once per
  action" and "Rake Expert discounts Rake path costs once and boosts Rake yield once".
- Charge validates throw/fuse/radius, server RNG, no duplicate awards -> "validates throws, honours the fuse
  and radius, rolls rainbow on the server, and never double-awards"; mini-charges only from the class ->
  "Blast Artist mini-charges come only from the resolved class modifier".
- Vac blocked while overheated, config cooling/runtime -> "pulls continuously ... overheats at runtime, and
  cools for coolingSeconds"; cleanup -> "stops on death, on equip change, and when the bag fills".
- Chick cleanup on round end/death/disconnect, never awards others -> "runs server-owned trips ... pays only
  its owner in exact cents" and "cleans up on death, disconnect, and round end".
- One-round grants reset next round, mock permanent grants max upgrades -> "one-round grants vanish next
  round; mock permanent entitlements grant max upgrades every round" (also Infinite Bag through the resolver).
- Overflow policy exact -> "overflow policy: the bag is clamped and the remainder becomes a short-lived world
  bundle" (awarded 5, bundle 7, gather after selling, expiry at `overflowBundleSeconds`).
- Integer cents drift-free -> cents asserted integral in the chick, purchase and stress cases.
- Four-player stress within acceptance, no unbounded tasks -> "four players running every tool for a
  simulated minute" (600 ticks under 3 s wall, charges and chick units bounded, pile bookkeeping exact).
- Normal/Hard through config -> "Hard difficulty modifiers flow from config through the resolver".

## Studio - desktop (Play Solo, 1608x772)

1. **Funds.** `DEBUG_GRANT_CASH {before=0 after=72749}`, `DEBUG_GRANT_GEMS {before=0 after=40}` (72749 cents =
   the sum of every acquisition and path cost in `SYSTEM_CONFIG`).
2. **Purchase every path to max through `UpgradePurchase`.** 51 accepted purchases (4 acquisitions + 47 path
   levels), each `paidCents` equal to the JSON cost (e.g. `nestRake.sweep 100/200/400/800`, `featherVac.power
   600/1400/3200/7000`, `tool:featherVac 6999`, `tool:scoutChick 40 Gems`), 12 "maxed" refusals with no debit,
   cash `72749 -> 0` exactly, profile Gems `40 -> 0`, HUD `Gems 0`. Server `toolLevels` all at the JSON
   maxima; `upgrades purchases=47 acquisitions=4`. The purchase rate limit (3/s from config) throttled a
   first, unpaced loop with `rate_limited` and no debit. Screenshot `P3_workbench_maxed` (rows grouped per
   tool, "MAXED" / "OWNED" states).
3. **Nest Rake (max paths, mock Infinite Bag).** `sweepTest` from the nest centre: 23 sweeps in 16 s,
   508 feathers, cadence min/median/mean `0.650 / 0.663 / 0.665 s` against the configured hold interval
   0.62 s (network round trip on top); an earlier edge run gave 8 sweeps at `0.657-0.665 s` before the
   neighbourhood ran dry (`no_feathers`).
4. **Confetti Charge (max, then base).** 20 throws total, 20 explosions, 20 immediate re-throws refused
   (`cooldown`), one live charge at a time. Fuse measured client-side from the accepted throw to the visual
   burst: max paths `1.42-1.47 s` (config 1.40), base `2.53-2.61 s` (config 2.50). Max-power throws removed
   115 each; 36 of 230 feathers came back rainbow (15.7% against the 16% Lucky Blast max). Two max blasts
   pushed the removed fraction past the Egg depth, the round left `Searching`, and further throws were refused
   with `phase` - the Egg was then claimed through the prompt path (`elapsedMs=263000`) and Replay started
   round 2.
5. **Round reset vs permanent grant.** `DEBUG_SET_ENTITLEMENT {key=nestRakePermanent owned=true}` before
   Replay; round 2 started with `roundTools={hand,nestRake}`, `permanentTools={nestRake}`, Rake levels
   `sweep=4 cooldown=4 hold=3`, Charge/Vac/Chick levels 0 and not owned, cash `$0.00`, equipped `hand`,
   hotbar 2 slots. Screenshot `P3_workbench_acquire` (Rake rows "PERMANENT", other tools "Buy $25.00" /
   "Buy $69.99" / "Buy 40 Gems").
6. **Feather Vac (base).** `toolBegin` -> `{perSecond=8, runtimeSeconds=8, coolingSeconds=20}`; heat sampled
   every second `0.94, 1.98, 3.01, 3.95, 4.89, 6.04, 7.09, 8.00`; overheated at `8.06 s`, 63 feathers pulled
   (7.8/s), retry refused `overheated`. Server `overheatedAt=44021.02`, next accepted start `44042.64`
   (20 s cooling plus the client reacting to the `ready` event). Release stops suction with heat retained
   (`wasRunning=true heat=1.47`). Screenshot `P3_vac_running` (heat bar full, "Overheated", toasts).
7. **Scout Chick (base) + concurrent Charge.** Deploy `{moveSpeed=12.5, grasp=1, capacity=10}`; server trace
   over 22 s: `Collecting load 2..10 -> ToSeller -> Depositing -> ToPile`, trips `7 -> 8 -> 9`, owner cash
   `70 -> 80 -> 90` cents (10 feathers x 1 cent per trip) while 10 charges were thrown and exploded on top;
   21 trips by the end of the session. Screenshot `P3_charge_chick` (hotbar "Out foraging", `$0.20`).
8. **Overflow bundle (normal 25 bag).** `DEBUG_SET_ENTITLEMENT {infiniteBag false}`; one Rake sweep on a fresh
   corner: `removed=27 awarded=25 overflow=2 bag=25/25 bundles=1`, later sweeps `bag_full`, the walk-over
   gather refused while full; after selling 25 for 25 cents the walk-over gather took exactly 2 (`gathers=1`,
   bundle removed, bag `2 / 25`); server `bundlesGathered=1`.
9. **Death cleanup.** With the Vac running (heat 1.55) and the Chick out: `Humanoid.Health = 0` -> server
   `vac.running=false`, `chick.active=false units=[]`; after respawn `phase=Searching`, 5 tools still owned,
   equipped tool restored, bag `14 / 25` and cash preserved (A-RND-07).
10. **Input.** Hotbar slot `Slot_nestRake` (96x64 px) clicked through the GUI -> `equipped=nestRake`; a
    virtual `Five` key press equipped the Scout Chick before Studio refused a core-bound key.
11. **Stress scene (single client: Chick out, Charge in flight, Vac pulling, then Rake).** Client `40 fps`,
    worst frame `28 ms`, workspace `698 parts (20 unanchored)`, `3 enabled emitters`, `1046 descendants`,
    tool visual instances 6, VFX `402 emitted 0 dropped`, `2080 MB` Studio memory; server `158 Hz` heartbeat,
    `handlerErrors=0`, `securityRejections=0`. The 22 rejected remotes in the 8 s window were the walk-over
    gather retrying against a full bag; that client loop now skips a full bag (fix verified in the phone
    session: `rejected=0`).
12. **Output.** No errors across the session; only the labelled `DEBUG_*` warnings, autosaves, and the known
    `GuiService.SelectedObject` notice on modal close.

## Studio - iPhone 17 Pro preset (874x402, viewport 750x361)

Client `layoutClass=phone inputMode=touch qualityTier=low`. In-Studio suite 225/225 on the patched build.
Purchases of the three tools through the touch-scaled workbench; every visible TextButton at least 44 px
(`Buy 113x44`, `Done 419x44`, `Close 44x44`, hotbar slots `82x55`). Screenshot `P3_phone_workbench`
(grouped rows fit the safe area). Chick deployed and Vac started on the nest: `heat=2.98 running=true`
then the Vac stopped itself at `Bag 25 / 25`; screenshot `P3_phone_hud_vac` (hotbar with "Out foraging" /
"Ready", ember bag meter, touch prompts). Server `registry rejected=0 handlerErrors=0`. Device simulator reset
to default afterwards.

## Screenshot index (Phase 3)

| Id | Content |
|---|---|
| P3_lobby | Lobby at boot with the Phase 3 build |
| P3_workbench_maxed | Workbench, every tool owned and every path maxed |
| P3_workbench_acquire | Round 2: permanent Rake rows, acquisition rows with config prices |
| P3_vac_running | Feather Vac overheated: heat bar, hotbar status, toasts |
| P3_charge_chick | Charge viewmodel, Chick "Out foraging", chick cash |
| P3_phone_workbench | iPhone 17 Pro workbench |
| P3_phone_hud_vac | iPhone 17 Pro HUD with hotbar during Vac/Chick |

# Phase 4 - lobby, meta, and the feather mound

Environment: Mac laptop, Roblox Studio (Play Solo, unpublished place -> `studio-memory` store), Rojo 7.7.0 serve,
Studio MCP bridge (`ServerStorage.SFE_DebugInvoke`, `PlayerScripts.SFE_ClientDebug`). Build label
`phase4-lobby-meta`. Play-mode screen captures return blank on this laptop, so UI evidence is recorded as
measurements and the mound is photographed in edit mode from the same `PileVisualController` source (cloned
module, stubbed deps, full 16x16 grid, one delta applied).

## Automated

| Command | Result |
|---|---|
| `lune run lune/test` | `Tests: 256 passed, 0 failed, 0 skipped, 256 total` - exit 0 (18 spec modules) |
| `lune run lune/check` | config valid (609 checks), CSV/JSON agree (74 rows), no hard-coded prices/IDs (124 files), stylua ok, selene ok - exit 0 |

Phase 4 evidence mapping: `Meta.spec` (class roll odds/pity/duplicates/slots, perk levels and stale-level refusal,
daily calendar/streak/grace, code normalisation/rate/one-per-account, group reward once, inventory equip,
leaderboard bounds) and `Party.spec` (create/join/leave/leader handoff/availability/projection validity);
`PileSurface.spec` (dome field, hollows, continuous surface, ray march from outside only, server aim from the rim,
skirt hits mapped to the edge cell); `Design.spec` (motion recipes within `maximumUiTweenSeconds`, image ids,
mesh warm-up is a no-op headless); `Net.spec` (47 remotes including `PartyCancel`, `PerkPurchase`,
`LeaderboardRequest`, `PartyListProjection`, `LeaderboardProjection`, `RewardGranted`).

## Studio - desktop (Play Solo, viewport 1223x658)

1. **Boot.** Server `server_ready {bootMs=1275 meshesRepaired=1 remotes=47}`, client `ready in 2109 ms
   (meshesRepaired 1)`, lobby `actors=124 strands=80 loops=8 tier=high`, `layoutClass=desktop inputMode=mouse`,
   objective `enter_party`, HUD prompt `LMB Gather / E Interact`, station rail 8 buttons at 64x64 px.
2. **Every station modal opens through the real prompt path** (`openStation`/`stationPrompt`): party, daily,
   classes, shop, event, inventory, stats, codes each reported `blocking=true blur=14` (recipe `blurIn`), an
   initial selection inside the card (e.g. `Modal_Daily Nest...Button_Claim`, `Modal_Forager Ledger...Tabs.Button_Most
   Eggs Won`, `Modal_Sunlit Henhouse...Button_Set off alone`, `Modal_Nest Mailbox...CodeBox`), every visible
   button at least 44x44 px except the classes "Auto roll" toggle at 156x40 px (touch target check covers phones
   through the `SafeArea` scale). After closing all: `modalsOpen=0 blur=0 selected=nil`, ambient connections back to 1.
3. **Rewards through the real remotes** (`Gems 400` injected with `DEBUG_GRANT_GEMS`): `DailyClaim` day 1
   `+10` (`gemsBalance 410`), replay `replayed=true` with no second grant; `CodeRedeem ALIEN` `+200` and
   `eventTokens 200`, second redeem `already_done`, garbage code `not_found`; `GroupRewardClaim` `+25` then
   `replayed=true`; `PerkPurchase bagSize` level 1 `paidGems=25` (`1.0 -> 1.1`), level 2 `paidGems=43`
   (`1.1 -> 1.2`), the HUD chip counted up `Gems 400 -> 567` only from acknowledged projections. Server
   `rewards {daily=1 codes=1 group=1 replays=3 rejected=2}`, `perks {purchases=2 rejected=0}`.
4. **Classes.** `ClassRoll` x3 from the Class Cards modal: `rollCount=3`, owned `newcomer, eggTrader,
   blastArtist`, one duplicate refunded per policy (`duplicates=1`), equipped slot 1 `blastArtist`, odds table
   served from config (`newcomer 40% ... masterForager 0.1%`, `rollGemCost 40`, `animationSeconds 2.4`).
5. **Parties.** Three simulated members: leader handoff `1001 -> 1002 -> 1003` on successive leaves, projection
   versions `12 -> 14 -> 16 -> 17`, the party closed when the last member left; open party list emptied.
   Leaderboards refreshed 8 times on the config cadence with `writes=0 failures=0` (nothing to write in Studio).
6. **Mound (rebuilt as a dense feather mountain).** Round started from the party modal (`Countdown -> Cutscene
   -> Countdown -> Searching`). Client pile: `domeKind=mesh`, `coatKind=mesh`, 256 cells, 9,002 planned and
   placed Feather-mesh clones (`clones=9002`, 256 colliders, 1 body mesh), placed 400 per frame with no hitch,
   Feather template `MeshSize 121.97 x 322.34 x 29.05` after repair (was `0,0,0`: the cause of the giant
   feathers); lobby drift strands `0.71 x 1.87` studs. Heartbeat `16.66 ms` (60 Hz); the render sample read
   `66.7 ms` because Studio throttles an unfocused window to 15 fps (same value with the pile removed), so the
   owner reads the real frame rate in the focused window. Studio memory 4909 MB.
7. **Digging the flank.** From `z=383` four `CollectAction`s aimed at the flank (`0, 5, 390`): `sent=4 accepted=4
   rejected=0`, dents `0 -> 4`, visible feathers `9002 -> 8970` (thinned in the touched cells only, 10,047
   re-seats total), 4 streamed feathers, bag `4 / 25`; server `registry rejected=0 handlerErrors=0
   securityRejections=0`, `removedFraction 0.0025`. Walking into the mound stops at the colliders; the crown is
   reachable only by jumping the collider steps (limitation).
8. **Output.** No errors; only the labelled `DEBUG_*` warnings and autosaves.

## Mound captures (edit mode, same client source)

| Id | Content |
|---|---|
| ScreenCapture_dome_v4_front | Full mound on the nest base cylinder, rounded-cone silhouette, shingles |
| ScreenCapture_dome_v4_eye | Eye-level view up the flank: smooth body, tangent shingles, no grid |
| ScreenCapture_dome_v4_high | High view with the dug hollow on the near face after one delta |
| ScreenCapture_dome_fixed_front | Earlier column/cap build (rejected: visible bubble grid) |
| ScreenCapture_mesh_liveupdate | EditableMesh live vertex update test (centre lowered) |

## Not performed by the agent

- Phone preset (StudioDeviceSimulatorService) session for the Phase 4 modals: the device preset is a Studio UI
  action on this laptop; the layout classes and the touch scale are covered by `Design.spec` and the 44 px
  minimum was measured on desktop.
- Real clicks on modal buttons through the virtual mouse (owner checkpoint; in-modal presses were driven through
  `modalAction`, which calls the same routines). The classes modal roll button is at
  `PlayerGui.SFE_Modals.Modal_classes.Card.Panel.Content.Controls.RollButton` for that check.
- Controller D-pad traversal on a real gamepad.

# Map integration pass (13 Sep 2026)

Environment: the published place `xSoryn's Place: 09132026_1` (placeId 89488644743966) with the owner's
`SearchForTheEgg_Lobby` and `SearchForTheEgg_Map2` models in Workspace, Studio API access off (the server logged
`StudioAccessToApisNotAllowed` on the probe and correctly fell back to `studio-memory`), "Allow Mesh & Image APIs"
off (the mound body used its ellipsoid fallback; the coat hides it). Server `server_ready {mapMode=true remotes=52}`.

## Automated

`lune run lune/test`: 269 passed (new `PartyPad.spec`: found/join/leave through zones, independent pads, full-pad
auto start with sign countdown, modal parties untouched; `PileSurface.spec` re-based on the 1.8-stud cells).
`lune run lune/check`: OK.

## Lobby (Play Solo)

1. **Boot.** `SFE_LobbyShell` built in map mode with 36 functional/ambient instances: `PortalAnchor` (`SFE_Portal`) in
   the barn doorway, prompt anchors on the UPGRADES counter (`SFE_Station_shop`), CLASSES counter (`classes`), the
   middle leaderboard board (`stats`), the two coops (`codes`, `inventory`), the Daily Nest ring and Moonlit Chest
   on the barn floor (`daily`, `event`), four pad zones and `SFE_PadStart_1..4` on the sign posts, four feather
   drift anchors and spawn dust. Ambient: `actors=87 strands=80 loops=8`.
2. **Physical fit (measured).** Every visible prop rests on the barn floor: `DailyNestRing` bottom 2.49 on floor
   2.49, `MoonChestBody` bottom 2.50, eggs nestled 0.3 into the straw hollow, lid seated on the body; zero overlaps
   with any map part (`GetPartsInPart` against the whole map). Prompt anchors are invisible and non-colliding.
3. **Party nest pads.** Walking onto pad 1 founded a party (`Ready`, leader = player) and the map sign changed to
   `Join Match 1/4  Henhouse`; stepping off left the party (`sessionPhase=Lobby`) and the sign returned to
   `Join Match 0/4`; stepping back on rejoined; `PartyStart` from the sign post showed `Setting off in 3`, the
   round began (`Searching`) and the character stood on the map's `MapSpawn` pad at `(0, 55.1, 404)`; the sign reset.
4. **Station prompts through the real router** (`prompt(name)` debug action from each anchor's approach spot):
   shop, classes, stats, codes, inventory, portal, daily, event each opened their modal (`top` = the station id;
   portal = party). All 12 prompts sit within their 10-12 stud activation range of the approach spots.
5. The map's own `LobbyRuntime` script is disabled (place and boot); it would otherwise overwrite the same signs.

## Chapter 1 (Play Solo, map 2)

1. **Nest in the pit.** Coat built with 9,002 Feather clones (`instances=9261`), lowest feather 45.8 (pit floor 46.5,
   half-buried kind), highest 65.1 (about 13 studs above the yard), 236 column colliders rise above ground, only
   1 feather above ground past the pit opening; 135 feathers sit inside the pit's earth below ground (invisible).
2. **Digging.** From the east rim `(19, 55, 317)` aiming at the flank: 3/3 accepted; from the south edge
   `(0, 55, 334)`: 3/3 accepted (bag 6/25, 6 dents). From 16 studs back on the south path the server correctly
   refused with `out_of_range`: players dig from the rim or walk down the steps into the pit.
3. **Selling and upgrades through the real prompts.** Standing by the conveyor `(41.5, 55, 324)`, `SFE_Sell`
   reached the server and answered `nothing_to_sell` for an empty bag (in range of the processor button, 12.5
   studs). Walking through the shop door to the counter `(-44.9, 56.8, 305.8)`, `SFE_Upgrade` opened the
   workbench modal (`top=upgrades`, 4.9 studs from the counter anchor). Registry `handlerErrors=0`,
   `securityRejections=0`; the only rejection was the empty-bag sale.

## Captures (edit mode, same builders)

| Id | Content |
|---|---|
| ScreenCapture_map_lobby_spawn | Spawn view: barn portal ahead, pads with live signs, coops and stalls flanking |
| ScreenCapture_map_pad | Pad 1 with `Join Match 2/4  Henhouse` sign and the set-off post |
| ScreenCapture_map_barn_interior | Barn floor: Daily Nest (left) and Moonlit Chest (right) under the nesting shelves |
| ScreenCapture_map_pit | Farmyard: the feather mountain rising out of the pit between the supplies shop and the processor |
| ScreenCapture_map_processor | Processor with the green sell button and conveyors |
| ScreenCapture_map_supplies | Supplies counter (upgrade prompt anchor) |


# Feather pile rebuild - Verification Evidence (13 Sep 2026)

Environment: Mac laptop, Roblox Studio Play Solo (unpublished place, `studio-memory` store), Rojo 7.7.0 serve,
Studio MCP bridge. Play-mode screen captures return blank on this laptop and the Studio window is on another
desktop space, so evidence is recorded as measurements taken through the real client/server debug surfaces.
Frame-rate sampling is not meaningful here (Studio throttles a hidden window to ~14 fps regardless of the
2,322 or 6,194 pile instances measured), so it is reported as inconclusive rather than as a pass.

## Automated

`lune run lune/test`: 284 passed, 0 failed (new `tests/PileCollection.spec.luau`: duplicate request id, line of
sight, out-of-range / off-aim, full bag, exact single record + untouched neighbours, buried slot refused and
next slot exposed, id/placement determinism, delta masks, dead/left/rejoin, terrain build/dent/rewrite/hollow/
clear, fresh mound per round, Egg concealment, config validation; `Gameplay.spec`: same-feather race between two
players, exactly one per click at any grasp level). `lune run lune/check`: OK (config 714 checks, CSV, forbidden
literals, stylua, selene).

## Studio - Play Solo (desktop viewport 1223x658), two rounds

- Pile built: 512 exposed feather parts (2 per cell x 256) + 5,681 fluff strands = 6,194 instances (high);
  low tier 1,809 fluff = 2,322 instances. Coat kind `feathers`, dome kind `terrain`. Terrain mound written:
  surface 63.2 at the crown (base 47 + apex 16), 50.0 at the rim, 184 voxel cells, zero raycast misses along
  two diameters, largest 1-stud step 1.38 (walkable slope).
- Standing / walking: character teleported onto the crown stands at y 66.26 on `Snow`, velocity 0, no fall-through;
  walking to four points down and around the mound stays on `Snow` / the map floor, max speed 20.2, never below
  the base, no fling.
- No hands: `workspace.CurrentCamera` children = `AudioListener` only; zero parts named hand/viewmodel anywhere;
  hotbar keeps the Hand slot.
- Targeted pickup: reticle highlight on feather 7687 (cell 120 slot 7); one click -> 1 request, 1 accepted,
  exactly that part gone, the next record (7685) appeared in its place, 512 parts before and after, bag 0 -> 1,
  carried stack 1 feather (tier low). Server masks after the first round's four picks: exactly the picked slots.
- Rapid clicking: 12 presses in 0.49 s -> 2 requests (cooldown 0.32 s), 2 feathers. Held input without the hold
  upgrade: 1.2 s press -> 1 request. Latency 1.0 s (server hold): five clicks 60 ms apart -> 1 request, 1 feather,
  bag +1. Same-feather race (rival simulated player takes feather 9733 while the client's request is held
  0.8 s): client reply `already_collected`, bag unchanged, feather no longer shown.
- Depression: 10 picks around one spot lowered the terrain there 61.45 -> 60.61, 25 picks -> 57.77 (neighbours
  60.1 -> 57.5), 50 picks -> 56.1 (east 53.9); emptied cells dropped their fluff (5,681 -> 5,588); crown untouched
  beyond the rewrite margin.
- Bag full (25/25): three presses -> 0 requests, 3 local rejections, pile unchanged, toast "Bag full - trade
  your feathers", stack tier full (9 feathers). Sale at the crate: bag 0, stack cleared. Upgrades modal open:
  stack hidden, gameplay input suspended; closed: stack visible again.
- Mobile density: quality low -> 2,322 instances (fluff 7/cell), high -> 6,194.
- Output: no errors or warnings from SFE code in either round (DataStore Studio-access notice only).

# Crate sale run, precise picks, held bundle, mouse lock (13 Sep 2026)

Play Solo, desktop viewport 1223x658, owner map. Headless: 289 tests pass, check runner OK.

- Mouse lock: lobby and Searching `LockFirstPerson` + `LockCenter`, icon hidden; cutscene and the
  Settings modal `Classic` + `Default`, icon shown; relocked after close. Bundle hidden behind the menu.
- Nest relocated: coat spans x -15..14, z 357..386 (centre 0, 372), zero parts within 20 studs of the
  pit; terrain crown 68, no terrain in the pit or on the conveyor exit line.
- One pick: 1 part gone, 1 new record exposed, 0 other feathers moved, 36 fluff strands of that cell
  settled 0.5 studs, 7,702 parts identical; bag 0 -> 1, bundle 1 feather.
- Targeting: 19 of 20 random reticle points on the mound yield a target (bed clicks resolve to the
  cell's top feather); 12 rapid picks accepted in 12 attempts.
- Sale: 7 feathers -> $0.07, bag 0, bundle cleared, 7 feathers shown inside the crate; the crate rode
  the front belt (z 341 -> 320 at 7 studs/s), through the processor, west along the side belt
  (x 42 -> 15.7), across to the pit (y 57.9 -> 49.5), and was back home at 12.6 s; rollers turned.
  Sale attempts while away: `nothing_to_sell` x4 (empty), `crate_busy` with 3 feathers kept; after the
  run the sale succeeded ($0.14 total); three runs, none overlapping.
- Output: no SFE errors.

## Coat coverage and bundle fit (13 Sep 2026, follow-up)

- Coat parts seat on max(smooth field, voxel surface) at build; terrain inset 1.6 studs; bed 44
  strands per cell in 4 layers plus a 1,600-strand rim bed that spills 1.2 studs past the foot.
  Coverage from above over the footprint: 26 of 560 rays met terrain before the previous rim fix, all
  on the ground-level skirt; after the rim bed the edit-mode render shows no core from a 3/4 view.
- One pick: 1 part removed, 1 exposed, parts before/after 11,820 -> 11,821 (the flying feather).
- Bundle frame 232 x 153 at (973, 355) in a 1223 x 658 viewport, all feather corners inside the
  viewport camera frustum; size follows 19 % of the viewport width clamped 130..260 px.

## Invisible shell, feathers all the way down (13 Sep 2026, follow-up 2)

- Collision is now `pile.collision.kind = "parts"`: 256 anchored, invisible, non-queryable boxes
  (one per cell, tilted to the slope, 1.3x overlap, top face 0.3 under the coat). No terrain is
  written (0 voxel cells). Character stands on the crown at y 70.7 and walks down to 63.6 on the shell.
- Only feathers are visible: rays from above over the footprint hit a coat part first in 477 of 478
  cases (the one miss is at the foot ring), 144 of 144 from the sides at six heights.
- Bed strands sit in four depth bands (0, 0.9, 1.8, 2.8 studs) so a dug cell shows feathers on its
  walls and floor. One pick: 1 record gone, 1 exposed, 0 other feathers moved, 51 bed strands of
  that cell settled 0.34 studs, 13,403 parts unchanged; bag 0 -> 1.

## Full-depth columns and the buried Egg (13 Sep 2026, follow-up 3)

- Every cell now holds records from the floor to the dome (`pile.recordSpacingStuds` 0.55): 3,369
  records this round, 1 at the rim to 32 at the crown (mask cap), crown cell 23.
- Digging: 60 picks around the crown lowered its column 3.4 studs; the pit floor is a feather part and
  rays from the pit centre at the exposed heights hit feather parts on every side (wall strands are
  added on newly exposed faces, never moved or removed). Pile stats: fluff 12,967 -> 13,231 (walls added),
  exposed feathers 477 -> 476.
- Egg: server placed it in cell (5, 12) at slot 15 of 32 (5.1 studs above the ground, ~10 below the
  surface), invisible and absent from the workspace. With the 3x3 dug to its height and one covering
  record left, picking exactly that record (id 12687) revealed it at (-4.5, 57.7, 380.1) inside the hole;
  phase EggRevealed. One pick still awards exactly one.

## Frozen bed and packed layers (13 Sep 2026, follow-up 4)

- Coat: 477 exposed records + 17,220 bed strands (60 small strands per cell in three shallow bands,
  2,400 rim strands); 17,697 instances. From above over the footprint 747 of 749 rays meet a feather
  first; from the sides 283 of 283.
- One pick: 1 record gone, 0 parts moved, 17,695 unchanged, 29 added (the next record plus fixed
  floor/wall strands at the new depth). Bag 0 -> 1.
- Digging one column: 25 of 25 rays down into the pit and 12 of 12 angled looks from its rim hit
  feathers, never the ground. Nothing in the coat moves after placement.

## Wider double-sided feathers, four offset layers (13 Sep 2026, follow-up 5)

- Feather vanes render both faces (`DoubleSided`), so flat strands no longer vanish at grazing angles.
- Bed strands are 1.2-2.2 long and 0.9-1.6 wide, tilted 4-34 degrees, in four offset layers (0, 0.35,
  0.7, 1.05 studs deep), 64 per cell; no shrink toward the rim. 20,064 instances at high tier.
- Judged from a first-person camera at the base of the flank looking up the slope (edit render of a
  fresh build with a 2x2 hole dug 12 records deep): solid feathers from foot to crown, no ground or
  sky between them.

## Underlayer sheets (13 Sep 2026, follow-up 6)

- Two gridded sheets of small flat feathers (5x5 at 1.3 studs deep, 4x4 at 1.75 deep, the second
  offset half a step) sit under every cell's bed: 29,971 instances at high tier. Close-up render from
  2.6 studs off the flank surface, looking down the slope, after a 2x2 hole dug 40 records: feathers
  behind every crack, no ground, sky, or darkness.

## Real feather mesh restored (13 Sep 2026, follow-up 7)

- Root cause: the Rojo-synced `SFE_Assets.Feather` MeshPart had an empty MeshId (rbxm strips it), so
  every clone rendered as its blank bounding box - the grey angular shards. `AssetManifest.warm` now
  rebuilds the mesh from a hard-coded id (feather rbxassetid://439102658) and applies it in place with
  Automatic LOD + double-sided. Verified in Play: template healthy at client boot (meshSize
  121.97/322.34/29.05), 14,723 rendered parts all real meshes, 0 blank boxes.
- Density lowered to premium levels (~19.7k at high tier with the real mesh, Automatic LOD): from the
  gameplay eye at the flank base, no ground or sky between feathers; digging a pit reveals more
  feathers.
- One pick unchanged: 1 record removed, 0 parts moved, 14,722 unchanged, bag +1.


## Follow-up: exact-cursor pick and the 12-feather carried stack (13 Sep 2026)

Commits 524cac8, 24396bf, 8fd3f43, d7f555d, b20f3b6. Verified in Studio Play (three fresh rounds,
`SFE_ClientDebug` automation, place 89488644743966).

- **Exact pick.** The pick ray starts at the camera through the crosshair (the locked mouse sits on it;
  a free mouse aims through its own position; touch/gamepad use the centre) and is resolved at the
  instant of the click. The first part it meets must carry `SFE_FeatherId`; cosmetic strands no longer
  answer the ray and a hit on the ground targets nothing. Three runs: highlighted id 13836 (cell 216)
  -> server hit cell 216, 1 part removed, 0 parts moved; id 14859 (cell 232) -> cell 232, 1/0; id 13836
  -> cell 216, 1/0.
- **Records seat by slot** on both client and server (`FeatherLayout.seatOffset`), 12 per cell rendered
  and collectible. Two server probes had to stop treating the invisible collision shell as geometry
  (a colliding part is always queryable): before that fix, follow-up picks on a dug cell were refused
  with `aim` (9/11) and then `line_of_sight` (10/11); after it, 14/18 aimed picks accepted with zero
  server rejections (the 4 were client `no_target` on already-dug aim points).
- **Pickable surface** from the gameplay eye: a 21x21 ray grid over the mound met a record on 392 of
  400 rays (the 8 misses were the freshly dug hole).
- **Carried stack.** Bag 2/25 -> 1 feather, 4 -> 2, 6 -> 3, 8 -> 4, 10 -> 5, 12 -> 6, 14 -> 7, 24 -> 12
  (`ceil(fullness * 12)`). Infinite bag (`setEntitlement infiniteBag`): counter reads `Bag 26 / Infinite`
  while the bundle shows 7 = `floor(1 + 11 * ln(26) / ln(200))`. Every bundle feather projected through
  the viewport camera at 12 feathers stays within 87% of the frame's half-extents (no cropping); the
  frame sits 18 px inside the right edge and 92 px above the bottom of the safe-area gui (1223x600).


## Follow-up: nothing cosmetic, everything pickable (13 Sep 2026, later)

Commits c3bd219 .. bdc58c0. Owner direction after the exact-pick work: the mound looked thin once the
bed was sunk, and a strand under the dot that is not the outlined one is unacceptable - "nothing
should be cosmetic, everything should be pickable".

- **Grid** 32x32 columns of 0.9 studs (was 16x16 at 1.8), records 0.45 studs apart, 15,916 records
  in a chapter-1 mound, twelve rendered per column on desktop (9,703 parts) and four on the low tier.
  Bed, underlayer, rim bed and wall/floor filler are off; the pile folder holds only `Feather`
  records (0 blank meshes in a 3,000-part sample). Edit-mode render from the near flank: solid,
  layered coat with no ground visible.
- **Reticle** drawn on the raw viewport centre (611,329 of 1223x658), where the locked mouse and the
  pick ray are; previously the inset-adjusted gui centre sat it below the aim point.
- **Exact pick**: a box test over every part on the crosshair ray found the outlined record first
  (`firstVisibleIsTarget = true`); the server hit the same cell (909); 1 part removed, 0 moved,
  1 added (the next record entering the window); bag +1.
- **Regressions checked in the same Play round**: 22 of 22 aimed picks accepted with no rejection
  codes; stack 2..12 tracked bag 3..23 of 25 exactly; settings menu unlocks the mouse (Default +
  icon, stack hidden) and re-locks on close; sale of 23 feathers started the crate run and cleared
  the bag and the bundle; camera stayed LockFirstPerson; 295 headless tests pass.


## UI rebuild (13 Sep 2026)

Commits "UI rebuild 1/5" (foundation) through "4/5" (screens) plus the fixes that followed. Verified
through the edit-mode UI probe (`docs/studio/ui_probe.luau`, Play-mode `screen_capture` is blank on
this laptop) at desktop (Studio viewport), phone (812x375 override, touch mode) and tablet (1024x700).

- **Foundation.** Tokens retuned to warm cream / feather-white / gold / soft brown with teal accents;
  vector icon kit; frame kit (cream panels in gold bevels, nameplate pills, badges, animated meters);
  button states hover / press / release / selected / disabled / pending / focus with per-state art;
  tabs, switch, confetti, dialog; modal shell (lift-in, content-sized card, ambient sheen, art close
  button and leaves); toasts with tone glyphs; built-in UI sounds with pitch and per-role throttles.
- **Art.** 136 of the 152 PNGs in `/ui` uploaded and mapped in `AssetManifest` with nine-slice rects
  (2x export, sliceScale 0.5). Left out: `modal.card` and the toast backgrounds (teal fills), the
  `stack.*` pictures (the bundle is a live viewport), the duplicate `button.gold` set and the ripple.
- **HUD.** Iconed currency chips, art banner (pops on objective change), keycap prompt (hidden on
  touch), round gear button, art reticle that locks/grows on a target plus a hold ring, round strip
  with art bag fill and a FULL - DEPOSIT state that breathes only while full, floating cash deltas,
  hotbar slots with tool art / keycap hints / tone bars, sale popup with count-up and confetti,
  loading veil, settings modal with switches and quality tabs.
- **Screens.** Shop cards (affordable / dimmed / MAX), class cards with rarity art per state, daily
  cells with a pulse only on the claimable day, codes box with idle / focused / error art and shake,
  inventory tool rows, stats tiles + tab strip, party destinations with locked / unavailable art and a
  leave confirmation dialog, workbench rows, victory plate + results confetti, cutscene caption plate,
  station rail pressed art while open and a Daily pulse when claimable.
- **Layout rules found on the way.** No AutomaticSize on frames with scale-sized shadow/art children
  (size from TextBounds); UIPadding on a Content child, not on the art holder; UIStroke on text objects
  needs `ApplyStrokeMode.Border`; a fitted nameplate must not truncate.
- **Checks.** 295 headless tests pass; selene / stylua clean. Emulation captures showed no overlap or
  cropping on phone (strip + hotbar in the centre band, bundle above the jump button) or tablet.

- **Follow-ups (same day).** Custom proximity prompts (server prompts are `Style = Custom`, the
  client PromptController draws a cream billboard with keycap / object / action / hold fill; verified
  at the Perk Bench: billboard with art, key `E`, "Perk Bench" / "Open the shop", gone after leaving).
  Round strip and hotbar scale down together on narrow viewports (`emulate(600, 800)` gave band scale
  0.6, strip 271 px). Owner sound ids wired: click, hover, denied, pickup, purchase, upgrade, sell,
  queue all preload; the music loop `132601187837139` is not shared with the experience yet ("Click
  to share access" in the Studio output), so it stays silent until the owner grants access.
  Camera: first person only in Countdown / Searching / EggRevealed; the lobby is Classic (zoom
  0.5..28) with the cursor visible; menus free the cursor in both modes (verified per phase).
  Note: after the edit-mode probe renamed `ReplicatedStorage.Shared`, Rojo stopped delivering that
  subtree to Studio; `Tokens` was patched in place and the Rojo plugin should be reconnected before
  the next `Shared` change.

## UI v2 "cookie" re-skin (14 Sep 2026)

The owner rejected the pasted-kit look ("everything about it screams UI pack"). Every screen was
re-drawn as vector "cookie" UI: cocoa outline, bottom lip, cream panel with a faint studs weave, gold
header band with rays and an outlined FredokaOne title, lipped buttons whose face drops 4 px on press,
teal only as an accent. The pack's frame art is retired (`Skin.frameArtEnabled = false`); icons,
station tiles, glyphs and the two textures stay. Verified through the edit-mode probe at the Studio
viewport (939x659) and the 812x375 phone override, touch mode:

- **Round HUD.** Timer / bag / cash chips, bag fill with the ember FULL state, hotbar tiles with the
  status text on a cream band over the bar, keycap prompt only while Searching / EggRevealed, toasts
  hug their text under the banner.
- **Lobby.** Station rail with hover nameplates (title rises above the tile); the prompt chip no
  longer sits on the rail.
- **Modals.** Shop, classes, daily, settings (tabs share the track, lipless faces), party (wide card
  at 0.9 / 860 px, empty member and party lists hidden, action buttons fill the row), stats
  (friendly leaderboard tab names before the snapshot arrives), codes (feedback line only when set),
  tool rack (two-line rows, Moonlit Chest badge, gold stroke when equipped), workbench (level pips,
  current -> next detail, price on the button, MAX / OWNED badges). Phone: the shop card scrolls
  inside 90 % of 375 px with no cropping.
- **Play pass.** Console clean apart from the music asset permission. The dropped pack
  `StarterGui.ScreenGui` is disabled and its `LocalScript` is now disabled too: it installs a
  `UIBlur` in Lighting and hides every other ScreenGui when one of its frames opens.
- 295 headless tests pass; selene / stylua clean.

## Lobby vendors, barn displays, Perk Shop and Class Cards (14 Sep 2026)

Owner brief: bring the lobby and its two shops up to the reference screenshots without copying
their branding, keep every price and server rule. Verified in Play Solo (map mode, mock Marketplace)
and through the edit-mode UI probe at the Studio viewport and the 812x375 phone override.

- **Lobby.** Drifting feather strands off in the lobby (`SFE_LobbyShell actors=9 strands=0`; the
  arena keeps its 80). The bottom station rail is gone; the only permanent menu is a right-hand
  stack of Stats, Inventory and Codes tiles with names beneath. Party, Daily, Chest open from the
  world as before.
- **Vendors.** The owner's `Cow Boy` (Classes stall) and `Cow Boy Brother` (Upgrades stall) rigs
  host the `SFE_Station_classes` / `SFE_Station_shop` prompts ("Class Master / Roll a class",
  "Perk Seller / Browse permanent perks"), wear a nameplate with a role pill, breathe, turn to face
  the player within 22 studs, greet with a speech bubble while the prompt shows ("Perks bought here
  stay with you on every search, friend!") and say "Take a good look!" on interact. The stall
  signs are retitled at boot: PERMANENT PERKS / UPGRADES THAT STAY WITH YOU and CLASSES / ROLL YOUR
  STYLE. Interact opened "Perk Shop" with `MouseBehavior = Default` and the cursor visible.
- **Barn displays.** `FeatherBag` and `InfiniteBag` sit on the FEATHER SUPPLIES counter,
  `Pitchfork` and `Dynamite` on the two rear-wall display boards, each with a price card (name,
  price or OWNED / MAX, caption) and a `SFE_Display_<key>` Buy prompt (8 studs). Cards read the round
  previews: `$1.00 | Lv 2 - holds 50` -> bought through the display -> `$2.00 | Lv 3 - holds 100`
  with the "Upgrade Bag improved" toast; the Infinite Bag showed `R$ 99` then, after the
  `PurchasePromptRequest` and the mock pass completion, `OWNED | Your bag never fills`. The controller
  rebuilds cards as the barn streams in (StreamingEnabled place).
- **Commerce.** `CommerceService` is now constructed; `PurchasePromptRequest` and
  `ProductCatalogRequest` are served; grants push a projection. In Studio with missing deployment
  ids the server uses `ProductMap.studioMockDeployment` + the mock Marketplace, and prompts complete
  themselves after 1.2 s so the pipeline can be exercised.
- **Perk Shop.** Header "Perk Shop", subtitle "Permanent Player Perks", gem balance chip with "+",
  2 x 2 illustrated perk tiles (tinted face, art on a sunburst, level pips, `Lv 2 · +20% -> +30%`,
  gem-purple price button, MAXED badge), a Robux column (100 / 400 Gems with a POPULAR ribbon, 2x
  Gems, Infinite Bag; OWNED badge when entitled) and a red Close. Purchases pop the tile, light the
  new pip and shower confetti.
- **Class Cards.** Deck of eight rarity-tinted rows (art, name, odds bar, lock / check), spotlight
  with arrows, rarity badge, sunburst emblem, `Spin - 40 Gems`, `Auto: Off`, 2x Luck / Fast Rolls
  pass buttons, and a side panel with stacked slot chips (`Slot 1 - Newcomer`, `+1 Slot R$ 119`),
  story, bonus line, odds and Equip. A spin sweeps the deck and flickers the spotlight, decelerates,
  and lands with a pop, confetti and the result pill ("New class: Gem Seeker!"). Phone: two columns
  with the side panel below.
- **Workbench.** Rows carry large item art on the left; purchases flash the row, hop the button and
  burst confetti.
- 295 headless tests pass; selene / stylua clean. Console clean apart from the music asset permission.

## Hierarchy pass: Stats, Tool Rack, Perk Shop, barn (14 Sep 2026)

Owner brief: less text, bigger art, chunkier cards, stronger colour per menu; barn displays at eye
level. Verified in the edit-mode probe (Studio viewport) and Play Solo.

- **Stats.** Teal header with the player's headshot, display name and TOTAL PLAYTIME; six tinted
  picture cards (CLASS, TIME RECORD, EGGS WON, FEATHERS, EGGS FOUND, SEARCHES) with big art and a
  single value; leaderboard tabs with medal-coloured rank badges. The ledger tiles and refresh line
  are gone.
- **Tool Rack.** Four tool tabs (Rake / Charge / Vac / Chick) over big square skin cards: art, a
  one-word name strip, a green check when equipped, LOCKED over unowned skins (event skins tinted).
  Tap a card to equip; a locked card shakes and toasts. Red Close.
- **Perk Shop.** PERMANENT PERKS title only; taller tiles with larger art, an `LV 2 · +20%` badge
  above the pips and one title-size price button. Offers: big art, giant `R$` button, POPULAR and
  PERMANENT corner tags, no captions.
- **Barn.** Rear display boards lowered to y 60.2; pitchfork on the left board, dynamite on the
  right; both bags scaled to 0.8 on the counter at x -47 / -36.5. With the player's eye at y 58.3 the
  items span 55.9-64.5 and the cards read name + price only (`Nest Rake | $8.00`, `Infinite Bag |
  R$ 99`); states (OWNED / MAX) keep a one-line caption.
- Tiles carry a 4 px cocoa outline everywhere (`FrameKit.tile`). 295 tests, selene / stylua clean.

## Egg depth, live product ids, music loop (14 Sep 2026)

- **Egg spawn.** `minimumRemovalFraction` 0.2 -> 0.45 (max stays 0.65); new `luckyRoundChance`
  0.09 with `luckyMinimumRemovalFraction` 0.1; spawn nodes weighted by distance to the mound's
  core (`coreNodeWeight` 3, `edgeNodeWeight` 1). Simulated 200k rounds: mean depth fraction 0.534,
  9.0 % lucky, 3.3 % found under 30 % dug. A Play Solo round drew `eggDepthFraction 0.643` on
  `chapter1:node_12` (core). Hard keeps its own 0.45-0.8 window.
- **Product ids.** All 9 passes and 10 developer products filled in `ProductIds.luau`; only the
  three place ids are missing, so Studio still runs the mock Marketplace. Test updated to assert
  every pass and product resolves.
- **Music.** Loop `130291967851605` (122 s) loads and plays: `Music_Lobby playing=true vol=0.45`,
  and after setting off `Music_Search playing=true` picked up at the same position (18.9 s ->
  26.8 s eight seconds later), so the loop runs continuously across lobby, search, discovery,
  victory and results. Fixed on the way: `setState` only started a stem when its target volume
  was exactly 1, so no stem had ever started.
- Rojo plugin was disconnected during this pass; the six changed sources were patched into Studio
  directly and match the repository.
