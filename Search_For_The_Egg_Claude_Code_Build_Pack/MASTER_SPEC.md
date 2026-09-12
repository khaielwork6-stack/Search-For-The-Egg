# Search for the Egg - Master Implementation Specification

Version: 1.0  
Evidence snapshot: 12 September 2026  
Status: Approved for phased implementation with centralized `ASSUMED` values

## 1. Document authority

This file is the implementation source of truth for Claude Code. Resolve conflicts in this order:

1. The user's latest explicit instruction.
2. `MASTER_SPEC.md` for behavior and architecture.
3. `SYSTEM_CONFIG.json` for values, IDs, feature flags, prices, rewards, and thresholds.
4. `STATE_MACHINES.md` for transitions and invariants.
5. `DATASTORE_SCHEMA.md` for persistence and transaction rules.
6. `TEST_PLAN.md` for acceptance evidence.
7. `ASSUMPTIONS.md` for provenance and changeability.
8. `ECONOMY_TABLES.csv` as a balancing view of the JSON; if values disagree, stop and report the conflict.
9. `FINAL_GDD.pdf` for human-readable intent and presentation.

Claude Code must read the entire pack before modifying the repository. It must inspect the existing codebase and preserve healthy systems. No phase authorizes a full rewrite.

## 2. Product definition

`Search for the Egg` is a cozy first-person Roblox collection and hidden-object game. Players enter compact, richly animated environments containing enormous feather piles or nests. They physically clear feathers, fill a personal bag, sell feathers for round cash, buy stronger collection methods, and search for the hidden Egg. The first valid Egg discovery ends the party's round, awards progression, and returns the party to the lobby.

The target pursues close functional parity with the observable structure of Search For The Needle while using entirely original branding, world construction, art, UI, models, animation, audio, text, and code.

### Core fantasy

“I am digging through an impossibly large living nest, getting visibly stronger every minute, and any removed feather could reveal the Egg.”

### Player promise

- Immediate tactile feedback from the first click/tap.
- A legible short-term target: fill, sell, upgrade, search deeper.
- Constant visual proof that the party is changing the pile.
- Suspense from a concealed server-selected Egg position.
- A concise, premium discovery and victory payoff.
- Persistent reasons to return: wins, best times, classes, daily rewards, cosmetics, Hard mode, and Chapter 2.

## 3. Non-negotiable principles

### Server authority

The server decides pile cells removed, feathers awarded, bag limits, sale value, cash, upgrade eligibility, tool ownership, cooldowns, RNG, Egg position, winner, time, rewards, unlocks, receipt grants, and saved data. Client-side prediction is cosmetic.

### Configuration first

All tunable values must originate from a typed configuration module generated or manually mirrored from `SYSTEM_CONFIG.json`. Services may cache resolved values; they may not restate literals. Product IDs are deployment-specific and must be provided through a separate secrets/deployment mapping, never guessed.

### Assumption visibility

Unverified behavior is allowed and required to unblock production. It must be marked `ASSUMED` in docs/config and isolated behind policies or values that can be changed without architectural surgery.

### Premium from Phase 1

Polish is not a Phase 6 paint job. Each vertical implementation includes responsive input, animation timing, audio cue, VFX cue, camera/UI response, ambient world behavior, quality scaling, and cleanup. Phase 6 unifies, measures, replaces placeholders, and optimizes these layers.

### Original expression

Do not copy reference assets, layouts pixel-for-pixel, code, map geometry, character names, UI text, icons, audio, or models. Functional behaviors may be reconstructed; expression must be original.

## 4. Experience structure

### Places

Preferred production structure:

1. Lobby place: social/meta hub, party formation, shops, classes, rewards, inventory, stats, chapter selection.
2. Chapter 1 place: Sunlit Henhouse.
3. Chapter 2 place: Moonlit Cellar.

During early development these may coexist in one test place behind adapters. The architecture must not assume same-place travel. Teleport data contains opaque reservation/session identifiers only.

### Server sizes

- Lobby: maximum 20 players.
- Round party: 1-4 players.
- One authoritative round per reserved gameplay server unless profiling proves safe multi-round hosting.

### Chapter 1 - Sunlit Henhouse

