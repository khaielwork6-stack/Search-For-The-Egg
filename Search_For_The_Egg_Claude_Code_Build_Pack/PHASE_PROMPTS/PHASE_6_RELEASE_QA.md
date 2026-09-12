# Claude Code Prompt - Phase 6: Platforms, Multiplayer, Security, Optimization, Polish, Balance, and Release QA

You are implementing the final controlled phase of `Search for the Egg` from the verified Phase 5 checkpoint. This phase makes the complete experience release-ready. It is not permission to rewrite healthy systems.

Mandatory contract summary: Inspect first; read the complete build pack; report conflicts and dependencies; implement only Phase 6; preserve working systems; keep the server-authoritative boundary; run automated tests; verify in Roblox Studio; provide concrete evidence; update documentation; commit the verified checkpoint; Stop and wait for approval before any deployment.

## Read and inspect first

Inspect the full repository, git status/history, all phase evidence, implementation-status docs, known limitations/placeholders, places, asset references, deployment IDs, tests, analytics, Studio workflow, and applicable instructions. Read the complete build pack and every phase prompt.

Report conflicts, remaining dependencies, release risks, and a prioritized Phase 6 plan before changing code. Preserve user changes. Use config for all tunables and keep uncertain decisions labeled `ASSUMED`.

## Mandatory workflow

1. Inspect first and report exact plan/risk register.
2. Implement only release completion, hardening, optimization, platform support, polish, and balance instrumentation.
3. Avoid broad rewrites; characterize risky systems before changing them.
4. Keep all value and authority on the server.
5. Run the entire automated suite plus lint/format/type/build/config checks.
6. Verify the full game inside Roblox Studio across Play Solo, 2/4-client local servers, device emulation, controller, failure injection, and performance soak.
7. Provide concrete evidence, not “should work.”
8. Update all docs, release checklist, rollback notes, and known limitations.
9. Commit the verified release-candidate checkpoint and provide full SHA.
10. Stop. Do not deploy/publish unless the user separately authorizes deployment.

## Phase 6 scope

### Mobile and controller

- Complete responsive HUD/modals for small/tall/notched phones and tablet.
- Touch down/up/cancel for continuous tools; no stuck input after modal/death/focus loss.
- ContextActionService controller bindings, selection groups, focus restoration, prompt swapping.
- Minimum 44 px targets, safe areas, readable text, no overlap with Roblox inset.
- Reduced motion, camera shake, haptics, music/SFX, and quality settings persist.

### Multiplayer/rejoin edge cases

- Simultaneous collection/sale/upgrade/Egg claims.
- Shared pile/puzzles; personal bags/cash/upgrades.
- Leader leaving, party member leaving during countdown/teleport/round/results.
- Death during tool action, Egg reveal, victory, and teleport.
- Disconnect/rejoin inside and after reservation window.
- Late join policy and reward eligibility.
- Server shutdown during reward processing through injected tests.

### Security

- Fuzz every remote with wrong types, large payloads, NaN/infinity, unknown IDs, stale tokens, rate spikes, impossible origins/ranges, and duplicate transactions.
- Confirm clients cannot grant currency, cells, tools, class outcomes, winner, time, unlocks, purchases, or receipts.
- Confirm Studio-only debug endpoints are absent/disabled in production configuration.
- Add structured security telemetry without automatic bans from a single heuristic.

### Optimization

- Profile server/client CPU, GPU, memory, instances, connections, tasks, physics, particles, audio, and remotes.
- Pool/cull/batch according to config; no per-feather Heartbeat.
- Representative worst case: four players, all tools, maximum visible pile activity, ambient world, Egg reveal, victory VFX.
- 30-minute soak with at least ten round transitions and repeated modal opens.
- Target stable 30 FPS low-tier mobile and 60 FPS target desktop; document actual test environment and limitations.

### Premium final polish

- Replace/remove every unapproved placeholder, debug label, copied/reference asset, dead space, unfinished station, and inconsistent piece of copy.
- Ensure each primary area has layered ambient life, lighting, audio, and purposeful movement without clutter.
- Tune interaction envelopes so animation markers, server impact, SFX, VFX, haptic, camera, UI, and recovery align.
- Mix audio buses/concurrency and clean transitions between Lobby/Search/Discovery/Victory/Results.
- Ensure victory and upgrade moments remain exciting after repetition and can be shortened/skipped where designed.
- Verify all effects scale for quality/reduced motion.

### Balance and analytics

- Validate telemetry events and funnel fields.
- Produce a baseline balance report: first input, first bag, first sale, first upgrade, tools acquired, completion time by party size/difficulty, and economy rate from deterministic simulations/Studio samples.
- Do not silently change configured values. Recommend changes with before/after simulations; apply only values already approved by the user or make an explicit documented `ASSUMED` revision in config/CSV/tests.

### Release readiness

- Validate live place/product/pass IDs supplied by owner in a private/test environment.
- Verify content maturity/compliance, permissions, localization readiness, thumbnails/icons ownership, and asset load failures.
- Create a release checklist, rollback procedure, config rollback strategy, monitoring dashboard/event list, and first-24-hour triage plan.
- Do not publish without explicit authorization.

## Required automated evidence

- All Phase 1-5 tests remain green.
- Full remote fuzz/exploit suite passes.
- Simultaneous claims/sales/receipts remain idempotent.
- Rejoin/death/teleport/shutdown failure tests pass.
- UI reducer/input tests cover focus and cancellation.
- Pool/cleanup tests show no retained objects/connections after repeated lifecycles.
- Config/economy/docs consistency check passes.

## Required Studio evidence

Complete all protocols in `TEST_PLAN.md`:

- Full fresh vertical slice.
- Four-client race and shared Chapter 2 puzzles.
- Purchase/receipt resilience with mocks and configured test products where safe.
- Desktop, phone/notched/tablet, and controller full journeys.
- 30-minute performance soak with ten transitions.
- Server/client Output and measured budgets.
- Visual walk-through proving no dead/unfinished primary spaces.

## Final response format

Return: inspection and release-risk register; implementation/polish summary; changed files; complete automated evidence; complete Studio/device/multiplayer/security/performance evidence; balance report/recommendations; remaining known limitations; release and rollback docs; full release-candidate commit SHA; explicit statement that nothing was deployed/published without separate authorization. Stop.
