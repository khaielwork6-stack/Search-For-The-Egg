--!strict
-- Pure validator for the raw SYSTEM_CONFIG table. Checks weights, IDs, curves, references, and
-- terminal null costs. Returns a report; it never mutates the input and never throws for data
-- problems (only for a non-table input).

local Validator = {}

export type Report = { ok: boolean, errors: { string }, warnings: { string }, checks: number }

local WEIGHT_TOLERANCE = 1e-6
local KNOWN_DIFFICULTIES = { "normal", "hard" }
local KNOWN_UNLOCK_TYPES = { always = true, chapterWins = true }
local KNOWN_AFTER_DAY8 = { loop_to_day1 = true, stay_on_day8 = true }
local KNOWN_MISS_POLICY = { reset_to_day1_after_grace = true, keep_progress = true }
local KNOWN_LUCK_MODES = { double_odds_at_or_below_weight_then_renormalize_from_newcomer = true }

-- Value keys per upgrade path and the direction the benefit must move as level increases.
local PATH_MONOTONIC: { [string]: { key: string, direction: string } } = {
	grasp = { key = "amount", direction = "up" },
	speed = { key = "walkSpeed", direction = "up" },
	hold = { key = "intervalSeconds", direction = "down" },
	sweep = { key = "yield", direction = "up" },
	cooldown = { key = "seconds", direction = "down" },
	luckyBlast = { key = "rainbowChance", direction = "up" },
	power = { key = "yield", direction = "up" },
	cooling = { key = "seconds", direction = "down" },
	runtime = { key = "seconds", direction = "up" },
	grasp_tool = { key = "value", direction = "up" },
	capacity = { key = "value", direction = "up" },
}

local function sumWeights(items: { any }, key: string): number
	local total = 0
	for _, item in ipairs(items) do
		total += tonumber(item[key]) or 0
	end
	return total
end

local function isPositiveNumber(value: any): boolean
	return type(value) == "number" and value > 0 and value == value and value ~= math.huge
end

local function isNonNegativeNumber(value: any): boolean
	return type(value) == "number" and value >= 0 and value == value and value ~= math.huge
end

