# Search for the Egg

## Final Game Design Document

Document version: 1.0  
Research and evidence date: 12 September 2026  
Production status: Approved to build in six controlled phases with centralized `ASSUMED` values

## Executive decision

Search for the Egg will enter production now. The supplied five-minute recording and public research are the source of truth for observable lobby, onboarding, collection, selling, tool, upgrade, class, event, and monetization behavior. The recording does not contain the post-victory journey, Hard Mode, Chapter 2, persistence, multiplayer, or mobile behavior. Those systems are deliberately designed here using strong Roblox conventions and are marked `ASSUMED`; their values and policies are centralized in `SYSTEM_CONFIG.json`.

This is not an evidence-gap report. It is a production specification.

## Product vision

Players enter a living, oversized nest environment and use increasingly powerful methods to clear feathers while searching for one hidden Egg. The tactile loop is immediately understandable, but the hidden target creates suspense: every removed patch might expose the Egg. Within a round, the player accelerates through selling and upgrades. Across rounds, wins, best times, classes, permanent perks, chapters, difficulty, cosmetics, events, and daily rewards create return goals.

The product must feel premium and authored. No primary area may resemble an empty simulator template. Animation, ambient movement, layered audio, responsive UI, lighting, VFX, camera response, haptics, and environmental activity are treated as system requirements from the first playable phase. Effects are pooled, distance-culled, quality-scaled, and compatible with mobile performance.

## Build thesis

The game's commercial and retention potential rests on five connected beats:

1. Immediate tactile collection with visible world deformation.
2. Frequent short upgrades that noticeably change efficiency.
3. A concealed Egg that turns ordinary collecting into suspense.
4. A short, high-quality discovery and victory payoff.
5. Persistent classes, wins, unlocks, rewards, and events that make another run meaningful.

## Evidence basis

Primary direct evidence is the user-supplied 5:25.667 H.264 recording at 1280x720 and 60 FPS. It captures a fresh profile, approximately one minute of lobby/meta surfaces, an 18-20 second chapter transition/cutscene, and roughly four minutes of active Farmhouse play. It directly supports the starting 25 capacity, baseline sale examples, early upgrade prices, tool packaging, class odds, Daily rewards, event chest odds, party capacity, and visible unlock gates.

Public sources establish the official experience identity, universe/place structure, badge signals, current analytics snapshot, class-effect corroboration, event codes/currency guidance, Chapter 2 route hypothesis, and historical pass descriptions. Version conflicts are resolved in favor of the uploaded live recording for visible values.

## Evidence labels

- `VERIFIED`: directly visible in the recording or officially documented.
- `CORROBORATED`: supported by multiple reliable public sources or video plus a reliable guide.
- `ASSUMED`: selected production behavior where exact current-build evidence is unavailable.

`ASSUMED` never means hidden. It means configurable, testable, and easy to revise.

## Six-phase roadmap

1. Architecture, networking, configuration, player data, sessions, and tests.
2. Complete playable lobby-to-victory Chapter 1 vertical slice.
3. Progression, bags, Hand, all tools, upgrades, economy, and difficulty math.
4. Complete lobby/meta systems, parties, classes, rewards, inventory, stats, and selection.
5. Hard Mode, Moonlit Cellar/Chapter 2, monetization, permanent tools, and products.
6. Mobile/controller, multiplayer edge cases, security, optimization, complete polish, balance, and release QA.

Every phase must finish with automated tests, actual Roblox Studio verification, concrete evidence, updated documentation, and a committed checkpoint. Claude Code must stop for approval before the next phase.

## Human and machine-readable deliverables

This PDF explains product intent and design. Implementation must also follow:

- `MASTER_SPEC.md`
- `SYSTEM_CONFIG.json`
- `ECONOMY_TABLES.csv`
- `DATASTORE_SCHEMA.md`
- `STATE_MACHINES.md`
- `TEST_PLAN.md`
- `ASSUMPTIONS.md`
- Six standalone phase prompts
- `START_HERE.md`

If this PDF and the machine-readable files conflict, the authority order in `MASTER_SPEC.md` applies.
