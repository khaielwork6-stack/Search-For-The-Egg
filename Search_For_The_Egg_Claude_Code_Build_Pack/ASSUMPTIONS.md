# Search for the Egg - Assumptions Register

This file is the canonical register for decisions that were not directly visible in the supplied 5:25 recording or confirmed by current official evidence. Every item is marked `ASSUMED`. The implementation must read tunable values from `SYSTEM_CONFIG.json`; it must not duplicate these values in services, UI controllers, or tests.

## Rules for using assumptions

1. An assumption is a production decision, not a claim about Search For The Needle.
2. Code must refer to a stable configuration key, never a copied literal.
3. Tests may assert the current configured value, but must load the same configuration module generated from the JSON.
4. When later evidence changes a value, update `SYSTEM_CONFIG.json`, `ECONOMY_TABLES.csv`, this register, and the relevant test fixture in one commit.
5. If an assumption changes save semantics, increment the profile schema version and add a migration.

## Core round assumptions

| ID | `ASSUMED` decision | Current value | Why this choice is reasonable | Configuration key |
|---|---|---:|---|---|
| A-RND-01 | Maximum round lifetime | 1,800 seconds | Prevents abandoned servers and pathological sessions while preserving a relaxed count-up timer. | `round.maximumRoundSeconds` |
| A-RND-02 | Rejoin reservation | 120 seconds | Covers common disconnects without keeping stale session membership indefinitely. | `round.rejoinReservationSeconds` |
| A-RND-03 | Victory flow timing | 1.1s lock, 1.5s camera, 2.5s winner, 3s reward | Short, readable, and appropriately celebratory without stalling replay. | `round.discoverySequence` |
| A-RND-04 | Results auto-continue | 15 seconds | Gives players time to read while keeping public parties moving. | `round.resultScreenAutoContinueSeconds` |
| A-RND-05 | Party win credit | All present party members | Supports cooperation and avoids frustrating last-hit competition. | `victory.partyRewardPolicy` |
| A-RND-06 | Finder bonus | 5 Gems | Adds personal excitement without denying party progression. | `victory.finderBonusGems` |
| A-RND-07 | Death penalty | No loss; 3-second respawn | Matches a cozy game and avoids losing paid/earned round progress. | `death` |

## Egg discovery assumptions

| ID | `ASSUMED` decision | Current value | Rationale | Configuration key |
|---|---|---:|---|---|
| A-EGG-01 | Spawn selection | Weighted node, no immediate repeat | Makes QA deterministic enough while reducing obvious repetition. | `eggSpawn.selection` |
| A-EGG-02 | Candidate node target | 24 nodes per chapter | Provides spatial variety without requiring arbitrary voxel positions. | `eggSpawn.spawnNodeCountTarget` |
| A-EGG-03 | Required pile removal | 20%-65% Normal | Produces suspense but avoids a target always near the surface or bottom. | `eggSpawn.minimumRemovalFraction`, `maximumRemovalFraction` |
| A-EGG-04 | Reveal and claim radii | 5 and 8 studs | Clear local discovery with server-side proximity validation. | `eggSpawn.revealRadiusStuds`, `claimRadiusStuds` |
| A-EGG-05 | Claim hold | 0.65 seconds | Long enough to prevent accidental claims, short enough to feel responsive. | `eggSpawn.claimHoldSeconds` |
| A-EGG-06 | One winner event | First valid server claim wins; party shares completion | Prevents duplicate completion and receipt races. | `eggSpawn.oneWinnerPerRound`, `partySharesWin` |

## Economy and progression assumptions

