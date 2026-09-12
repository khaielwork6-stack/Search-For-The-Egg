--!strict
-- Round upgrade + soft-currency acquisition authority (STATE_MACHINES.md section 6). Everything is
-- data-driven from SYSTEM_CONFIG (bags.levels, handUpgrades.*, toolUpgrades.*, tools.*). Requests
-- carry the expected current level, never a price; the server recalculates cost in integer cents
-- (or Gems for the Scout Chick), applies class discounts exactly once, and debits atomically.
-- Upgrade ids: "bag", "handGrasp", "handSpeed", "handHold", "<toolId>.<path>", "tool:<toolId>"
-- (acquisition; level 0 = not owned, 1 = owned).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local ToolSpecs = require(Shared.Domain.ToolSpecs)
local EconomyMath = require(Shared.EconomyMath)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)
local RoundModifiers = require(script.Parent.RoundModifiers)

local UpgradeService = {}
UpgradeService.__index = UpgradeService

export type Preview = {
	upgradeId: string,
	kind: string, -- "bag" | "hand" | "tool" | "acquire"
	toolId: string?,
	pathName: string?,
	level: number,
	maxLevel: number,
	current: any,
	next: any?,
	costCents: number?,
	costGems: number?,
	maxed: boolean,
	permanent: boolean?,
}

export type UpgradeService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_rounds: any,
		_sessions: any,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_getProfileData: ((userId: number) -> any?)?,
		_getProfile: ((userId: number) -> any?)?,
		_getEntitlements: ((userId: number) -> { [string]: boolean }?)?,
		_analytics: any?,
		purchased: any, -- (userId, runtime, result)
		acquired: any, -- (userId, runtime, toolId, result)
		stats: { purchases: number, acquisitions: number, rejected: number },
	},
	UpgradeService
))

UpgradeService.IDS = table.freeze({ "bag", "handGrasp", "handSpeed", "handHold" })
local HAND_PATHS = table.freeze({ handGrasp = "grasp", handSpeed = "speed", handHold = "hold" })

function UpgradeService.new(options: {
	config: { [string]: any },
	rounds: any,
	sessions: any,
	getCharacterPosition: (userId: number) -> Vector3?,
	getProfileData: ((userId: number) -> any?)?,
	getProfile: ((userId: number) -> any?)?,
	getEntitlements: ((userId: number) -> { [string]: boolean }?)?,
	analytics: any?,
}): UpgradeService
	return setmetatable({
		_config = options.config,
		_rounds = options.rounds,
		_sessions = options.sessions,
		_getCharacterPosition = options.getCharacterPosition,
		_getProfileData = options.getProfileData,
		_getProfile = options.getProfile,
		_getEntitlements = options.getEntitlements,
		_analytics = options.analytics,
		purchased = Signal.new(),
		acquired = Signal.new(),
		stats = { purchases = 0, acquisitions = 0, rejected = 0 },
	}, UpgradeService)
end

-- Splits an upgrade id into its parts.
function UpgradeService.parseId(upgradeId: string): { kind: string, toolId: string?, pathName: string? }?
	if upgradeId == "bag" then
		return { kind = "bag" }
	end
	if HAND_PATHS[upgradeId] then
		return { kind = "hand", pathName = HAND_PATHS[upgradeId] }
	end
	local acquireTool = string.match(upgradeId, "^tool:(%w+)$")
	if acquireTool and ToolSpecs.isTool(acquireTool) then
		return { kind = "acquire", toolId = acquireTool }
	end
	local toolId, pathName = string.match(upgradeId, "^(%w+)%.(%w+)$")
	if toolId and ToolSpecs.isTool(toolId) and table.find(ToolSpecs.PATHS[toolId], pathName) then
		return { kind = "tool", toolId = toolId, pathName = pathName }
	end
	return nil
end

local function describeHand(entry: any)
	if not entry then
		return nil
	end
	return { amount = entry.amount, walkSpeed = entry.walkSpeed, enabled = entry.enabled, intervalSeconds = entry.intervalSeconds }
end

local function describeTool(entry: any)
	if not entry then
		return nil
	end
	local out = {}
	for key, value in pairs(entry) do
		if key ~= "level" and key ~= "nextCash" and key ~= "evidence" then
			out[key] = value
		end
	end
	return out
end

-- Discount multiplier for a tool path (class rakeUpgradeCostMultiplier applies to Rake paths only).
function UpgradeService.discountFor(self: UpgradeService, runtime: any, userId: number, toolId: string): number
	if toolId ~= "nestRake" then
		return 1
	end
	local profileData = if self._getProfileData then self._getProfileData(userId) else nil
	local entitlements = if self._getEntitlements then self._getEntitlements(userId) else nil
	local modifiers = RoundModifiers.resolve(self._config, profileData, runtime.state.difficulty, entitlements)
	return modifiers.rakeUpgradeCostMultiplier
