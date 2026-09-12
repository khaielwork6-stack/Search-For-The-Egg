# Search for the Egg - DataStore Schema

## 1. Authority and persistence boundary

The server owns every persistent mutation. Clients may request actions and display predicted feedback, but they never submit final balances, inventory grants, class results, wins, best times, or receipt outcomes.

Persistent: Gems, Event Tokens, chapter wins, difficulty unlocks, best times, class ownership/equipped slots, permanent perk levels, cosmetics, codes, daily state, settings, aggregate stats, tutorial progress, processed developer-product receipts.

Round-scoped: Cash, bag level/capacity, Hand upgrades, soft-purchased tools, one-round product grants, tool upgrades, carried feathers, active objective, local pile contribution. These live in the session store and reset at the next round unless a permanent entitlement defines a starting grant.

Marketplace pass ownership must be queried through Roblox services and treated as canonical. A cached profile snapshot may support diagnostics/UI loading but must never grant ownership by itself.

## 2. DataStore keys

| Store | Key | Purpose |
|---|---|---|
| `SFE_PlayerProfile_v1` | `player:{userId}` | Main player profile |
| `SFE_ReceiptLedger_v1` | `receipt:{purchaseId}` | Idempotent developer-product processing |
| `SFE_GlobalStats_v1` | Sharded ordered stores | Best times, wins, hay/feather totals where appropriate |
| `SFE_ConfigAudit_v1` | `release:{configVersion}` | Optional deployed config hash and release metadata |

Use a profile/session-locking library already present in the repository if it is healthy and compatible. Do not introduce a second profile library. If none exists, create a minimal adapter that supports session locks, reconciliation, migrations, update transactions, and shutdown flushing.

## 3. Canonical profile

```lua
export type PlayerProfile = {
    schemaVersion: number,
    createdAt: number,
    updatedAt: number,

    currencies: {
        gems: number,
        eventTokens: number,
    },

    progression: {
        totalWins: number,
        chapterWins: {[string]: {normal: number, hard: number}},
        bestTimeMs: {[string]: {normal: number?, hard: number?}},
        unlockedChapters: {[string]: boolean},
        unlockedDifficulties: {[string]: {[string]: boolean}},
    },

    classes: {
        owned: {[string]: boolean},
        equipped: {string},
        slotCount: number,
        rollCount: number,
        lastRollAt: number?,
    },

    permanentPerks: {
        bagSize: number,
        handGrab: number,
        gemValue: number,
        featherValue: number,
    },

    inventory: {
        toolSkins: {[string]: boolean},
        equippedSkins: {[string]: string},
        cosmetics: {[string]: boolean},
    },

    entitlementsCache: {
        checkedAt: number,
        passes: {[string]: boolean},
    },

    rewards: {
        dailyIndex: number,
        dailyLastClaimAt: number?,
        dailyStreakStartedAt: number?,
        claimedCodes: {[string]: number},
        groupRewardClaimed: boolean,
    },

    tutorial: {
        version: number,
        completedSteps: {[string]: boolean},
        completed: boolean,
    },

    stats: {
        playtimeSeconds: number,
        feathersCollected: number,
        cashEarnedLifetime: number,
        eggsFound: number,
        roundsStarted: number,
        roundsCompleted: number,
        deaths: number,
    },

    settings: {
        musicVolume: number,
        sfxVolume: number,
        reducedMotion: boolean,
        cameraShake: boolean,
        haptics: boolean,
        qualityMode: string,
    },

    pendingTransactions: {[string]: PendingTransaction},
    migrationHistory: {string},
}
```

## 4. Default profile

```lua
local DEFAULT = {
    schemaVersion = 1,
    createdAt = 0,
    updatedAt = 0,
    currencies = {gems = 0, eventTokens = 0},
    progression = {
        totalWins = 0,
        chapterWins = {
            chapter1 = {normal = 0, hard = 0},
            chapter2 = {normal = 0, hard = 0},
        },
        bestTimeMs = {
            chapter1 = {normal = nil, hard = nil},
            chapter2 = {normal = nil, hard = nil},
        },
        unlockedChapters = {chapter1 = true, chapter2 = false},
        unlockedDifficulties = {
            chapter1 = {normal = true, hard = false},
            chapter2 = {normal = false, hard = false},
        },
    },
    classes = {
        owned = {newcomer = true},
        equipped = {"newcomer"},
        slotCount = 1,
        rollCount = 0,
        lastRollAt = nil,
    },
    permanentPerks = {bagSize = 0, handGrab = 0, gemValue = 0, featherValue = 0},
    inventory = {
        toolSkins = {defaultRake = true, defaultCharge = true, defaultVac = true, defaultChick = true},
        equippedSkins = {
            nestRake = "defaultRake",
            confettiCharge = "defaultCharge",
            featherVac = "defaultVac",
            scoutChick = "defaultChick",
        },
        cosmetics = {},
    },
    entitlementsCache = {checkedAt = 0, passes = {}},
    rewards = {
        dailyIndex = 1,
        dailyLastClaimAt = nil,
        dailyStreakStartedAt = nil,
        claimedCodes = {},
        groupRewardClaimed = false,
    },
    tutorial = {version = 1, completedSteps = {}, completed = false},
    stats = {
        playtimeSeconds = 0,
        feathersCollected = 0,
        cashEarnedLifetime = 0,
        eggsFound = 0,
        roundsStarted = 0,
        roundsCompleted = 0,
        deaths = 0,
    },
    settings = {
        musicVolume = 0.7,
        sfxVolume = 0.85,
        reducedMotion = false,
        cameraShake = true,
        haptics = true,
        qualityMode = "auto",
    },
    pendingTransactions = {},
    migrationHistory = {},
}
```

