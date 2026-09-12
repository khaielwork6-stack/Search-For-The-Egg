# Search for the Egg - Test Plan

## 1. Definition of verified

A phase is not complete because code was written or a build succeeded. It is complete only when:

1. Static analysis and automated tests pass.
2. The place loads without new errors or infinite yields.
3. The phase acceptance journey succeeds in Roblox Studio Play mode.
4. Server and client Output logs are attached or summarized with zero unexplained errors.
5. Concrete evidence is produced: commands, test counts, screenshots/timecodes, measured values, and changed-file list.
6. Documentation and config references are updated.
7. A verified checkpoint is committed.

Claude Code must never claim Studio verification if it could not access Studio. In that case it must report automated evidence, provide the exact manual test, and stop with the phase marked `BLOCKED_ON_STUDIO_VERIFICATION` rather than inventing evidence.

## 2. Test layers

| Layer | Runs where | Purpose |
|---|---|---|
| Config validation | CLI/test runner | Schema, IDs, probability sums, monotonic curves, references, feature flags |
| Pure unit tests | CLI or TestService | Economy formulas, RNG boundaries, migrations, unlocks, state reducers |
| Service integration | TestService/server harness | Networking validation, profile adapter, party/round transactions, receipts |
| Client controller tests | Test harness | UI state reducers, safe-area layout logic, input routing, feedback sequencing |
| Studio Play Solo | Roblox Studio | Real services, character, physics, UI, lighting, audio, teleport fallbacks |
| Studio multi-client | Local server with 2 and 4 clients | Party, shared pile, simultaneous claims, disconnect/rejoin |
| Device emulation | Studio device emulator | Mobile safe areas, touch targets, low resolution, controller navigation |
| Performance soak | Studio/microprofiler | Memory, frame time, remote rates, pooling, long-session leaks |

## 3. Required tooling

Use the repository's existing tools when healthy. Do not add duplicates. Preferred checks:

- StyLua formatting.
- Selene linting.
- Luau type checking where available.
- A test framework such as TestEZ if already present; otherwise a minimal compatible test runner.
- Rojo build/sourcemap validation.
- Roblox Studio Play Solo and Start Server tests.
- MicroProfiler, Developer Console, and Script Performance for final budgets.

Pin tool versions in the repository. Tests must be deterministic: inject clocks, RNG, Marketplace, DataStore, Teleport, and analytics adapters.

## 4. Global automated suites

### Configuration

- JSON parses and `configVersion` is positive.
- Every referenced chapter, difficulty, tool, class, skin, product, and upgrade ID exists.
- Class weights total exactly 100.0 before transforms.
- Event chest weights total exactly 100.0.
- Levels are contiguous and start at the expected index.
- Upgrade costs are positive or null only at max.
- Benefits are monotonic in the intended direction.
- All `ASSUMED` tunables appear in `ASSUMPTIONS.md` or match an approved exception.
- No product ID or Robux price is hard-coded in a UI/controller/service module.

### Economy

- Standard sale: 25 feathers -> 25 cents and 50 -> 50 cents at neutral modifiers.
- Rainbow multiplier, class sell multiplier, and perk multiplier apply exactly once.
- Cash uses integer cents; no floating drift after 10,000 transactions.
- Bag clamp cannot be exceeded by normal collection.
- Tool overflow produces server-owned pickups or discarded overflow according to config; it never silently creates impossible bag values.
- Purchase is atomic: insufficient funds, stale level, duplicate request, and max level do not debit.
- Discount rounding is deterministic.

### Weighted RNG

- Boundary tests select every class/chest interval correctly.
- Same injected seed produces the same sequence in tests.
- Client-supplied seed/result is ignored.
- Luck transformation stays non-negative and totals 100%.
- A statistical smoke test over 100,000 injected rolls remains within a generous deterministic tolerance; it is not a replacement for boundary tests.

### Unlocks

- Chapter 1 Normal is available by default.
- Chapter 1 Hard and Chapter 2 Normal unlock from configurable policies.
- Locked party members prevent start under the default all-members rule.
- Changing config policy changes behavior without editing services.

### Profile and migrations

- Empty profile reconciles to default.
- Partial and malformed fields are corrected/clamped.
- Unknown inventory IDs fall back safely.
- Migration re-run is idempotent.
- A migration never reduces Gems or owned cosmetics.
- Session lock prevents two live writers.
- Failed initial load never starts a writable default profile.

### Transactions/receipts

- Same victory transaction applied 100 times grants once.
- Same developer product receipt applied 100 times grants once.
- Unknown Product ID returns retry/not-processed, no grant.
- Save failure keeps receipt pending and succeeds on later replay.
- Teleport failure after reward does not duplicate or lose reward.

### Networking/security

- Spam beyond each remote rate limit is rejected and sampled to telemetry.
- NaN, infinity, wrong types, huge strings/tables, unknown IDs, and stale tokens are rejected.
- Collection outside range or through impossible direction is rejected.
- Client cannot set cash, capacity, cooldown, tool ownership, class result, timer, or winner.
- Simultaneous Egg claims produce exactly one finder and one party reward per user.

## 5. Phase acceptance suites

### Phase 1

- Repository inspection report exists.
- Shared config loads identically on server/client sanitized views.
- Mock DataStore profile loads, locks, saves, migrates, and releases.
- Remote registry rejects unknown calls and enforces schemas/rates.
- Party/session/round skeleton transitions through a simulated lifecycle.
- Headless test command exits 0 with test count.
- Studio: two clients join with separate profiles; server shuts down cleanly.

### Phase 2

