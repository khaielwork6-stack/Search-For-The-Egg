--!strict
-- Per-player session authority: owns SessionReducer state and tokens, guarantees a user is never
-- active in two sessions, and validates request tokens before any service mutates economy state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local SessionReducer = require(Shared.Reducers.SessionReducer)
local Signal = require(Shared.Util.Signal)

local SessionService = {}
SessionService.__index = SessionService

export type SessionService = typeof(setmetatable(
	{} :: {
		_sessions: { [number]: SessionReducer.SessionState },
		_idGen: () -> string,
		_clock: any,
		_log: any,
		changed: any,
	},
	SessionService
))

function SessionService.new(options: { idGen: () -> string, clock: any, log: any? }): SessionService
	return setmetatable({
		_sessions = {},
		_idGen = options.idGen,
		_clock = options.clock,
		_log = options.log,
		changed = Signal.new(),
	}, SessionService)
end

function SessionService.open(self: SessionService, userId: number): SessionReducer.SessionState
	assert(self._sessions[userId] == nil, "SessionService: session already open for " .. tostring(userId))
	local state = SessionReducer.create(userId, self._idGen())
	self._sessions[userId] = state
	self.changed:Fire(userId, state)
	return state
end

function SessionService.get(self: SessionService, userId: number): SessionReducer.SessionState?
	return self._sessions[userId]
end

function SessionService.has(self: SessionService, userId: number): boolean
	return self._sessions[userId] ~= nil
end

-- Applies a reducer function (state, ...) -> (newState?, err?) and stores the normalized result.
function SessionService.apply(self: SessionService, userId: number, reducerFn: any, ...: any): (SessionReducer.SessionState?, string?)
	local state = self._sessions[userId]
	if not state then
		return nil, "no_session"
	end
	local next, err = reducerFn(state, ...)
	if not next then
		return nil, err
	end
	next = SessionReducer.normalize(next)
	self._sessions[userId] = next
	self.changed:Fire(userId, next)
	return next, nil
end

function SessionService.close(self: SessionService, userId: number)
	self._sessions[userId] = nil
end

function SessionService.newToken(self: SessionService): string
	return self._idGen()
end

-- Token + phase validation used by every gameplay/economy handler.
function SessionService.validate(self: SessionService, userId: number, token: any, requiredPhase: string?): (boolean, string?)
	local state = self._sessions[userId]
	if not state then
		return false, "no_session"
	end
	if not SessionReducer.tokenMatches(state, token) then
		return false, "stale_token"
	end
	if requiredPhase and state.phase ~= requiredPhase then
		return false, "invalid_phase"
	end
	return true, nil
end

function SessionService.count(self: SessionService): number
	local n = 0
	for _ in pairs(self._sessions) do
		n += 1
	end
	return n
end

function SessionService.project(self: SessionService, userId: number): { [string]: any }?
	local state = self._sessions[userId]
	return state and SessionReducer.project(state) or nil
end

return SessionService