| ID | `ASSUMED` decision | Current value | Rationale | Configuration key |
|---|---|---:|---|---|
| A-ECO-01 | Standard feather value | $0.01 | Multiple visible sale notifications support this baseline; the exact rounding rule is assumed. | `selling.cashPerStandardFeather` |
| A-ECO-02 | Rainbow value | 5x | Makes the Lucky Blast proc readable without dominating the economy. | `selling.rainbowFeatherMultiplier` |
| A-ECO-03 | Bag levels 3-5 | 100, 200, 400 | Clean doubling curve after the verified 25 to 50 step. | `bags.levels` |
| A-ECO-04 | Bag costs after $2 | $5, $12 | Creates reachable milestones around tool purchases. | `bags.levels[].upgradeCash` |
| A-ECO-05 | Remaining Hand curves | See JSON/CSV | Built to produce a meaningful first five-minute upgrade cadence; not claimed as reference values. | `handUpgrades` |
| A-ECO-06 | Remaining tool curves | See JSON/CSV | Monotonic benefits, increasing costs, no hidden formula. | `toolUpgrades` |
| A-ECO-07 | Confetti Charge one-round price | 29 R$ | Fits the visible ladder between Rake/Drone and Vacuum. | `tools.confettiCharge.oneRoundRobux` |
| A-ECO-08 | Completion rewards | Chapter/difficulty table | Rewards are deliberately modest because the persistent economy centers on Gems and unlocks. | `chapters.*.*Rewards` |
| A-ECO-09 | Hard modifiers | 1.6x pile, 0.9x yield, 1.1x sale, 2x reward | Makes Hard perceptibly longer and more valuable without requiring separate content. | `difficulty.hard` |
| A-ECO-10 | Permanent perk effects | +10% per level, capped at 10 | First prices are visible; effects/caps were not. Linear effects are transparent and easy to rebalance. | `permanentPerks` |

## Class and RNG assumptions

The displayed class weights and roll cost are verified. The renamed target classes preserve function while avoiding copied branding.

| ID | `ASSUMED` decision | Current value | Configuration key |
|---|---|---:|---|
| A-CLS-01 | 2x Luck transformation | Double classes at or below 9% then remove excess probability from Newcomer and normalize | `classes.luckTransform` |
| A-CLS-02 | Gem Seeker proc | 1% gem find; 0.2% diamond feather | `classes.weights[gemSeeker].effect` |
| A-CLS-03 | Automation swarm proc | 5% per completed trip | `classes.weights[automationExpert].effect.swarmChancePerTrip` |
| A-CLS-04 | Golden Rush proc | 3% per minute for 15 seconds | `classes.weights[masterForager].effect` |
| A-CLS-05 | Duplicate roll behavior | Duplicate is accepted and simply replaces/equips the same class; no pity | Implemented policy; add config if changed |
| A-CLS-06 | Roll result authority | Server-seeded weighted roll; client animation reveals committed result | Architecture rule |

## Daily, codes, and event assumptions

| ID | `ASSUMED` decision | Current value | Configuration key |
|---|---|---:|---|
| A-META-01 | Daily claim interval | 86,400 seconds | Standard daily cadence; visible cards show 24-hour spacing. | `dailyRewardRules.claimCooldownSeconds` |
| A-META-02 | Miss grace | 48 hours, then reset | Forgiving while keeping streak meaning. | `dailyRewardRules.gracePeriodSeconds` |
| A-META-03 | Day 8 behavior | Loop to Day 1 | No post-Day-8 UI was observed. | `dailyRewardRules.afterDay8` |
| A-META-04 | Group reward | One-time account grant | Avoids group leave/rejoin farming. | `monetization.groupRewardGems` plus saved claim flag |
| A-META-05 | Event skin duplicate conversion | 35/50/75/150 tokens by rarity | Prevents dead duplicate rewards. | `monetization.eventChest.duplicateTokenValues` |
| A-META-06 | ALIEN code availability | Enabled until manually disabled | Public current guides support it; expiry was not official. | `codes.ALIEN` |

## Chapter 2 assumptions

The hidden key, three colored levers, crystal-count puzzle, four-digit note puzzle, 16-tile rotation puzzle, alien release, and ladder exit are corroborated public structure. Their exact layouts, randomization, timings, and failure behavior are not directly observed.

