--!strict
-- Permanent perk authority (SYSTEM_CONFIG.permanentPerks, ASSUMED A-ECO-10). Purchases are Gem
-- transactions against the profile: the request carries the expected current level (never a price),
-- the server recomputes the cost, refuses stale/maxed/insufficient requests without debiting, and
-- applies debit + level in one update. Effects reach gameplay only through ModifierResolver.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Perks = require(Shared.Domain.Perks)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)

local PerkService = {}
PerkService.__index = PerkService

export type PerkService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_sessions: any,
		_getProfile: (userId: number) -> any?,
		_analytics: any?,
		purchased: any, -- (userId, result)
		stats: { purchases: number, rejected: number },
	},
	PerkService
))

local LOBBY_PHASES = { Lobby = true, Party = true }

function PerkService.new(
	options: { config: { [string]: any }, sessions: any, getProfile: (userId: number) -> any?, analytics: any? }
): PerkService
	return setmetatable({
		_config = options.config,
		_sessions = options.sessions,
		_getProfile = options.getProfile,
		_analytics = options.analytics,
		purchased = Signal.new(),
		stats = { purchases = 0, rejected = 0 },
	}, PerkService)
end

local function reject(self: PerkService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

function PerkService.previews(self: PerkService, userId: number): { Perks.Preview }
	local profile = self._getProfile(userId)
	local levels = if profile then profile.data.permanentPerks else {}
	return Perks.previews(self._config, levels)
end

function PerkService.purchase(self: PerkService, userId: number, perkId: string, expectedLevel: number): Envelope.Envelope<any>
	local profile = self._getProfile(userId)
	if not profile or not profile:isActive() then
		return reject(self, Envelope.Codes.INVALID_STATE, "profile")
	end
	local session = self._sessions:get(userId)
	if not session or not LOBBY_PHASES[session.phase] then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_in_lobby")
	end
	if not Perks.isPerk(self._config, perkId) then
		return reject(self, Envelope.Codes.NOT_FOUND, "perk")
	end
	local level = profile.data.permanentPerks[perkId] or 0
	if level ~= expectedLevel then
		return reject(self, Envelope.Codes.STALE_TOKEN, "stale_level")
	end
	local preview = Perks.preview(self._config, perkId, level)
	if preview.maxed or not preview.costGems then
		return reject(self, Envelope.Codes.INVALID_STATE, "maxed")
	end
	local cost = preview.costGems :: number
	if (profile.data.currencies.gems or 0) < cost then
		return reject(self, Envelope.Codes.INSUFFICIENT_FUNDS, "gems")
	end
	profile:update(function(data)
		data.currencies.gems -= cost
		data.permanentPerks[perkId] = level + 1
	end)
	self.stats.purchases += 1
	local after = Perks.preview(self._config, perkId, level + 1)
	local result = {
		perkId = perkId,
		level = level + 1,
		paidGems = cost,
		gems = profile.data.currencies.gems,
		previousMultiplier = preview.currentMultiplier,
		currentMultiplier = after.currentMultiplier,
		nextMultiplier = after.nextMultiplier,
		nextCostGems = after.costGems,
		maxed = after.maxed,
	}
	if self._analytics then
		self._analytics:track("perk_purchased", { upgradeId = perkId, level = level + 1, gems = cost }, userId)
	end
	self.purchased:Fire(userId, result)
	return Envelope.ok(result)
end

return PerkService
