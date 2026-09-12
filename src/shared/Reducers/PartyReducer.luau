--!strict
-- Pure party state machine (STATE_MACHINES.md section 2). The service wraps this reducer, owns
-- the clock and adapters, and serializes calls. Every transition returns a new state table or an
-- error code; the input state is never mutated.

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

local PartyReducer = {}

export type PartyState = {
	partyId: string,
	leaderUserId: number,
	members: { number }, -- ordered by join time; index 1 is earliest
	chapter: string,
	difficulty: string,
	phase: "Forming" | "Ready" | "Countdown" | "Reserving" | "Teleporting" | "Closed",
	countdownDeadline: number?, -- monotonic seconds
	reservation: { code: string, placeKey: string }?,
	maxMembers: number,
	version: number, -- increments on every accepted transition (stale-request protection)
}

PartyReducer.Errors = table.freeze({
	FULL = "party_full",
	ALREADY_MEMBER = "already_member",
	NOT_MEMBER = "not_member",
	NOT_LEADER = "not_leader",
	INVALID_PHASE = "invalid_phase",
	LOCKED = "destination_locked",
	ALREADY_STARTED = "already_started",
	NOT_READY = "not_ready",
})

function PartyReducer.create(partyId: string, leaderUserId: number, chapter: string, difficulty: string, maxMembers: number): PartyState
	assert(maxMembers >= 1, "maxMembers must be >= 1")
	return {
		partyId = partyId,
		leaderUserId = leaderUserId,
		members = { leaderUserId },
		chapter = chapter,
		difficulty = difficulty,
		phase = "Forming",
		countdownDeadline = nil,
		reservation = nil,
		maxMembers = maxMembers,
		version = 1,
	}
end

local function bump(state: PartyState, patch: { [string]: any }): PartyState
	local next = table.clone(state) :: any
	for key, value in pairs(patch) do
		next[key] = value
	end
	next.version = state.version + 1
	return next
end

-- Validity is computed by the service (unlock checks per member); the reducer trusts `valid`.
function PartyReducer.evaluate(state: PartyState, valid: boolean): PartyState
	if state.phase == "Forming" and valid then
		return bump(state, { phase = "Ready" })
	elseif state.phase == "Ready" and not valid then
		return bump(state, { phase = "Forming" })
	elseif state.phase == "Countdown" and not valid then
		return bump(state, { phase = "Forming", countdownDeadline = false })
	end
	return state
end

function PartyReducer.join(state: PartyState, userId: number): (PartyState?, string?)
	if state.phase ~= "Forming" and state.phase ~= "Ready" then
		return nil, PartyReducer.Errors.INVALID_PHASE
	end
	if table.find(state.members, userId) then
		return nil, PartyReducer.Errors.ALREADY_MEMBER
	end
	if #state.members >= state.maxMembers then
		return nil, PartyReducer.Errors.FULL
	end
	local members = table.clone(state.members)
	table.insert(members, userId)
	-- Membership change returns to Forming until the service re-evaluates validity.
	return bump(state, { members = members, phase = "Forming" }), nil
end

function PartyReducer.leave(state: PartyState, userId: number): (PartyState?, string?)
	local index = table.find(state.members, userId)
	if not index then
		return nil, PartyReducer.Errors.NOT_MEMBER
	end
	local members = table.clone(state.members)
	table.remove(members, index)
	if #members == 0 then
		return bump(state, { members = members, phase = "Closed", countdownDeadline = false }), nil
	end
	local leader = state.leaderUserId
	if leader == userId then
		leader = members[1] -- deterministic: earliest remaining member
	end
	local phase = state.phase
	if phase == "Ready" or phase == "Countdown" then
		phase = "Forming"
	end
	return bump(state, { members = members, leaderUserId = leader, phase = phase, countdownDeadline = false }), nil
end

function PartyReducer.setDestination(state: PartyState, userId: number, chapter: string, difficulty: string): (PartyState?, string?)
	if userId ~= state.leaderUserId then
		return nil, PartyReducer.Errors.NOT_LEADER
	end
	if state.phase ~= "Forming" and state.phase ~= "Ready" then
		return nil, PartyReducer.Errors.INVALID_PHASE
	end
	return bump(state, { chapter = chapter, difficulty = difficulty, phase = "Forming" }), nil
end

function PartyReducer.start(state: PartyState, userId: number, countdownDeadline: number): (PartyState?, string?)
	if userId ~= state.leaderUserId then
		return nil, PartyReducer.Errors.NOT_LEADER
	end
	if state.phase == "Countdown" or state.phase == "Reserving" or state.phase == "Teleporting" then
		return nil, PartyReducer.Errors.ALREADY_STARTED
	end
	if state.phase ~= "Ready" then
		return nil, PartyReducer.Errors.NOT_READY
	end
	return bump(state, { phase = "Countdown", countdownDeadline = countdownDeadline }), nil
end

function PartyReducer.cancelCountdown(state: PartyState, userId: number): (PartyState?, string?)
	if userId ~= state.leaderUserId then
		return nil, PartyReducer.Errors.NOT_LEADER
	end
	if state.phase ~= "Countdown" then
		return nil, PartyReducer.Errors.INVALID_PHASE
	end
	return bump(state, { phase = "Ready", countdownDeadline = false }), nil
end

-- Called by the service tick with the monotonic time; moves Countdown -> Reserving once due.
function PartyReducer.tick(state: PartyState, now: number): PartyState
	if state.phase == "Countdown" and state.countdownDeadline and now >= state.countdownDeadline then
		return bump(state, { phase = "Reserving", countdownDeadline = false })
	end
	return state
end

function PartyReducer.reservationSucceeded(state: PartyState, reservation: { code: string, placeKey: string }): (PartyState?, string?)
	if state.phase ~= "Reserving" then
		return nil, PartyReducer.Errors.INVALID_PHASE
	end
	return bump(state, { phase = "Teleporting", reservation = reservation }), nil
end

function PartyReducer.reservationFailed(state: PartyState): (PartyState?, string?)
	if state.phase ~= "Reserving" then
		return nil, PartyReducer.Errors.INVALID_PHASE
	end
	return bump(state, { phase = "Ready", reservation = false }), nil
end

function PartyReducer.teleportFailed(state: PartyState): (PartyState?, string?)
	if state.phase ~= "Teleporting" then
		return nil, PartyReducer.Errors.INVALID_PHASE
	end
	return bump(state, { phase = "Ready", reservation = false }), nil
end

function PartyReducer.close(state: PartyState): PartyState
	return bump(state, { phase = "Closed", countdownDeadline = false })
end

-- Strips false sentinels (used to clear optional fields through table.clone) into nils.
function PartyReducer.normalize(state: PartyState): PartyState
	local out = table.clone(state) :: any
	if out.countdownDeadline == false then
		out.countdownDeadline = nil
	end
	if out.reservation == false then
		out.reservation = nil
	end
	return out
end

-- Client-safe projection: members and phase, no reservation codes.
function PartyReducer.project(state: PartyState, countdownRemaining: number?): { [string]: any }
	return {
		partyId = state.partyId,
		leaderUserId = state.leaderUserId,
		members = table.clone(state.members),
		chapter = state.chapter,
		difficulty = state.difficulty,
		phase = state.phase,
		countdownRemaining = countdownRemaining,
		maxMembers = state.maxMembers,
		version = state.version,
	}
end

PartyReducer.deepEqual = TableUtil.deepEqual

return PartyReducer
