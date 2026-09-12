--!strict
-- Domain types only. No behavior. Mirrors DATASTORE_SCHEMA.md and STATE_MACHINES.md.

export type Difficulty = "normal" | "hard"

export type ChapterKey = "chapter1" | "chapter2"

export type PendingTransaction = {
	id: string,
	kind: string,
	createdAt: number,
	committedAt: number?,
	result: any?,
	intent: { [string]: any }?,
}

export type PlayerProfile = {
	schemaVersion: number,
	createdAt: number,
	updatedAt: number,
	currencies: { gems: number, eventTokens: number },
	progression: {
		totalWins: number,
		chapterWins: { [string]: { normal: number, hard: number } },
		bestTimeMs: { [string]: { normal: number?, hard: number? } },
		unlockedChapters: { [string]: boolean },
		unlockedDifficulties: { [string]: { [string]: boolean } },
	},
	classes: {
		owned: { [string]: boolean },
		equipped: { string },
		slotCount: number,
		rollCount: number,
		lastRollAt: number?,
	},
	permanentPerks: { bagSize: number, handGrab: number, gemValue: number, featherValue: number },
	inventory: {
		toolSkins: { [string]: boolean },
		equippedSkins: { [string]: string },
		cosmetics: { [string]: boolean },
	},
	entitlementsCache: { checkedAt: number, passes: { [string]: boolean } },
	rewards: {
		dailyIndex: number,
		dailyLastClaimAt: number?,
		dailyStreakStartedAt: number?,
		claimedCodes: { [string]: number },
		groupRewardClaimed: boolean,
	},
	tutorial: { version: number, completedSteps: { [string]: boolean }, completed: boolean },
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
	pendingTransactions: { [string]: PendingTransaction },
	migrationHistory: { string },
}

-- Sanitized projection sent to the owning client. Never includes pendingTransactions,
-- entitlementsCache, migrationHistory, or raw timestamps that leak server internals.
export type ProfileProjection = {
	currencies: { gems: number, eventTokens: number },
	progression: {
		totalWins: number,
		chapterWins: { [string]: { normal: number, hard: number } },
		bestTimeMs: { [string]: { normal: number?, hard: number? } },
		unlockedChapters: { [string]: boolean },
		unlockedDifficulties: { [string]: { [string]: boolean } },
	},
	classes: { owned: { [string]: boolean }, equipped: { string }, slotCount: number },
	permanentPerks: { bagSize: number, handGrab: number, gemValue: number, featherValue: number },
	inventory: { toolSkins: { [string]: boolean }, equippedSkins: { [string]: string }, cosmetics: { [string]: boolean } },
	rewards: { dailyIndex: number, dailyReady: boolean, groupRewardClaimed: boolean },
	tutorial: { version: number, completedSteps: { [string]: boolean }, completed: boolean },
	stats: { playtimeSeconds: number, feathersCollected: number, eggsFound: number, roundsCompleted: number },
	settings: {
		musicVolume: number,
		sfxVolume: number,
		reducedMotion: boolean,
		cameraShake: boolean,
		haptics: boolean,
		qualityMode: string,
	},
	entitlements: { [string]: boolean },
}

export type RoundPlayerState = {
	userId: number,
	roundId: string,
	joinedAtMs: number,
	cashCents: number,
	carriedStandard: number,
	carriedRainbow: number,
	bagLevel: number,
	handLevels: { grasp: number, speed: number, hold: number },
	roundTools: { [string]: boolean },
	toolLevels: { [string]: { [string]: number } },
	contribution: { cellsRemoved: number, feathersCollected: number },
	alive: boolean,
	disconnectedAt: number?,
}

export type ModifierSource = {
	id: string, -- unique source id, e.g. "class:nestCarrier", "perk:bagSize", "difficulty:hard"
	kind: "class" | "perk" | "difficulty" | "entitlement" | "tool" | "debug",
	bagCapacityMultiplier: number?,
	sellMultiplier: number?,
	toolYieldMultiplier: number?,
	rakeYieldMultiplier: number?,
	rakeUpgradeCostMultiplier: number?,
	blastRadiusMultiplier: number?,
	pileHealthMultiplier: number?,
	rewardMultiplier: number?,
	gemValueMultiplier: number?,
	handGrabMultiplier: number?,
	infiniteBag: boolean?,
	procs: { [string]: number }?,
	params: { [string]: number }?,
	entitlements: { [string]: boolean }?,
}

export type ResolvedModifiers = {
	bagCapacityMultiplier: number,
	sellMultiplier: number,
	toolYieldMultiplier: number,
	rakeYieldMultiplier: number,
	rakeUpgradeCostMultiplier: number,
	blastRadiusMultiplier: number,
	pileHealthMultiplier: number,
	rewardMultiplier: number,
	gemValueMultiplier: number,
	handGrabMultiplier: number,
	infiniteBag: boolean,
	procs: { [string]: number },
	params: { [string]: number },
	entitlements: { [string]: boolean },
	appliedSources: { string },
}

export type Envelope<T> = {
	ok: boolean,
	data: T?,
	code: string?,
	message: string?,
}

return nil
