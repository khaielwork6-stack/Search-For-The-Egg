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
		check(isPositiveNumber(pile.maxVisualHeightStuds), "pile.maxVisualHeightStuds must be > 0")
		-- Collision core and visual coat (ASSUMED A-PILE-01..02)
		local collision = pile.collision
		check(type(collision) == "table", "pile.collision missing")
		if type(collision) == "table" then
			check(collision.kind == "terrain", "pile.collision.kind must be terrain")
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
				"digRadiusStuds",
				"sweepDigRadiusStuds",
				"eggHollowRadiusStuds",
				"lineOfSightToleranceStuds",
				"strikeDentDepthStuds",
				"sweepDentDepthStuds",
				"eggHollowDepthStuds",
			}) do
				check(isPositiveNumber(collision[key]), "pile.collision." .. key .. " must be > 0")
			end
			check(isNonNegativeNumber(collision.surfaceInsetStuds), "pile.collision.surfaceInsetStuds must be >= 0")
			check(
				isPositiveNumber(collision.rewriteEveryRecords)
					and collision.rewriteEveryRecords % 1 == 0
					and collision.rewriteEveryRecords <= 12,
				"pile.collision.rewriteEveryRecords must be an integer 1..12"
			)
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
			range("fluffLengthRange", 0.2, 12)
			range("fluffWidthRange", 0.1, 6)
			range("tiltRangeDegrees", 0, 90)
			range("fluffTiltRangeDegrees", 0, 90)
			check(
				isPositiveNumber(visual.visibleSlotsPerCell) and visual.visibleSlotsPerCell % 1 == 0 and visual.visibleSlotsPerCell <= 4,
				"pile.visual.visibleSlotsPerCell must be an integer 1..4"
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
			for _, key in ipairs({ "liftSeconds", "settleSeconds", "liftStuds", "pickScale", "rimInsetStuds", "rimTaperStuds" }) do
				check(isPositiveNumber(visual[key]), "pile.visual." .. key .. " must be > 0")
			end
			check(
				isNonNegativeNumber(visual.downslopeYawJitterDegrees) and visual.downslopeYawJitterDegrees <= 180,
				"pile.visual.downslopeYawJitterDegrees must be 0..180"
			)
			check(
				isPositiveNumber(visual.fluffLayers) and visual.fluffLayers % 1 == 0 and visual.fluffLayers <= 6,
				"pile.visual.fluffLayers must be an integer 1..6"
			)
			check(isPositiveNumber(visual.fluffLayerStepStuds), "pile.visual.fluffLayerStepStuds must be > 0")
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
		check(
			isPositiveNumber(pile.depthPerFeatherStuds) and pile.depthPerFeatherStuds <= 4,
			"pile.depthPerFeatherStuds must be within (0, 4]"
		)
		check(
			isPositiveNumber(pile.aimPlaneHeightStuds) and pile.aimPlaneHeightStuds <= pile.maxVisualHeightStuds,
			"pile.aimPlaneHeightStuds must be > 0 and <= maxVisualHeightStuds"
		)
		-- Feather ids pack the slot into 6 bits: the densest cell (cover, hard difficulty, max variance)
		-- must stay below 64 feathers.
		local densest = pile.baseFeathersPerCell * (1 + pile.surfaceVariance) * pile.coverDepthMultiplier
		local hardest = 1
		if type(raw.difficulty) == "table" then
			for _, difficulty in pairs(raw.difficulty) do
				if type(difficulty) == "table" and type(difficulty.pileHealthMultiplier) == "number" then
					hardest = math.max(hardest, difficulty.pileHealthMultiplier)
				end
			end
		end
		check(densest * hardest < 63.5, "pile: the densest possible cell must hold fewer than 64 feathers (feather id slot bits)")
	end
	-- Carried feather stack HUD (ASSUMED A-HUD-04)
	local carried = type(raw.hud) == "table" and raw.hud.carriedStack or nil
	check(type(carried) == "table", "hud.carriedStack missing")
	if type(carried) == "table" then
		check(type(carried.tiers) == "table" and #carried.tiers >= 2, "hud.carriedStack.tiers needs at least two tiers")
		local lastMin, lastFeathers = -1, -1
		for index, tier in ipairs(carried.tiers or {}) do
			local okTier = type(tier) == "table"
				and type(tier.name) == "string"
				and isNonNegativeNumber(tier.minFullness)
				and tier.minFullness <= 1
				and isNonNegativeNumber(tier.feathers)
				and tier.feathers % 1 == 0
				and tier.feathers <= 16
			check(okTier, "hud.carriedStack.tiers[" .. index .. "] must have name, minFullness 0..1, integer feathers 0..16")
			if okTier then
				check(tier.minFullness >= lastMin and tier.feathers >= lastFeathers, "hud.carriedStack.tiers must be ascending")
				lastMin, lastFeathers = tier.minFullness, tier.feathers
			end
		end
		if type(carried.tiers) == "table" and type(carried.tiers[1]) == "table" then
			check(carried.tiers[1].feathers == 0 and carried.tiers[1].minFullness == 0, "hud.carriedStack.tiers[1] must be the empty tier")
		end
		for _, key in ipairs({
			"infiniteReferenceCount",
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