A warm barn/henhouse centered on a huge sculpted nest. A collection/selling character or station sits across a short movement lane. Upgrade stations form an intuitive loop around the nest. Windows, fans, hanging cloth, pecking birds, floating dust, drifting feathers, moving belts, and distant farm activity make the space alive without obscuring interactions.

Chapter objective: clear the nest, expose the hidden Egg, and claim it first for the party.

### Chapter 2 - Moonlit Cellar

An original subterranean hatchery/cellar. The party searches feather and nesting debris for a hidden key, activates three mechanisms, solves three compact shared puzzles, releases a trapped hatchling, and exits with the Egg. The public reference structure is inspiration for functional pacing only; all layout, story, puzzle presentation, symbols, models, and copy must be original.

## 5. Player journey

### First session

1. Load profile and entitlements before interactive spawn.
2. Spawn facing the primary chapter portal and visible Daily reward cue.
3. Display one concise objective: create/join a Chapter 1 Normal party.
4. Party start -> reservation -> teleport/load.
5. One skippable 18-second story scene establishes the lost Egg.
6. Tutorial asks the player to collect 25 feathers.
7. Bag fills, sell station highlights, player sells.
8. Upgrade board highlights; player buys a starter upgrade when affordable.
9. Tutorial collapses into the standard objective: “Search the nest for the Egg.”
10. The player cycles collection, selling, and upgrades.
11. Covering cells reveal the Egg; a positional chime and glint create the discovery moment.
12. Claim -> winner announcement -> committed rewards -> results -> lobby.
13. First win unlocks Chapter 1 Hard and Chapter 2 Normal through configuration policy.

### Short-session loop

Lobby -> party -> chapter -> collect -> sell -> upgrade -> reveal -> win -> rewards -> replay/lobby.

### Long-term loop

Earn wins/Gems/tokens -> roll and equip classes -> improve permanent perks -> unlock chapters/difficulties -> improve best time -> collect original tool cosmetics/event rewards -> return for daily/event cadence.

## 6. Core round design

### Timer

Timer counts upward from the authoritative `Searching` start timestamp. Display hundredths only where it improves time-record excitement; server stores integer milliseconds. Cutscene/countdown time is excluded.

### Pile model

Do not construct the pile from thousands of networked physical feathers. Use two layers:

1. Server logical grid/volume: roughly 256 cells, each with bounds, remaining density/health, region, and optional spawn-node coverage relationship.
2. Client visual layer: pooled meshes/strands and surface chunks driven by cell snapshots/deltas.

The server accepts an action origin/direction/tool ID, identifies valid nearby cells, removes an allowed amount, and returns deltas plus awarded counts. Clients animate strands, chunks, compression, particles, and small debris. Collision must remain simple and stable.

Requirements:

- Removed volume is visible and persistent to the party.
- New clients receive a snapshot then deltas.
- Simultaneous hits cannot award the same cell content twice.
- Cell removal and award calculation are atomic within the round service.
- Mobile visual density is lower without changing authoritative yield.
- Egg cover is defined by logical cells, not unreliable touch events.

### Bag

Starting capacity is 25. Normal collection clamps to free space. Tool-generated overflow becomes short-lived server-owned collectible bundles if enabled, otherwise only the fitting amount is awarded. Never display impossible values such as 139/25 as normal bag state.

Bag capacity is calculated in this order:

```text
roundBagLevelCapacity
* permanentBagPerkMultiplier
* classBagMultiplier
or Infinite Bag entitlement override
```

Round displayed capacity is floored to an integer. Infinite capacity uses an explicit state, not an enormous sentinel exposed to UI.

### Selling

Interact with the selling station to exchange all personal carried contents. The server computes integer cents and returns a transaction result containing counts, modifiers, and final cents. UI animates bag decrement and cash increment from that result.

### Egg spawn and reveal

At round bootstrap, the server selects a validated chapter spawn node using the configured weighted policy and recent-node protection. Nodes define transform, cover cells, reveal camera anchor, and allowed depths.

The Egg remains non-interactive and visually concealed until its cover condition is met. On reveal, join is closed and the party sees a synchronized but quality-scaled cue. The first valid claim wins atomically. A party receives shared base rewards; the finder receives the configured personal bonus.

### Victory

Use the standard assumed flow exactly:

