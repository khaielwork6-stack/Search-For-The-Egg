--!strict
-- Sanitized profile projection sent to the owning client only. Excludes pendingTransactions,
-- entitlementsCache, migrationHistory, raw timestamps, and claimed code history.

local ProfileProjection = {}

ProfileProjection.EXCLUDED_KEYS =
	table.freeze({ "pendingTransactions", "entitlementsCache", "migrationHistory", "createdAt", "updatedAt", "schemaVersion" })

function ProfileProjection.project(data: { [string]: any }, entitlements: { [string]: boolean }, dailyReady: boolean): { [string]: any }
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
			slotCount = data.classes.slotCount,
		},
		permanentPerks = table.clone(data.permanentPerks),
		inventory = {
			toolSkins = table.clone(data.inventory.toolSkins),
			equippedSkins = table.clone(data.inventory.equippedSkins),
			cosmetics = table.clone(data.inventory.cosmetics),
		},
		rewards = {
			dailyIndex = data.rewards.dailyIndex,
			dailyReady = dailyReady,
			groupRewardClaimed = data.rewards.groupRewardClaimed,
		},
		tutorial = {
			version = data.tutorial.version,
			completedSteps = table.clone(data.tutorial.completedSteps),
			completed = data.tutorial.completed,
		},
		stats = {
			playtimeSeconds = data.stats.playtimeSeconds,
			feathersCollected = data.stats.feathersCollected,
			eggsFound = data.stats.eggsFound,
			roundsCompleted = data.stats.roundsCompleted,
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
	return projection.rewards ~= nil and projection.rewards.claimedCodes ~= nil
end

return ProfileProjection
