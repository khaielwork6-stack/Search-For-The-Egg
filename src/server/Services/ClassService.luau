--!strict
-- Class roll and equip authority (MASTER_SPEC 10). The server selects the result with the injected
-- RNG before answering; the client animates toward the committed class and reveals only after the
-- configured animation lands. 2x Luck, Fast Rolls, and the extra slot come from verified entitlements
-- (mock adapter in Studio). Duplicates re-equip (A-CLS-05). Rolls obey a server minimum interval so an
-- auto-roll can never outrun result sequencing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local ClassRoll = require(Shared.Domain.ClassRoll)
local Config = require(Shared.Config)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)

local ClassService = {}
ClassService.__index = ClassService

export type ClassService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_clock: any,
		_rng: any,
		_sessions: any,
		_getProfile: (userId: number) -> any?,
		_getEntitlements: (userId: number) -> { [string]: boolean },
		_analytics: any?,
		_lastRollMono: { [number]: number },
		rolled: any, -- (userId, result)
		equipped: any, -- (userId, equipped)
		stats: { rolls: number, duplicates: number, equips: number, rejected: number },
	},
	ClassService
))

local LOBBY_PHASES = { Lobby = true, Party = true }

function ClassService.new(options: {
	config: { [string]: any },
	clock: any,
	rng: any,
	sessions: any,
	getProfile: (userId: number) -> any?,
	getEntitlements: (userId: number) -> { [string]: boolean },
	analytics: any?,
}): ClassService
	return setmetatable({
		_config = options.config,
		_clock = options.clock,
		_rng = options.rng,
		_sessions = options.sessions,
		_getProfile = options.getProfile,
		_getEntitlements = options.getEntitlements,
		_analytics = options.analytics,
		_lastRollMono = {},
		rolled = Signal.new(),
		equipped = Signal.new(),
		stats = { rolls = 0, duplicates = 0, equips = 0, rejected = 0 },
	}, ClassService)
end

local function reject(self: ClassService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

-- Common gate: feature flag, active profile, lobby-phase session (classes change between rounds).
local function gate(self: ClassService, userId: number): (any?, string?, string?)
	if not Config.featureEnabled(self._config, "classesEnabled") then
		return nil, Envelope.Codes.UNAVAILABLE, "classes_disabled"
	end
	local profile = self._getProfile(userId)
	if not profile or not profile:isActive() then
		return nil, Envelope.Codes.INVALID_STATE, "profile"
	end
	local session = self._sessions:get(userId)
	if not session or not LOBBY_PHASES[session.phase] then
		return nil, Envelope.Codes.INVALID_STATE, "not_in_lobby"
	end
	return profile, nil, nil
end

-- Client view: odds (with luck applied when owned), slots, animation timing, roll cost.
function ClassService.view(self: ClassService, userId: number): { [string]: any }
	local entitlements = self._getEntitlements(userId)
	local doubleLuck = entitlements.doubleLuck == true
	return {
		odds = ClassRoll.odds(self._config, doubleLuck),
		doubleLuck = doubleLuck,
		fastRolls = entitlements.fastRolls == true,
		slotCount = ClassRoll.slotCount(self._config, entitlements),
		animationSeconds = ClassRoll.animationSeconds(self._config, entitlements),
		rollGemCost = self._config.classes.rollGemCost,
		minIntervalSeconds = self._config.lobby.classRollMinIntervalSeconds,
	}
end

function ClassService.roll(self: ClassService, userId: number, slot: number): Envelope.Envelope<any>
	local profile, code, message = gate(self, userId)
	if not profile then
		return reject(self, code :: string, message)
	end
	local entitlements = self._getEntitlements(userId)
	local slotCount = ClassRoll.slotCount(self._config, entitlements)
	if slot < 1 or slot > slotCount then
		return reject(self, Envelope.Codes.INVALID_PAYLOAD, "slot")
	end
	local now = self._clock:monotonic()
	local last = self._lastRollMono[userId]
	if last and (now - last) < self._config.lobby.classRollMinIntervalSeconds then
		return reject(self, Envelope.Codes.RATE_LIMITED, "roll_interval")
	end
	local cost = self._config.classes.rollGemCost
	if (profile.data.currencies.gems or 0) < cost then
		return reject(self, Envelope.Codes.INSUFFICIENT_FUNDS, "gems")
	end
	local doubleLuck = entitlements.doubleLuck == true
	local classId, rollValue = ClassRoll.roll(self._config, self._rng, doubleLuck)
	local duplicate = false
	-- Atomic: debit and apply in one profile update (single-threaded; nothing yields here).
	profile:update(function(data)
		data.currencies.gems -= cost
		duplicate = ClassRoll.applyResult(data.classes, classId, slot, slotCount)
		data.classes.lastRollAt = self._clock:now()
	end)
	self._lastRollMono[userId] = now
	self.stats.rolls += 1
	if duplicate then
		self.stats.duplicates += 1
	end
	local entry = Config.class(self._config, classId)
	local result = {
		classId = classId,
		displayName = entry and entry.displayName or classId,
		rarity = ClassRoll.rarity(entry and entry.weight or 0),
		duplicate = duplicate,
		slot = slot,
		slotCount = slotCount,
		paidGems = cost,
		gems = profile.data.currencies.gems,
		equipped = table.clone(profile.data.classes.equipped),
		owned = table.clone(profile.data.classes.owned),
		rollCount = profile.data.classes.rollCount,
		animationSeconds = ClassRoll.animationSeconds(self._config, entitlements),
		roll = rollValue,
	}
	if self._analytics then
		self._analytics:track("class_rolled", { class = classId, duplicate = duplicate, gems = cost, luck = doubleLuck }, userId)
	end
	self.rolled:Fire(userId, result)
	return Envelope.ok(result)
end

function ClassService.equip(self: ClassService, userId: number, classId: string, slot: number): Envelope.Envelope<any>
	local profile, code, message = gate(self, userId)
	if not profile then
		return reject(self, code :: string, message)
	end
	if not Config.class(self._config, classId) then
		return reject(self, Envelope.Codes.NOT_FOUND, "class")
	end
	local slotCount = ClassRoll.slotCount(self._config, self._getEntitlements(userId))
	local ok, reason = nil, nil
	profile:update(function(data)
		ok, reason = ClassRoll.equip(data.classes, classId, slot, slotCount)
	end)
	if not ok then
		return reject(self, if reason == "not_owned" then Envelope.Codes.NOT_AUTHORIZED else Envelope.Codes.INVALID_PAYLOAD, reason)
	end
	self.stats.equips += 1
	if self._analytics then
		self._analytics:track("class_equipped", { class = classId, slot = slot }, userId)
	end
	local equipped = table.clone(profile.data.classes.equipped)
	self.equipped:Fire(userId, equipped)
	return Envelope.ok({ classId = classId, slot = slot, equipped = equipped, slotCount = slotCount })
end

function ClassService.forget(self: ClassService, userId: number)
	self._lastRollMono[userId] = nil
end

return ClassService