`Egg discovered -> winner announcement -> round rewards -> results screen -> return to lobby -> progression saved`

Reward persistence is committed before teleport. If saving is delayed, keep the results scene alive with a polished “Securing rewards...” state. Never show a paid or earned reward as final based only on a client animation.

Results contain:

- Winner/finder.
- Chapter and difficulty.
- Authoritative completion time.
- New personal best marker.
- Individual contribution.
- Base reward and finder bonus separated.
- Newly unlocked content.
- Replay and Lobby actions.

## 7. Tutorial and objective system

Objectives are server-approved state IDs with localized client copy. They are not raw server strings.

First-run steps:

1. `enter_party`
2. `collect_25`
3. `sell_first_bag`
4. `buy_first_upgrade`
5. `search_for_egg`
6. `claim_or_complete_round`

Tutorial highlights one target at a time, never covers the reticle/action area, respects safe areas, and survives character respawn. It can be skipped after the story setup; completion state persists by tutorial version.

## 8. Tools

Target tools use original names and presentation while preserving distinct roles.

### Hand

Free baseline. Responsive short reach, exact server cooldown, local hand animation, contact puff, feather tug, and subtle haptic. Paths: Grasp, Speed, Hold.

### Nest Rake

Deep discrete extraction. Slower cadence, wider/deeper server query, larger sculpted dent, weighty anticipation and recovery. Paths: Sweep, Cooldown, Hold.

### Confetti Charge

Burst area clearing. Light, throw, fuse, explosion, surface displacement, optional rainbow conversion. Server owns charge/fuse/affected cells. Paths: Lucky Blast, Speed, Power. Visual theme is playful paper/confetti pressure rather than copied explosives.

### Feather Vac

Continuous surface collection with runtime/heat and forced cooling. Server integrates allowed suction over time; client smooths beam/strand motion and meter. Paths: Power, Cooling, Runtime.

### Scout Chick

Autonomous helper that travels to the nest, fills its own capacity, returns to the seller, and deposits value for its owner. Server chooses cells and grants output. Client renders smoothed motion and personality animation. Paths: Speed, Grasp, Capacity.

### Acquisition and reset

- Soft-currency and one-round Robux acquisition lasts for the current round only.
- Permanent entitlement grants the tool automatically at round start and currently assumes max tool upgrades.
- Every rule is centralized in configuration.
- Product ownership is server-checked.

## 9. Progression and difficulty

### Round progression

Cash is round-scoped. Players buy Hand, Bag, tool access, and tool upgrades. This creates acceleration within one run while preventing early permanent power from erasing the search loop.

### Persistent progression

Gems/tokens buy class rolls, permanent perks, event chests, and eligible cosmetics. Wins and best times unlock difficulties/chapters and support leaderboards.

### Difficulty

Normal is default. Hard is unlocked through the policy object in configuration, never through scattered `wins >= 1` checks. Hard currently assumes deeper Egg placement, more pile density, slightly lower tool yield, improved sale value, and larger completion reward. All modifiers compose through one resolved round-modifier object.

## 10. Classes

Implement the eight configured target classes with the verified probability weights:

- Newcomer 40%
- Nest Carrier 25%
- Egg Trader 14%
- Rake Expert 9%
- Blast Artist 7%
- Gem Seeker 3.9%
- Automation Expert 1%
- Master Forager 0.1%

Server selects the result before animation. Client wheel/card animation lands on the committed result, then the server projection updates and reward modal appears. The result must not be announced before the animation lands.

Class modifiers are composed by a pure `ModifierResolver` with named sources. No service manually checks class names. The resolver returns bag, sale, tool, proc, and entitlement modifiers and prevents double application.

The assumed 2x Luck transformation is isolated in one policy function and unit-tested for non-negative weights and exact normalization.

## 11. Lobby systems

### Layout

The lobby is compact and readable from spawn. Primary portal/party interaction is straight ahead. Daily reward and classes are visible from the main path. Shops and event chest flank the route without forming a dead mall. Stats/leaderboards and social reward occupy secondary sightlines.

Every station has world animation plus UI identity:

- Party portal: animated destination diorama and current party silhouette.
- Daily rewards: opening calendar/nest display and ready pulse.
- Classes: rotating class tokens/cards, visible odds, reveal stage.
- Permanent perks: mechanical upgrade bench with before/after previews.
- Event chest: contained UFO/moonlight effect with strict particle budget.
- Inventory: physical display hooks and a responsive modal.
- Codes/Stats: secondary stations, not dominant spawn clutter.

### Parties

Create/join, leader, 1-4 players, chapter, difficulty, unlock validation, countdown, reservation, and teleport fallback. Party actions are server-serialized. Invite features may integrate Roblox-native invite APIs behind an adapter.

### Daily rewards

Eight-day visible cycle with verified Gem amounts. Timing, grace, loop, and miss policy are assumed/configured. Server time and one claim transaction are mandatory.

### Codes

Codes are normalized uppercase, trimmed, rate-limited, server-configured, optionally time-bounded, and idempotent per account. Never expose unpublished codes to the client config.

### Inventory

Categories: Rake, Charge, Vac, Chick, and future cosmetics. Client requests equip by owned item ID; server validates ownership and returns the new projection. Cosmetics never change power unless a separately named gameplay entitlement says so.

### Stats and leaderboards

Personal stats: playtime, equipped class, best times, total wins, feathers collected, Eggs found. Leaderboards use bounded update cadence and ordered stores; they do not write on every feather.

## 12. Chapter 2

Phase 5 implements a complete assumed/corroborated Chapter 2 journey:

1. Search debris for a hidden key.
2. Activate three spatially separated mechanisms.
3. Solve a visible-object count puzzle.
4. Assemble a four-digit code from environmental notes.
5. Rotate a 4x4 tile image into the correct orientation.
6. Release a trapped hatchling and disable the barrier.
7. Exit with the Egg and trigger the same transaction-safe victory pipeline.

Puzzle solutions are server-generated from validated sets, shared by the party, recoverable after rejoin, and impossible to permanently softlock through wrong input. UI must not rely on color alone; shapes/symbols accompany colors.

## 13. Networking contract

Create one typed remote registry with schemas, rates, permissions, and direction. Suggested logical messages:

Client requests:

- `PartyCreate`, `PartyJoin`, `PartyLeave`, `PartySetDestination`, `PartyStart`
- `TutorialAction`
- `CollectAction`, `ToolEquip`, `ToolActionBegin`, `ToolActionEnd`
- `SellRequest`, `UpgradePurchase`
- `EggClaim`
- `ClassRoll`, `ClassEquip`
- `DailyClaim`, `CodeRedeem`, `GroupRewardClaim`
- `InventoryEquip`
- `ResultsAction`
- `SettingsUpdate`
- `PurchasePromptRequest`

Server events/projections:

- `ProfileProjection`
- `PartyProjection`
- `RoundSnapshot`, `RoundDelta`, `ObjectiveChanged`
- `ActionResult`, `SaleResult`, `UpgradeResult`
- `EggRevealed`, `VictoryStarted`, `RewardsCommitted`, `ResultsProjection`
- `Toast`, `ModalDirective`
- `EntitlementsProjection`

Every request schema rejects unexpected types/size, unknown IDs, stale tokens, impossible states, distance violations, and rate violations. Never create a generic remote that accepts arbitrary method names and payloads from the client.

## 14. Service architecture

Adapt names to the healthy existing repository rather than duplicating equivalent modules.

### Shared/domain

- `Config`: typed immutable configuration and deployment product mapping.
- `Types`: domain types only.
- `NetSchema`: remote contracts and sanitizers.
- `StateReducers`: pure lobby/party/round/UI reducers.
- `EconomyMath`: integer-cents calculations.
- `ModifierResolver`: class/perk/difficulty composition.
- `WeightedRandom`: injected RNG.
- `Clock`: injected wall/monotonic time.

### Server

- `PlayerDataService`
- `EntitlementService`
- `ReceiptService`
- `PartyService`
- `SessionService`
- `RoundService`
- `PileService`
- `CollectionService`
- `SellingService`
- `UpgradeService`
- `ToolService` with tool strategies
- `EggService`
- `VictoryService`
- `ChapterService`
- `PuzzleService`
- `ClassService`
- `RewardService`
- `InventoryService`
- `DailyService`
- `CodeService`
- `StatsService`
- `AnalyticsService`
- `SecurityService`

