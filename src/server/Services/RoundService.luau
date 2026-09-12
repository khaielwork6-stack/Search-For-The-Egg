--!strict
-- Round lifecycle authority (skeleton). Owns RoundReducer state per round, the cutscene and
-- countdown deadlines, the authoritative Searching start timestamp, Egg node selection with
-- repeat protection, and the victory -> commit -> results -> return sequence. Collection,
-- selling, and Egg reveal detection arrive in Phase 2 and must go through this service.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local SessionReducer = require(Shared.Reducers.SessionReducer)
local WeightedRandom = require(Shared.WeightedRandom)
local Signal = require(Shared.Util.Signal)

local RoundService = {}
RoundService.__index = RoundService

type Round = {
	state: RoundReducer.RoundState,
	cutsceneDeadline: number?,
	createdAt: number,
}

export type RoundService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_clock: any,
		_idGen: () -> string,
		_rng: any,
		_sessions: any,
		_analytics: any?,
		_log: any?,
		_rounds: { [string]: Round },
		_recentNodes: { [string]: { string } }, -- chapter -> last N node ids
		changed: any,
		completed: any,
	},
	RoundService
))

function RoundService.new(options: {
	config: { [string]: any },
	clock: any,
	idGen: () -> string,
	rng: any,
	sessions: any,
	analytics: any?,
	log: any?,
}): RoundService
	return setmetatable({
		_config = options.config,
		_clock = options.clock,
		_idGen = options.idGen,
		_rng = options.rng,
		_sessions = options.sessions,
		_analytics = options.analytics,
		_log = options.log,
		_rounds = {},
		_recentNodes = {},
		changed = Signal.new(),
		completed = Signal.new(),
	}, RoundService)
end

local function commit(self: RoundService, round: Round, state: RoundReducer.RoundState): RoundReducer.RoundState
	round.state = state
	self.changed:Fire(state)
	return state
end

-- Placeholder spawn-node catalogue: `spawnNodeCountTarget` synthetic ids per chapter, equal
-- weight. Phase 2 replaces this with authored nodes (transform, cover cells, camera anchor).
-- PLACEHOLDER owner: Phase 2 EggService.
function RoundService.candidateNodes(self: RoundService, chapter: string): { WeightedRandom.WeightedEntry }
	local out = {}
	for index = 1, self._config.eggSpawn.spawnNodeCountTarget do
		table.insert(out, { id = chapter .. ":node_" .. tostring(index), weight = 1 })
	end
	return out
end

-- Weighted selection excluding the last `repeatProtectionRounds` nodes for the chapter.
function RoundService.selectEggNode(self: RoundService, chapter: string): string
	local recent = self._recentNodes[chapter] or {}
	local candidates = {}
	for _, node in ipairs(self:candidateNodes(chapter)) do
		if not table.find(recent, node.id) then
			table.insert(candidates, node)
		end
	end
	if #candidates == 0 then
		candidates = self:candidateNodes(chapter)
	end
	local chosen = WeightedRandom.select(candidates, self._rng).id
	table.insert(recent, chosen)
	while #recent > self._config.eggSpawn.repeatProtectionRounds do
		table.remove(recent, 1)
	end
	self._recentNodes[chapter] = recent
	return chosen
end

