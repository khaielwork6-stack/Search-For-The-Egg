--!strict
-- Party authority: serialized create/join/leave/destination/start with per-member unlock
-- validation, a server countdown deadline, reservation through the teleport adapter, and
-- hand-off to RoundService (local adapter) or TeleportService (production). Wraps PartyReducer.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local PartyReducer = require(Shared.Reducers.PartyReducer)
local SessionReducer = require(Shared.Reducers.SessionReducer)
local UnlockPolicy = require(Shared.Domain.UnlockPolicy)
local Signal = require(Shared.Util.Signal)

local PartyService = {}
PartyService.__index = PartyService

export type PartyService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_clock: any,
		_idGen: () -> string,
		_sessions: any,
		_getProgression: (userId: number) -> any?,
		_teleport: any,
		_analytics: any?,
		_log: any?,
		_parties: { [string]: PartyReducer.PartyState },
		_memberParty: { [number]: string },
		changed: any,
		started: any, -- fires (party, reservation) when a local reservation completes
	},
	PartyService
))

PartyService.Errors = table.freeze({
	NO_SESSION = "no_session",
	IN_PARTY = "already_in_party",
	NOT_FOUND = "party_not_found",
	FLAG_DISABLED = "chapter_disabled",
	UNAVAILABLE = "chapter_unavailable",
	INVALID_DIFFICULTY = "invalid_difficulty",
})

-- Content availability (chapters.<key>.availableDifficulties, ASSUMED): Phase 5 activates Chapter 2.
-- Separate from the unlock policy, which decides whether a player has earned the destination.
function PartyService.isDestinationAvailable(config: { [string]: any }, chapter: string, difficulty: string): (boolean, string?)
	local entry = config.chapters[chapter]
	if not entry then
		return false, PartyService.Errors.NOT_FOUND
	end
	if difficulty ~= "normal" and difficulty ~= "hard" then
		return false, PartyService.Errors.INVALID_DIFFICULTY
	end
	if chapter == "chapter2" and not config.featureFlags.chapter2Enabled then
		return false, PartyService.Errors.FLAG_DISABLED
	end
	if difficulty == "hard" and not config.featureFlags.hardModeEnabled then
		return false, PartyService.Errors.FLAG_DISABLED
	end
	local available = entry.availableDifficulties
	if type(available) ~= "table" or available[difficulty] ~= true then
		return false, PartyService.Errors.UNAVAILABLE
	end
	return true, nil
end

function PartyService.new(options: {
	config: { [string]: any },
	clock: any,
	idGen: () -> string,
	sessions: any,
	getProgression: (userId: number) -> any?,
	teleport: any,
	analytics: any?,
	log: any?,
}): PartyService
	return setmetatable({
		_config = options.config,
		_clock = options.clock,
		_idGen = options.idGen,
		_sessions = options.sessions,
		_getProgression = options.getProgression,
		_teleport = options.teleport,
		_analytics = options.analytics,
		_log = options.log,
		_parties = {},
		_memberParty = {},
		changed = Signal.new(),
		started = Signal.new(),
	}, PartyService)
end

local function commit(self: PartyService, state: PartyReducer.PartyState)
	state = PartyReducer.normalize(state)
	if state.phase == "Closed" then
		self._parties[state.partyId] = nil
	else
		self._parties[state.partyId] = state
	end
	self.changed:Fire(state)
	return state
end

-- Destination validity: chapter exists, feature flag allows it, content is available, every member
-- owns the unlock. Returns (ok, reason, lockedUserIds).
function PartyService.evaluateValidity(self: PartyService, state: PartyReducer.PartyState): (boolean, string?, { number })
	local available, reason = PartyService.isDestinationAvailable(self._config, state.chapter, state.difficulty)
	if not available then
		return false, reason, {}
	end
	local progressions = {}
	for _, userId in ipairs(state.members) do
		local progression = self._getProgression(userId)
		if not progression then
			return false, PartyService.Errors.NO_SESSION, {}
		end
		table.insert(progressions, progression)
	end
	local ok, lockedIndexes = UnlockPolicy.partyCanStart(self._config.chapters, state.chapter, state.difficulty, progressions)
	local lockedUserIds = {}
	for _, index in ipairs(lockedIndexes) do
		table.insert(lockedUserIds, state.members[index])
	end
	return ok, if ok then nil else PartyReducer.Errors.LOCKED, lockedUserIds