### Client

- `BootstrapController`
- `InputController`
- `CameraController`
- `HUDController`
- `ModalController`
- `PartyController`
- `RoundController`
- `PileVisualController`
- `ToolVisualController`
- `ObjectiveController`
- `VictoryController`
- `LobbyController`
- `AudioDirector`
- `VFXDirector`
- `HapticsController`
- `QualityController`
- `AccessibilityController`

### Presentation components

Use a component library with design tokens for typography, color, spacing, radius, stroke, shadow, motion, sound semantics, and input prompts. Components include buttons, tabs, currency chips, progress meters, product cards, tooltips, toast queue, modal shell, reward row, class card, party member card, and result card.

## 15. Premium game-feel specification

Every important action uses a feedback envelope:

1. Anticipation: windup, hover/press response, sound pickup, target highlight.
2. Contact: authoritative impact aligned to animation marker.
3. Reward: number/currency change, particles, pitch layer, haptic, visible world change.
4. Recovery: eased settle and immediate readiness cue.

### Collection

- Feathers bend/tug before release, then stream toward the bag.
- Contact sound varies by tool and uses small pitch variation without becoming noisy.
- Bag meter has restrained squash and a stronger full-state pulse.
- Surface dents are spatially coherent; no random visual holes unrelated to server cells.

### Selling

- Bag contents visually arc into the station.
- Cash counts with a short accelerating tick, not one sound per feather.
- Large sales use a stronger but capped burst.
- The player can move again quickly; feedback does not trap input.

### Upgrades

- Preview clearly states old -> new and cost.
- Purchase produces one mechanical world response, UI snap, audio chord, and stat number transition.
- Maxed state is celebratory and visually distinct, not simply disabled grey.

### Discovery/victory

- Final cover lifts in a readable spiral.
- Directional chime and glow guide all party members.
- Camera framing never causes motion sickness; reduced-motion uses a static framed cut.
- Winner and party both feel rewarded.
- Victory presentation is short enough to sustain replay.

### Ambient life

- At least three visible ambient behaviors from any primary standing position.
- Mix large slow motions (fan, cloth, bird path) with small close motions (dust, feathers, props).
- Ambient actors use seeded schedules and pooling, not permanent heartbeat loops per object.
- Interactables remain the highest contrast; ambiance must not become visual noise.

### Audio

- Separate buses: Music, Ambience, SFX, UI.
- State-driven music layers: Lobby, Search, Discovery tension, Victory, Results.
- Positional sounds for world actions; UI sounds remain non-positional.
- Concurrency limits and priority prevent tool spam from clipping.
- Settings apply immediately and persist.

## 16. UI and platform requirements

- Responsive constraints, safe areas, and UIScale policy; no hard-coded desktop-only offsets.
- Mobile primary action under comfortable right thumb; movement remains clear.
- Hold/continuous tools support touch down/up and cancellation.
- Controller actions use ContextActionService and explicit selection groups.
- Mouse, touch, and controller prompts switch without rebuilding the entire UI.
- Minimum 44 px touch targets.
- Text remains legible at small phone widths.
- No more than one blocking modal.
- Reduced motion and camera shake toggles.
- Color is never the sole puzzle/status signal.

## 17. Monetization design

Implement only configured products and product mapping supplied by the owner. Prices in UI come from validated config/product info, never from duplicated literals.

Principles:

- No forced purchase during tutorial.
- No purchase required to complete a chapter.
- Show exact benefit before native prompt.
- One-round versus permanent is unmistakable.
- Cancel closes cleanly and returns focus.
- Native purchase completion is not proof of grant; server ownership/receipt is.
- Paid acceleration does not create exclusive server-authoritative completion access.

Current surfaces: Gem bundles, 2x Gems, Infinite Bag, class 2x Luck, Fast Rolls, extra class slot, one-round and permanent tools, Skip Upgrade products, event chest bundles.

Developer product IDs remain `TODO_DEPLOYMENT_IDS`. Claude Code must create a validated mapping interface and refuse unknown IDs; it must not invent live IDs.

## 18. Analytics and balancing