function Validator.validate(raw: any): Report
	local errors: { string } = {}
	local warnings: { string } = {}
	local checks = 0

	local function fail(message: string)
		table.insert(errors, message)
	end
	local function warnIf(message: string)
		table.insert(warnings, message)
	end
	local function check(condition: boolean, message: string)
		checks += 1
		if not condition then
			fail(message)
		end
	end

	if type(raw) ~= "table" then
		fail("config root must be a table")
		return { ok = false, errors = errors, warnings = warnings, checks = checks }
	end

	-- Version and project
	check(
		type(raw.configVersion) == "number" and raw.configVersion > 0 and raw.configVersion % 1 == 0,
		"configVersion must be a positive integer"
	)
	check(type(raw.project) == "table", "project block missing")
	if type(raw.project) == "table" then
		check(isPositiveNumber(raw.project.maxServerPlayers), "project.maxServerPlayers must be > 0")
		check(isPositiveNumber(raw.project.maxPartyPlayers), "project.maxPartyPlayers must be > 0")
		check(raw.project.dataAuthority == "server", "project.dataAuthority must be 'server'")
	end

	-- Feature flags are booleans
	check(type(raw.featureFlags) == "table", "featureFlags missing")
	if type(raw.featureFlags) == "table" then
		for name, value in pairs(raw.featureFlags) do
			check(type(value) == "boolean", "featureFlags." .. tostring(name) .. " must be boolean")
		end
	end

	-- Round / interaction
	check(type(raw.round) == "table" and isPositiveNumber(raw.round.maximumRoundSeconds), "round.maximumRoundSeconds must be > 0")
	check(type(raw.round) == "table" and isPositiveNumber(raw.round.rejoinReservationSeconds), "round.rejoinReservationSeconds must be > 0")
	check(type(raw.interaction) == "table", "interaction block missing")
	if type(raw.interaction) == "table" then
		for _, key in ipairs({
			"collectRequestRatePerSecond",
			"toolRequestRatePerSecond",
			"purchaseRequestRatePerSecond",
			"remoteBurstAllowance",
			"defaultRangeStuds",
			"sellRangeStuds",
			"upgradeRangeStuds",
			"serverPositionToleranceStuds",
		}) do
			check(isPositiveNumber(raw.interaction[key]), "interaction." .. key .. " must be > 0")
		end
	end

	-- Currencies
	check(type(raw.currencies) == "table", "currencies block missing")
	if type(raw.currencies) == "table" then
		for name, currency in pairs(raw.currencies) do
			check(
				type(currency) == "table"
					and isNonNegativeNumber(currency.minimum)
					and isPositiveNumber(currency.maximum)
					and currency.maximum > currency.minimum,
				"currencies." .. tostring(name) .. " range invalid"
			)
			check(
				type(currency) == "table" and type(currency.roundScoped) == "boolean",
				"currencies." .. tostring(name) .. ".roundScoped must be boolean"
			)
		end
	end

	-- Collection / selling
	check(
		type(raw.collection) == "table" and isPositiveNumber(raw.collection.startingBagCapacity),
		"collection.startingBagCapacity must be > 0"
	)
	check(
		type(raw.selling) == "table" and isPositiveNumber(raw.selling.cashPerStandardFeather),
		"selling.cashPerStandardFeather must be > 0"
	)
	check(
		type(raw.selling) == "table" and isPositiveNumber(raw.selling.rainbowFeatherMultiplier),
		"selling.rainbowFeatherMultiplier must be > 0"
	)
	if type(raw.collection) == "table" and type(raw.selling) == "table" then
		check(
			raw.collection.baseFeatherCashValue == raw.selling.cashPerStandardFeather,
			"collection.baseFeatherCashValue must equal selling.cashPerStandardFeather"
		)
	end

	-- Bags
	check(type(raw.bags) == "table" and type(raw.bags.levels) == "table", "bags.levels missing")
	if type(raw.bags) == "table" and type(raw.bags.levels) == "table" then
		local levels = raw.bags.levels
		check(#levels == raw.bags.maxLevel, "bags.maxLevel must equal number of bag levels")
		local lastCapacity = 0
		for index, entry in ipairs(levels) do
			check(entry.level == index, "bags.levels[" .. index .. "].level must be " .. index)
			check(isPositiveNumber(entry.capacity) and entry.capacity > lastCapacity, "bags.levels[" .. index .. "].capacity must increase")
			lastCapacity = entry.capacity or lastCapacity
			if index == #levels then
				check(entry.upgradeCash == nil, "final bag level must have null upgradeCash")
			else
				check(isPositiveNumber(entry.upgradeCash), "bags.levels[" .. index .. "].upgradeCash must be > 0")
			end
		end
		if type(raw.collection) == "table" then
			check(
				levels[1] and levels[1].capacity == raw.collection.startingBagCapacity,
				"bag level 1 capacity must equal collection.startingBagCapacity"
			)
		end
	end

	-- Upgrade path helper
	local function validatePath(label: string, levels: any, monotonicKey: string?, direction: string?, startLevel: number)
		if type(levels) ~= "table" or #levels == 0 then
			fail(label .. " must be a non-empty array")
			return
		end
		local previous: number? = nil
		for index, entry in ipairs(levels) do
			local expectedLevel = startLevel + index - 1
			check(type(entry) == "table" and entry.level == expectedLevel, label .. "[" .. index .. "].level must be " .. expectedLevel)
			if type(entry) ~= "table" then
				continue
			end
			if index == #levels then
				check(entry.nextCash == nil, label .. " final level must have null nextCash")
			else
				check(isPositiveNumber(entry.nextCash), label .. "[" .. index .. "].nextCash must be > 0")
			end
			if monotonicKey and entry[monotonicKey] ~= nil then
				local value = entry[monotonicKey]
				check(type(value) == "number", label .. "[" .. index .. "]." .. monotonicKey .. " must be a number")
				if previous ~= nil and type(value) == "number" then
					if direction == "up" then
						check(value > previous, label .. "[" .. index .. "]." .. monotonicKey .. " must increase")
					else
						check(value < previous, label .. "[" .. index .. "]." .. monotonicKey .. " must decrease")
					end
				end
				if type(value) == "number" then
					previous = value
				end
			end
		end
	end

	-- Hand upgrades
	check(type(raw.handUpgrades) == "table", "handUpgrades missing")
	if type(raw.handUpgrades) == "table" then
		for pathName, levels in pairs(raw.handUpgrades) do
			local rule = PATH_MONOTONIC[pathName]
			validatePath("handUpgrades." .. tostring(pathName), levels, rule and rule.key, rule and rule.direction, 0)
		end
	end

	-- Tools and tool upgrades
	check(type(raw.tools) == "table", "tools missing")
	check(type(raw.toolUpgrades) == "table", "toolUpgrades missing")
	if type(raw.tools) == "table" then
		for toolId, tool in pairs(raw.tools) do
			check(
				type(tool) == "table" and type(tool.displayName) == "string" and #tool.displayName > 0,
				"tools." .. tostring(toolId) .. ".displayName missing"
			)
			if type(tool) == "table" then
				check(
					isPositiveNumber(tool.oneRoundRobux) and isPositiveNumber(tool.permanentRobux),
					"tools." .. tostring(toolId) .. " robux prices must be > 0"
				)
				check(
					isPositiveNumber(tool.softCashPrice) or isPositiveNumber(tool.softGemPrice),
					"tools." .. tostring(toolId) .. " needs a soft price"
				)
				check(
					type(tool.permanentIncludesMaxUpgrades) == "boolean",
					"tools." .. tostring(toolId) .. ".permanentIncludesMaxUpgrades must be boolean"
				)
			end
			if type(raw.toolUpgrades) == "table" then
				check(type(raw.toolUpgrades[toolId]) == "table", "toolUpgrades." .. tostring(toolId) .. " missing")
			end
		end
	end
	if type(raw.toolUpgrades) == "table" then
		for toolId, paths in pairs(raw.toolUpgrades) do
			check(type(raw.tools) == "table" and raw.tools[toolId] ~= nil, "toolUpgrades." .. tostring(toolId) .. " has no matching tool")
			if type(paths) == "table" then
				for pathName, levels in pairs(paths) do
					if pathName == "evidence" then
						continue
					end
					local rule = PATH_MONOTONIC[pathName]
					if toolId == "scoutChick" and pathName == "grasp" then
						rule = PATH_MONOTONIC.grasp_tool
					elseif toolId == "scoutChick" and (pathName == "speed" or pathName == "capacity") then
						rule = { key = "value", direction = "up" }
					elseif toolId == "confettiCharge" and pathName == "speed" then
						rule = { key = "fuseSeconds", direction = "down" }
					elseif toolId == "featherVac" and pathName == "power" then
						rule = { key = "perSecond", direction = "up" }
					end
					validatePath(
						"toolUpgrades." .. tostring(toolId) .. "." .. tostring(pathName),
						levels,
						rule and rule.key,
						rule and rule.direction,
						0
					)
				end
			end
		end
	end

	-- Classes
	check(type(raw.classes) == "table" and type(raw.classes.weights) == "table", "classes.weights missing")
	if type(raw.classes) == "table" and type(raw.classes.weights) == "table" then
		local total = sumWeights(raw.classes.weights, "weight")
		check(math.abs(total - 100) <= WEIGHT_TOLERANCE, "class weights must total exactly 100 (got " .. tostring(total) .. ")")
		local seen: { [string]: boolean } = {}
		for index, entry in ipairs(raw.classes.weights) do
			check(type(entry.id) == "string" and #entry.id > 0, "classes.weights[" .. index .. "].id missing")
			check(not seen[entry.id], "duplicate class id " .. tostring(entry.id))
			seen[entry.id] = true
			check(isNonNegativeNumber(entry.weight), "classes.weights[" .. index .. "].weight must be >= 0")
			check(type(entry.effect) == "table", "classes.weights[" .. index .. "].effect must be a table")
		end
		check(seen.newcomer == true, "classes must include the newcomer baseline class")
		check(isPositiveNumber(raw.classes.rollGemCost), "classes.rollGemCost must be > 0")
		check(
			isPositiveNumber(raw.classes.slotsDefault)
				and isPositiveNumber(raw.classes.maximumSlots)
				and raw.classes.maximumSlots >= raw.classes.slotsDefault,
			"classes slot bounds invalid"
		)
		local luck = raw.classes.luckTransform
		check(type(luck) == "table" and KNOWN_LUCK_MODES[luck.mode] == true, "classes.luckTransform.mode unknown")
		check(type(luck) == "table" and isPositiveNumber(luck.rareWeightThreshold), "classes.luckTransform.rareWeightThreshold must be > 0")
	end

	-- Daily rewards
	check(type(raw.dailyRewards) == "table" and #raw.dailyRewards == 8, "dailyRewards must list 8 days")
	if type(raw.dailyRewards) == "table" then
		for index, entry in ipairs(raw.dailyRewards) do
			check(entry.day == index, "dailyRewards[" .. index .. "].day must be " .. index)
			check(isNonNegativeNumber(entry.gems), "dailyRewards[" .. index .. "].gems must be >= 0")
		end
	end
	check(type(raw.dailyRewardRules) == "table", "dailyRewardRules missing")
	if type(raw.dailyRewardRules) == "table" then
		local rules = raw.dailyRewardRules
		check(isPositiveNumber(rules.claimCooldownSeconds), "dailyRewardRules.claimCooldownSeconds must be > 0")
		check(
			isPositiveNumber(rules.gracePeriodSeconds) and rules.gracePeriodSeconds >= rules.claimCooldownSeconds,
			"dailyRewardRules.gracePeriodSeconds must be >= cooldown"
		)
		check(KNOWN_AFTER_DAY8[rules.afterDay8] == true, "dailyRewardRules.afterDay8 unknown")
		check(KNOWN_MISS_POLICY[rules.missPolicy] == true, "dailyRewardRules.missPolicy unknown")
		check(rules.serverTimeOnly == true, "dailyRewardRules.serverTimeOnly must be true")
	end

	-- Permanent perks
	check(type(raw.permanentPerks) == "table", "permanentPerks missing")
	if type(raw.permanentPerks) == "table" then
		for perkId, perk in pairs(raw.permanentPerks) do
			if perkId == "evidence" then
				continue
			end
			check(
				type(perk) == "table"
					and isPositiveNumber(perk.baseGemCost)
					and isPositiveNumber(perk.costGrowth)
					and isPositiveNumber(perk.valuePerLevel)
					and isPositiveNumber(perk.maxLevel),
				"permanentPerks." .. tostring(perkId) .. " invalid"
			)
		end
	end

	-- Chapters and unlock policies
	check(type(raw.chapters) == "table", "chapters missing")
	local chapterIds: { [string]: boolean } = {}
	if type(raw.chapters) == "table" then
		for chapterKey in pairs(raw.chapters) do
			chapterIds[chapterKey] = true
		end
		local function validatePolicy(label: string, policy: any)
			check(type(policy) == "table" and KNOWN_UNLOCK_TYPES[policy.type] == true, label .. ".type unknown")
			if type(policy) == "table" and policy.type == "chapterWins" then
				check(chapterIds[policy.chapter] == true, label .. ".chapter references unknown chapter " .. tostring(policy.chapter))
				check(table.find(KNOWN_DIFFICULTIES, policy.difficulty) ~= nil, label .. ".difficulty unknown")
				check(isPositiveNumber(policy.count), label .. ".count must be > 0")
			end
		end
		local function validateRewards(label: string, rewards: any)
			check(type(rewards) == "table", label .. " missing")
			if type(rewards) == "table" then
				for _, key in ipairs({ "cash", "gems", "wins", "eventTokens" }) do
					check(isNonNegativeNumber(rewards[key]), label .. "." .. key .. " must be >= 0")
				end
			end
		end
		for chapterKey, chapter in pairs(raw.chapters) do
			check(
				type(chapter) == "table" and type(chapter.id) == "string" and type(chapter.displayName) == "string",
				"chapters." .. tostring(chapterKey) .. " needs id/displayName"
			)
			if type(chapter) == "table" then
				validatePolicy("chapters." .. tostring(chapterKey) .. ".normalUnlock", chapter.normalUnlock)
				validatePolicy("chapters." .. tostring(chapterKey) .. ".hardUnlock", chapter.hardUnlock)
				validateRewards("chapters." .. tostring(chapterKey) .. ".normalRewards", chapter.normalRewards)
				validateRewards("chapters." .. tostring(chapterKey) .. ".hardRewards", chapter.hardRewards)
			end
		end
		check(chapterIds.chapter1 == true, "chapter1 must exist")
	end

	-- Difficulty
	check(type(raw.difficulty) == "table", "difficulty missing")
	if type(raw.difficulty) == "table" then
		for _, difficultyId in ipairs(KNOWN_DIFFICULTIES) do
			local entry = raw.difficulty[difficultyId]
			check(type(entry) == "table", "difficulty." .. difficultyId .. " missing")
			if type(entry) == "table" then
				for _, key in ipairs({ "pileHealthMultiplier", "toolYieldMultiplier", "sellMultiplier", "rewardMultiplier" }) do
					check(isPositiveNumber(entry[key]), "difficulty." .. difficultyId .. "." .. key .. " must be > 0")
				end
			end
		end
	end

	-- Pile (ASSUMED A-EGG-07)
	check(type(raw.pile) == "table", "pile block missing")
	if type(raw.pile) == "table" then
		local pile = raw.pile
		check(isPositiveNumber(pile.gridWidth) and pile.gridWidth % 1 == 0, "pile.gridWidth must be a positive integer")
		check(isPositiveNumber(pile.gridDepth) and pile.gridDepth % 1 == 0, "pile.gridDepth must be a positive integer")
		if type(raw.collection) == "table" and type(raw.collection.pileRepresentation) == "table" then
			check(
				pile.gridWidth * pile.gridDepth == raw.collection.pileRepresentation.serverGridCells,
				"pile grid must contain collection.pileRepresentation.serverGridCells cells"
			)
		end
		check(isPositiveNumber(pile.cellSizeStuds), "pile.cellSizeStuds must be > 0")
		check(
			isPositiveNumber(pile.baseFeathersPerCell) and pile.baseFeathersPerCell % 1 == 0,
			"pile.baseFeathersPerCell must be a positive integer"
		)
		check(isNonNegativeNumber(pile.surfaceVariance) and pile.surfaceVariance < 1, "pile.surfaceVariance must be within [0,1)")
		check(isPositiveNumber(pile.coverDepthMultiplier) and pile.coverDepthMultiplier >= 1, "pile.coverDepthMultiplier must be >= 1")
		check(
			isNonNegativeNumber(pile.coverRadiusCells) and pile.coverRadiusCells % 1 == 0,
			"pile.coverRadiusCells must be a non-negative integer"
		)
		check(isPositiveNumber(pile.maxVisualHeightStuds), "pile.maxVisualHeightStuds must be > 0")
	end

	-- Egg spawn
	check(type(raw.eggSpawn) == "table", "eggSpawn missing")
	if type(raw.eggSpawn) == "table" then
		local egg = raw.eggSpawn
		check(isPositiveNumber(egg.spawnNodeCountTarget), "eggSpawn.spawnNodeCountTarget must be > 0")
		check(
			isNonNegativeNumber(egg.minimumRemovalFraction)
				and isPositiveNumber(egg.maximumRemovalFraction)
				and egg.maximumRemovalFraction <= 1
				and egg.minimumRemovalFraction < egg.maximumRemovalFraction,
			"eggSpawn removal fractions invalid"
		)
		check(
			isPositiveNumber(egg.revealRadiusStuds)
				and isPositiveNumber(egg.claimRadiusStuds)
				and egg.claimRadiusStuds >= egg.revealRadiusStuds,
			"eggSpawn radii invalid"
		)
		check(egg.oneWinnerPerRound == true, "eggSpawn.oneWinnerPerRound must be true")
	end

	-- Victory
	check(type(raw.victory) == "table" and isNonNegativeNumber(raw.victory.finderBonusGems), "victory.finderBonusGems must be >= 0")
	check(type(raw.victory) == "table" and raw.victory.saveBeforeTeleport == true, "victory.saveBeforeTeleport must be true")

	-- Monetization
	check(type(raw.monetization) == "table", "monetization missing")
	if type(raw.monetization) == "table" then
		local m = raw.monetization
		check(type(m.gemBundles) == "table" and #m.gemBundles > 0, "monetization.gemBundles missing")
		if type(m.gemBundles) == "table" then
			for index, bundle in ipairs(m.gemBundles) do
				check(isPositiveNumber(bundle.gems) and isPositiveNumber(bundle.robux), "monetization.gemBundles[" .. index .. "] invalid")
			end
		end
		check(type(m.passes) == "table", "monetization.passes missing")
		if type(m.passes) == "table" then
			for passId, pass in pairs(m.passes) do
				check(
					type(pass) == "table" and isPositiveNumber(pass.robux),
					"monetization.passes." .. tostring(passId) .. ".robux must be > 0"
				)
			end
		end
		check(type(m.eventChest) == "table" and type(m.eventChest.rewards) == "table", "monetization.eventChest.rewards missing")
		if type(m.eventChest) == "table" and type(m.eventChest.rewards) == "table" then
			local total = sumWeights(m.eventChest.rewards, "weight")
			check(math.abs(total - 100) <= WEIGHT_TOLERANCE, "event chest weights must total exactly 100 (got " .. tostring(total) .. ")")
			local rewardIds: { [string]: boolean } = {}
			for index, reward in ipairs(m.eventChest.rewards) do
				check(
					type(reward.id) == "string" and not rewardIds[reward.id],
					"eventChest.rewards[" .. index .. "] id missing or duplicate"
				)
				rewardIds[reward.id] = true
				check(isNonNegativeNumber(reward.weight), "eventChest.rewards[" .. index .. "].weight must be >= 0")
				if reward.min ~= nil or reward.max ~= nil then
					check(
						isPositiveNumber(reward.min) and isPositiveNumber(reward.max) and reward.max >= reward.min,
						"eventChest.rewards[" .. index .. "] min/max invalid"
					)
				end
			end
			check(isPositiveNumber(m.eventChest.tokenCost), "eventChest.tokenCost must be > 0")
			if type(m.eventChest.duplicateTokenValues) == "table" then
				for rewardId, tokens in pairs(m.eventChest.duplicateTokenValues) do
					check(rewardIds[rewardId] == true, "eventChest.duplicateTokenValues references unknown reward " .. tostring(rewardId))
					check(isPositiveNumber(tokens), "eventChest.duplicateTokenValues." .. tostring(rewardId) .. " must be > 0")
				end
			end
			if type(m.eventChest.robuxBundles) == "table" then
				for index, bundle in ipairs(m.eventChest.robuxBundles) do
					check(
						isPositiveNumber(bundle.count) and isPositiveNumber(bundle.robux),
						"eventChest.robuxBundles[" .. index .. "] invalid"
					)
				end
			end
		end
		check(
			type(m.principles) == "table"
				and m.principles.receiptHandledServerSide == true
				and m.principles.neverTrustClientPriceOrOwnership == true,
			"monetization principles must keep server authority"
		)
	end

	-- Codes: uppercase, trimmed keys; rewards non-negative
	check(type(raw.codes) == "table", "codes missing")
	if type(raw.codes) == "table" then
		for code, entry in pairs(raw.codes) do
			check(
				type(code) == "string" and code == string.upper(code) and code == (string.match(code, "^%s*(.-)%s*$") or code) and #code > 0,
				"code key must be uppercase and trimmed: " .. tostring(code)
			)
			check(
				type(entry) == "table" and type(entry.active) == "boolean" and type(entry.rewards) == "table",
				"codes." .. tostring(code) .. " invalid"
			)
			if type(entry) == "table" and type(entry.rewards) == "table" then
				for _, amount in pairs(entry.rewards) do
					check(isNonNegativeNumber(amount), "codes." .. tostring(code) .. " reward must be >= 0")
				end
			end
		end
	end

	-- Analytics enumerations
	check(
		type(raw.analytics) == "table" and type(raw.analytics.events) == "table" and #raw.analytics.events > 0,
		"analytics.events missing"
	)
	if type(raw.analytics) == "table" and type(raw.analytics.events) == "table" then
		local seen: { [string]: boolean } = {}
		for index, eventName in ipairs(raw.analytics.events) do
			check(
				type(eventName) == "string" and #eventName > 0 and not seen[eventName],
				"analytics.events[" .. index .. "] invalid or duplicate"
			)
			seen[eventName] = true
		end
		check(
			isNonNegativeNumber(raw.analytics.sampledCollectionEventRate) and raw.analytics.sampledCollectionEventRate <= 1,
			"analytics.sampledCollectionEventRate must be within [0,1]"
		)
		check(
			raw.analytics.neverLogFreeText == true and raw.analytics.neverLogSensitiveData == true,
			"analytics privacy flags must be true"
		)
	end

	-- Polish budgets
	check(type(raw.polishBudgets) == "table", "polishBudgets missing")
	if type(raw.polishBudgets) == "table" then
		local p = raw.polishBudgets
		for _, key in ipairs({
			"targetFpsDesktop",
			"targetFpsMobileLowTier",
			"maximumActiveParticlesDesktop",
			"maximumActiveParticlesMobile",
			"maximumConcurrentOneShotSounds",
			"maximumLoopingAmbientSounds",
			"maximumUiTweenSeconds",
			"minimumTapTargetPixels",
		}) do
			check(isPositiveNumber(p[key]), "polishBudgets." .. key .. " must be > 0")
		end
		check(isPositiveNumber(p.reducedMotionScale) and p.reducedMotionScale <= 1, "polishBudgets.reducedMotionScale must be within (0,1]")
		if
			isPositiveNumber(p.maximumActiveParticlesMobile)
			and isPositiveNumber(p.maximumActiveParticlesDesktop)
			and p.maximumActiveParticlesMobile > p.maximumActiveParticlesDesktop
		then
			warnIf("mobile particle budget exceeds desktop budget")
		end
	end

	return { ok = #errors == 0, errors = errors, warnings = warnings, checks = checks }
end

return Validator
