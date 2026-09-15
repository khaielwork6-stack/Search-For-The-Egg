--!strict
-- Sanitized profile projection sent to the owning client only. Excludes pendingTransactions,
-- entitlementsCache, migrationHistory, raw timestamps, and claimed code history. Phase 4 adds the
-- daily evaluation, the entitlement-backed class slot count, live session playtime, and the
-- remaining personal stats the Stats modal shows.

local ProfileProjection = {}

ProfileProjection.EXCLUDED_KEYS =
	table.freeze({ "pendingTransactions", "entitlementsCache", "migrationHistory", "createdAt", "updatedAt", "schemaVersion" })

export type Extras = {
	daily: { status: string, dayIndex: number, gems: number, nextClaimInSeconds: number, graceRemainingSeconds: number }?,
	slotCount: number?,
	sessionSeconds: number?,
	-- Today's quests as the client draws them: objective, exact progress, reward and claim state.
	-- No transaction ids and no stored record, so nothing here can leak a claim key.
	quests: { any }?,
	questResetInSeconds: number?,
}

function ProfileProjection.project(
	data: { [string]: any },
	entitlements: { [string]: boolean },
	dailyReady: boolean,
	extras: Extras?
): { [string]: any }
	local ex = (extras or {}) :: Extras
	local daily = ex.daily
	return {
		currencies = { gems = data.currencies.gems, eventTokens = data.currencies.eventTokens },
		progression = {
			totalWins = data.progression.totalWins,
			chapterWins = table.clone(data.progression.chapterWins),
			bestTimeMs = table.clone(data.progression.bestTimeMs),
			unlockedChapters = table.clone(data.progression.unlockedChapters),
			unlockedDifficulties = table.clone(data.progression.unlockedDifficulties),
		},
		classes = {
			owned = table.clone(data.classes.owned),
			equipped = table.clone(data.classes.equipped),
			slotCount = ex.slotCount or data.classes.slotCount,
			rollCount = data.classes.rollCount,
		},
		permanentPerks = table.clone(data.permanentPerks),
		inventory = {
			toolSkins = table.clone(data.inventory.toolSkins),
			equippedSkins = table.clone(data.inventory.equippedSkins),
			cosmetics = table.clone(data.inventory.cosmetics),
		},
		rewards = {
			quests = if ex.quests then table.clone(ex.quests) else nil,
			questResetInSeconds = ex.questResetInSeconds,
			dailyIndex = data.rewards.dailyIndex,
			dailyReady = dailyReady,
			groupRewardClaimed = data.rewards.groupRewardClaimed,
			daily = if daily
				then {
					status = daily.status,
					dayIndex = daily.dayIndex,
					gems = daily.gems,
					nextClaimInSeconds = daily.nextClaimInSeconds,
					graceRemainingSeconds = daily.graceRemainingSeconds,
				}
				else nil,
		},
		tutorial = {
			version = data.tutorial.version,
			completedSteps = table.clone(data.tutorial.completedSteps),
			completed = data.tutorial.completed,
		},
		stats = {
			playtimeSeconds = data.stats.playtimeSeconds + (ex.sessionSeconds or 0),
			feathersCollected = data.stats.feathersCollected,
			eggsFound = data.stats.eggsFound,
			roundsCompleted = data.stats.roundsCompleted,
			roundsStarted = data.stats.roundsStarted,
			cashEarnedLifetime = data.stats.cashEarnedLifetime,
			deaths = data.stats.deaths,
		},
		settings = table.clone(data.settings),
		entitlements = table.clone(entitlements),
	}
end

-- True if a projection contains a key that must never leave the server.
function ProfileProjection.leaks(projection: { [string]: any }): boolean
	for _, key in ipairs(ProfileProjection.EXCLUDED_KEYS) do
		if projection[key] ~= nil then
			return true
		end
	end
	if projection.rewards ~= nil then
		local rewards = projection.rewards
		return rewards.claimedCodes ~= nil or rewards.lastDailyClaimTxId ~= nil or rewards.dailyLastClaimAt ~= nil
	end
	return false
end

return ProfileProjection
