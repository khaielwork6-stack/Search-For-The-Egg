--!strict
-- Pure round lifecycle machine (STATE_MACHINES.md section 3). Phase 1 ships the transitions and
-- invariants only; collection/selling/Egg gameplay arrives in Phase 2 and must call
-- `acceptsGameplay` / `acceptsClaim` before mutating anything.

local RoundReducer = {}

export type RoundPhase =
	"Bootstrapping"
	| "Cutscene"
	| "Countdown"
	| "Searching"
	| "EggRevealed"
	| "Victory"
	| "CommittingRewards"
	| "Results"
	| "Returning"
	| "Abandoned"

export type RoundState = {
	roundId: string,
	chapter: string,
	difficulty: string,
	configVersion: number,
	eggNodeId: string?, -- immutable once set during bootstrap
	phase: RoundPhase,
	members: { number },
	present: { [number]: boolean },
	skipVotes: { [number]: boolean },
	introReady: { [number]: boolean },
	countdownDeadline: number?,
	searchingStartedAtMs: number?,
	victory: { finderUserId: number, elapsedMs: number }?,
	joinClosed: boolean,
	version: number,
}

RoundReducer.Errors = table.freeze({
	INVALID_PHASE = "invalid_phase",
	NOT_MEMBER = "not_member",
	JOIN_CLOSED = "join_closed",
	ALREADY_WON = "already_won",
	IMMUTABLE = "immutable_field",
})

local function bump(state: RoundState, patch: { [string]: any }): RoundState
	local next = table.clone(state) :: any
	for key, value in pairs(patch) do
		next[key] = value
	end
	next.version = state.version + 1
	return next
end

function RoundReducer.create(roundId: string, chapter: string, difficulty: string, configVersion: number, members: { number }): RoundState
	local present = {}
	for _, userId in ipairs(members) do
		present[userId] = true
	end
	return {
		roundId = roundId,
		chapter = chapter,
		difficulty = difficulty,
		configVersion = configVersion,
		eggNodeId = nil,
		phase = "Bootstrapping",
		members = table.clone(members),
		present = present,
		skipVotes = {},
		introReady = {},
		countdownDeadline = nil,
		searchingStartedAtMs = nil,
		victory = nil,
		joinClosed = false,
		version = 1,
	}
end

-- Bootstrap completes once the map, pile, and Egg node are ready.
function RoundReducer.bootstrapComplete(state: RoundState, eggNodeId: string): (RoundState?, string?)
	if state.phase ~= "Bootstrapping" then
		return nil, RoundReducer.Errors.INVALID_PHASE
	end
	if state.eggNodeId ~= nil and state.eggNodeId ~= eggNodeId then
		return nil, RoundReducer.Errors.IMMUTABLE
	end
	return bump(state, { eggNodeId = eggNodeId, phase = "Cutscene" }), nil
end

function RoundReducer.voteSkip(state: RoundState, userId: number): (RoundState?, string?)
	if state.phase ~= "Cutscene" then
		return nil, RoundReducer.Errors.INVALID_PHASE
	end
	if not table.find(state.members, userId) then
		return nil, RoundReducer.Errors.NOT_MEMBER
	end
	local votes = table.clone(state.skipVotes)
	votes[userId] = true
	return bump(state, { skipVotes = votes }), nil
end

function RoundReducer.allPresentVotedSkip(state: RoundState): boolean
	for _, userId in ipairs(state.members) do
		if state.present[userId] and not state.skipVotes[userId] then
			return false
		end
	end
	return true
end

-- A member reports that the intro has finished playing for them (watched through, or skipped, or
-- failed and fell back). Idempotent by construction: the same report twice writes the same flag, so
-- spamming it cannot start the round twice. Only meaningful during the intro.
function RoundReducer.introReady(state: RoundState, userId: number): (RoundState?, string?)
	if state.phase ~= "Cutscene" then
		return nil, RoundReducer.Errors.INVALID_PHASE
	end
	if not table.find(state.members, userId) then
		return nil, RoundReducer.Errors.NOT_MEMBER
	end
	if state.introReady[userId] then
		return state, nil -- already ready: no version bump, nothing to broadcast
	end
	local ready = table.clone(state.introReady)
	ready[userId] = true
	return bump(state, { introReady = ready }), nil
end

-- Everyone still in the round has finished the intro. A member who disconnected is not present, so
-- the rest of the party is never held waiting for someone who left.
function RoundReducer.allPresentIntroReady(state: RoundState): boolean
	local anyPresent = false
	for _, userId in ipairs(state.members) do
		if state.present[userId] then
			anyPresent = true
			if not state.introReady[userId] and not state.skipVotes[userId] then
				return false
			end
		end
	end
	return anyPresent
end

-- How many of the present members are waiting, for the "Waiting for party..." line.
function RoundReducer.introReadyCounts(state: RoundState): (number, number)
	local ready, present = 0, 0
	for _, userId in ipairs(state.members) do
		if state.present[userId] then
			present += 1
			if state.introReady[userId] or state.skipVotes[userId] then
				ready += 1
			end
		end
	end
	return ready, present
end

function RoundReducer.cutsceneFinished(state: RoundState, countdownDeadline: number): (RoundState?, string?)
	if state.phase ~= "Cutscene" then
		return nil, RoundReducer.Errors.INVALID_PHASE
	end
	return bump(state, { phase = "Countdown", countdownDeadline = countdownDeadline }), nil