end

-- Builds the preview (old -> new, cost) for one upgrade from the player's round state.
function UpgradeService.preview(self: UpgradeService, state: any, upgradeId: string, runtime: any?, userId: number?): Preview?
	local cfg = self._config
	local parsed = UpgradeService.parseId(upgradeId)
	if not parsed then
		return nil
	end
	if parsed.kind == "bag" then
		local levels = cfg.bags.levels
		local level = state.bagLevel
		local current, nextEntry = levels[level], levels[level + 1]
		return {
			upgradeId = upgradeId,
			kind = "bag",
			level = level,
			maxLevel = cfg.bags.maxLevel,
			current = { capacity = current.capacity },
			next = nextEntry and { capacity = nextEntry.capacity } or nil,
			costCents = current.upgradeCash and EconomyMath.dollarsToCents(current.upgradeCash) or nil,
			maxed = nextEntry == nil,
		}
	end
	if parsed.kind == "hand" then
		local pathName = parsed.pathName :: string
		local path = cfg.handUpgrades[pathName]
		local level = state.handLevels[pathName]
		local current, nextEntry = path[level + 1], path[level + 2]
		return {
			upgradeId = upgradeId,
			kind = "hand",
			pathName = pathName,
			level = level,
			maxLevel = #path - 1,
			current = describeHand(current),
			next = describeHand(nextEntry),
			costCents = current.nextCash and EconomyMath.dollarsToCents(current.nextCash) or nil,
			maxed = nextEntry == nil,
		}
	end
	local toolId = parsed.toolId :: string
	if parsed.kind == "acquire" then
		local owned = state.roundTools[toolId] == true
		local price = ToolSpecs.acquisitionPrice(cfg, toolId)
		return {
			upgradeId = upgradeId,
			kind = "acquire",
			toolId = toolId,
			level = if owned then 1 else 0,
			maxLevel = 1,
			current = if owned then { owned = true, displayName = cfg.tools[toolId].displayName } else nil,
			next = if owned then nil else { owned = true, displayName = cfg.tools[toolId].displayName },
			costCents = if owned then nil else price.cashCents,
			costGems = if owned then nil else price.gems,
			maxed = owned,
			permanent = state.permanentTools[toolId] == true,
		}
	end
	-- Tool path (only meaningful when the tool is owned this round).
	local pathName = parsed.pathName :: string
	if not state.roundTools[toolId] then
		return nil
	end
	local level = state.toolLevels[toolId][pathName]
	local discount = if runtime and userId then self:discountFor(runtime, userId, toolId) else 1
	local base = ToolSpecs.pathPreview(cfg, toolId, pathName, level, discount)
	return {
		upgradeId = upgradeId,
		kind = "tool",
		toolId = toolId,
		pathName = pathName,
		level = level,
		maxLevel = base.maxLevel,
		current = describeTool(base.current),
		next = describeTool(base.next),
		costCents = base.costCents,
		maxed = base.maxed,
		permanent = state.permanentTools[toolId] == true,
	}
end

-- Every preview relevant to the player: bag, Hand paths, then per tool either the acquisition row
-- (unowned) or the owned row plus its three paths.
function UpgradeService.previews(self: UpgradeService, state: any, runtime: any?, userId: number?): { Preview }
	local out = {}
	for _, id in ipairs(UpgradeService.IDS) do
		local preview = self:preview(state, id, runtime, userId)
		if preview then
			table.insert(out, preview)
		end
	end
	for _, toolId in ipairs(ToolSpecs.TOOL_IDS) do
		local acquire = self:preview(state, "tool:" .. toolId, runtime, userId)
		if acquire then
			table.insert(out, acquire)
		end
		if state.roundTools[toolId] then
			for _, pathName in ipairs(ToolSpecs.PATHS[toolId]) do
				local preview = self:preview(state, toolId .. "." .. pathName, runtime, userId)
				if preview then
					table.insert(out, preview)
				end
			end
		end
	end
	return out
end

