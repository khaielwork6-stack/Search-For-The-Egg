# START HERE - Building Search for the Egg with Claude Code

## The correct first move

Do not ask Claude Code to build the whole game from the PDF. Give Claude Code the complete unzipped build-pack folder and run only the Phase 1 prompt.

The best setup is local Claude Code opened at the root of the Roblox repository with:

- The repository already cloned locally.
- Roblox Studio available on the same computer.
- Rojo configured if the repository uses Rojo.
- Existing Wally/tooling preserved.
- A Studio bridge/MCP available if you already use one; otherwise Claude must provide manual Studio verification steps and may not pretend they ran.
- This entire build-pack folder copied into the repository at `docs/SearchForTheEggBuildPack/` or another stable documentation path.

## Exactly what to give Claude Code first

1. Unzip this package.
2. Copy the folder into the game repository without deleting existing files.
3. Open Claude Code in the repository root.
4. Attach or reference the full build-pack directory.
5. Paste the complete contents of:

`PHASE_PROMPTS/PHASE_1_ARCHITECTURE.md`

Do not append “and start Phase 2.” Phase 1 must finish, be verified, committed, and reviewed first.

## Build-pack reading order

Claude Code is instructed to read every file. For your own review, use:

1. `FINAL_GDD.pdf` - product intent and complete human-readable design.
2. `MASTER_SPEC.md` - authoritative implementation rules.
3. `SYSTEM_CONFIG.json` - every tunable value and assumption.
4. `STATE_MACHINES.md` - transitions and invariants.
5. `DATASTORE_SCHEMA.md` - persistence, receipts, migrations, rejoin.
6. `TEST_PLAN.md` - acceptance and evidence requirements.
7. `ASSUMPTIONS.md` - everything not directly observed.
8. `ECONOMY_TABLES.csv` - easy balance-table view.
9. The active phase prompt.

## What to expect from Claude Code before coding

Claude Code should first return a repository inspection report containing:

- Current tree and project format.
- Existing gameplay/data/network/UI/test systems.
- Dirty files and user-owned changes it will preserve.
- Conflicts between the repository and build pack.
- Reusable systems versus systems that must be added.
- The exact Phase 1 file plan.
- Test and Roblox Studio verification route.

It may then implement Phase 1 unless it finds a genuinely blocking permission/repository problem. Missing reference evidence is not a blocker because assumptions are already approved and centralized.

## How to approve a phase

Approve only when Claude Code provides:

- Exact automated test commands and pass counts.
- Formatting/lint/build results.
- Roblox Studio test steps actually completed.
- Server and client Output status.
- Concrete screenshots, recording timecodes, or measurements where relevant.
- Files changed and architectural notes.
- Known limitations.
- Updated repository documentation.
- Full commit SHA for the verified checkpoint.

If it says “should work” or “I could not access Studio,” the phase is not verified. Let it provide a manual test protocol, perform that test yourself, paste the output/screenshots back, and ask it to finish the same phase. Do not advance while a critical phase acceptance criterion is untested.

## Continue between phases

After reviewing a phase:

1. Run the game yourself from the verified commit.
2. Report any defect before proceeding.
3. Have Claude fix and re-verify within the same phase.
4. Once clean, begin a new Claude Code session if context is crowded.
5. Open at the same repository root.
6. Paste the next standalone prompt.

Sequence:

1. `PHASE_1_ARCHITECTURE.md`
2. `PHASE_2_VERTICAL_SLICE.md`
3. `PHASE_3_PROGRESSION_TOOLS.md`
4. `PHASE_4_LOBBY_META.md`
5. `PHASE_5_HARD_BASEMENT_MONETIZATION.md`
6. `PHASE_6_RELEASE_QA.md`

Each prompt requires Claude to inspect the current repository and commit history again, so a fresh session remains safe.

## If you already have working systems

Do not ask Claude to overwrite them for consistency. The prompts explicitly require integration and preservation. Claude should:

- Keep healthy systems.
- Add adapters where names/interfaces differ.
- Migrate incrementally.
- Write characterization tests before modifying risky working behavior.
- Avoid deleting user assets or unrelated code.

## Handling assumptions later

You have authorized production to proceed with assumptions. When new footage or playtest data arrives:

1. Update `SYSTEM_CONFIG.json` first.
2. Mirror the balancing view in `ECONOMY_TABLES.csv`.
3. Update or retire the corresponding row in `ASSUMPTIONS.md`.
4. Update tests that intentionally pin the behavior.
5. Do not patch literals in services or UI.

## Deployment IDs

The build pack contains visible prices but does not invent Roblox Product IDs or Game Pass IDs for the new experience. Before Phase 5 production testing, create the products in the target Roblox experience and provide Claude Code with the actual IDs. The code must reject missing/unknown IDs safely.

## Recommended owner checkpoints

### After Phase 2

Ask: Is the first collect satisfying? Does the nest visibly change? Is the first sale obvious? Is Egg discovery exciting? Does victory feel concise and premium?

### After Phase 3

Ask: Does every upgrade create a felt difference? Is any tool strictly useless? Does paid acceleration skip fun rather than remove friction? Can mobile handle the visual density?

### After Phase 4

Ask: Can a new player identify the main portal instantly? Is the lobby active without clutter? Does every modal work with touch/controller? Does the class reveal wait until the animation lands?

### After Phase 5

Ask: Can every chapter be completed for free? Do receipts survive retries? Are one-round and permanent products unmistakable? Can Chapter 2 ever softlock?

### Before release

Require the complete Phase 6 defect list, performance capture, security test results, device matrix, monetization sandbox proof, and rollback plan.

## The one rule that prevents most Claude Code failures

Never continue because a phase looks mostly finished. Continue only from a tested, documented, committed checkpoint.