end

local function reevaluate(self: PartyService, state: PartyReducer.PartyState): PartyReducer.PartyState
	local valid = self:evaluateValidity(state)
	return PartyReducer.evaluate(state, valid)
end

function PartyService.create(self: PartyService, userId: number, chapter: string, difficulty: string): (PartyReducer.PartyState?, string?)
	if self._memberParty[userId] then
		return nil, PartyService.Errors.IN_PARTY
	end
	local session = self._sessions:get(userId)
	if not session or session.phase ~= "Lobby" then
		return nil, PartyService.Errors.NO_SESSION
	end
	local available, reason = PartyService.isDestinationAvailable(self._config, chapter, difficulty)
	if not available then
		return nil, reason
	end
	local partyId = self._idGen()
	local state = PartyReducer.create(partyId, userId, chapter, difficulty, self._config.project.maxPartyPlayers)
	local sessionNext, sessionErr = self._sessions:apply(userId, SessionReducer.joinParty, partyId)
	if not sessionNext then
		return nil, sessionErr
	end
	self._memberParty[userId] = partyId
	state = commit(self, reevaluate(self, state))
	if self._analytics then
		self._analytics:track("party_created", { chapter = chapter, difficulty = difficulty, partySize = 1 }, userId)
	end
	return state, nil
end