-- Creates a round for a party and completes bootstrap immediately (map/pile readiness is a
-- Phase 2 concern; the skeleton has nothing to load).
function RoundService.createForParty(
	self: RoundService,
	party: { partyId: string, chapter: string, difficulty: string, members: { number } }
): RoundReducer.RoundState
	local roundId = self._idGen()
	local state = RoundReducer.create(roundId, party.chapter, party.difficulty, self._config.configVersion, party.members)
	local round: Round = { state = state, cutsceneDeadline = nil, createdAt = self._clock:monotonic() }
	self._rounds[roundId] = round

	for _, userId in ipairs(party.members) do
		self._sessions:apply(userId, SessionReducer.enterRound, roundId, self._sessions:newToken())
	end

	local eggNode = self:selectEggNode(party.chapter)
	local booted = RoundReducer.bootstrapComplete(state, eggNode) :: RoundReducer.RoundState
	round.cutsceneDeadline = self._clock:monotonic() + self._config.round.cutsceneSeconds
	commit(self, round, booted)
	if self._analytics then
		self._analytics:track("round_started", { chapter = party.chapter, difficulty = party.difficulty, partySize = #party.members })
	end
	return booted
end

function RoundService.voteSkip(self: RoundService, roundId: string, userId: number): (RoundReducer.RoundState?, string?)
	local round = self._rounds[roundId]
	if not round then
		return nil, "not_found"
	end
	local next, err = RoundReducer.voteSkip(round.state, userId)
	if not next then
		return nil, err
	end
	next = commit(self, round, next)
	if RoundReducer.allPresentVotedSkip(next) then
		round.cutsceneDeadline = self._clock:monotonic()
	end
	return next, nil
end

-- Advances time-driven transitions. Returns the number of rounds that changed phase.
function RoundService.tick(self: RoundService): number
	local now = self._clock:monotonic()
	local nowMs = self._clock:nowMs()
	local changed = 0
	for roundId, round in pairs(table.clone(self._rounds)) do
		local state = round.state
		if state.phase == "Cutscene" and round.cutsceneDeadline and now >= round.cutsceneDeadline then
			local next = RoundReducer.cutsceneFinished(state, now + self._config.round.countdownSeconds)
			if next then
				commit(self, round, next)
				changed += 1
			end
		elseif state.phase == "Countdown" and state.countdownDeadline and now >= state.countdownDeadline then
			local next = RoundReducer.beginSearching(state, nowMs)
			if next then
				commit(self, round, next)
				changed += 1
			end
		elseif
			(
				(state.phase == "Searching" or state.phase == "EggRevealed")
				and (now - round.createdAt) >= self._config.round.maximumRoundSeconds
			) or (state.phase == "Searching" and #RoundReducer.presentMembers(state) == 0)
		then
			-- Lifetime exceeded or every member gone: abandon (STATE_MACHINES.md section 3).
			local next = RoundReducer.abandon(state)
			if next then
				commit(self, round, next)
				changed += 1
			end
		end
		if round.state.phase == "Returning" then
			self._rounds[roundId] = nil
		end
	end
	return changed
end

-- Phase 2 will call this from EggService when cover cells are cleared.
function RoundService.markEggRevealed(self: RoundService, roundId: string): (RoundReducer.RoundState?, string?)
	local round = self._rounds[roundId]
	if not round then
		return nil, "not_found"
	end
	local next, err = RoundReducer.eggRevealed(round.state)
	if not next then
		return nil, err
	end
	return commit(self, round, next), nil
end

-- Atomic first-valid claim. Requires a valid session token for the claimant.
function RoundService.claim(self: RoundService, roundId: string, userId: number, token: any): (RoundReducer.RoundState?, string?)
	local round = self._rounds[roundId]
	if not round then
		return nil, "not_found"
	end
	local okToken, tokenErr = self._sessions:validate(userId, token, "Round")
	if not okToken then
		return nil, tokenErr
	end
	local next, err = RoundReducer.claim(round.state, userId, self._clock:nowMs())
	if not next then
		return nil, err
	end
	next = commit(self, round, next)
	if self._analytics then
		self._analytics:track(
			"egg_claimed",
			{ chapter = next.chapter, difficulty = next.difficulty, elapsedMs = next.victory and next.victory.elapsedMs or 0 },
			userId
		)
	end
	return next, nil
end

-- Victory -> CommittingRewards -> Results. `commitRewards(state)` is injected (VictoryService in
-- Phase 2) and must be idempotent; the skeleton passes when it returns true.
function RoundService.commitAndFinish(
	self: RoundService,
	roundId: string,
	commitRewards: (state: RoundReducer.RoundState) -> boolean
): (RoundReducer.RoundState?, string?)
	local round = self._rounds[roundId]
	if not round then
		return nil, "not_found"
	end
	local committing, err = RoundReducer.beginCommit(round.state)
	if not committing then
		return nil, err
	end
	committing = commit(self, round, committing)
	local ok = commitRewards(committing)
	if not ok then
		return committing, "commit_pending" -- stays in CommittingRewards ("Securing rewards...")
	end
	local results = RoundReducer.rewardsCommitted(committing) :: RoundReducer.RoundState
	results = commit(self, round, results)
	for _, userId in ipairs(results.members) do
		self._sessions:apply(userId, SessionReducer.roundCompleted)
	end
	self.completed:Fire(results)
	return results, nil
end

function RoundService.returnToLobby(self: RoundService, roundId: string): (RoundReducer.RoundState?, string?)
	local round = self._rounds[roundId]
	if not round then
		return nil, "not_found"
	end
	local next, err = RoundReducer.beginReturn(round.state)
	if not next then
		return nil, err
	end
	next = commit(self, round, next)
	for _, userId in ipairs(next.members) do
		local session = self._sessions:get(userId)
		if session and (session.phase == "Results" or session.phase == "Round" or session.phase == "RejoinReserved") then
			self._sessions:apply(userId, SessionReducer.returnToLobby, self._sessions:newToken())
		end
	end
	self._rounds[roundId] = nil
	return next, nil
end

function RoundService.setPresent(self: RoundService, roundId: string, userId: number, present: boolean): (RoundReducer.RoundState?, string?)
	local round = self._rounds[roundId]
	if not round then
		return nil, "not_found"
	end
	local next, err = RoundReducer.setPresent(round.state, userId, present)
	if not next then
		return nil, err
	end
	return commit(self, round, next), nil
end

function RoundService.get(self: RoundService, roundId: string): RoundReducer.RoundState?
	local round = self._rounds[roundId]
	return round and round.state or nil
end

function RoundService.project(self: RoundService, roundId: string): { [string]: any }?
	local round = self._rounds[roundId]
	return round and RoundReducer.project(round.state, self._clock:nowMs()) or nil
end

function RoundService.count(self: RoundService): number
	local n = 0
	for _ in pairs(self._rounds) do
		n += 1
	end
	return n
end

return RoundService
