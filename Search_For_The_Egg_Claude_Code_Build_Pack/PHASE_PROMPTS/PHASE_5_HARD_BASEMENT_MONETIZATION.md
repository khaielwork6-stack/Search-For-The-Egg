# Claude Code Prompt - Phase 5: Hard Mode, Chapter 2, and Monetization

You are implementing Phase 5 of `Search for the Egg` from the verified Phase 4 checkpoint. Complete config-driven Hard Mode, Moonlit Cellar/Chapter 2, and safe monetization. Do not begin Phase 6.

Mandatory contract summary: Inspect first; read the complete build pack; report conflicts and dependencies; implement only Phase 5; preserve working systems; keep the server-authoritative boundary; run automated tests; verify in Roblox Studio; provide concrete evidence; update documentation; commit the verified checkpoint; Stop and wait for approval.

## Read and inspect first

Inspect repository, git status/history, prior phase evidence, services/tests, place/teleport layout, Marketplace configuration, Studio workflow, and instructions. Read the complete build pack. Give special attention to `SYSTEM_CONFIG.json`, `ASSUMPTIONS.md`, `DATASTORE_SCHEMA.md`, `STATE_MACHINES.md`, `TEST_PLAN.md`, and monetization/Chapter 2 sections of `MASTER_SPEC.md`.

Report all conflicts, dependencies, and missing deployment IDs before implementation. Missing Product IDs are not permission to invent them: implement/test through validated configuration and mocks, then clearly list IDs the owner must supply for live testing.

## Mandatory workflow

1. Inspect first; report exact Phase 5 plan.
2. Implement only Phase 5.
3. Preserve working systems; avoid unnecessary rewrite/deletion.
4. Keep unlocks, puzzles, Egg, rewards, entitlements, receipts, and product grants server-authoritative.
5. Run automated tests and all checks.
6. Verify in Roblox Studio with solo and multi-client protocols. Use mock Marketplace for repeatable receipt tests; live purchase is not required.
7. Provide commands, test counts, Output, screenshots/timecodes, measurements, and receipt replay evidence.
8. Update docs and deployment checklist.
9. Commit verified checkpoint, give full SHA.
10. Stop before Phase 6.

## Phase 5 scope

### Hard Mode

- Unlock through configuration policy, not scattered win checks.
- Apply the resolved Hard modifiers from config: pile density, tool yield, sell multiplier, Egg depth, and reward policy.
- Show readable differences before party start.
- Use the same tested round/victory transaction pipeline.

### Moonlit Cellar / Chapter 2

Build an original, complete chapter with shared party state:

1. Search nesting debris for a hidden key.
2. Activate three distinct mechanisms, each labeled by color plus symbol/shape.
3. Solve a visible-object count puzzle.
4. Assemble and enter a four-digit code from environmental clues.
5. Rotate a 4x4 tile image into the valid state.
6. Release a trapped hatchling and disable the barrier.
7. Exit with the Egg and trigger the common victory/reward/results/return pipeline.

Solutions are server-generated from validated sets and synchronized to late/rejoining players. Wrong inputs provide feedback and cannot softlock. Any party member may interact. Provide reset/recovery for every puzzle.

### Monetization

- Game passes: 2x Gems, Infinite Bag, permanent Nest Rake, Confetti Charge, Feather Vac, Scout Chick, class 2x Luck, Fast Rolls, extra class slot where configured as passes.
- Developer products: Gem bundles, one-round tools, Skip Upgrade, event chest bundles, and other explicitly configured repeatable grants.
- Event Chest with exact observed weights/costs and assumed duplicate conversion policy.
- Product info/prompt UI clearly distinguishes one-round/permanent and exact grant.
- One central `ProcessReceipt`, persistent idempotency ledger, retries, unknown-ID safety, and server projection confirmation.
- Recheck game-pass ownership server-side after completion.
- No tutorial or chapter completion paywall.

## Premium requirements

- Hard Mode changes atmosphere and feedback as well as numbers, using quality-scaled lighting/audio/VFX without harming visibility.
- Moonlit Cellar must feel intentional and alive: mechanisms move, clues react, hatchling animates, puzzle feedback is layered, and the route has no dead filler space.
- Product surfaces feel integrated but never overwhelm the first-run objective.
- Purchase cancel returns input/focus cleanly; success feedback waits for authoritative grant.

## Required automated evidence

- Every unlock policy responds to config changes without service edits.
- Hard modifiers compose once and rewards remain idempotent.
- Chapter 2 can reach victory from every generated valid puzzle set.
- Wrong/repeated/concurrent puzzle inputs cannot corrupt or duplicate progress.
- Late join/rejoin receives the correct puzzle projection where allowed.
- Product mapping rejects missing/unknown IDs.
- Receipt replay 100 times grants once; first-save failure later commits once.
- Pass refresh grants only after ownership verification.
- Event chest boundary/weight tests, duplicates, inventory grants, and replay safety.
- One-round tool and Skip Upgrade products affect only intended round/level.

## Required Studio evidence

- Unlock Chapter 1 Hard and Chapter 2 through normal test progression/policy; show locked/unlocked UI.
- Complete Chapter 1 Hard solo and with two clients.
- Complete every Chapter 2 step solo, two-player, and four-player.
- Show wrong-input recovery and one disconnect/rejoin during a puzzle.
- Run mocked cancel/success/save-failure/replay for every grant-handler category.
- Confirm permanent tool/Infinite Bag start-of-round behavior.
- Capture Output and representative performance in Hard and Chapter 2.

## Final response format

Return inspection/conflicts; completed Hard/Chapter 2/commerce work; actual versus missing deployment IDs; changed files; automated evidence; Studio evidence; receipt proof; performance; known limitations; docs; full commit SHA; statement that Phase 6 has not begun. Stop.