function PartyService.join(self: PartyService, userId: number, partyId: string): (PartyReducer.PartyState?, string?)
	if self._memberParty[userId] then
		return nil, PartyService.Errors.IN_PARTY
	end
	local state = self._parties[partyId]
	if not state then
		return nil, PartyService.Errors.NOT_FOUND
	end
	local session = self._sessions:get(userId)
	if not session or session.phase ~= "Lobby" then
		return nil, PartyService.Errors.NO_SESSION
	end
	local next, err = PartyReducer.join(state, userId)
	if not next then
		return nil, err
	end
	local sessionNext, sessionErr = self._sessions:apply(userId, SessionReducer.joinParty, partyId)
	if not sessionNext then
		return nil, sessionErr
	end
	self._memberParty[userId] = partyId
	if self._analytics then
		self._analytics:track("party_joined", { chapter = state.chapter, difficulty = state.difficulty, partySize = #next.members }, userId)
	end
	return commit(self, reevaluate(self, next)), nil
end

function PartyService.leave(self: PartyService, userId: number): (PartyReducer.PartyState?, string?)
	local partyId = self._memberParty[userId]
	if not partyId then
		return nil, PartyReducer.Errors.NOT_MEMBER
	end
	local state = self._parties[partyId]
	local next, err = PartyReducer.leave(state, userId)
	if not next then
		return nil, err
	end
	self._memberParty[userId] = nil
	local session = self._sessions:get(userId)
	if session and session.phase == "Party" then
		self._sessions:apply(userId, SessionReducer.leaveParty)
	end
	if next.phase ~= "Closed" then
		next = reevaluate(self, next)
	end
	return commit(self, next), nil
end

function PartyService.setDestination(
	self: PartyService,
	userId: number,
	chapter: string,
	difficulty: string
): (PartyReducer.PartyState?, string?)
	local partyId = self._memberParty[userId]
	local state = partyId and self._parties[partyId]
	if not state then
		return nil, PartyReducer.Errors.NOT_MEMBER
	end
	local available, reason = PartyService.isDestinationAvailable(self._config, chapter, difficulty)
	if not available then
		return nil, reason
	end
	local next, err = PartyReducer.setDestination(state, userId, chapter, difficulty)
	if not next then
		return nil, err
	end
	return commit(self, reevaluate(self, next)), nil
end

function PartyService.start(self: PartyService, userId: number, partyId: string): (PartyReducer.PartyState?, string?)
	local state = self._parties[partyId]
	if not state or self._memberParty[userId] ~= partyId then
		return nil, PartyReducer.Errors.NOT_MEMBER
	end
	state = reevaluate(self, state)
	local deadline = self._clock:monotonic() + self._config.round.countdownSeconds
	local next, err = PartyReducer.start(state, userId, deadline)
	if not next then
		commit(self, state)
		return nil, err
	end
	return commit(self, next), nil
end

function PartyService.cancel(self: PartyService, userId: number, partyId: string): (PartyReducer.PartyState?, string?)
	local state = self._parties[partyId]
	if not state then
		return nil, PartyService.Errors.NOT_FOUND
	end
	local next, err = PartyReducer.cancelCountdown(state, userId)
	if not next then
		return nil, err
	end
	return commit(self, next), nil
end

-- Service tick: advances countdowns, performs reservations, and hands off. Returns parties touched.
function PartyService.tick(self: PartyService): number
	local now = self._clock:monotonic()
	local touched = 0
	for _, state in pairs(table.clone(self._parties)) do
		local next = PartyReducer.tick(state, now)
		if next ~= state then
			touched += 1
			-- Re-validate at the moment the countdown ends; a member may have lost eligibility.
			local valid = self:evaluateValidity(next)
			if not valid then
				commit(self, PartyReducer.evaluate(next, false))
				continue
			end
			next = commit(self, next)
			local ok, reservation = self._teleport:reserve(next.chapter)
			if not ok or not reservation then
				local failed = PartyReducer.reservationFailed(next)
				if failed then
					commit(self, failed)
				end
				continue
			end
			local teleporting = PartyReducer.reservationSucceeded(next, { code = reservation.code, placeKey = reservation.placeKey })
			if not teleporting then
				continue
			end
			teleporting = commit(self, teleporting)
			for _, memberId in ipairs(teleporting.members) do
				self._sessions:apply(memberId, SessionReducer.beginTeleport)
			end
			self.started:Fire(teleporting, reservation)
		end
	end
	return touched
end

-- Called after a local round accepted the party (same-place adapter) or a teleport failed.
function PartyService.finish(self: PartyService, partyId: string, success: boolean)
	local state = self._parties[partyId]
	if not state then
		return
	end
	if success then
		for _, memberId in ipairs(state.members) do
			self._memberParty[memberId] = nil
		end
		commit(self, PartyReducer.close(state))
	else
		local failed = PartyReducer.teleportFailed(state)
		if failed then
			for _, memberId in ipairs(state.members) do
				self._sessions:apply(memberId, SessionReducer.teleportFailed)
			end
			commit(self, reevaluate(self, failed))
		end
	end
end

function PartyService.get(self: PartyService, partyId: string): PartyReducer.PartyState?
	return self._parties[partyId]
end

function PartyService.partyOf(self: PartyService, userId: number): PartyReducer.PartyState?
	local partyId = self._memberParty[userId]
	return partyId and self._parties[partyId] or nil
end

function PartyService.project(self: PartyService, state: PartyReducer.PartyState): { [string]: any }
	local remaining = nil
	if state.phase == "Countdown" and state.countdownDeadline then
		remaining = math.max(0, state.countdownDeadline - self._clock:monotonic())
	end
	local projection = PartyReducer.project(state, remaining)
	if state.phase ~= "Closed" then
		local ok, reason, lockedUserIds = self:evaluateValidity(state)
		projection.valid = ok
		projection.invalidReason = reason
		projection.lockedUserIds = lockedUserIds
	end
	return projection
end

-- Open parties a lobby player could join (Forming/Ready, not full), for the party list.
function PartyService.openParties(self: PartyService): { { [string]: any } }
	local out = {}
	for _, state in pairs(self._parties) do
		if (state.phase == "Forming" or state.phase == "Ready") and #state.members < state.maxMembers then
			table.insert(out, {
				partyId = state.partyId,
				leaderUserId = state.leaderUserId,
				members = table.clone(state.members),
				chapter = state.chapter,
				difficulty = state.difficulty,
				maxMembers = state.maxMembers,
			})
		end
	end
	table.sort(out, function(a, b)
		return a.partyId < b.partyId
	end)
	return out
end

function PartyService.count(self: PartyService): number
	local n = 0
	for _ in pairs(self._parties) do
		n += 1
	end
	return n
end

return PartyService
