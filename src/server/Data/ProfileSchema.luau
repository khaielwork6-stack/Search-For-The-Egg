--!strict
-- Canonical profile defaults plus reconciliation (DATASTORE_SCHEMA.md sections 3, 4, 6).
-- Reconcile never trusts a client patch; it repairs shape, clamps ranges, drops unknown IDs,
-- recomputes unlock booleans from wins, and validates equipped classes/skins.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local TableUtil = require(Shared.Util.TableUtil)
local UnlockPolicy = require(Shared.Domain.UnlockPolicy)

local ProfileSchema = {}

ProfileSchema.SCHEMA_VERSION = 1
ProfileSchema.TUTORIAL_VERSION = 1

local DEFAULT_TOOL_SKINS = table.freeze({
	nestRake = "defaultRake",
	confettiCharge = "defaultCharge",
	featherVac = "defaultVac",
	scoutChick = "defaultChick",
})

function ProfileSchema.default(now: number): { [string]: any }
	return {
		schemaVersion = ProfileSchema.SCHEMA_VERSION,
		createdAt = now,
		updatedAt = now,
		currencies = { gems = 0, eventTokens = 0 },
		progression = {
			totalWins = 0,
			chapterWins = { chapter1 = { normal = 0, hard = 0 }, chapter2 = { normal = 0, hard = 0 } },
			bestTimeMs = { chapter1 = {}, chapter2 = {} },
			unlockedChapters = { chapter1 = true, chapter2 = false },
			unlockedDifficulties = { chapter1 = { normal = true, hard = false }, chapter2 = { normal = false, hard = false } },
		},
		classes = { owned = { newcomer = true }, equipped = { "newcomer" }, slotCount = 1, rollCount = 0, lastRollAt = nil },
		permanentPerks = { bagSize = 0, handGrab = 0, gemValue = 0, featherValue = 0 },
		inventory = {
			toolSkins = { defaultRake = true, defaultCharge = true, defaultVac = true, defaultChick = true },
			equippedSkins = table.clone(DEFAULT_TOOL_SKINS),
			cosmetics = {},
		},
		entitlementsCache = { checkedAt = 0, passes = {} },
		rewards = {
			dailyIndex = 1,
			dailyLastClaimAt = nil,
			dailyStreakStartedAt = nil,
			lastDailyClaimTxId = nil,
			claimedCodes = {},
			groupRewardClaimed = false,
		},
		tutorial = { version = ProfileSchema.TUTORIAL_VERSION, completedSteps = {}, completed = false },
		stats = {
			playtimeSeconds = 0,
			feathersCollected = 0,
			cashEarnedLifetime = 0,
			eggsFound = 0,
			roundsStarted = 0,
			roundsCompleted = 0,
			deaths = 0,
			chestsOpened = 0,
			puzzlesSolved = 0,
		},
		-- Paid grants that apply to a round (one-round tools, skip upgrades) bought outside one:
		-- consumed by the next round the player enters. Persisted so a crash never loses a purchase.
		pendingGrants = { oneRoundTools = {}, skipBagUpgrades = 0 },
		settings = { musicVolume = 0.7, sfxVolume = 0.85, reducedMotion = false, cameraShake = true, haptics = true, qualityMode = "auto" },
		pendingTransactions = {},
		migrationHistory = {},
	}
end

-- Known IDs from configuration.
function ProfileSchema.knownClassIds(cfg: { [string]: any }): { [string]: boolean }
	local out = {}
	for _, entry in ipairs(cfg.classes.weights) do
		out[entry.id] = true
	end
	return out
end

function ProfileSchema.knownSkinIds(cfg: { [string]: any }): { [string]: boolean }
	local out = {}
	for _, skin in pairs(DEFAULT_TOOL_SKINS) do
		out[skin] = true
	end
	for _, reward in ipairs(cfg.monetization.eventChest.rewards) do
		if reward.min == nil and reward.max == nil then
			out[reward.id] = true
		end
	end
	return out
