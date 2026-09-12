--!strict
-- Round upgrade authority (STATE_MACHINES.md section 6). Purchases are data-driven from
-- SYSTEM_CONFIG (bags.levels, handUpgrades.*). Request carries the expected current level, never a
-- price; the server recalculates cost in cents, applies class discounts once, and debits atomically.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local EconomyMath = require(Shared.EconomyMath)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)

local UpgradeService = {}
UpgradeService.__index = UpgradeService

export type Preview = {
	upgradeId: string,
	level: number,
	maxLevel: number,
	current: any,
	next: any?,
	costCents: number?,
	maxed: boolean,
}

export type UpgradeService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_rounds: any,
		_sessions: any,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_analytics: any?,
		purchased: any, -- (userId, runtime, result)
		stats: { purchases: number, rejected: number },
	},
	UpgradeService
))

UpgradeService.IDS = table.freeze({ "bag", "handGrasp", "handSpeed", "handHold" })

function UpgradeService.new(options: {
	config: { [string]: any },
	rounds: any,
	sessions: any,
	getCharacterPosition: (userId: number) -> Vector3?,
	analytics: any?,
}): UpgradeService
	return setmetatable({
		_config = options.config,
		_rounds = options.rounds,
		_sessions = options.sessions,
		_getCharacterPosition = options.getCharacterPosition,
		_analytics = options.analytics,
		purchased = Signal.new(),
		stats = { purchases = 0, rejected = 0 },
	}, UpgradeService)
end

-- Builds the preview (old -> new, cost) for one upgrade from the player's round state.
function UpgradeService.preview(self: UpgradeService, state: any, upgradeId: string): Preview?
	local cfg = self._config
	if upgradeId == "bag" then
		local levels = cfg.bags.levels
		local level = state.bagLevel
		local current, nextEntry = levels[level], levels[level + 1]
		return {
			upgradeId = upgradeId,
			level = level,
			maxLevel = cfg.bags.maxLevel,
			current = { capacity = current.capacity },
			next = nextEntry and { capacity = nextEntry.capacity } or nil,
			costCents = current.upgradeCash and EconomyMath.dollarsToCents(current.upgradeCash) or nil,
			maxed = nextEntry == nil,
		}
	end
	local pathName = ({ handGrasp = "grasp", handSpeed = "speed", handHold = "hold" })[upgradeId]
	if not pathName then
		return nil
	end
	local path = cfg.handUpgrades[pathName]
	local level = state.handLevels[pathName]
	local current, nextEntry = path[level + 1], path[level + 2]
	local function describe(entry: any)
		if not entry then
			return nil
		end
		return { amount = entry.amount, walkSpeed = entry.walkSpeed, enabled = entry.enabled, intervalSeconds = entry.intervalSeconds }
	end
	return {
		upgradeId = upgradeId,
		level = level,
		maxLevel = #path - 1,
		current = describe(current),
		next = describe(nextEntry),
		costCents = current.nextCash and EconomyMath.dollarsToCents(current.nextCash) or nil,
		maxed = nextEntry == nil,
	}
end

function UpgradeService.previews(self: UpgradeService, state: any): { Preview }
	local out = {}
	for _, id in ipairs(UpgradeService.IDS) do
		local preview = self:preview(state, id)
		if preview then
			table.insert(out, preview)
		end
	end
	return out
end

local function reject(self: UpgradeService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
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
	local preview = self:preview(state, upgradeId)
	if not preview then
		return reject(self, Envelope.Codes.NOT_FOUND, "upgrade")
	end
	if preview.level ~= expectedLevel then
		return reject(self, Envelope.Codes.STALE_TOKEN, "stale_level")
	end
	if preview.maxed or not preview.costCents then
		return reject(self, Envelope.Codes.INVALID_STATE, "maxed")
	end
	local costCents = preview.costCents
	if state.cashCents < costCents then
		return reject(self, Envelope.Codes.INSUFFICIENT_FUNDS)
	end
	-- Atomic debit + increment.
	state.cashCents -= costCents
	if upgradeId == "bag" then
		state.bagLevel += 1
	else
		local pathName = ({ handGrasp = "grasp", handSpeed = "speed", handHold = "hold" })[upgradeId]
		state.handLevels[pathName] += 1
	end
	state.upgradeCount += 1
	self.stats.purchases += 1
	local after = self:preview(state, upgradeId) :: Preview
	local result = {
		upgradeId = upgradeId,
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