end

-- Server sets the authoritative start timestamp; the timer is serverNowMs - searchingStartedAtMs.
function RoundReducer.beginSearching(state: RoundState, serverNowMs: number): (RoundState?, string?)
	if state.phase ~= "Countdown" then
		return nil, RoundReducer.Errors.INVALID_PHASE
	end
	return bump(state, { phase = "Searching", searchingStartedAtMs = serverNowMs, countdownDeadline = false }), nil
end

function RoundReducer.elapsedMs(state: RoundState, serverNowMs: number): number
	if not state.searchingStartedAtMs then
		return 0
	end
	return math.max(0, serverNowMs - state.searchingStartedAtMs)
end

function RoundReducer.acceptsGameplay(state: RoundState): boolean
	return state.phase == "Searching"
end

function RoundReducer.acceptsClaim(state: RoundState): boolean
	return state.phase == "EggRevealed"
end

-- Join is allowed during Searching until the Egg is revealed (A-MP-06).
function RoundReducer.join(state: RoundState, userId: number): (RoundState?, string?)
	if state.joinClosed or state.phase ~= "Searching" then
		return nil, RoundReducer.Errors.JOIN_CLOSED
	end
	local members = table.clone(state.members)
	if not table.find(members, userId) then
		table.insert(members, userId)
	end
	local present = table.clone(state.present)
	present[userId] = true
	return bump(state, { members = members, present = present }), nil
end

function RoundReducer.setPresent(state: RoundState, userId: number, isPresent: boolean): (RoundState?, string?)
	if not table.find(state.members, userId) then
		return nil, RoundReducer.Errors.NOT_MEMBER
	end
	local present = table.clone(state.present)
	present[userId] = isPresent
	return bump(state, { present = present }), nil
end

function RoundReducer.eggRevealed(state: RoundState): (RoundState?, string?)
	if state.phase ~= "Searching" then
		return nil, RoundReducer.Errors.INVALID_PHASE
	end
	return bump(state, { phase = "EggRevealed", joinClosed = true }), nil
end

function RoundReducer.revealInvalidated(state: RoundState): (RoundState?, string?)
	if state.phase ~= "EggRevealed" then
		return nil, RoundReducer.Errors.INVALID_PHASE
	end
	return bump(state, { phase = "Searching" }), nil
end

-- Atomic compare-and-set equivalent: the first claim in EggRevealed wins; every later call fails.
function RoundReducer.claim(state: RoundState, userId: number, serverNowMs: number): (RoundState?, string?)
	if state.victory ~= nil then
		return nil, RoundReducer.Errors.ALREADY_WON
	end
	if state.phase ~= "EggRevealed" then
		return nil, RoundReducer.Errors.INVALID_PHASE
	end
	if not table.find(state.members, userId) or not state.present[userId] then
		return nil, RoundReducer.Errors.NOT_MEMBER
	end
	return bump(state, {
		phase = "Victory",
		victory = { finderUserId = userId, elapsedMs = RoundReducer.elapsedMs(state, serverNowMs) },
	}),
		nil
end

function RoundReducer.beginCommit(state: RoundState): (RoundState?, string?)
	if state.phase ~= "Victory" then
		return nil, RoundReducer.Errors.INVALID_PHASE
	end
	return bump(state, { phase = "CommittingRewards" }), nil
end

function RoundReducer.rewardsCommitted(state: RoundState): (RoundState?, string?)
	if state.phase ~= "CommittingRewards" then
		return nil, RoundReducer.Errors.INVALID_PHASE
	end
	return bump(state, { phase = "Results" }), nil
end

function RoundReducer.beginReturn(state: RoundState): (RoundState?, string?)
	if state.phase ~= "Results" and state.phase ~= "Abandoned" then
		return nil, RoundReducer.Errors.INVALID_PHASE
	end
	return bump(state, { phase = "Returning" }), nil
end

function RoundReducer.abandon(state: RoundState): (RoundState?, string?)
	if
		state.phase ~= "Searching"
		and state.phase ~= "Cutscene"
		and state.phase ~= "Countdown"
		and state.phase ~= "Bootstrapping"
		and state.phase ~= "EggRevealed"
	then
		return nil, RoundReducer.Errors.INVALID_PHASE
	end
	return bump(state, { phase = "Abandoned", joinClosed = true }), nil
end

-- Members currently present receive base rewards (victory.partyRewardPolicy = all_present_party_members).
function RoundReducer.presentMembers(state: RoundState): { number }
	local out = {}
	for _, userId in ipairs(state.members) do
		if state.present[userId] then
			table.insert(out, userId)
		end
	end
	return out
end

function RoundReducer.project(state: RoundState, serverNowMs: number): { [string]: any }
	return {
		roundId = state.roundId,
		chapter = state.chapter,
		difficulty = state.difficulty,
		phase = state.phase,
		members = table.clone(state.members),
		elapsedMs = RoundReducer.elapsedMs(state, serverNowMs),
		joinClosed = state.joinClosed,
		finderUserId = state.victory and state.victory.finderUserId or nil,
		version = state.version,
		-- eggNodeId deliberately omitted: clients never learn the Egg position from projections.
	}
end

return RoundReducer