end

local QUALITY_MODES = { auto = true, low = true, medium = true, high = true }

local function ensureTable(parent: { [string]: any }, key: string, default: { [string]: any }, issues: { string }, path: string)
	if type(parent[key]) ~= "table" then
		parent[key] = TableUtil.deepCopy(default)
		table.insert(issues, path .. ":reset")
	end
end

local function reconcileNumber(
	parent: { [string]: any },
	key: string,
	default: number,
	minimum: number,
	maximum: number,
	issues: { string },
	path: string,
	integer: boolean?
)
	local value = parent[key]
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		parent[key] = default
		table.insert(issues, path .. ":reset")
		return
	end
	if integer and value % 1 ~= 0 then
		value = math.floor(value)
		table.insert(issues, path .. ":floor")
	end
	if value < minimum then
		value = minimum
		table.insert(issues, path .. ":clampMin")
	elseif value > maximum then
		value = maximum
		table.insert(issues, path .. ":clampMax")
	end
	parent[key] = value
end

local function reconcileBoolean(parent: { [string]: any }, key: string, default: boolean, issues: { string }, path: string)
	if type(parent[key]) ~= "boolean" then
		parent[key] = default
		table.insert(issues, path .. ":reset")
	end
end

local function reconcileOptionalNumber(
	parent: { [string]: any },
	key: string,
	minimum: number,
	maximum: number,
	issues: { string },
	path: string
)
	local value = parent[key]
	if value == nil then
		return
	end
	if type(value) ~= "number" or value ~= value or value < minimum or value > maximum then
		parent[key] = nil
		table.insert(issues, path .. ":cleared")
	end
end