| ID | `ASSUMED` decision | Current value | Configuration key |
|---|---|---:|---|
| A-CH2-01 | Target theme | Moonlit Cellar with an original trapped hatchling story | `chapters.chapter2` |
| A-CH2-02 | Puzzle randomization | New valid solution per round | `chapters.chapter2.puzzles.randomizeEachRound` |
| A-CH2-03 | Wrong input behavior | Non-destructive feedback; puzzle remains solvable | State machine implementation |
| A-CH2-04 | Chapter 2 Hard unlock | One Chapter 2 Normal win | `chapters.chapter2.hardUnlock` |
| A-CH2-05 | Party puzzle ownership | Shared world state, any member can interact | Chapter session state |

## Persistence assumptions

| ID | `ASSUMED` decision | Current value | Rationale |
|---|---|---:|---|
| A-DATA-01 | Round cash/upgrades | Session-scoped; reset at next round | Matches one-round economy and tool packaging. |
| A-DATA-02 | Gems, tokens, classes, wins, best times, cosmetics | Persistent | These drive the lobby/meta loop. |
| A-DATA-03 | Permanent entitlements | Marketplace ownership is canonical; cached snapshot is diagnostic only | Prevents stale saved ownership from granting products. |
| A-DATA-04 | Rejoin | Restore same active round state within 120 seconds where server/session still exists | Reduces disconnect frustration. |
| A-DATA-05 | Save-before-teleport | Reward transaction is committed before lobby teleport | Prevents win loss and duplicate grants. |
| A-DATA-06 | Failed save | Retry with backoff; show non-blocking warning; queue idempotent reward receipt | Protects progression without trusting client state. |

## Multiplayer assumptions

| ID | `ASSUMED` decision | Current value | Rationale |
|---|---|---:|---|
| A-MP-01 | Pile and Egg | Shared by the party | Enables visible cooperation. |
| A-MP-02 | Bag, cash, upgrades | Individual | Preserves personal progression and monetization choices. |
| A-MP-03 | Selling | Individual bag only | Prevents accidental theft of another player's work. |
| A-MP-04 | Tool effects | Remove shared cells; award generated feathers to the acting player | Clear ownership and anti-exploit accounting. |
| A-MP-05 | Completion | All present party members receive base reward; finder receives bonus | Cooperative with a personal moment. |
| A-MP-06 | Late join | Allowed during Searching until the Egg is revealed; no join after Victory begins | Avoids reward sniping. |

## Mobile and accessibility assumptions

| ID | `ASSUMED` decision | Current value | Configuration key |
|---|---|---:|---|
| A-UX-01 | Minimum touch target | 44 px | `polishBudgets.minimumTapTargetPixels` |
| A-UX-02 | Mobile visual strand budget | 420 | `collection.pileRepresentation.clientVisualStrandPoolMobile` |
| A-UX-03 | Low-tier target | Stable 30 FPS | `polishBudgets.targetFpsMobileLowTier` |
| A-UX-04 | Reduced motion | 35% camera/UI motion, no essential information removed | `polishBudgets.reducedMotionScale` |
| A-UX-05 | Controller navigation | Selection groups and explicit focus restoration | UI architecture rule |

## Premium presentation assumptions

These are deliberate target-game requirements rather than reference-game claims.

- Every interactable uses a four-layer response: anticipation, contact, reward, recovery.
- World activity must be visible while idle: drifting feathers, birds, fans, cloth, machinery, lighting variation, and distant activity.
- Ambient motion is pooled, distance-culled, and disabled or simplified on low quality levels.
- UI uses one consistent visual token set, safe-area layout, responsive scale, haptics where supported, and no overlapping modal ownership.
- Audio is layered by state: lobby, searching, pressure/discovery, victory, and results. Music transitions are cross-faded, not restarted abruptly.
- The vertical slice must contain representative polish. Phase 6 refines and optimizes it; it does not introduce game feel for the first time.

## Explicitly disabled until separately designed

The following are not silently assumed into scope: trading, gifting, offline income, subscriptions, rebirth/prestige, global admin events, competitive PvP, and user-generated item exchange. Feature flags remain false. Egg Index and Pets are disabled because the recording advertised an imminent update but did not show the live implementation.
