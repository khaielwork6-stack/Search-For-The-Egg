# Claude Code Prompt - Phase 3: Progression, Bags, Hands, Tools, Economy, and Difficulty

You are implementing Phase 3 of `Search for the Egg` from the verified Phase 2 checkpoint. Complete the configured round progression and tool systems. Do not begin Phase 4.

Mandatory contract summary: Inspect first; read the complete build pack; report conflicts and dependencies; implement only Phase 3; preserve working systems; keep the server-authoritative boundary; run automated tests; verify in Roblox Studio; provide concrete evidence; update documentation; commit the verified checkpoint; Stop and wait for approval.

## Read and inspect first

Inspect repository state, git status/history, Phase 1-2 documentation/evidence, current architecture, tests, Studio workflow, and all applicable instructions. Read the entire build pack, especially `MASTER_SPEC.md`, `SYSTEM_CONFIG.json`, `ECONOMY_TABLES.csv`, `STATE_MACHINES.md`, `TEST_PLAN.md`, `ASSUMPTIONS.md`, and `DATASTORE_SCHEMA.md`.

Report conflicts and dependencies before implementation. Preserve working systems and unrelated changes. `SYSTEM_CONFIG.json` is authoritative for values. If CSV and JSON disagree, stop and report the exact rows/keys rather than choosing silently.

## Mandatory workflow

1. Inspect existing implementation and report the Phase 3 plan.
2. Implement only Phase 3.
3. Avoid unnecessary rewrites and preserve Phase 2 game feel.
4. Keep yields, cells, cooldowns, heat, fuse, companions, prices, levels, ownership, and transactions server-authoritative.
5. Run automated tests and repository checks.
6. Verify every system inside Roblox Studio with concrete evidence.
7. Update docs/config/economy views when required.
8. Commit the verified checkpoint; provide full SHA.
9. Stop before Phase 4.

## Phase 3 scope

- Complete Hand paths: Grasp, Speed, Hold.
- Complete five-level Bag capacity path and Infinite Bag-compatible interface without granting the pass yet.
- Implement Nest Rake: acquisition, discrete deeper sweep, Cooldown/Hold/Sweep paths, animations, impacts, dents, audio, haptics.
- Implement Confetti Charge: safe server charge identity, light/throw/fuse/explosion, Power/Speed/Lucky Blast, rainbow conversion, optional mini-charges only through resolved class modifier.
- Implement Feather Vac: spin-up, continuous authoritative suction, Runtime/Power/Cooling, heat meter, overheat, cooling, cancel/death cleanup.
- Implement Scout Chick: server-owned trip state, cell selection, personal awards/sales, Speed/Grasp/Capacity, client-smoothed personality animation.
- Implement soft-currency, Gem, and one-round product acquisition interfaces according to config; live receipt products remain Phase 5.
- Implement round reset and permanent-entitlement starting-grant policies using the mock entitlement adapter.
- Implement the ModifierResolver fully for class/permanent-perk/difficulty/tool sources; classes can remain debug-selected until Phase 4.
- Implement Normal/Hard resolved modifiers through config. Hard selection UI/content remains Phase 5, but tests/debug route must prove modifier behavior now.
- Complete tool HUD/hotbar, context prompts, before/after upgrade previews, max states, insufficient-funds feedback, touch-compatible input abstraction, controller-compatible actions.
- Add analytics for acquisition, action, overheat, upgrade, sale, and progression timing.

## Premium requirements

Every tool must have a distinct, satisfying feedback envelope and remain readable when four players act at once. Use pooled/distance-culled effects, audio concurrency, quality tiers, and cleanup. Upgrade purchases must feel mechanically and audiovisually meaningful. Mobile quality may reduce strands/debris/particles but not action timing or yield.

Do not leave tools as identical raycasts with different numbers. Their state, cadence, affected volume, camera response, sound family, surface deformation, and UI meter must communicate a different role.

## Required automated evidence

- Every configured path can purchase sequentially to max using injected funds; values/costs match JSON.
- Stale level, max level, insufficient funds, duplicate request, invalid tool, and wrong phase never debit.
- Rake removes only eligible cells once and applies class discount/yield exactly once.
- Charge validates throw/fuse/radius, rolls server RNG, and never duplicates explosion awards.
- Vac cannot collect while overheated and cooling/runtime values follow config.
- Chick pauses/cleans up correctly on round end/death/disconnect and never awards another owner.
- One-round grants reset next round; mock permanent entitlement grants configured max upgrades.
- Normal collection caps bag; overflow policy behaves exactly as config.
- Integer-cent economy remains drift-free.
- Four-player action stress does not exceed configured server request acceptance or create unbounded tasks.

## Required Studio evidence

- Use debug funds only through secured Studio hooks and label the evidence.
- Purchase and max every Hand/Bag/tool path; capture before/after values.
- Perform at least 20 actions per tool and show measured cadence/yield/range/heat/fuse/trip behavior.
- Demonstrate round reset versus mock permanent grant.
- Run four-tool representative stress scene and capture FPS, instance count, physics parts, particles, remote rates, and Output.
- Demonstrate desktop plus one phone viewport for all tool controls/meters.

## Final response format

Return: inspection/conflicts; systems completed; exact config keys consumed; changed files; automated evidence; Studio measurements and screenshots/timecodes; balance observations without silently changing approved config; known limitations; documentation; full commit SHA; statement that Phase 4 has not begun. Stop.