Emit the configured enumerated events with build/config version, chapter, difficulty, party size, platform class, and relevant numeric state. Sample high-frequency collection telemetry. Never log free text.

Primary funnels:

- Join -> lobby interactive -> party created -> round started.
- Round started -> first collect -> bag full -> first sale -> first upgrade.
- First sale -> Egg reveal -> completion -> replay.
- Win -> Hard/Chapter 2 selection.
- Shop view -> prompt -> purchase completion.

Balance metrics:

- Seconds to first input, bag full, first sale, first upgrade.
- Feathers/min and cash/min by tool/class/party size.
- Round time distribution by chapter/difficulty/party size.
- Upgrade purchase order and level reached.
- Reveal depth and spawn-node completion distribution.
- Failure/leave location.

No economy change should be made from average session time alone. Segment by fresh/returning, party size, class, paid entitlement, platform, and chapter.

## 19. Security model

- Validate every remote by schema, state, rate, ownership, range, and server time.
- Use monotonic server deadlines for cooldowns.
- Server selects cells and outputs; client never submits yield.
- Server selects RNG result and winner.
- Use integer cents and bounded counts.
- Protect receipts with an idempotent ledger.
- Detect impossible request cadence and impossible movement/action origins; reject first, then sample telemetry.
- Avoid punitive automatic bans from one heuristic. Build evidence and rate-limit.
- Keep Studio-only debug commands disabled outside Studio/allowlisted private test environments.

## 20. Performance architecture

- Enable Streaming where map structure supports it.
- Pool strands, chunks, particles, number popups, sounds, companion visuals, and temporary UI.
- No per-feather Heartbeat connection.
- Batch pile deltas at configured replication rate.
- Use distance/visibility culling and quality tiers.
- Avoid unanchored decorative physics except short client-only cosmetic bursts.
- Cap concurrent audio and particle systems.
- Disconnect signals and cancel tasks/tweens when controllers/components unload.
- Profile representative worst case: four players, four tools, ambient systems, Egg reveal, victory VFX.

## 21. Six-phase implementation contract

### Phase 1 - Architecture and data

Inspect repository; establish typed config, adapters, networking, profile/session/party/round skeleton, transactions, test framework, and representative ambient/UI foundations. Do not implement the full gameplay loop.

### Phase 2 - Complete vertical slice

Deliver lobby -> party -> Chapter 1 -> tutorial -> collect -> sell -> reveal Egg -> victory -> reward -> results -> save -> lobby. Include representative polish and single-player robustness.

### Phase 3 - Progression and tools

Implement all Hand/Bag/tools/upgrades/economy/difficulty values and reset/entitlement behavior from config.

### Phase 4 - Lobby/meta

Complete parties, classes, rerolls, daily, codes, inventory, stats, chapter selection, responsive modals, and social/group reward.

### Phase 5 - Hard, Chapter 2, monetization

Implement config-driven unlocks, complete Chapter 2 puzzles, Marketplace adapters, passes/products, permanent tools, Infinite Bag, event chest, and receipt resilience.

### Phase 6 - Production completion

Complete mobile/controller, multiplayer/rejoin, exploit hardening, performance, VFX/audio/environment polish, balance instrumentation, release checklist, and removal of placeholders.

Each phase prompt is standalone and restates the mandatory workflow. Claude Code must implement only the active phase, provide automated and Studio evidence, update docs, commit the verified checkpoint, and stop.

## 22. Repository and change discipline

- Inspect `AGENTS.md`, README, project files, package manifests, Rojo/Wally config, tests, git status, branches, and existing architecture first.
- Preserve user changes and unrelated dirty files.
- Prefer integration with healthy patterns over creating parallel frameworks.
- No destructive resets or broad deletes.
- Small, reviewable commits; one verified phase checkpoint.
- Update a `docs/IMPLEMENTATION_STATUS.md` in the repository after each phase.
- Record deviations from this pack with reason and affected tests.
- If a material conflict cannot be resolved safely, stop that specific implementation area, report it, and continue only with independent work inside the phase.

## 23. Definition of done

The game is release-ready only when all six phase gates pass, the full journey works on supported inputs, persistent/premium rewards are idempotent, server authority is demonstrated, performance budgets are met in a representative stress scene, and no dead/unfinished/placeholder space remains in the release path.
