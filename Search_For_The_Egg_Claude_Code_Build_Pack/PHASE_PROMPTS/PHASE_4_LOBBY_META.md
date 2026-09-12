# Claude Code Prompt - Phase 4: Lobby, Parties, Classes, Rewards, Inventory, and Stats

You are implementing Phase 4 of `Search for the Egg` from the verified Phase 3 checkpoint. Complete the lobby and persistent meta systems. Do not begin Phase 5.

Mandatory contract summary: Inspect first; read the complete build pack; report conflicts and dependencies; implement only Phase 4; preserve working systems; keep the server-authoritative boundary; run automated tests; verify in Roblox Studio; provide concrete evidence; update documentation; commit the verified checkpoint; Stop and wait for approval.

## Read and inspect first

Inspect repository state, git status/history, Phase 1-3 evidence, current systems/tests, Studio workflow, and all repository instructions. Read the complete build pack: `START_HERE.md`, `MASTER_SPEC.md`, `SYSTEM_CONFIG.json`, `ECONOMY_TABLES.csv`, `DATASTORE_SCHEMA.md`, `STATE_MACHINES.md`, `TEST_PLAN.md`, `ASSUMPTIONS.md`, `FINAL_GDD.pdf`, and all prompts.

Report conflicts/dependencies first. Preserve working systems and user changes. Use centralized values and `ASSUMED` policies. Do not duplicate prices, weights, or unlock checks in UI.

## Mandatory workflow

1. Inspect first and give the exact Phase 4 plan.
2. Implement only this phase.
3. Integrate with healthy systems; no unnecessary rewrites.
4. Keep parties, RNG, claims, ownership, currencies, stats, and unlocks server-authoritative.
5. Run automated tests and repository checks.
6. Verify in Roblox Studio on desktop, phone viewport, controller, and multi-client where required.
7. Give concrete commands, pass counts, Output status, screenshots/timecodes, and measurements.
8. Update documentation.
9. Commit verified checkpoint and provide full SHA.
10. Stop before Phase 5.

## Phase 4 scope

### Premium compact lobby

- Finalize a clear spawn composition: chapter portal ahead; Daily and Classes on primary sightlines; perks/event/inventory adjacent; stats/codes/social secondary.
- Remove dead/unfinished primary space. Every visible station has purposeful world motion, legible identity, interaction feedback, audio layer, and mobile performance tier.
- Maintain an original visual language; do not replicate reference geometry/UI/assets/copy.

### Parties and chapter selection

- Create/join/leave; leader transfer; 1-4 members; destination/difficulty; per-member unlock validation; countdown cancel; reservation; teleport retry/fallback; party projection.
- Show Chapter 1 Normal plus locked future selections driven by policy/config. Phase 5 activates Hard and Chapter 2 gameplay.

### Classes and rerolls

- All eight configured target classes, exact base weights, 40-Gem roll, equipped slots, server-selected result, animation that lands before result notification.
- 2x Luck, Fast Rolls, and extra slot interfaces through entitlement mocks/deployment mapping. Live commerce comes in Phase 5.
- Auto roll obeys affordability, cancellation, result sequencing, and rate limits.
- Apply class modifiers through `ModifierResolver`, never class-name checks in gameplay services.

### Permanent perks

- Bag Size, Hand Grab, Gem Value, Feather Value with server costs/levels/caps and old -> new previews.
- Effects are `ASSUMED` and centralized.

### Daily, codes, group reward

- Eight-day verified reward table with assumed server-time cadence/grace/loop/reset policy.
- One claim transaction; idempotent after retries.
- Code entry normalization, rate limits, eligibility/expiry, one-account claim.
- One-time group reward after server eligibility check.

### Inventory and stats

- Tool-skin categories and owned-only equip.
- Personal stats: playtime, class, best times, wins, feathers, Eggs.
- Leaderboard adapters with bounded writes and refresh cadence.
- Codes, Stats, Inventory, Daily, Classes, Perks, Party modals using shared design system.

## UX requirements

- One blocking modal owner; focus restores correctly.
- Mobile safe areas and >=44 px targets.
- Controller can open, navigate, confirm, cancel, and recover focus in every modal.
- Currency changes and rewards animate only after server acknowledgement.
- Odds and purchase terms are readable before action.
- Auto roll can always be stopped; no result text appears before the animation lands.
- Ambient movement stays behind interaction contrast and respects quality/reduced motion.

## Required automated evidence

- Party membership/start is serialized; duplicate requests and invalid unlocks fail safely.
- Class weights total 100; boundary and seeded statistical tests pass.
- 2x Luck policy totals 100 and never goes negative.
- Class result persists and applies modifiers once.
- Duplicate/insufficient/auto-roll cancellation paths are safe.
- Daily timing across early/on-time/grace/expired/day8 cases; duplicate claim grants once.
- Code/group claim replay grants once; expired/invalid/rate-limited requests grant nothing.
- Permanent perk purchase is atomic and capped.
- Inventory cannot equip unowned IDs.
- Leaderboard writes are bounded, sanitized, and not per-feather.

## Required Studio evidence

- Lobby walk-through from spawn shows no dead primary path and at least three ambient motions from each major standing area.
- 1-, 2-, and 4-player party create/start/cancel/leader-leave scenarios.
- Class roll timing including duplicate and Auto stop; result appears only on landing.
- Daily claim, retry, code, group, perks, inventory equip, stats update.
- Every modal at desktop, phone/notched viewport, and controller-only navigation.
- Server/client Output free of unexplained errors and no modal/ambient connection growth after repeated open/close.

## Final response format

Return inspection/conflicts; implementation; config keys; changed files; automated evidence; Studio evidence; UX/accessibility evidence; remaining Phase 5 dependencies such as actual Product/Game Pass IDs; docs; full commit SHA; statement that Phase 5 has not begun. Stop.