## 5. Runtime session state

Runtime round state must not be written into the main profile on every collection action.

```lua
export type RoundPlayerState = {
    userId: number,
    roundId: string,
    joinedAtMs: number,
    cashCents: number,
    carriedStandard: number,
    carriedRainbow: number,
    bagLevel: number,
    handLevels: {grasp: number, speed: number, hold: number},
    roundTools: {[string]: boolean},
    toolLevels: {[string]: {[string]: number}},
    contribution: {cellsRemoved: number, feathersCollected: number},
    alive: boolean,
    disconnectedAt: number?,
}
```

Store currency internally as integers whenever possible. Cash uses cents (`cashCents`), not floating-point dollars. Convert only for display. Probabilities use integer basis points or deterministic integer weights in the server RNG implementation.

## 6. Validation and reconciliation

At load and before save:

- Reject non-tables where a table is expected and reconcile missing fields from defaults.
- Clamp all currencies, counts, levels, volumes, slot counts, and timestamps to configured ranges.
- Remove unknown class/tool/cosmetic IDs unless explicitly preserved in a quarantine field for rollout recovery.
- Recalculate unlock booleans from chapter wins and configurable unlock policies; do not trust old booleans alone.
- Validate equipped classes are owned and do not exceed the entitlement-backed slot count.
- Validate equipped skins are owned; fall back to the default skin for that tool.
- Deduplicate code claims and migration IDs.
- Never accept a client-provided profile patch.

## 7. Migration framework

Each migration is pure, ordered, idempotent, and identified by a stable string.

```lua
local MIGRATIONS = {
    {
        id = "v0_to_v1_initial_profile",
        from = 0,
        to = 1,
        apply = function(profile)
            -- Reconcile old keys, convert currency units, and preserve earned value.
            return profile
        end,
    },
}
```

Migration rules:

1. Back up the pre-migration snapshot in structured logs, not in another player-visible currency field.
2. Never reduce paid entitlements or earned premium currency without an explicit compensating migration.
3. Run migration tests against empty, default, partial, malformed, maximum-value, and prior-production fixtures.
4. Add the migration ID to `migrationHistory` only after successful application.
5. Save the migrated profile before permitting economy mutations when practical.

## 8. Transaction model

Use a server-side transaction helper with a stable idempotency key.

Victory key:

```text
roundId:userId:chapterId:difficulty
```

Developer-product key:

```text
purchaseId
```

Transaction sequence:

1. Validate eligibility and current state.
2. Create `pendingTransactions[id]` with before/after intent.
3. Apply the mutation in memory.
4. Save/update atomically where the selected profile system allows.
5. Mark transaction committed and record the receipt ledger.
6. Remove the pending marker on the next safe save.

On replay, a committed transaction returns its original result without granting again. A pending transaction is reconciled by checking whether the after-state already exists.

## 9. Developer product receipts

- Implement `MarketplaceService.ProcessReceipt` in exactly one server module.
- Never return `PurchaseGranted` until the persistent grant is confirmed or idempotently recognized.
- Unknown Product IDs return `NotProcessedYet` and emit an alert; they never grant a guessed item.
- Product definitions map IDs to named grant handlers in configuration. No grant logic belongs in UI code.
- Game passes are checked with `UserOwnsGamePassAsync`; developer products use receipts. Do not treat them interchangeably.

## 10. Save cadence and shutdown

- Load before spawning the interactive player character into the lobby.
- Autosave dirty persistent state every 60-120 seconds with jitter.
- Save immediately after premium currency grants, code/daily claims, class rolls, permanent perk purchases, victory commitment, and settings changes that matter.
- Bind to close and flush active profiles within Roblox's shutdown budget.
- Apply exponential backoff with jitter to transient failures; cap attempts and avoid synchronized retry storms.
- If initial load cannot be established safely, hold the user at a retry screen or remove them with a clear, friendly message. Never start a disposable profile that could overwrite real progress.

## 11. Rejoining

The 120-second round rejoin behavior is `ASSUMED`.

- Active round sessions maintain a short-lived reservation keyed by user ID.
- On disconnect, mark the player absent but retain `RoundPlayerState` until the reservation expires.
- On return to the same live round, restore cash, bag, tools, carried feathers, contribution, and objective state.
- If the round has ended, apply any already-committed reward and return the user to the lobby.
- If the reservation is missing, start a new round session from persistent defaults. Do not reconstruct round cash from the main profile.
- Never allow a second live connection to control the same session state.

## 12. Failure handling and player messaging

| Failure | Server behavior | Player-facing behavior |
|---|---|---|
| Initial profile load timeout | Retry with backoff; no gameplay mutation | Calm full-screen retry state |
| Autosave failure | Retain dirty state; retry; alert telemetry | Small “Saving...” indicator only if prolonged |
| Victory save delay | Hold results/teleport up to configured timeout; queue receipt | “Securing rewards...” with responsive animation |
| Receipt failure | Return `NotProcessedYet`; never double grant | Roblox retry handles later; no false success toast |
| Teleport failure | Keep player in results/lobby fallback and retry safely | Retry button after automatic attempts |
| Corrupt profile field | Quarantine field, reconcile default, structured alert | No scary technical error unless progress is at risk |

## 13. Security and privacy

- Log numeric identifiers and enumerated event fields only; never log chat, free text, or personal information.
- Do not expose full profile state through remotes. Send a sanitized projection required by the current UI.
- Rate-limit profile-affecting remotes separately from cosmetic remotes.
- Use server time for cooldowns and daily rewards.
- Obfuscation is not security. All validation and grants live on the server.
