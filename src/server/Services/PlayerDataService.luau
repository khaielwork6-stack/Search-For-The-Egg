--!strict
-- Player lifecycle glue: session open -> profile load (with retry hold) -> lobby; projection
-- delivery; release on leave; autosave; shutdown flush. Player objects are abstracted to
-- { UserId, Name, Kick(msg), LoadCharacter() } so the service is testable with doubles.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local SessionReducer = require(Shared.Reducers.SessionReducer)
local ProfileProjection = require(script.Parent.Parent.Data.ProfileProjection)

local PlayerDataService = {}
PlayerDataService.__index = PlayerDataService

export type PlayerDataService = typeof(setmetatable(
	{} :: {
		_profiles: any,
		_sessions: any,
		_entitlements: any,
		_clock: any,
		_policy: any,
		_send: (player: any, name: string, payload: { [string]: any }) -> (),
		_analytics: any?,
		_log: any?,
		_projectionExtras: ((userId: number, data: { [string]: any }) -> ProfileProjection.Extras)?,
		_players: { [number]: any },
		stats: { joined: number, loaded: number, held: number, kicked: number, released: number },
	},
	PlayerDataService
))

function PlayerDataService.new(options: {
	profiles: any,
	sessions: any,
	entitlements: any,
	clock: any,
	policy: any,
	send: (player: any, name: string, payload: { [string]: any }) -> (),
	analytics: any?,
	log: any?,
	projectionExtras: ((userId: number, data: { [string]: any }) -> ProfileProjection.Extras)?,
}): PlayerDataService
	return setmetatable({
		_projectionExtras = options.projectionExtras,
		_profiles = options.profiles,
		_sessions = options.sessions,
		_entitlements = options.entitlements,
		_clock = options.clock,
		_policy = options.policy,
		_send = options.send,
		_analytics = options.analytics,
		_log = options.log,
		_players = {},
		stats = { joined = 0, loaded = 0, held = 0, kicked = 0, released = 0 },
	}, PlayerDataService)
end

local function dailyReady(self: PlayerDataService, data: { [string]: any }, cfg: { [string]: any }): boolean
	local last = data.rewards.dailyLastClaimAt
	if last == nil then
		return true
	end
	return (self._clock:now() - last) >= cfg.dailyRewardRules.claimCooldownSeconds
end

function PlayerDataService.buildProjection(self: PlayerDataService, userId: number, cfg: { [string]: any }): { [string]: any }?
	local profile = self._profiles:get(userId)
	if not profile then
		return nil
	end
	local entitlements = self._entitlements:snapshot(userId)
	local extras: ProfileProjection.Extras = if self._projectionExtras then self._projectionExtras(userId, profile.data) else {}
	if extras.sessionSeconds == nil then
		extras.sessionSeconds = math.max(0, math.floor(self._clock:now() - profile.loadedAt))
	end
	return ProfileProjection.project(profile.data, entitlements, dailyReady(self, profile.data, cfg), extras)
end

-- Sets (or replaces) the projection extras hook after construction (services built later).
function PlayerDataService.setProjectionExtras(
	self: PlayerDataService,
	hook: (userId: number, data: { [string]: any }) -> ProfileProjection.Extras
)
	self._projectionExtras = hook
end

function PlayerDataService.pushProjection(self: PlayerDataService, player: any, cfg: { [string]: any })
	local projection = self:buildProjection(player.UserId, cfg)
	if projection then
		self._send(player, "ProfileProjection", { projection = projection })
	end
end

function PlayerDataService.pushSession(self: PlayerDataService, player: any)
	local projection = self._sessions:project(player.UserId)
	if projection then
		self._send(player, "SessionProjection", projection)
	end
end

-- Synchronous from the caller's point of view (the store's injected wait yields in production).
-- Returns "loaded" | "held" | "kicked".
function PlayerDataService.onPlayerAdded(self: PlayerDataService, player: any, cfg: { [string]: any }): string
	local userId = player.UserId
	self.stats.joined += 1
	self._players[userId] = player
	if self._sessions:has(userId) then
		-- Same user connected twice to one server (should be impossible); refuse the second.
		self.stats.kicked += 1
		player:Kick(self._policy.duplicateSessionKickMessage)
		return "kicked"
	end
	self._sessions:open(userId)
	self:pushSession(player)

	local result = self._profiles:loadAsync(userId)
	if not result.profile then
		-- Load-failure hold: the player stays in LoadRetry (client shows the calm retry state),
		-- never receives a writable default, and is removed with a friendly message.
		self._sessions:apply(userId, SessionReducer.loadFailed)
		self:pushSession(player)
		self.stats.held += 1
		if self._log then
			self._log:warn("player_load_held", { userId = userId, reason = result.reason })
		end
		self.stats.kicked += 1
		player:Kick(self._policy.loadFailureKickMessage)
		self._sessions:close(userId)
		self._players[userId] = nil
		return "kicked"
	end

	self._sessions:apply(userId, SessionReducer.profileLoaded)
	self.stats.loaded += 1
	self._entitlements:refresh(userId)
	local profile = result.profile
	profile:update(function(data)
		data.entitlementsCache = { checkedAt = self._clock:now(), passes = self._entitlements:snapshot(userId) }
	end)
	self:pushProjection(player, cfg)
	self:pushSession(player)
	if self._analytics then
		self._analytics:track("session_start", { migrations = #profile.migrationsApplied, issues = #profile.issues }, userId)
	end
	-- Only now is the character allowed to spawn (MASTER_SPEC 5: load before interactive spawn).
	if type(player.LoadCharacter) == "function" then
		player:LoadCharacter()
	end
	return "loaded"
end

function PlayerDataService.onPlayerRemoving(self: PlayerDataService, player: any): boolean
	local userId = player.UserId
	self._players[userId] = nil
	local profile = self._profiles:get(userId)
	local ok = false
	if profile then
		local session = self._sessions:get(userId)
		if session and session.phase ~= "Saving" and SessionReducer.canTransition(session, "Saving") then
			self._sessions:apply(userId, SessionReducer.beginSaving)
		end
		profile:update(function(data: any)
			data.stats.playtimeSeconds += math.max(0, math.floor(self._clock:now() - profile.loadedAt))
		end)
		ok = self._profiles:releaseAsync(profile)
		self.stats.released += 1
	end
	self._sessions:close(userId)
	self._entitlements:forget(userId)
	return ok
end

function PlayerDataService.autosaveTick(self: PlayerDataService)
	return self._profiles:autosaveTick()
end

function PlayerDataService.flushAll(self: PlayerDataService)
	return self._profiles:flushAll()
end

function PlayerDataService.getProgression(self: PlayerDataService, userId: number): any?
	local profile = self._profiles:get(userId)
	return profile and profile.data.progression or nil
end

function PlayerDataService.getProfile(self: PlayerDataService, userId: number): any?
	return self._profiles:get(userId)
end

function PlayerDataService.playerOf(self: PlayerDataService, userId: number): any?
	return self._players[userId]
end

return PlayerDataService