- Fresh player spawns in a premium lobby with intentional ambient activity.
- Solo party enters Chapter 1, sees/skip-votes cutscene, and timer counts up.
- Hand collection removes authoritative pile cells and fills 25-capacity bag.
- Sell converts 25 standard feathers to $0.25.
- Egg is revealed only after its configured coverage condition.
- First valid claim triggers one winner, rewards, results, save, and lobby return.
- Replayed claim/reward requests do not duplicate.
- At least one representative layer each of animation, UI motion, SFX, VFX, and ambient activity is present.

### Phase 3

- Every config-defined Hand, Bag, and tool upgrade can be purchased to max with injected funds.
- Live values match `SYSTEM_CONFIG.json`/`ECONOMY_TABLES.csv`.
- Rake, Charge, Vac, and Chick complete their state cycles and respect cooldowns.
- Permanent-tool mock entitlement grants maximum configured upgrades; one-round purchase resets next round.
- Normal and Hard modifiers change the same underlying systems through config.
- Four tools remain within remote/particle/physics budgets on mobile quality.

### Phase 4

- Party size, leadership, locks, start cancellation, and teleport fallback work with 1-4 clients.
- Class roll result is committed server-side and revealed after the animation lands.
- All eight displayed class weights sum to 100 and modifiers apply exactly once.
- Daily claim is idempotent and server-time based.
- Code redemption and group reward are one-time.
- Inventory equips only owned skins.
- Stats and chapter selection update from server projections.
- Modal focus, controller selection, and mobile safe areas remain valid across every lobby screen.

### Phase 5

- Hard/Chapter 2 unlock policies are config-driven.
- Chapter 2 key/levers/puzzles/exit can be completed by 1, 2, and 4 clients.
- Wrong puzzle input cannot softlock the round.
- All pass/product flows use mocked Marketplace adapters in tests.
- Receipt retry and duplicate processing are proven.
- Monetization never blocks tutorial or chapter completion.
- Permanent tools and Infinite Bag are validated server-side.

### Phase 6

- Full journey passes on desktop keyboard/mouse, mobile emulation, and controller.
- Two- and four-player simultaneous collection/sale/claim tests pass.
- Disconnect/rejoin within and after reservation window behaves as documented.
- Exploit suite passes.
- Low-tier mobile maintains 30 FPS target in representative stress scene.
- Desktop maintains 60 FPS target on target hardware or documented emulator baseline.
- No unbounded connections, tweens, tasks, instances, particles, or audio channels after a 30-minute soak.
- All placeholder art/audio/copy/debug UI is removed or explicitly release-approved.

## 6. Studio verification protocols

### Protocol A - Fresh vertical slice

1. Clear test profile through a Studio-only secured command.
2. Start Play Solo from the lobby.
3. Record starting currencies/class/wins.
4. Create solo Chapter 1 Normal party.
5. Complete cutscene and tutorial with no debug grants.
6. Collect exactly 25 standard feathers and sell.
7. Confirm cash is `$0.25` and transaction log contains one sale.
8. Continue until Egg reveal; claim once while sending duplicate client requests through the test harness.
9. Confirm one finder announcement, one reward transaction, results, return, and updated persistent projection.
10. Stop/restart Play and confirm persistent reward remains while round cash/upgrades reset.

### Protocol B - Multi-client race

1. Start local server with four clients.
2. Form one party and enter the same round.
3. Have all clients collect the same visible pile region simultaneously.
4. Confirm cells are removed once and yields do not duplicate.
5. Expose the Egg and trigger claim from all clients on the same frame through the test harness.
6. Confirm one finder, four base rewards, one finder bonus, and no duplicated win.
7. Disconnect one non-finder during results; rejoin and confirm its committed reward.

### Protocol C - Purchase and receipt resilience

Use a mock Marketplace adapter in Studio. Do not make live purchases.

1. Prompt each pass/product mapping.
2. Cancel and confirm no grant.
3. Complete mock purchase; fail first save; replay receipt.
4. Confirm exactly one grant and `PurchaseGranted` only after persistence.
5. Replay the same receipt 100 times.

### Protocol D - Mobile/controller

1. Test 16:9, tall phone, notched phone safe area, tablet, and small landscape viewport.
2. Confirm touch targets >= 44 px and no HUD collision with Roblox inset/safe area.
3. Navigate every modal with controller only; close/reopen and confirm focus restoration.
4. Complete one round using each input mode.

### Protocol E - Performance

1. Use production-like pile visuals, four players, four tools, ambient world systems, and victory VFX.
2. Capture CPU frame time, GPU frame time, memory, instance count, physics parts, particles, remote receive/send rates, and server script activity.
3. Run 30 minutes including ten round transitions.
4. Compare start/end memory and instance counts; investigate monotonic growth.

## 7. Evidence report template

Every phase handoff must include:

```markdown
## Verification evidence
- Commit: <full SHA>
- Automated command: <exact command>
- Result: <N passed, N failed, exit code>
- Lint/format/build: <commands and results>
- Studio mode: <Play Solo / local server N clients / device emulator>
- Studio steps completed: <protocol and steps>
- Screenshots or recording: <paths/timecodes>
- Server Output: <zero errors or exact explained warnings>
- Client Output: <zero errors or exact explained warnings>
- Performance measurements: <where applicable>
- Known limitations: <explicit list>
- Documentation updated: <files>
```

## 8. Release blocking defects

- Data loss, duplicated rewards, or unprocessed paid receipts.
- Any client-authoritative currency, inventory, winner, timer, or pile mutation.
- Repeatable remote exploit producing value or server instability.
- A party/round softlock with no recovery path.
- Unreadable or inaccessible required UI on a supported platform.
- Persistent Output errors, memory leak, or severe frame collapse in the representative stress scene.
- Placeholder or copied reference assets/copy remaining in production.
- A phase marked complete without concrete Studio evidence.
