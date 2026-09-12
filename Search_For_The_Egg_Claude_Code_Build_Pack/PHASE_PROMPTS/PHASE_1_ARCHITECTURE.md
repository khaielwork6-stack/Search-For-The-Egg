# Claude Code Prompt - Phase 1: Architecture, Networking, Data, Sessions, and Tests

You are implementing Phase 1 of the Roblox experience `Search for the Egg`. Work inside the existing repository. Do not begin Phase 2.

Mandatory contract summary: Inspect first; read the complete build pack; report conflicts and dependencies; implement only Phase 1; preserve working systems; keep the server-authoritative boundary; run automated tests; verify in Roblox Studio; provide concrete evidence; update documentation; commit the verified checkpoint; Stop and wait for approval.

## Mandatory source material

Locate and read the complete build-pack directory before changing code, including `START_HERE.md`, `MASTER_SPEC.md`, `SYSTEM_CONFIG.json`, `ECONOMY_TABLES.csv`, `DATASTORE_SCHEMA.md`, `STATE_MACHINES.md`, `TEST_PLAN.md`, `ASSUMPTIONS.md`, and `FINAL_GDD.pdf`. Also read every applicable `AGENTS.md`, README, project manifest, Rojo configuration, Wally manifest, tool configuration, and repository-specific instruction.

Authority order: latest user instruction -> `MASTER_SPEC.md` -> `SYSTEM_CONFIG.json` -> state/data/test documents -> assumptions/economy -> GDD. Report any conflicts before implementation. Do not invent missing values; use configured `ASSUMED` values.

## Required workflow

1. Inspect the existing repository first: tree, git status, recent commits, architecture, packages, tooling, tests, Studio/Rojo workflow, and existing data/network/session/UI systems.
2. Identify user-owned dirty changes and preserve them.
3. Report conflicts, dependencies, reusable systems, risks, and the exact Phase 1 file plan.
4. Implement only Phase 1.
5. Avoid deleting or rewriting working systems unnecessarily. Add characterization tests before risky modifications.
6. Keep the server authoritative. Client modules receive sanitized projections and cosmetic cues only.
7. Run automated tests, formatting, linting, type/build checks, and config validation.
8. Verify the result inside Roblox Studio. Use the available local Studio/Rojo/MCP workflow. Never claim Studio verification if it was not actually performed.
9. Provide concrete test evidence: exact commands, exit codes, pass counts, Studio mode/steps, Output errors/warnings, screenshots/timecodes where possible.
10. Update repository documentation, including an implementation status record and deviations from the pack.
11. Commit the verified Phase 1 checkpoint with a clear commit message and provide the full SHA. Do not include unrelated user changes.
12. Stop and wait for approval. Do not begin Phase 2.

## Phase 1 scope

Build or integrate:

- Typed immutable shared configuration aligned to `SYSTEM_CONFIG.json` and a validator that checks weights, IDs, curves, references, and terminal null costs.
- A deployment-only Product/Game Pass ID mapping with safe missing-ID behavior; do not invent live IDs.
- Shared domain types, injected clock, injected RNG, integer-cents economy primitives, modifier resolver skeleton, and pure state reducers.
- One typed remote registry with direction, schema validation, payload bounds, per-action rate limits, and sanitized error/result envelopes. Do not expose a generic arbitrary-method remote.
- Player profile adapter with session locking, defaults, reconciliation, migrations, dirty tracking, autosave, shutdown flush, load-failure hold state, and test doubles.
- Idempotent transaction abstraction for rewards and developer-product receipts; receipt grant implementations can remain stubbed until Phase 5, but replay safety must be testable now.
- Entitlement adapter interface with mocks; Marketplace calls may be integrated if already present.
- Party/session/round lifecycle skeletons and tokens matching `STATE_MACHINES.md`; no complete collection gameplay yet.
- Analytics adapter with enumerated events, config/build version, high-frequency sampling, and no free-text logging.
- Client bootstrap, sanitized profile projection, modal ownership foundation, input abstraction, quality/accessibility settings foundation, and design tokens.
- Testing framework integrated with existing tools. Prefer existing healthy frameworks rather than adding duplicates.
- Studio-only debug/test hooks that are disabled in production and strictly allowlisted.

## Premium baseline required in Phase 1

Do not build an empty technical shell. Establish reusable presentation foundations:

- UI design tokens and button/modal/toast motion semantics.
- Audio buses and a state-driven AudioDirector interface.
- Pooled VFX interface and quality budget tiers.
- Ambient activity scheduler/component that avoids per-object Heartbeat loops.
- Haptic/camera feedback interfaces with reduced-motion support.

Use original placeholder primitives only where necessary; label every placeholder and give it an owner/removal phase. Do not copy reference assets or text.

## Out of scope

- Complete pile collection, selling, Egg discovery, and victory journey.
- Full tools/upgrades.
- Full lobby/meta UI.
- Chapter 2 content.
- Live monetization grants.

## Required automated evidence

At minimum prove:

- Config parses and validates; class and chest weights each total 100.
- Server/client config projections do not expose server-only code/product secrets.
- Malformed/oversized/unknown remote requests are rejected and rate-limited.
- Profile default, reconciliation, clamping, migration idempotency, session lock, save failure, and release work using injected adapters.
- Victory/receipt transaction replay grants exactly once in the test harness.
- Party/session/round skeleton transitions reject invalid states and duplicate start.
- Modifier resolver does not double-apply sources.
- Headless/test command exits successfully with a reported test count.

## Required Studio evidence

- Build/sync succeeds.
- Play Solo loads a default test profile into an intentional lobby shell with no new Output errors.
- A local server with two clients gives each client a separate sanitized profile and releases locks on shutdown.
- Modal/input/design-token foundation renders at desktop and one phone viewport.
- Ambient scheduler, audio bus, and pooled VFX sample run and clean up without growing instance/connection counts.

## Final response format

Return: inspection findings; conflicts/dependencies; implementation summary; changed files; exact automated evidence; exact Studio evidence; known limitations/placeholders; documentation changes; full commit SHA; statement that Phase 2 has not begun. Then stop.