-- Reconciles a raw stored table into a valid profile. Returns (profile, issues). The input is
-- copied, never mutated. Unknown top-level keys are dropped (quarantined into `_quarantine` count).
function ProfileSchema.reconcile(raw: any, cfg: { [string]: any }, now: number): ({ [string]: any }, { string })
	local issues: { string } = {}
	local default = ProfileSchema.default(now)
	local profile: { [string]: any }
	if type(raw) ~= "table" then
		profile = default
		table.insert(issues, "root:reset")
	else
		profile = TableUtil.deepCopy(raw)
	end

	-- Drop unknown top-level keys (schema drift / tampering) but keep a count for telemetry.
	local dropped = 0
	for key in pairs(profile) do
		if default[key] == nil and key ~= "_quarantine" then
			profile[key] = nil
			dropped += 1
		end
	end
	if dropped > 0 then
		table.insert(issues, "root:unknownKeys=" .. dropped)
	end

	reconcileNumber(profile, "schemaVersion", 0, 0, ProfileSchema.SCHEMA_VERSION, issues, "schemaVersion", true)
	reconcileNumber(profile, "createdAt", now, 0, 4102444800, issues, "createdAt", true)
	reconcileNumber(profile, "updatedAt", now, 0, 4102444800, issues, "updatedAt", true)

	-- Currencies -------------------------------------------------------------------------------
	ensureTable(profile, "currencies", default.currencies, issues, "currencies")
	for name, currency in pairs(cfg.currencies) do
		if currency.roundScoped then
			continue
		end
		reconcileNumber(profile.currencies, name, currency.default, currency.minimum, currency.maximum, issues, "currencies." .. name, true)
	end
	for key in pairs(profile.currencies) do
		if default.currencies[key] == nil then
			profile.currencies[key] = nil
			table.insert(issues, "currencies." .. key .. ":unknown")
		end
	end

	-- Progression ------------------------------------------------------------------------------
	ensureTable(profile, "progression", default.progression, issues, "progression")
	local progression = profile.progression
	reconcileNumber(progression, "totalWins", 0, 0, 1e9, issues, "progression.totalWins", true)
	ensureTable(progression, "chapterWins", default.progression.chapterWins, issues, "progression.chapterWins")
	ensureTable(progression, "bestTimeMs", default.progression.bestTimeMs, issues, "progression.bestTimeMs")
	for chapterKey in pairs(cfg.chapters) do
		ensureTable(progression.chapterWins, chapterKey, { normal = 0, hard = 0 }, issues, "progression.chapterWins." .. chapterKey)
		for _, difficulty in ipairs({ "normal", "hard" }) do
			reconcileNumber(
				progression.chapterWins[chapterKey],
				difficulty,
				0,
				0,
				1e9,
				issues,
				"progression.chapterWins." .. chapterKey .. "." .. difficulty,
				true
			)
		end
		ensureTable(progression.bestTimeMs, chapterKey, {}, issues, "progression.bestTimeMs." .. chapterKey)
		for _, difficulty in ipairs({ "normal", "hard" }) do
			reconcileOptionalNumber(
				progression.bestTimeMs[chapterKey],
				difficulty,
				1,
				cfg.round.maximumRoundSeconds * 1000,
				issues,
				"progression.bestTimeMs." .. chapterKey .. "." .. difficulty
			)
		end
	end
	for chapterKey in pairs(progression.chapterWins) do
		if cfg.chapters[chapterKey] == nil then
			progression.chapterWins[chapterKey] = nil
			table.insert(issues, "progression.chapterWins." .. tostring(chapterKey) .. ":unknown")
		end
	end
	-- Unlocks are recomputed from wins and policy; stored booleans are never trusted alone.
	progression.unlockedChapters, progression.unlockedDifficulties = UnlockPolicy.recompute(cfg.chapters, progression)

	-- Classes ----------------------------------------------------------------------------------
	ensureTable(profile, "classes", default.classes, issues, "classes")
	local classes = profile.classes
	local knownClasses = ProfileSchema.knownClassIds(cfg)
	ensureTable(classes, "owned", default.classes.owned, issues, "classes.owned")
	for classId, owned in pairs(classes.owned) do
		if not knownClasses[classId] or owned ~= true then
			classes.owned[classId] = nil
			table.insert(issues, "classes.owned." .. tostring(classId) .. ":removed")
		end
	end
	classes.owned.newcomer = true
	reconcileNumber(
		classes,
		"slotCount",
		cfg.classes.slotsDefault,
		cfg.classes.slotsDefault,
		cfg.classes.maximumSlots,
		issues,
		"classes.slotCount",
		true
	)
	reconcileNumber(classes, "rollCount", 0, 0, 1e9, issues, "classes.rollCount", true)
	reconcileOptionalNumber(classes, "lastRollAt", 0, 4102444800, issues, "classes.lastRollAt")
	if type(classes.equipped) ~= "table" then
		classes.equipped = { "newcomer" }
		table.insert(issues, "classes.equipped:reset")
	else
		local cleaned = {}
		local seen = {}
		for _, classId in ipairs(classes.equipped) do
			if classes.owned[classId] and not seen[classId] and #cleaned < classes.slotCount then
				table.insert(cleaned, classId)
				seen[classId] = true
			end
		end
		if #cleaned ~= #classes.equipped then
			table.insert(issues, "classes.equipped:pruned")
		end
		if #cleaned == 0 then
			cleaned = { "newcomer" }
		end
		classes.equipped = cleaned
	end

	-- Permanent perks --------------------------------------------------------------------------
	ensureTable(profile, "permanentPerks", default.permanentPerks, issues, "permanentPerks")
	for perkId, perk in pairs(cfg.permanentPerks) do
		if perkId == "evidence" then
			continue
		end
		reconcileNumber(profile.permanentPerks, perkId, 0, 0, perk.maxLevel, issues, "permanentPerks." .. perkId, true)
	end
	for perkId in pairs(profile.permanentPerks) do
		if default.permanentPerks[perkId] == nil then
			profile.permanentPerks[perkId] = nil
			table.insert(issues, "permanentPerks." .. tostring(perkId) .. ":unknown")
		end
	end

	-- Inventory --------------------------------------------------------------------------------
	ensureTable(profile, "inventory", default.inventory, issues, "inventory")
	local inventory = profile.inventory
	local knownSkins = ProfileSchema.knownSkinIds(cfg)
	ensureTable(inventory, "toolSkins", default.inventory.toolSkins, issues, "inventory.toolSkins")
	for skinId, owned in pairs(inventory.toolSkins) do
		if not knownSkins[skinId] or owned ~= true then
			inventory.toolSkins[skinId] = nil
			table.insert(issues, "inventory.toolSkins." .. tostring(skinId) .. ":removed")
		end
	end
	for _, skin in pairs(DEFAULT_TOOL_SKINS) do
		inventory.toolSkins[skin] = true
	end
	ensureTable(inventory, "equippedSkins", default.inventory.equippedSkins, issues, "inventory.equippedSkins")
	for toolId, defaultSkin in pairs(DEFAULT_TOOL_SKINS :: { [string]: string }) do
		local equipped = inventory.equippedSkins[toolId]
		if type(equipped) ~= "string" or not inventory.toolSkins[equipped] then
			inventory.equippedSkins[toolId] = defaultSkin
			if equipped ~= nil then
				table.insert(issues, "inventory.equippedSkins." .. toolId .. ":fallback")
			end
		end
	end
	for toolId in pairs(inventory.equippedSkins) do
		if DEFAULT_TOOL_SKINS[toolId] == nil then
			inventory.equippedSkins[toolId] = nil
			table.insert(issues, "inventory.equippedSkins." .. tostring(toolId) .. ":unknown")
		end
	end
	ensureTable(inventory, "cosmetics", {}, issues, "inventory.cosmetics")

	-- Entitlement cache (diagnostic only) -----------------------------------------------------
	ensureTable(profile, "entitlementsCache", default.entitlementsCache, issues, "entitlementsCache")
	reconcileNumber(profile.entitlementsCache, "checkedAt", 0, 0, 4102444800, issues, "entitlementsCache.checkedAt", true)
	ensureTable(profile.entitlementsCache, "passes", {}, issues, "entitlementsCache.passes")

	-- Rewards ----------------------------------------------------------------------------------
	ensureTable(profile, "rewards", default.rewards, issues, "rewards")
	local rewards = profile.rewards
	reconcileNumber(rewards, "dailyIndex", 1, 1, #cfg.dailyRewards, issues, "rewards.dailyIndex", true)
	reconcileOptionalNumber(rewards, "dailyLastClaimAt", 0, 4102444800, issues, "rewards.dailyLastClaimAt")
	reconcileOptionalNumber(rewards, "dailyStreakStartedAt", 0, 4102444800, issues, "rewards.dailyStreakStartedAt")
	ensureTable(rewards, "claimedCodes", {}, issues, "rewards.claimedCodes")
	for code, claimedAt in pairs(rewards.claimedCodes) do
		if type(code) ~= "string" or type(claimedAt) ~= "number" then
			rewards.claimedCodes[code] = nil
			table.insert(issues, "rewards.claimedCodes:pruned")
		end
	end
	reconcileBoolean(rewards, "groupRewardClaimed", false, issues, "rewards.groupRewardClaimed")
	if rewards.lastDailyClaimTxId ~= nil and type(rewards.lastDailyClaimTxId) ~= "string" then
		rewards.lastDailyClaimTxId = nil
		table.insert(issues, "rewards.lastDailyClaimTxId:cleared")
	end

	-- Tutorial ---------------------------------------------------------------------------------
	ensureTable(profile, "tutorial", default.tutorial, issues, "tutorial")
	reconcileNumber(profile.tutorial, "version", ProfileSchema.TUTORIAL_VERSION, 0, 1000, issues, "tutorial.version", true)
	ensureTable(profile.tutorial, "completedSteps", {}, issues, "tutorial.completedSteps")
	reconcileBoolean(profile.tutorial, "completed", false, issues, "tutorial.completed")
	if profile.tutorial.version ~= ProfileSchema.TUTORIAL_VERSION then
		profile.tutorial = TableUtil.deepCopy(default.tutorial)
		table.insert(issues, "tutorial:versionReset")
	end

	-- Stats ------------------------------------------------------------------------------------
	ensureTable(profile, "stats", default.stats, issues, "stats")
	for key, value in pairs(default.stats) do
		reconcileNumber(profile.stats, key, value, 0, 1e12, issues, "stats." .. key, true)
	end
	for key in pairs(profile.stats) do
		if default.stats[key] == nil then
			profile.stats[key] = nil
		end
	end

	-- Pending paid grants ------------------------------------------------------------------------
	ensureTable(profile, "pendingGrants", default.pendingGrants, issues, "pendingGrants")
	ensureTable(profile.pendingGrants, "oneRoundTools", {}, issues, "pendingGrants.oneRoundTools")
	for toolId, count in pairs(profile.pendingGrants.oneRoundTools) do
		if cfg.tools[toolId] == nil or type(count) ~= "number" or count < 1 then
			profile.pendingGrants.oneRoundTools[toolId] = nil
			table.insert(issues, "pendingGrants.oneRoundTools." .. tostring(toolId) .. ":removed")
		else
			profile.pendingGrants.oneRoundTools[toolId] = math.floor(math.min(count, 100))
		end
	end
	reconcileNumber(profile.pendingGrants, "skipBagUpgrades", 0, 0, 100, issues, "pendingGrants.skipBagUpgrades", true)

	-- Settings ---------------------------------------------------------------------------------
	ensureTable(profile, "settings", default.settings, issues, "settings")
	local settings = profile.settings
	reconcileNumber(settings, "musicVolume", default.settings.musicVolume, 0, 1, issues, "settings.musicVolume")
	reconcileNumber(settings, "sfxVolume", default.settings.sfxVolume, 0, 1, issues, "settings.sfxVolume")
	reconcileBoolean(settings, "reducedMotion", false, issues, "settings.reducedMotion")
	reconcileBoolean(settings, "cameraShake", true, issues, "settings.cameraShake")
	reconcileBoolean(settings, "haptics", true, issues, "settings.haptics")
	if type(settings.qualityMode) ~= "string" or not QUALITY_MODES[settings.qualityMode] then
		settings.qualityMode = "auto"
		table.insert(issues, "settings.qualityMode:reset")
	end
	for key in pairs(settings) do
		if default.settings[key] == nil then
			settings[key] = nil
		end
	end

	-- Transactions and migrations --------------------------------------------------------------
	ensureTable(profile, "pendingTransactions", {}, issues, "pendingTransactions")
	for txId, tx in pairs(profile.pendingTransactions) do
		if type(txId) ~= "string" or type(tx) ~= "table" or tx.id ~= txId then
			profile.pendingTransactions[txId] = nil
			table.insert(issues, "pendingTransactions:pruned")
		end
	end
	if type(profile.migrationHistory) ~= "table" then
		profile.migrationHistory = {}
		table.insert(issues, "migrationHistory:reset")
	else
		local deduped = {}
		local seen = {}
		for _, id in ipairs(profile.migrationHistory) do
			if type(id) == "string" and not seen[id] then
				seen[id] = true
				table.insert(deduped, id)
			end
		end
		if #deduped ~= #profile.migrationHistory then
			table.insert(issues, "migrationHistory:deduped")
		end
		profile.migrationHistory = deduped
	end

	return profile, issues
end

ProfileSchema.DEFAULT_TOOL_SKINS = DEFAULT_TOOL_SKINS

return ProfileSchema
