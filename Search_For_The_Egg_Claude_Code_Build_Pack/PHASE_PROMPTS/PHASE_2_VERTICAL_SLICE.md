# Claude Code Prompt - Phase 2: Complete Playable Vertical Slice

You are implementing Phase 2 of `Search for the Egg` from the verified Phase 1 checkpoint. Implement a complete solo-capable journey from lobby through Egg discovery, victory, rewards, save, and return. Do not begin Phase 3.

Mandatory contract summary: Inspect first; read the complete build pack; report conflicts and dependencies; implement only Phase 2; preserve working systems; keep the server-authoritative boundary; run automated tests; verify in Roblox Studio; provide concrete evidence; update documentation; commit the verified checkpoint; Stop and wait for approval.

## Mandatory source material and inspection

Before editing, inspect the repository, `git status`, Phase 1 commit/evidence, tests, current Studio workflow, and all applicable instructions. Read the complete build pack: `START_HERE.md`, `MASTER_SPEC.md`, `SYSTEM_CONFIG.json`, `ECONOMY_TABLES.csv`, `DATASTORE_SCHEMA.md`, `STATE_MACHINES.md`, `TEST_PLAN.md`, `ASSUMPTIONS.md`, `FINAL_GDD.pdf`, and every phase prompt for dependency awareness.

Report conflicts and dependencies first. Preserve working systems and unrelated user changes. Use configured `ASSUMED` values; do not block on missing reference footage and do not scatter guessed literals.

## Mandatory workflow

1. Inspect first and report the precise Phase 2 plan.
2. Implement only this phase.
3. Avoid unnecessary deletion/rewrite; integrate with Phase 1 architecture.
4. Keep all gameplay, time, pile mutation, Egg selection, winner, rewards, and saving server-authoritative.
5. Run automated tests and all repository checks.
6. Verify inside Roblox Studio with real Play Solo; never fabricate evidence.
7. Provide exact commands, test counts, outputs, screenshots/timecodes/measurements.
8. Update documentation and config references.
9. Commit the verified checkpoint and provide the full SHA.
10. Stop and wait for approval before Phase 3.

## Phase 2 scope

Deliver the complete Chapter 1 Normal vertical slice:

1. Premium lobby spawn and one clear Chapter 1 party/portal path.
2. Solo party creation, validation, countdown, reservation, and chapter entry. Use a same-place test adapter if multi-place IDs are not configured, but preserve the production teleport interface.
3. Original skippable 18-second Sunlit Henhouse cutscene.
4. Server start timestamp and count-up timer.
5. First-run objective chain: enter party -> collect 25 -> sell first bag -> buy first upgrade -> search -> complete.
6. Logical server pile grid and pooled client feather visuals. No thousands of replicated physical feathers.
7. Hand collection with server-selected cells, cooldown, range validation, bag capacity 25, visible coherent dents, responsive animation/SFX/VFX/UI/haptic.
8. Selling station with exact integer-cent transaction. Neutral 25-feather sale must yield `$0.25`.
9. One starter Hand or Bag upgrade sufficient to prove the purchase path; Phase 3 completes all curves.
10. Server-selected Egg node, cover condition, synchronized reveal, first-valid atomic claim.
11. Polished assumed completion: Egg discovered -> winner announcement -> base reward and finder bonus -> results -> save -> return to lobby.
12. First-win unlock projection for Chapter 1 Hard and Chapter 2 Normal using configurable policies; destinations can remain unavailable until later phases.
13. Result idempotency, personal best, total win, Egg count, analytics, and safe teleport/lobby fallback.

## Game-feel acceptance

The vertical slice must already feel representative, not like a grey simulator template:

- At least three visible ambient motions from main lobby and chapter standing positions.
- Layered ambience and state-driven music transitions.
- Hand anticipation/contact/reward/recovery alignment.
- Feathers visibly tug, release, and stream to the bag.
- Selling has a restrained arc/count-up/audio response.
- Upgrade preview displays old -> new and produces physical/UI/audio response.
- Egg reveal has a readable final-cover motion, positional chime, glow, camera framing, quality scaling, and reduced-motion alternative.
- Victory is exciting but concise; controls recover predictably.
- No dead primary route or unexplained placeholder UI.

## Out of scope

- Complete upgrade curves and four tools.
- Full classes/daily/codes/inventory shops.
- Chapter 2 gameplay.
- Live monetization.
- Final multiplayer/mobile optimization, though architecture and responsive design must not prevent them.

## Required automated evidence

- Cell depletion cannot double-award under simultaneous requests.
- Invalid phase/range/cooldown/capacity requests are rejected.
- Bag never exceeds capacity under normal Hand collection.
- 25 standard feathers sell for exactly 25 cents and duplicate sale request pays once.
- Egg node is valid, concealed until condition, and reveals once.
- 100 simultaneous claim attempts choose one finder.
- Base reward grants once per present party member; finder bonus grants once.
- Reward save retry, results replay, and teleport failure do not duplicate or lose reward.
- Timer and personal best use server milliseconds.
- Tutorial transitions are valid and persist by version.

## Required Studio evidence

Run `TEST_PLAN.md` Protocol A completely. Show:

- Fresh profile starting state.
- Lobby -> party -> cutscene -> tutorial.
- Exactly 25 feathers collected and sold for `$0.25`.
- Starter upgrade before/after.
- Visible pile deformation.
- Egg reveal and claim.
- Winner/rewards/results.
- Lobby return with updated win/best time/unlocks.
- Play restart proving persistent reward remains and round cash resets.
- Server/client Output with no unexplained errors.

## Final response format

Return: inspection/conflicts; completed vertical slice; config/assumptions used; changed files; automated evidence; Studio evidence with screenshots/timecodes; performance observations; known limitations; docs; full commit SHA; explicit statement that Phase 3 has not begun. Then stop.