local function reject(self: UpgradeService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

-- Soft-currency acquisition: round cash for cash-priced tools, profile Gems for the Scout Chick.
-- Robux one-round / permanent packaging is a receipt-driven grant (Phase 5) through ToolService.
local function acquire(self: UpgradeService, userId: number, runtime: any, state: any, toolId: string, preview: Preview)
	local source = "softCash"
	if preview.costGems then
		source = "softGems"
		local profile = if self._getProfile then self._getProfile(userId) else nil
		if not profile or not profile:isActive() then
			return reject(self, Envelope.Codes.INVALID_STATE, "profile")
		end
		if (profile.data.currencies.gems or 0) < preview.costGems then
			return reject(self, Envelope.Codes.INSUFFICIENT_FUNDS, "gems")
		end
		profile:update(function(data)
			data.currencies.gems -= preview.costGems :: number
		end)
	else
		local costCents = preview.costCents :: number
		if state.cashCents < costCents then
			return reject(self, Envelope.Codes.INSUFFICIENT_FUNDS)
		end
		state.cashCents -= costCents
	end
	state.roundTools[toolId] = true
	state.upgradeCount += 1
	self.stats.acquisitions += 1
	local result = {
		upgradeId = "tool:" .. toolId,
		kind = "acquire",
		toolId = toolId,
		level = 1,
		paidCents = preview.costCents or 0,
		paidGems = preview.costGems or 0,
		cashCents = state.cashCents,
		current = { owned = true, displayName = self._config.tools[toolId].displayName },
		maxed = true,
		source = source,
	}
	if self._analytics then
		self._analytics:track(
			"tool_acquired",
			{ chapter = runtime.state.chapter, tool = toolId, source = source, cents = result.paidCents, gems = result.paidGems },
			userId
		)
	end
	self.acquired:Fire(userId, runtime, toolId, result)
	self.purchased:Fire(userId, runtime, result)
	return Envelope.ok(result)
end

function UpgradeService.purchase(
	self: UpgradeService,
	userId: number,
	token: any,
	upgradeId: string,
	expectedLevel: number
): Envelope.Envelope<any>
	local runtime = self._rounds:roundOf(userId)
	if not runtime then
		return reject(self, Envelope.Codes.INVALID_STATE, "no_round")
	end
	local okToken, tokenErr = self._sessions:validate(userId, token, "Round")
	if not okToken then
		return reject(self, Envelope.Codes.STALE_TOKEN, tokenErr)
	end
	if not RoundReducer.acceptsGameplay(runtime.state) then
		return reject(self, Envelope.Codes.INVALID_STATE, "phase")
	end
	local state = runtime.players[userId]
	if not state or not state.alive then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_alive")
	end
	local characterPosition = self._getCharacterPosition(userId)
	if not characterPosition then
		return reject(self, Envelope.Codes.INVALID_STATE, "no_character")
	end
	local board = ChapterLayout[runtime.state.chapter].upgradeBoard
	local flat = Vector3.new(characterPosition.X - board.X, 0, characterPosition.Z - board.Z)
	if flat.Magnitude > self._config.interaction.upgradeRangeStuds then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "board")
	end
	local parsed = UpgradeService.parseId(upgradeId)
	local preview = parsed and self:preview(state, upgradeId, runtime, userId)
	if not parsed or not preview then
		return reject(self, Envelope.Codes.NOT_FOUND, "upgrade")
	end
	if preview.level ~= expectedLevel then
		return reject(self, Envelope.Codes.STALE_TOKEN, "stale_level")
	end
	if preview.maxed or (not preview.costCents and not preview.costGems) then
		return reject(self, Envelope.Codes.INVALID_STATE, if parsed.kind == "acquire" then "already_owned" else "maxed")
	end

	if parsed.kind == "acquire" then
		return acquire(self, userId, runtime, state, parsed.toolId :: string, preview)
	end

	local costCents = preview.costCents :: number
	if state.cashCents < costCents then
		return reject(self, Envelope.Codes.INSUFFICIENT_FUNDS)
	end
	-- Atomic debit + increment.
	state.cashCents -= costCents
	if parsed.kind == "bag" then
		state.bagLevel += 1
	elseif parsed.kind == "hand" then
		state.handLevels[parsed.pathName :: string] += 1
	else
		state.toolLevels[parsed.toolId :: string][parsed.pathName :: string] += 1
	end
	state.upgradeCount += 1
	self.stats.purchases += 1
	local after = self:preview(state, upgradeId, runtime, userId) :: Preview
	local result = {
		upgradeId = upgradeId,
		kind = parsed.kind,
		toolId = parsed.toolId,
		pathName = parsed.pathName,
		level = after.level,
		paidCents = costCents,
		cashCents = state.cashCents,
		previous = preview.current,
		current = after.current,
		next = after.next,
		nextCostCents = after.costCents,
		maxed = after.maxed,
		walkSpeed = upgradeId == "handSpeed" and after.current and after.current.walkSpeed or nil,
	}
	if self._analytics then
		self._analytics:track(
			"upgrade_purchased",
			{ chapter = runtime.state.chapter, upgradeId = upgradeId, level = after.level, cents = costCents },
			userId
		)
	end
	self.purchased:Fire(userId, runtime, result)
	return Envelope.ok(result)
end

return UpgradeService
