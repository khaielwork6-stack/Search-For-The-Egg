--!strict
-- Pure per-player lifecycle machine (STATE_MACHINES.md section 1). A player is never active in
-- two authoritative sessions: the session token and round membership must agree before any
-- economy mutation is accepted by a service.

local SessionReducer = {}

export type SessionPhase =
	"LoadingProfile"
	| "LoadRetry"
	| "Removed"
	| "Lobby"
	| "Party"
	| "Teleporting"
	| "Round"
	| "RejoinReserved"
	| "Results"
	| "Saving"

export type SessionState = {
	userId: number,
	phase: SessionPhase,
	sessionToken: string, -- rotates on every phase that changes authority (lobby<->round)
	partyId: string?,
	roundId: string?,
	rejoinDeadline: number?, -- monotonic seconds
	loadAttempts: number,
	version: number,
}

SessionReducer.Errors = table.freeze({
	INVALID_PHASE = "invalid_phase",
	ALREADY_IN_SESSION = "already_in_session",
})

local TRANSITIONS: { [string]: { [string]: boolean } } = {
	LoadingProfile = { Lobby = true, LoadRetry = true },
	LoadRetry = { LoadingProfile = true, Removed = true },
	Lobby = { Party = true, Saving = true },
	Party = { Teleporting = true, Lobby = true, Saving = true },
	Teleporting = { Round = true, Party = true, Lobby = true },
	Round = { Results = true, RejoinReserved = true, Lobby = true, Saving = true },
	RejoinReserved = { Round = true, Lobby = true, Saving = true },
	Results = { Lobby = true, Saving = true },
	Saving = {},
	Removed = {},
}

local function bump(state: SessionState, patch: { [string]: any }): SessionState
	local next = table.clone(state) :: any
	for key, value in pairs(patch) do
		next[key] = value
	end
	next.version = state.version + 1
	return next
end

function SessionReducer.create(userId: number, token: string): SessionState
	return {
		userId = userId,
		phase = "LoadingProfile",
		sessionToken = token,
		partyId = nil,
		roundId = nil,
		rejoinDeadline = nil,
		loadAttempts = 0,
		version = 1,
	}
end

function SessionReducer.canTransition(state: SessionState, target: SessionPhase): boolean
	local allowed = TRANSITIONS[state.phase]
	return allowed ~= nil and allowed[target] == true
end

-- Generic guarded transition used by the service; specific helpers below add bookkeeping.
function SessionReducer.transition(state: SessionState, target: SessionPhase, patch: { [string]: any }?): (SessionState?, string?)
	if not SessionReducer.canTransition(state, target) then
		return nil, SessionReducer.Errors.INVALID_PHASE
	end
	local merged = table.clone(patch or {}) :: any
	merged.phase = target
	return bump(state, merged), nil
end

function SessionReducer.profileLoaded(state: SessionState): (SessionState?, string?)
	return SessionReducer.transition(state, "Lobby")
end

function SessionReducer.loadFailed(state: SessionState): (SessionState?, string?)
	return SessionReducer.transition(state, "LoadRetry", { loadAttempts = state.loadAttempts + 1 })
end

function SessionReducer.retryLoad(state: SessionState): (SessionState?, string?)
	return SessionReducer.transition(state, "LoadingProfile")
end

function SessionReducer.remove(state: SessionState): (SessionState?, string?)
	return SessionReducer.transition(state, "Removed")
end

function SessionReducer.joinParty(state: SessionState, partyId: string): (SessionState?, string?)
	if state.partyId ~= nil and state.partyId ~= partyId then
		return nil, SessionReducer.Errors.ALREADY_IN_SESSION
	end
	return SessionReducer.transition(state, "Party", { partyId = partyId })
end

function SessionReducer.leaveParty(state: SessionState): (SessionState?, string?)
	return SessionReducer.transition(state, "Lobby", { partyId = false })
end

function SessionReducer.beginTeleport(state: SessionState): (SessionState?, string?)
	return SessionReducer.transition(state, "Teleporting")
end

function SessionReducer.teleportFailed(state: SessionState): (SessionState?, string?)
	return SessionReducer.transition(state, "Party")
end

-- Entering a round rotates the token so lobby-era tokens are stale inside the round.
function SessionReducer.enterRound(state: SessionState, roundId: string, newToken: string): (SessionState?, string?)
	if state.roundId ~= nil and state.roundId ~= roundId then
		return nil, SessionReducer.Errors.ALREADY_IN_SESSION
	end
	return SessionReducer.transition(state, "Round", { roundId = roundId, sessionToken = newToken, rejoinDeadline = false })
end

function SessionReducer.disconnectInRound(state: SessionState, rejoinDeadline: number): (SessionState?, string?)
	return SessionReducer.transition(state, "RejoinReserved", { rejoinDeadline = rejoinDeadline })
end

function SessionReducer.rejoin(state: SessionState, now: number): (SessionState?, string?)
	if state.phase ~= "RejoinReserved" then
		return nil, SessionReducer.Errors.INVALID_PHASE
	end
	if state.rejoinDeadline and now > state.rejoinDeadline then
		return SessionReducer.transition(state, "Lobby", { roundId = false, rejoinDeadline = false })
	end
	return SessionReducer.transition(state, "Round", { rejoinDeadline = false })
end

function SessionReducer.roundCompleted(state: SessionState): (SessionState?, string?)
	return SessionReducer.transition(state, "Results")
end

function SessionReducer.returnToLobby(state: SessionState, newToken: string): (SessionState?, string?)
	return SessionReducer.transition(state, "Lobby", { roundId = false, partyId = false, sessionToken = newToken, rejoinDeadline = false })
end

function SessionReducer.beginSaving(state: SessionState): (SessionState?, string?)
	return SessionReducer.transition(state, "Saving")
end

-- Clears false sentinels used to null optional fields via table.clone.
function SessionReducer.normalize(state: SessionState): SessionState
	local out = table.clone(state) :: any
	for _, key in ipairs({ "partyId", "roundId", "rejoinDeadline" }) do
		if out[key] == false then
			out[key] = nil
		end
	end
	return out
end

function SessionReducer.tokenMatches(state: SessionState, token: any): boolean
	return type(token) == "string" and token == state.sessionToken
end

function SessionReducer.project(state: SessionState): { [string]: any }
	return {
		phase = state.phase,
		partyId = state.partyId,
		roundId = state.roundId,
		sessionToken = state.sessionToken, -- the owning client needs its token for requests
		version = state.version,
	}
end

return SessionReducer
