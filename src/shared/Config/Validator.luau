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
	-- Crate run (the sold crate rides the conveyors into the machine and falls into the pit) - ASSUMED
	local crate = type(raw.selling) == "table" and raw.selling.crate or nil
	check(type(crate) == "table", "selling.crate missing")
	if type(crate) == "table" then
		for _, key in ipairs({
			"liftSeconds",
			"beltStudsPerSecond",
			"machineSeconds",
			"turnSeconds",
			"toPitSeconds",
			"tipSeconds",
			"fallSeconds",
			"fallDepthStuds",
			"rollerSpinDegreesPerSecond",
		}) do
			check(isPositiveNumber(crate[key]), "selling.crate." .. key .. " must be > 0")
		end
		check(isNonNegativeNumber(crate.resetDelaySeconds), "selling.crate.resetDelaySeconds must be >= 0")
		-- OWNER 16 Sep 2026: the crate only refuses a second sale for this long, not for its whole ride.
		check(isNonNegativeNumber(crate.sellCooldownSeconds), "selling.crate.sellCooldownSeconds must be >= 0")
		check(
			isPositiveNumber(crate.featherVisualMax) and crate.featherVisualMax % 1 == 0 and crate.featherVisualMax <= 64,
			"selling.crate.featherVisualMax must be an integer 1..64"
		)
	end
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

	-- Phase 4 ASSUMED lobby/meta policies (A-LOBBY-01..03, A-META-07..08)
	check(type(raw.lobby) == "table", "lobby block missing")
	if type(raw.lobby) == "table" then
		local lobby = raw.lobby
		check(isPositiveNumber(lobby.classRollAnimationSeconds), "lobby.classRollAnimationSeconds must be > 0")
		check(
			isPositiveNumber(lobby.classRollFastAnimationSeconds) and lobby.classRollFastAnimationSeconds <= lobby.classRollAnimationSeconds,
			"lobby.classRollFastAnimationSeconds must be > 0 and <= classRollAnimationSeconds"
		)
		check(isNonNegativeNumber(lobby.classRollMinIntervalSeconds), "lobby.classRollMinIntervalSeconds must be >= 0")
		check(isPositiveNumber(lobby.autoRollMaxPerMinute), "lobby.autoRollMaxPerMinute must be > 0")
		check(isPositiveNumber(lobby.stationPromptRangeStuds), "lobby.stationPromptRangeStuds must be > 0")
		check(isNonNegativeNumber(lobby.padFullAutoStartSeconds), "lobby.padFullAutoStartSeconds must be >= 0")
		check(isPositiveNumber(lobby.padZoneHeightStuds), "lobby.padZoneHeightStuds must be > 0")
		check(type(lobby.ambientActorsByTier) == "table", "lobby.ambientActorsByTier missing")
		if type(lobby.ambientActorsByTier) == "table" then
			for _, tier in ipairs({ "low", "medium", "high" }) do
				check(
					isPositiveNumber(lobby.ambientActorsByTier[tier]) and lobby.ambientActorsByTier[tier] % 1 == 0,
					"lobby.ambientActorsByTier." .. tier .. " must be a positive integer"
				)
			end
		end
	end
	check(type(raw.codePolicy) == "table", "codePolicy block missing")
	if type(raw.codePolicy) == "table" then
		local policy = raw.codePolicy
		check(isPositiveNumber(policy.maxLength) and policy.maxLength % 1 == 0, "codePolicy.maxLength must be a positive integer")
		check(isPositiveNumber(policy.attemptsPerMinute), "codePolicy.attemptsPerMinute must be > 0")
		check(isPositiveNumber(policy.burst) and policy.burst % 1 == 0, "codePolicy.burst must be a positive integer")
		check(policy.normalization == "trim_uppercase_strip_spaces", "codePolicy.normalization unknown")
		if type(raw.codes) == "table" then
			for code in pairs(raw.codes) do
				check(type(code) == "string" and #code <= policy.maxLength, "code key longer than codePolicy.maxLength: " .. tostring(code))
			end
		end
	end
	check(type(raw.leaderboards) == "table", "leaderboards block missing")
	if type(raw.leaderboards) == "table" then
		local boards = raw.leaderboards
		check(isPositiveNumber(boards.refreshSeconds), "leaderboards.refreshSeconds must be > 0")
		check(isPositiveNumber(boards.writeMinIntervalSeconds), "leaderboards.writeMinIntervalSeconds must be > 0")
		check(isPositiveNumber(boards.topCount) and boards.topCount % 1 == 0, "leaderboards.topCount must be a positive integer")
		check(type(boards.boards) == "table" and #boards.boards > 0, "leaderboards.boards must be a non-empty list")
		if type(boards.boards) == "table" then
			local seen: { [string]: boolean } = {}
			for index, boardId in ipairs(boards.boards) do
				check(
					type(boardId) == "string" and #boardId > 0 and not seen[boardId],
					"leaderboards.boards[" .. index .. "] invalid or duplicate"
				)
				seen[boardId] = true
			end
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
				check(
					type(chapter.availableDifficulties) == "table"
						and type(chapter.availableDifficulties.normal) == "boolean"
						and type(chapter.availableDifficulties.hard) == "boolean",
					"chapters." .. tostring(chapterKey) .. ".availableDifficulties must declare normal/hard booleans"
				)
			end
		end
		check(chapterIds.chapter1 == true, "chapter1 must exist")
		-- Chapter 2 puzzle configuration (MASTER_SPEC 12; ASSUMED A-CH2-02..08)
		local chapter2 = raw.chapters.chapter2
		if type(chapter2) == "table" then
			local puzzles = chapter2.puzzles
			check(type(puzzles) == "table", "chapters.chapter2.puzzles missing")
			if type(puzzles) == "table" then
				local known = {
					findKey = true,
					activateLevers = true,
					solveCrystals = true,
					solveCode = true,
					solveTiles = true,
					releaseHatchling = true,
					exit = true,
				}
				check(type(puzzles.order) == "table" and #puzzles.order == 7, "chapter2.puzzles.order must list the seven stages")
				if type(puzzles.order) == "table" then
					local seen = {}
					for _, stage in ipairs(puzzles.order) do
						check(
							known[stage] == true and not seen[stage],
							"chapter2.puzzles.order has unknown or duplicate stage " .. tostring(stage)
						)
						seen[stage] = true
					end
					check(puzzles.order[#puzzles.order] == "exit", "chapter2.puzzles.order must end with exit")
				end
				check(
					isPositiveNumber(puzzles.leverCount) and puzzles.leverCount % 1 == 0,
					"chapter2.puzzles.leverCount must be a positive integer"
				)
				check(
					type(puzzles.leverLabels) == "table" and #puzzles.leverLabels == puzzles.leverCount,
					"chapter2.puzzles.leverLabels must have one colour+symbol entry per lever"
				)
				if type(puzzles.leverLabels) == "table" then
					local colours, symbols = {}, {}
					for index, entry in ipairs(puzzles.leverLabels) do
						check(
							type(entry) == "table" and type(entry.color) == "string" and type(entry.symbol) == "string",
							"chapter2.puzzles.leverLabels[" .. index .. "] needs color and symbol"
						)
						if type(entry) == "table" then
							check(
								not colours[entry.color] and not symbols[entry.symbol],
								"chapter2.puzzles.leverLabels must be distinct (never colour alone)"
							)
							colours[entry.color] = true
							symbols[entry.symbol] = true
						end
					end
				end
				check(
					type(puzzles.crystalCountRange) == "table"
						and isPositiveNumber(puzzles.crystalCountRange.min)
						and isPositiveNumber(puzzles.crystalCountRange.max)
						and puzzles.crystalCountRange.min <= puzzles.crystalCountRange.max
						and puzzles.crystalCountRange.max <= 12,
					"chapter2.puzzles.crystalCountRange must be 1..12 with min <= max"
				)
				check(puzzles.codeDigits == 4, "chapter2.puzzles.codeDigits must be 4 (four-digit code)")
				check(type(puzzles.codeDistinctDigits) == "boolean", "chapter2.puzzles.codeDistinctDigits must be a boolean")
				check(puzzles.tileRotationPuzzleSize == 16, "chapter2.puzzles.tileRotationPuzzleSize must be 16 (4x4)")
				check(
					isPositiveNumber(puzzles.tileMinimumScrambled) and puzzles.tileMinimumScrambled <= 16,
					"chapter2.puzzles.tileMinimumScrambled must be 1..16"
				)
				check(isNonNegativeNumber(puzzles.wrongInputFeedbackSeconds), "chapter2.puzzles.wrongInputFeedbackSeconds must be >= 0")
			end
		end
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
		if pile.rainbowChance ~= nil then
			check(isNonNegativeNumber(pile.rainbowChance) and pile.rainbowChance <= 1, "pile.rainbowChance must be within [0, 1]")
		end
		check(isPositiveNumber(pile.maxVisualHeightStuds), "pile.maxVisualHeightStuds must be > 0")
		-- Collision core and visual coat (ASSUMED A-PILE-01..02)
		local collision = pile.collision
		check(type(collision) == "table", "pile.collision missing")
		if type(collision) == "table" then
			check(collision.kind == "terrain" or collision.kind == "parts", 'pile.collision.kind must be "terrain" or "parts"')
			check(
				isPositiveNumber(collision.shellOverlap)
					and isPositiveNumber(collision.bodyBuryStuds)
					and type(collision.shellFolderName) == "string",
				"pile.collision shell overlap/bury depth/folder name are required"
			)
			check(type(collision.material) == "string" and #collision.material > 0, "pile.collision.material must name a terrain material")
			check(
				type(collision.color) == "table"
					and #collision.color == 3
					and isNonNegativeNumber(collision.color[1])
					and collision.color[1] <= 255,
				"pile.collision.color must be an RGB triple"
			)
			check(collision.voxelResolution == 4, "pile.collision.voxelResolution must be 4 (Roblox terrain)")
			for _, key in ipairs({
				"eggHollowRadiusStuds",
				"lineOfSightToleranceStuds",
				"eggHollowDepthStuds",
			}) do
				check(isPositiveNumber(collision[key]), "pile.collision." .. key .. " must be > 0")
			end
			check(isNonNegativeNumber(collision.surfaceInsetStuds), "pile.collision.surfaceInsetStuds must be >= 0")
			-- The dent map is gone: records are the only thing that lowers this surface, so a strike no
			-- longer has a radius or a depth of its own and the body is re-seated on every award. A config
			-- still carrying those keys is stale and says so rather than being quietly ignored.
			for _, dead in ipairs({
				"digRadiusStuds",
				"sweepDigRadiusStuds",
				"strikeDentDepthStuds",
				"sweepDentDepthStuds",
				"rewriteEveryRecords",
			}) do
				check(collision[dead] == nil, "pile.collision." .. dead .. " was removed with the dent map; delete it from the config")
			end
			check(
				isPositiveNumber(collision.rewriteMarginCells)
					and collision.rewriteMarginCells % 1 == 0
					and collision.rewriteMarginCells <= 4,
				"pile.collision.rewriteMarginCells must be an integer 1..4"
			)
		end
		local visual = pile.visual
		check(type(visual) == "table", "pile.visual missing")
		if type(visual) == "table" then
			check(
				isPositiveNumber(visual.partBudgetDesktop) and isPositiveNumber(visual.partBudgetMobile),
				"pile.visual part budgets must be > 0"
			)
			check(visual.partBudgetMobile <= visual.partBudgetDesktop, "pile.visual.partBudgetMobile must not exceed desktop")
			local function range(key: string, minimum: number, maximum: number)
				local value = visual[key]
				check(
					type(value) == "table"
						and #value == 2
						and type(value[1]) == "number"
						and type(value[2]) == "number"
						and value[1] <= value[2]
						and value[1] >= minimum
						and value[2] <= maximum,
					"pile.visual." .. key .. " must be an ascending [min, max] within " .. minimum .. ".." .. maximum
				)
			end
			range("featherLengthRange", 0.2, 12)
			range("featherWidthRange", 0.1, 6)
			-- A record's slab must be at least as thick as the deepest layer step or the inside of the
			-- mound shows between records; a nil here would size every feather to nothing.
			check(
				isPositiveNumber(visual.featherThicknessStuds) and visual.featherThicknessStuds <= 3,
				"pile.visual.featherThicknessStuds must be > 0 and <= 3"
			)
			range("fluffLengthRange", 0.2, 12)
			range("fluffWidthRange", 0.1, 6)
			range("tiltRangeDegrees", 0, 90)
			range("fluffTiltRangeDegrees", 0, 90)
			check(
				isPositiveNumber(visual.visibleSlotsPerCell) and visual.visibleSlotsPerCell % 1 == 0 and visual.visibleSlotsPerCell <= 12,
				"pile.visual.visibleSlotsPerCell must be an integer 1..12"
			)
			check(
				isPositiveNumber(visual.visibleSlotsPerCellMobile)
					and visual.visibleSlotsPerCellMobile % 1 == 0
					and visual.visibleSlotsPerCellMobile <= (tonumber(visual.visibleSlotsPerCell) or 0),
				"pile.visual.visibleSlotsPerCellMobile must be an integer 1..visibleSlotsPerCell"
			)
			-- Adaptive coat window: steep columns render deeper so the coat covers the mound body. A
			-- low tier's ceiling stays at or under the desktop one, so what it renders is always a
			-- subset of what the server accepts.
			check(
				isPositiveNumber(visual.maxVisibleSlotsPerCell)
					and visual.maxVisibleSlotsPerCell % 1 == 0
					and visual.maxVisibleSlotsPerCell >= (tonumber(visual.visibleSlotsPerCell) or 0)
					and visual.maxVisibleSlotsPerCell <= 32
					and isPositiveNumber(visual.maxVisibleSlotsPerCellMobile)
					and visual.maxVisibleSlotsPerCellMobile % 1 == 0
					and visual.maxVisibleSlotsPerCellMobile >= (tonumber(visual.visibleSlotsPerCellMobile) or 0)
					and visual.maxVisibleSlotsPerCellMobile <= (tonumber(visual.maxVisibleSlotsPerCell) or 0),
				"pile.visual.maxVisibleSlotsPerCell(Mobile) must be integers visibleSlotsPerCell..32 and mobile <= desktop"
			)
			check(
				isPositiveNumber(visual.featherSpreadFraction) and visual.featherSpreadFraction <= 1,
				"pile.visual.featherSpreadFraction must be within (0, 1]"
			)
			check(
				isNonNegativeNumber(visual.rollRangeDegrees) and visual.rollRangeDegrees <= 180,
				"pile.visual.rollRangeDegrees must be 0..180"
			)
			check(isNonNegativeNumber(visual.fluffTintShift) and visual.fluffTintShift <= 1, "pile.visual.fluffTintShift must be 0..1")
			check(
				isNonNegativeNumber(visual.fluffPerCellDesktop)
					and visual.fluffPerCellDesktop % 1 == 0
					and isNonNegativeNumber(visual.fluffPerCellMobile)
					and visual.fluffPerCellMobile % 1 == 0
					and visual.fluffPerCellMobile <= visual.fluffPerCellDesktop,
				"pile.visual fluff counts must be non-negative integers with mobile <= desktop"
			)
			check(type(visual.palette) == "table" and #visual.palette >= 2, "pile.visual.palette needs at least two RGB entries")
			for index, entry in ipairs(visual.palette or {}) do
				check(type(entry) == "table" and #entry == 3, "pile.visual.palette[" .. index .. "] must be an RGB triple")
			end
			check(
				type(visual.selectionOutlineColor) == "table" and #visual.selectionOutlineColor == 3,
				"pile.visual.selectionOutlineColor must be an RGB triple"
			)
			check(
				isNonNegativeNumber(visual.selectionFillTransparency) and visual.selectionFillTransparency <= 1,
				"pile.visual.selectionFillTransparency must be 0..1"
			)
			for _, key in ipairs({
				"cullDistanceDesktopStuds",
				"cullDistanceMobileStuds",
				"targetRateHz",
				"pullSeconds",
				"chevronSeconds",
				"bagFullToastCooldownSeconds",
				"layerStepStuds",
			}) do
				check(isPositiveNumber(visual[key]), "pile.visual." .. key .. " must be > 0")
			end
			check(isNonNegativeNumber(visual.surfaceLiftStuds), "pile.visual.surfaceLiftStuds must be >= 0")
			check(isPositiveNumber(visual.rimMinScale) and visual.rimMinScale <= 1, "pile.visual.rimMinScale must be within (0, 1]")
			range("underlayerLengthRange", 0.2, 12)
			range("underlayerWidthRange", 0.1, 6)
			range("underlayerTiltRangeDegrees", 0, 90)
			local function gridOk(grid)
				return type(grid) == "table"
					and #grid == 2
					and isNonNegativeNumber(grid[1])
					and grid[1] % 1 == 0
					and isNonNegativeNumber(grid[2])
					and grid[2] % 1 == 0
			end
			check(
				gridOk(visual.underlayerGridDesktop) and gridOk(visual.underlayerGridMobile),
				"pile.visual underlayer grids must be [n, m] positive integers"
			)
			check(
				type(visual.underlayerDepths) == "table"
					and #visual.underlayerDepths == 2
					and isPositiveNumber(visual.underlayerDepths[1])
					and isPositiveNumber(visual.underlayerDepths[2]),
				"pile.visual.underlayerDepths must be two positive depths"
			)
			check(
				isNonNegativeNumber(visual.wallStrandsPerLevel)
					and visual.wallStrandsPerLevel % 1 == 0
					and isPositiveNumber(visual.wallLevelSpacingStuds),
				"pile.visual wall strand rule must be a positive integer count and spacing"
			)
			check(
				isNonNegativeNumber(visual.floorStrandsPerLevel)
					and visual.floorStrandsPerLevel % 1 == 0
					and isPositiveNumber(visual.floorLevelSpacingStuds),
				"pile.visual floor strand rule must be a positive integer count and spacing"
			)
			check(
				isNonNegativeNumber(visual.rimStrandsDesktop)
					and isNonNegativeNumber(visual.rimStrandsMobile)
					and visual.rimStrandsMobile <= visual.rimStrandsDesktop,
				"pile.visual rim strand counts must be non-negative with mobile <= desktop"
			)
			for _, key in ipairs({ "liftSeconds", "liftStuds", "pickScale", "rimTaperStuds" }) do
				check(isPositiveNumber(visual[key]), "pile.visual." .. key .. " must be > 0")
			end
			check(
				type(visual.rimInsetStuds) == "number" and visual.rimInsetStuds >= -4 and visual.rimInsetStuds <= 4,
				"pile.visual.rimInsetStuds must be within -4..4 (negative = bed spills past the mound's foot)"
			)
			check(
				isNonNegativeNumber(visual.downslopeYawJitterDegrees) and visual.downslopeYawJitterDegrees <= 180,
				"pile.visual.downslopeYawJitterDegrees must be 0..180"
			)
			local depths, shares = visual.fluffBandDepths, visual.fluffBandShares
			local bandsOk = type(depths) == "table" and type(shares) == "table" and #depths >= 1 and #depths == #shares
			if bandsOk then
				local total = 0
				for index = 1, #depths do
					if not (isNonNegativeNumber(depths[index]) and isPositiveNumber(shares[index])) then
						bandsOk = false
					end
					if index > 1 and depths[index] <= depths[index - 1] then
						bandsOk = false
					end
					total += shares[index] or 0
				end
				bandsOk = bandsOk and math.abs(total - 1) < 1e-6
			end
			check(bandsOk, "pile.visual fluff bands must be ascending depths with shares summing to 1")
			for _, key in ipairs({ "streakCount", "chevronCount" }) do
				check(
					isPositiveNumber(visual[key]) and visual[key] % 1 == 0 and visual[key] <= 12,
					"pile.visual." .. key .. " must be an integer 1..12"
				)
			end
			for _, key in ipairs({ "cameraImpulseHand", "cameraImpulseRake", "rustleVolume", "pickupVolume" }) do
				check(isNonNegativeNumber(visual[key]) and visual[key] <= 1, "pile.visual." .. key .. " must be 0..1")
			end
		end
		check(isPositiveNumber(pile.recordSpacingStuds) and pile.recordSpacingStuds <= 4, "pile.recordSpacingStuds must be within (0, 4]")
		check(
			isPositiveNumber(pile.aimPlaneHeightStuds) and pile.aimPlaneHeightStuds <= pile.maxVisualHeightStuds,
			"pile.aimPlaneHeightStuds must be > 0 and <= maxVisualHeightStuds"
		)
		-- Records per column are capped at PileGrid.MAX_SLOTS (32, one mask bit each); denser configs saturate.
	end
	-- Carried feather stack HUD (ASSUMED A-HUD-04)
	local carried = type(raw.hud) == "table" and raw.hud.carriedStack or nil
	check(type(carried) == "table", "hud.carriedStack missing")
	if type(carried) == "table" then
		check(
			-- The bundle is three overlapping layers now, so it carries more than the old flat fan could
			-- without reading as loose quills. It is still a fixed cap: never one model per feather.
			isPositiveNumber(carried.maxVisibleFeathers) and carried.maxVisibleFeathers % 1 == 0 and carried.maxVisibleFeathers <= 24,
			"hud.carriedStack.maxVisibleFeathers must be an integer 1..24"
		)
		check(
			isPositiveNumber(carried.infiniteCapCount) and carried.infiniteCapCount >= 2,
			"hud.carriedStack.infiniteCapCount must be a count >= 2"
		)
		for _, key in ipairs({
			"widthPxDesktop",
			"heightPxDesktop",
			"widthPxMobile",
			"heightPxMobile",
			"bounceSeconds",
			"bounceStuds",
		}) do
			check(isPositiveNumber(carried[key]), "hud.carriedStack." .. key .. " must be > 0")
		end
		check(isNonNegativeNumber(carried.anchorX) and carried.anchorX <= 1, "hud.carriedStack.anchorX must be 0..1")
		check(
			isPositiveNumber(carried.widthFraction)
				and carried.widthFraction <= 0.5
				and isPositiveNumber(carried.minWidthPx)
				and isPositiveNumber(carried.maxWidthPx)
				and carried.minWidthPx <= carried.maxWidthPx
				and isPositiveNumber(carried.aspect),
			"hud.carriedStack width rule must be a fraction <= 0.5 with min <= max px and a positive aspect"
		)
		for _, key in ipairs({
			"rightOffsetPx",
			"bottomOffsetPxDesktop",
			"bottomOffsetPxMobile",
			"bobAmplitudeStuds",
			"bobHz",
			"swayDegrees",
			"easeSeconds",
		}) do
			check(isNonNegativeNumber(carried[key]), "hud.carriedStack." .. key .. " must be >= 0")
		end
		check(isNonNegativeNumber(carried.anchorBottomOffsetPx), "hud.carriedStack.anchorBottomOffsetPx must be >= 0")
		for _, key in ipairs({ "depositSeconds", "depositStaggerSeconds", "rainbowHueRate" }) do
			check(isPositiveNumber(carried[key]), "hud.carriedStack." .. key .. " must be > 0")
		end
		check(
			isNonNegativeNumber(carried.rainbowSaturation) and carried.rainbowSaturation <= 1,
			"hud.carriedStack.rainbowSaturation must be 0..1"
		)
		check(type(carried.depositRiseStuds) == "number", "hud.carriedStack.depositRiseStuds must be a number")
		check(type(carried.depositDriftStuds) == "number", "hud.carriedStack.depositDriftStuds must be a number")
		local bundle = carried.bundle
		check(type(bundle) == "table", "hud.carriedStack.bundle missing")
		if type(bundle) == "table" then
			for _, key in ipairs({ "spreadDegrees", "layerSpreadGain", "layerRiseStuds", "layerDepthStuds" }) do
				check(isNonNegativeNumber(bundle[key]), "hud.carriedStack.bundle." .. key .. " must be >= 0")
			end
			check(
				isPositiveNumber(bundle.spreadDegrees) and bundle.spreadDegrees <= 120,
				"hud.carriedStack.bundle.spreadDegrees must be within (0, 120]"
			)
			for _, key in ipairs({ "leanDegrees", "baseX", "baseY", "baseZ" }) do
				check(type(bundle[key]) == "number", "hud.carriedStack.bundle." .. key .. " must be a number")
			end
		end
	end
	if type(raw.interaction) == "table" then
		check(
			isPositiveNumber(raw.interaction.aimMissToleranceStuds) and raw.interaction.aimMissToleranceStuds <= 6,
			"interaction.aimMissToleranceStuds must be within (0, 6]"
		)
		check(isPositiveNumber(raw.interaction.collectDebounceSeconds), "interaction.collectDebounceSeconds must be > 0")
	end

	-- Phase 3 ASSUMED tool mechanics (A-TOOL-01..03)
	if type(raw.tools) == "table" then
		local charge = raw.tools.confettiCharge
		if type(charge) == "table" then
			check(isPositiveNumber(charge.throwDistanceStuds), "tools.confettiCharge.throwDistanceStuds must be > 0")
			check(isNonNegativeNumber(charge.cooldownSeconds), "tools.confettiCharge.cooldownSeconds must be >= 0")
			check(isPositiveNumber(charge.miniChargeFuseSeconds), "tools.confettiCharge.miniChargeFuseSeconds must be > 0")
			check(isPositiveNumber(charge.throwFloorDropStuds), "tools.confettiCharge.throwFloorDropStuds must be > 0")
		end
		local chick = raw.tools.scoutChick
		if type(chick) == "table" then
			check(isPositiveNumber(chick.collectIntervalSeconds), "tools.scoutChick.collectIntervalSeconds must be > 0")
			check(isNonNegativeNumber(chick.depositSeconds), "tools.scoutChick.depositSeconds must be >= 0")
		end
	end
	if type(raw.collection) == "table" then
		check(isPositiveNumber(raw.collection.overflowBundleSeconds), "collection.overflowBundleSeconds must be > 0")
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
		if egg.luckyRoundChance ~= nil then
			check(
				isNonNegativeNumber(egg.luckyRoundChance) and egg.luckyRoundChance <= 1,
				"eggSpawn.luckyRoundChance must be within [0, 1]"
			)
			check(
				isNonNegativeNumber(egg.luckyMinimumRemovalFraction) and egg.luckyMinimumRemovalFraction < egg.maximumRemovalFraction,
				"eggSpawn.luckyMinimumRemovalFraction invalid"
			)
		end
		if egg.coreNodeWeight ~= nil or egg.edgeNodeWeight ~= nil then
			check(isPositiveNumber(egg.coreNodeWeight) and isPositiveNumber(egg.edgeNodeWeight), "eggSpawn node weights must be > 0")
		end
	end

	-- Clues (Professor Plume)
	check(type(raw.clues) == "table", "clues missing")
	if type(raw.clues) == "table" then
		local clues = raw.clues
		check(type(clues.costsRainbow) == "table" and #clues.costsRainbow > 0, "clues.costsRainbow must list at least one cost")
		if type(clues.costsRainbow) == "table" then
			for index, cost in ipairs(clues.costsRainbow) do
				check(isPositiveNumber(cost) and cost == math.floor(cost), "clues.costsRainbow[" .. index .. "] must be a positive integer")
			end
		end
		check(
			isPositiveNumber(clues.maxPerRound) and clues.maxPerRound == math.floor(clues.maxPerRound),
			"clues.maxPerRound must be a positive integer"
		)
		check(isPositiveNumber(clues.stationRangeStuds), "clues.stationRangeStuds must be > 0")
		check(isPositiveNumber(clues.analyzeSeconds), "clues.analyzeSeconds must be > 0")
		check(
			type(clues.direction) == "table" and isPositiveNumber(clues.direction.sideFraction) and clues.direction.sideFraction < 1,
			"clues.direction.sideFraction must be within (0, 1)"
		)
		check(
			type(clues.depth) == "table"
				and isPositiveNumber(clues.depth.outerMaxFraction)
				and isPositiveNumber(clues.depth.coreMinFraction)
				and clues.depth.outerMaxFraction < clues.depth.coreMinFraction
				and clues.depth.coreMinFraction < 1,
			"clues.depth fractions must satisfy 0 < outerMaxFraction < coreMinFraction < 1"
		)
	end

	-- Survey (Molly the Mole)
	check(type(raw.survey) == "table", "survey missing")
	if type(raw.survey) == "table" then
		local survey = raw.survey
		check(
			isPositiveNumber(survey.SurveyCrateCost) and survey.SurveyCrateCost == math.floor(survey.SurveyCrateCost),
			"survey.SurveyCrateCost must be a positive integer"
		)
		check(isPositiveNumber(survey.stationRangeStuds), "survey.stationRangeStuds must be > 0")
		check(isPositiveNumber(survey.sequenceSeconds), "survey.sequenceSeconds must be > 0")
		check(
			isPositiveNumber(survey.weakManhattanDistance) and survey.weakManhattanDistance == math.floor(survey.weakManhattanDistance),
			"survey.weakManhattanDistance must be a positive integer"
		)
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

	-- Audio: every id, mix value, loop flag and cooldown the client plays lives here, so this is the
	-- only place a wrong role name or an out-of-range volume can be caught before it ships.
	-- The lobby's permanent offer button (owner artwork; lobby only).
	local offer = type(raw.lobby) == "table" and raw.lobby.offer or nil
	check(type(offer) == "table", "lobby.offer missing")
	if type(offer) == "table" then
		check(type(offer.productKey) == "string" and #offer.productKey > 0, "lobby.offer.productKey must name a product")
		for _, key in ipairs({ "widthPx", "floatSeconds", "shineSeconds", "shineGapSeconds" }) do
			check(isPositiveNumber(offer[key]), "lobby.offer." .. key .. " must be > 0")
		end
		check(isNonNegativeNumber(offer.floatPx) and offer.floatPx <= 40, "lobby.offer.floatPx must be within [0, 40]")
		for _, key in ipairs({ "shineTransparency", "glowTransparency" }) do
			check(isNonNegativeNumber(offer[key]) and offer[key] <= 1, "lobby.offer." .. key .. " must be 0..1")
		end
		check(
			isPositiveNumber(offer.hoverScale) and offer.hoverScale >= 1 and offer.hoverScale <= 1.3,
			"lobby.offer.hoverScale must be within [1, 1.3]"
		)
		check(
			isPositiveNumber(offer.pressScale) and offer.pressScale <= 1 and offer.pressScale >= 0.8,
			"lobby.offer.pressScale must be within [0.8, 1]"
		)
	end

	-- Round intro cinematic: the shot list, the subtitle beats and the named camera markers. The
	-- markers are also built as world parts, so these are the authored defaults, not the only source.
	local intro = type(raw.round) == "table" and raw.round.intro or nil
	check(type(intro) == "table", "round.intro missing")
	if type(intro) == "table" then
		check(type(intro.playEveryRound) == "boolean", "round.intro.playEveryRound must be boolean")
		check(type(intro.allowSkip) == "boolean", "round.intro.allowSkip must be boolean")
		for _, key in ipairs({
			"durationSeconds",
			"maxWaitSeconds",
			"loadGraceSeconds",
			"fadeInSeconds",
			"fadeOutSeconds",
			"letterboxSeconds",
			"subtitleCharactersPerSecond",
			"objectiveSeconds",
		}) do
			check(isPositiveNumber(intro[key]), "round.intro." .. key .. " must be > 0")
		end
		check(
			isNonNegativeNumber(intro.letterboxFraction) and intro.letterboxFraction <= 0.3,
			"round.intro.letterboxFraction must be within [0, 0.3]"
		)
		-- The intro has to be allowed to finish before the backstop fires, or nobody ever sees it.
		check(
			not isPositiveNumber(intro.maxWaitSeconds)
				or not isPositiveNumber(intro.durationSeconds)
				or intro.maxWaitSeconds > intro.durationSeconds,
			"round.intro.maxWaitSeconds must exceed durationSeconds"
		)
		check(type(intro.waitingLabel) == "string" and #intro.waitingLabel > 0, "round.intro.waitingLabel must be text")
		check(type(intro.objectiveLabel) == "string" and #intro.objectiveLabel > 0, "round.intro.objectiveLabel must be text")
		local poster = intro.poster
		check(type(poster) == "table", "round.intro.poster missing")
		if type(poster) == "table" then
			for _, key in ipairs({ "title", "subtitle", "rewardPrefix", "footer" }) do
				check(type(poster[key]) == "string", "round.intro.poster." .. key .. " must be text")
			end
			-- The flyer's reward is computed from the round being played; a literal here would be a
			-- promise the round might not keep.
			check(
				type(poster.rewardPrefix) ~= "string" or string.match(poster.rewardPrefix, "%d") == nil,
				"round.intro.poster.rewardPrefix must not contain a hard-coded amount"
			)
		end
		check(type(intro.beats) == "table" and #intro.beats > 0, "round.intro.beats must be a non-empty list")
		if type(intro.beats) == "table" then
			local previous = -1
			for index, beat in ipairs(intro.beats) do
				local where = "round.intro.beats[" .. index .. "]"
				check(type(beat) == "table" and isNonNegativeNumber(beat.at), where .. ".at must be >= 0")
				check(type(beat) == "table" and type(beat.text) == "string" and #beat.text > 0, where .. ".text must be text")
				check(type(beat) ~= "table" or not isNonNegativeNumber(beat.at) or beat.at > previous, where .. ".at must increase")
				previous = if type(beat) == "table" and isNonNegativeNumber(beat.at) then beat.at else previous
			end
		end
		check(type(intro.shots) == "table" and #intro.shots > 0, "round.intro.shots must be a non-empty list")
		local markers = intro.markers
		check(type(markers) == "table", "round.intro.markers missing")
		if type(markers) == "table" then
			for _, name in ipairs({
				"IntroPosterClose",
				"IntroPlayerApproach",
				"IntroPlayerReading",
				"IntroFarmReveal",
				"RoundSpawnCamera",
			}) do
				local entry = markers[name]
				check(type(entry) == "table", "round.intro.markers." .. name .. " missing")
				if type(entry) == "table" then
					check(
						type(entry.position) == "table" and #entry.position == 3,
						"round.intro.markers." .. name .. ".position must be a 3-vector"
					)
					check(
						type(entry.lookAt) == "table" and #entry.lookAt == 3,
						"round.intro.markers." .. name .. ".lookAt must be a 3-vector"
					)
					check(
						isPositiveNumber(entry.fieldOfView) and entry.fieldOfView <= 120,
						"round.intro.markers." .. name .. ".fieldOfView must be within (0, 120]"
					)
				end
			end
		end
		if type(intro.shots) == "table" and type(markers) == "table" then
			for index, shot in ipairs(intro.shots) do
				local where = "round.intro.shots[" .. index .. "]"
				check(type(shot) == "table" and markers[shot.marker] ~= nil, where .. ".marker must name a marker")
				check(type(shot) == "table" and isNonNegativeNumber(shot.at), where .. ".at must be >= 0")
				check(type(shot) == "table" and isPositiveNumber(shot.seconds), where .. ".seconds must be > 0")
			end
		end
		local actor = intro.actor
		check(type(actor) == "table", "round.intro.actor missing")
		if type(actor) == "table" then
			check(type(actor.startPosition) == "table" and #actor.startPosition == 3, "round.intro.actor.startPosition must be a 3-vector")
			check(type(actor.standPosition) == "table" and #actor.standPosition == 3, "round.intro.actor.standPosition must be a 3-vector")
			for _, key in ipairs({ "walkSeconds", "turnSeconds", "walkSpeedStudsPerSecond", "stepsPerSecond" }) do
				check(isPositiveNumber(actor[key]), "round.intro.actor." .. key .. " must be > 0")
			end
		end
		local sign = intro.sign
		check(type(sign) == "table", "round.intro.sign missing")
		if type(sign) == "table" then
			check(type(sign.position) == "table" and #sign.position == 3, "round.intro.sign.position must be a 3-vector")
			check(type(sign.facing) == "table" and #sign.facing == 3, "round.intro.sign.facing must be a 3-vector")
			check(isPositiveNumber(sign.postHeightStuds), "round.intro.sign.postHeightStuds must be > 0")
			check(isPositiveNumber(sign.pixelsPerStud), "round.intro.sign.pixelsPerStud must be > 0")
		end
	end

	check(type(raw.audio) == "table", "audio missing")
	if type(raw.audio) == "table" then
		local audio = raw.audio
		check(isNonNegativeNumber(audio.musicVolume) and audio.musicVolume <= 1, "audio.musicVolume must be within [0,1]")
		check(isPositiveNumber(audio.musicFadeSeconds), "audio.musicFadeSeconds must be > 0")
		check(isNonNegativeNumber(audio.loopFadeSeconds), "audio.loopFadeSeconds must be >= 0")
		check(type(audio.roles) == "table", "audio.roles missing")
		if type(audio.roles) == "table" then
			for role, tuning in pairs(audio.roles) do
				local where = "audio.roles." .. tostring(role)
				if type(tuning) ~= "table" then
					check(false, where .. " must be a table")
					continue
				end
				-- An empty id is a deliberate silence (a placeholder the owner has not replaced, or a
				-- sound removed on purpose), not a mistake; anything else must look like an asset.
				check(
					type(tuning.id) == "string"
						and (
							tuning.id == ""
							or string.match(tuning.id, "^rbxassetid://%d+$") ~= nil
							or string.match(tuning.id, "^rbxasset://") ~= nil
						),
					where .. '.id must be "", an rbxassetid:// id, or an rbxasset:// path'
				)
				check(isNonNegativeNumber(tuning.volume) and tuning.volume <= 1, where .. ".volume must be within [0,1]")
				check(isPositiveNumber(tuning.speed) and tuning.speed <= 4, where .. ".speed must be within (0,4]")
				check(isNonNegativeNumber(tuning.variance) and tuning.variance <= 1, where .. ".variance must be within [0,1]")
				check(isNonNegativeNumber(tuning.minGap) and tuning.minGap <= 10, where .. ".minGap must be within [0,10]")
				check(tuning.group == nil or type(tuning.group) == "string", where .. ".group must be a string when present")
				check(tuning.looped == nil or type(tuning.looped) == "boolean", where .. ".looped must be a boolean when present")
			end
		end
		check(type(audio.music) == "table", "audio.music missing")
		if type(audio.music) == "table" and type(audio.roles) == "table" then
			for state, role in pairs(audio.music) do
				check(
					type(role) == "string" and audio.roles[role] ~= nil,
					"audio.music." .. tostring(state) .. " must name a role in audio.roles"
				)
				check(
					type(role) ~= "string" or audio.roles[role] == nil or audio.roles[role].looped == true,
					"audio.music." .. tostring(state) .. " must name a looped role"
				)
			end
		end
	end

	return { ok = #errors == 0, errors = errors, warnings = warnings, checks = checks }
end

return Validator
