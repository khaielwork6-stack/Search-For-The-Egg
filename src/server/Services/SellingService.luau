--!strict
-- Selling authority (STATE_MACHINES.md section 5). Exchanges the whole personal bag at the sell
-- station for integer cents in one transaction. A duplicate request finds an empty bag and pays
-- nothing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local EconomyMath = require(Shared.EconomyMath)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)
local RoundModifiers = require(script.Parent.RoundModifiers)

local SellingService = {}
SellingService.__index = SellingService

export type SellingService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_rounds: any,
		_sessions: any,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_getProfileData: (userId: number) -> any?,
		_analytics: any?,
		sold: any, -- (userId, runtime, sale)
		stats: { sales: number, rejected: number },
	},
	SellingService
))

function SellingService.new(options: {
	config: { [string]: any },
	rounds: any,
	sessions: any,
	getCharacterPosition: (userId: number) -> Vector3?,
	getProfileData: (userId: number) -> any?,
	analytics: any?,
}): SellingService
	return setmetatable({
		_config = options.config,
		_rounds = options.rounds,
		_sessions = options.sessions,
		_getCharacterPosition = options.getCharacterPosition,
		_getProfileData = options.getProfileData,
		_analytics = options.analytics,
		sold = Signal.new(),
		stats = { sales = 0, rejected = 0 },
	}, SellingService)
end

local function reject(self: SellingService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

function SellingService.sell(self: SellingService, userId: number, token: any): Envelope.Envelope<any>
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
	local layout = ChapterLayout[runtime.state.chapter]
	if not characterPosition then
		return reject(self, Envelope.Codes.INVALID_STATE, "no_character")
	end
	local station = layout.sellStation
	local flat = Vector3.new(characterPosition.X - station.X, 0, characterPosition.Z - station.Z)
	if flat.Magnitude > self._config.interaction.sellRangeStuds then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "station")
	end
	if state.carriedStandard + state.carriedRainbow == 0 then
		return reject(self, Envelope.Codes.ALREADY_DONE, "nothing_to_sell")
	end
	local modifiers = RoundModifiers.resolve(self._config, self._getProfileData(userId), runtime.state.difficulty, nil)
	local sale = EconomyMath.computeSale({ standardCount = state.carriedStandard, rainbowCount = state.carriedRainbow }, {
		standardCents = EconomyMath.dollarsToCents(self._config.selling.cashPerStandardFeather),
		rainbowMultiplier = self._config.selling.rainbowFeatherMultiplier,
		classSellMultiplier = modifiers.sellMultiplier, -- class + perk + difficulty composed once by the resolver
		perkSellMultiplier = 1,
	})
	-- One transaction: clear the exact counts sold and credit cash.
	state.carriedStandard = 0
	state.carriedRainbow = 0
	local maximumCents = EconomyMath.dollarsToCents(self._config.currencies.cash.maximum)
	state.cashCents = EconomyMath.addBounded(state.cashCents, sale.finalCents, maximumCents)
	state.saleCount += 1
	local result = {
		standardCount = sale.standardCount,
		rainbowCount = sale.rainbowCount,
		baseCents = sale.baseCents,
		rainbowCents = sale.rainbowCents,
		multiplier = modifiers.sellMultiplier,
		finalCents = sale.finalCents,
		cashCents = state.cashCents,
		saleIndex = state.saleCount,
	}
	state.lastSale = result
	self.stats.sales += 1
	if self._analytics then
		self._analytics:track(
			"sell_completed",
			{ chapter = runtime.state.chapter, feathers = sale.standardCount + sale.rainbowCount, cents = sale.finalCents },
			userId
		)
	end
	self.sold:Fire(userId, runtime, result)
	return Envelope.ok(result)
end

return SellingService
