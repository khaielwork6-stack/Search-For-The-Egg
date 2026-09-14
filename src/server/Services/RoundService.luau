--!strict
-- Round lifecycle authority. Owns RoundReducer state per round plus the round runtime: the logical
-- pile grid, the selected Egg node (immutable), per-player round state (cash, bag, levels,
-- contribution), pending pile deltas batched at the configured replication rate, and results.
-- Gameplay services (Collection/Selling/Upgrade/Egg/Victory) mutate runtime only through this
-- service's accessors and always re-check `RoundReducer.acceptsGameplay`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local SessionReducer = require(Shared.Reducers.SessionReducer)
local WeightedRandom = require(Shared.WeightedRandom)
local PileGrid = require(Shared.Domain.PileGrid)
local PileSurface = require(Shared.Domain.PileSurface)
local EggNodes = require(Shared.Domain.EggNodes)
local ToolSpecs = require(Shared.Domain.ToolSpecs)
local Signal = require(Shared.Util.Signal)

local RoundService = {}
RoundService.__index = RoundService

export type PlayerState = {
	lastCollectRequestId: any?,
	userId: number,
	roundId: string,
	joinedAtMs: number,
	cashCents: number,
	carriedStandard: number,
	carriedRainbow: number,
	bagLevel: number,
	handLevels: { grasp: number, speed: number, hold: number },
	roundTools: { [string]: boolean },
	toolLevels: { [string]: { [string]: number } },
	contribution: { cellsRemoved: number, feathersCollected: number },
	alive: boolean,
	cooldownUntil: number, -- monotonic seconds
	saleCount: number,
	upgradeCount: number,
	lastSale: any?,
	equippedTool: string,
	toolRuntime: { [string]: any }, -- per-tool live state owned by ToolService (vac heat, charges, chick)
	permanentTools: { [string]: boolean },
}

export type Runtime = {
	state: RoundReducer.RoundState,
	cutsceneDeadline: number?,
	createdAt: number,
	grid: PileGrid.Grid,
	nodes: { EggNodes.Node },
	eggNode: EggNodes.Node,
	eggDepthFraction: number,
	eggSlot: number,
	eggCoverCleared: boolean,
	players: { [number]: PlayerState },
	pendingDelta: { [number]: number }, -- cell index -> remaining
	results: { [number]: any },
	commitPending: boolean,
	resultsShownAt: number?,
	returnVotes: { [number]: string },
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
		_rounds: { [string]: Runtime },
		_roundOf: { [number]: string },
		_recentNodes: { [string]: { string } },
		changed: any,
		created: any,
		deltaFlushed: any,
		completed: any,
		returned: any,
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
		_roundOf = {},
		_recentNodes = {},
		changed = Signal.new(),
		created = Signal.new(),
		deltaFlushed = Signal.new(),
		completed = Signal.new(),
		returned = Signal.new(),
	}, RoundService)
end

local function commit(self: RoundService, runtime: Runtime, state: RoundReducer.RoundState): RoundReducer.RoundState
	runtime.state = state
	self.changed:Fire(state)
	return state
end

function RoundService.candidateNodes(self: RoundService, chapter: string): { EggNodes.Node }
	return EggNodes.build(chapter, self._config.pile, self._config.eggSpawn)
end

-- Weighted selection excluding the last `repeatProtectionRounds` nodes for the chapter.
function RoundService.selectEggNode(self: RoundService, chapter: string): EggNodes.Node
	local recent = self._recentNodes[chapter] or {}
	local nodes = self:candidateNodes(chapter)
	local candidates = {}
	for _, node in ipairs(nodes) do
		if not table.find(recent, node.id) then
			table.insert(candidates, node)
		end
	end
	if #candidates == 0 then
		candidates = nodes
	end
	local entries = {}
	for _, node in ipairs(candidates) do
		table.insert(entries, { id = node.id, weight = node.weight })
	end
	local chosenId = WeightedRandom.select(entries, self._rng).id
	table.insert(recent, chosenId)
	while #recent > self._config.eggSpawn.repeatProtectionRounds do
		table.remove(recent, 1)
	end
	self._recentNodes[chapter] = recent
	return EggNodes.byId(nodes, chosenId) :: EggNodes.Node
end

local function newPlayerState(userId: number, roundId: string, nowMs: number): PlayerState
	return {
		lastCollectRequestId = nil,
		userId = userId,
		roundId = roundId,
		joinedAtMs = nowMs,
		cashCents = 0,
		carriedStandard = 0,
		carriedRainbow = 0,
		bagLevel = 1,
		handLevels = { grasp = 0, speed = 0, hold = 0 },
		roundTools = { hand = true },
		toolLevels = ToolSpecs.defaultLevels(),
		contribution = { cellsRemoved = 0, feathersCollected = 0 },
		alive = true,
		cooldownUntil = 0,
		saleCount = 0,
		upgradeCount = 0,
		lastSale = nil,
		equippedTool = "hand",
		toolRuntime = {},
		permanentTools = {},
	}
end

-- Creates a round for a party: selects the Egg node, builds the pile with cover density, creates
-- per-player state, rotates session tokens, and completes bootstrap into the cutscene.
function RoundService.createForParty(
	self: RoundService,
	party: { partyId: string, chapter: string, difficulty: string, members: { number } }
): RoundReducer.RoundState
	local roundId = self._idGen()
	local state = RoundReducer.create(roundId, party.chapter, party.difficulty, self._config.configVersion, party.members)
	local eggNode = self:selectEggNode(party.chapter)
	local difficulty = self._config.difficulty[party.difficulty]
	local cover: { [number]: boolean } = {}
	for _, index in ipairs(eggNode.coverIndexes) do
		cover[index] = true
	end
	local pileConfig = self._config.pile
	local config = self._config
	local grid = PileGrid.create(pileConfig, difficulty.pileHealthMultiplier, cover, function()
		return self._rng:next()
	end, function(x, z)
		return PileSurface.columnRecords(config, pileConfig.gridWidth, pileConfig.gridDepth, pileConfig.cellSizeStuds, x, z)
	end)
	-- The Egg sits inside its column: `eggSlot` is the lowest record that must be gone before it
	-- shows, chosen so a deep fraction of the column covers it.
	local eggLucky = EggNodes.rollLucky(self._config.eggSpawn, self._rng:next())
	local eggDepthFraction = EggNodes.rollDepth(self._config.eggSpawn, difficulty, self._rng:next(), eggLucky)
	local eggCell = grid.cells[PileGrid.index(grid.width, eggNode.x, eggNode.z)]
	local eggSlot = math.clamp(eggCell.base - math.floor(eggCell.base * eggDepthFraction + 0.5) + 1, 2, math.max(2, eggCell.base))
	local runtime: Runtime = {
		state = state,
		cutsceneDeadline = self._clock:monotonic() + self._config.round.cutsceneSeconds,
		createdAt = self._clock:monotonic(),
		grid = grid,
		nodes = self:candidateNodes(party.chapter),
		eggNode = eggNode,
		eggDepthFraction = eggDepthFraction,
		eggLucky = eggLucky,
		eggSlot = eggSlot,
		eggCoverCleared = false,
		players = {},
		pendingDelta = {},
		results = {},
		bundles = {},
		charges = {},
		commitPending = false,
		rewardsCommitted = false,
		resultsShownAt = nil,
		returnVotes = {},
	}
	local nowMs = self._clock:nowMs()
	for _, userId in ipairs(party.members) do
		runtime.players[userId] = newPlayerState(userId, roundId, nowMs)
		self._roundOf[userId] = roundId
		self._sessions:apply(userId, SessionReducer.enterRound, roundId, self._sessions:newToken())
	end
	self._rounds[roundId] = runtime
	local booted = RoundReducer.bootstrapComplete(state, eggNode.id) :: RoundReducer.RoundState
	commit(self, runtime, booted)
	if self._analytics then
		self._analytics:track("round_started", { chapter = party.chapter, difficulty = party.difficulty, partySize = #party.members })
	end
	self.created:Fire(booted, runtime)
	return booted
end

function RoundService.runtime(self: RoundService, roundId: string): Runtime?
	return self._rounds[roundId]
end

-- Live runtimes keyed by round id (read-only iteration for tick-driven services).
function RoundService.all(self: RoundService): { [string]: Runtime }
	return self._rounds
end

function RoundService.roundOf(self: RoundService, userId: number): Runtime?
	local roundId = self._roundOf[userId]
	return roundId and self._rounds[roundId] or nil
end

function RoundService.playerState(self: RoundService, roundId: string, userId: number): PlayerState?
	local runtime = self._rounds[roundId]
	return runtime and runtime.players[userId] or nil
end

function RoundService.voteSkip(self: RoundService, roundId: string, userId: number): (RoundReducer.RoundState?, string?)
	local runtime = self._rounds[roundId]
	if not runtime then
		return nil, "not_found"
	end
	local next, err = RoundReducer.voteSkip(runtime.state, userId)
	if not next then
		return nil, err
	end
	next = commit(self, runtime, next)
	if RoundReducer.allPresentVotedSkip(next) then
		runtime.cutsceneDeadline = self._clock:monotonic()
	end
	return next, nil
end

-- Queues a pile cell change for the next replication flush.
function RoundService.queueDelta(self: RoundService, roundId: string, cellIndex: number, remaining: number, mask: number?)
	local runtime = self._rounds[roundId]
	if runtime then
		local cell = runtime.grid.cells[cellIndex]
		runtime.pendingDelta[cellIndex] = { r = remaining, m = mask or (cell and cell.taken) or 0 }
	end
end

-- Flushes batched deltas (called at collection.pileRepresentation.replicationHz). Returns rounds flushed.
function RoundService.flushDeltas(self: RoundService): number
	local flushed = 0
	for roundId, runtime in pairs(self._rounds) do
		if next(runtime.pendingDelta) ~= nil then
			local cells = {}
			for index, change in pairs(runtime.pendingDelta) do
				table.insert(cells, { i = index, r = change.r, m = change.m })
			end
			runtime.pendingDelta = {}
			flushed += 1
			self.deltaFlushed:Fire(roundId, {
				roundId = roundId,
				cells = cells,
				removed = runtime.grid.removed,
				total = runtime.grid.total,
				version = runtime.grid.version,
			})
		end
	end
	return flushed
end

-- Advances time-driven transitions. Returns the number of rounds that changed phase.
function RoundService.tick(self: RoundService): number
	local now = self._clock:monotonic()
	local nowMs = self._clock:nowMs()
	local changed = 0
	for roundId, runtime in pairs(table.clone(self._rounds)) do
		local state = runtime.state
		if state.phase == "Cutscene" and runtime.cutsceneDeadline and now >= runtime.cutsceneDeadline then
			local next = RoundReducer.cutsceneFinished(state, now + self._config.round.countdownSeconds)
			if next then
				commit(self, runtime, next)
				changed += 1
			end
		elseif state.phase == "Countdown" and state.countdownDeadline and now >= state.countdownDeadline then
			local next = RoundReducer.beginSearching(state, nowMs)
			if next then
				commit(self, runtime, next)
				changed += 1
			end
		elseif
			(
				(state.phase == "Searching" or state.phase == "EggRevealed")
				and (now - runtime.createdAt) >= self._config.round.maximumRoundSeconds
			) or (state.phase == "Searching" and #RoundReducer.presentMembers(state) == 0)
		then
			-- Lifetime exceeded or every member gone: abandon (STATE_MACHINES.md section 3).
			local next = RoundReducer.abandon(state)
			if next then
				commit(self, runtime, next)
				changed += 1
			end
		elseif
			state.phase == "Results"
			and runtime.resultsShownAt
			and (now - runtime.resultsShownAt) >= self._config.round.resultScreenAutoContinueSeconds
		then
			self:returnToLobby(roundId)
			changed += 1
		end
		if self._rounds[roundId] and self._rounds[roundId].state.phase == "Returning" then
			self._rounds[roundId] = nil
		end
	end
	return changed
end

function RoundService.markEggRevealed(self: RoundService, roundId: string): (RoundReducer.RoundState?, string?)
	local runtime = self._rounds[roundId]
	if not runtime then
		return nil, "not_found"
	end
	local next, err = RoundReducer.eggRevealed(runtime.state)
	if not next then
		return nil, err
	end
	return commit(self, runtime, next), nil
end

-- Atomic first-valid claim. Requires a valid session token for the claimant.
function RoundService.claim(self: RoundService, roundId: string, userId: number, token: any): (RoundReducer.RoundState?, string?)
	local runtime = self._rounds[roundId]
	if not runtime then
		return nil, "not_found"
	end
	local okToken, tokenErr = self._sessions:validate(userId, token, "Round")
	if not okToken then
		return nil, tokenErr
	end
	local next, err = RoundReducer.claim(runtime.state, userId, self._clock:nowMs())
	if not next then
		return nil, err
	end
	next = commit(self, runtime, next)
	if self._analytics then
		self._analytics:track(
			"egg_claimed",
			{ chapter = next.chapter, difficulty = next.difficulty, elapsedMs = next.victory and next.victory.elapsedMs or 0 },
			userId
		)
	end
	return next, nil
end

-- Victory -> CommittingRewards -> Results. `commitRewards(runtime)` must be idempotent; when it
-- returns false the round stays in CommittingRewards ("Securing rewards...") for a later retry.
function RoundService.commitAndFinish(
	self: RoundService,
	roundId: string,
	commitRewards: (runtime: Runtime) -> boolean
): (RoundReducer.RoundState?, string?)
	local runtime = self._rounds[roundId]
	if not runtime then
		return nil, "not_found"
	end
	local state = runtime.state
	if state.phase == "Victory" then
		local committing, err = RoundReducer.beginCommit(state)
		if not committing then
			return nil, err
		end
		state = commit(self, runtime, committing)
	elseif state.phase ~= "CommittingRewards" then
		return nil, RoundReducer.Errors.INVALID_PHASE
	end
	local ok = commitRewards(runtime)
	if not ok then
		runtime.commitPending = true
		return state, "commit_pending"
	end
	runtime.commitPending = false
	local results = RoundReducer.rewardsCommitted(state) :: RoundReducer.RoundState
	results = commit(self, runtime, results)
	runtime.resultsShownAt = self._clock:monotonic()
	for _, userId in ipairs(results.members) do
		self._sessions:apply(userId, SessionReducer.roundCompleted)
	end
	self.completed:Fire(results, runtime)
	return results, nil
end

-- Records a member's results choice; the round returns once every present member has chosen.
function RoundService.resultsAction(self: RoundService, roundId: string, userId: number, action: string): (boolean, string?)
	local runtime = self._rounds[roundId]
	if not runtime or runtime.state.phase ~= "Results" then
		return false, RoundReducer.Errors.INVALID_PHASE
	end
	if not table.find(runtime.state.members, userId) then
		return false, RoundReducer.Errors.NOT_MEMBER
	end
	runtime.returnVotes[userId] = action
	if self._analytics then
		self._analytics:track(
			"results_closed",
			{ chapter = runtime.state.chapter, difficulty = runtime.state.difficulty, replay = action == "replay" },
			userId
		)
	end
	for _, memberId in ipairs(RoundReducer.presentMembers(runtime.state)) do
		if not runtime.returnVotes[memberId] then
			return true, nil
		end
	end
	self:returnToLobby(roundId)
	return true, nil
end

function RoundService.returnToLobby(self: RoundService, roundId: string): (RoundReducer.RoundState?, string?)
	local runtime = self._rounds[roundId]
	if not runtime then
		return nil, "not_found"
	end
	local next, err = RoundReducer.beginReturn(runtime.state)
	if not next then
		return nil, err
	end
	next = commit(self, runtime, next)
	for _, userId in ipairs(next.members) do
		local session = self._sessions:get(userId)
		if session and (session.phase == "Results" or session.phase == "Round" or session.phase == "RejoinReserved") then
			self._sessions:apply(userId, SessionReducer.returnToLobby, self._sessions:newToken())
		end
		if self._roundOf[userId] == roundId then
			self._roundOf[userId] = nil
		end
	end
	self._rounds[roundId] = nil
	self.returned:Fire(next, runtime)
	return next, nil
end

function RoundService.setPresent(self: RoundService, roundId: string, userId: number, present: boolean): (RoundReducer.RoundState?, string?)
	local runtime = self._rounds[roundId]
	if not runtime then
		return nil, "not_found"
	end
	local next, err = RoundReducer.setPresent(runtime.state, userId, present)
	if not next then
		return nil, err
	end
	return commit(self, runtime, next), nil
end

function RoundService.get(self: RoundService, roundId: string): RoundReducer.RoundState?
	local runtime = self._rounds[roundId]
	return runtime and runtime.state or nil
end

-- Phase/timer projection (no Egg position). `includePile` adds the full grid snapshot.
function RoundService.project(self: RoundService, roundId: string, includePile: boolean?): { [string]: any }?
	local runtime = self._rounds[roundId]
	if not runtime then
		return nil
	end
	local nowMs = self._clock:nowMs()
	local projection = RoundReducer.project(runtime.state, nowMs)
	projection.serverNowMs = nowMs
	projection.searchingStartedAtMs = runtime.state.searchingStartedAtMs
	projection.cutsceneSeconds = self._config.round.cutsceneSeconds
	projection.countdownSeconds = self._config.round.countdownSeconds
	projection.removedFraction = PileGrid.removedFraction(runtime.grid)
	if includePile then
		projection.pile = PileGrid.snapshot(runtime.grid)
		local bundles = {}
		for _, bundle in pairs(runtime.bundles) do
			table.insert(bundles, {
				bundleId = bundle.id,
				x = bundle.position.X,
				y = bundle.position.Y,
				z = bundle.position.Z,
				standard = bundle.standard,
				rainbow = bundle.rainbow,
			})
		end
		projection.bundles = bundles
		local charges = {}
		for _, charge in pairs(runtime.charges) do
			table.insert(charges, {
				chargeId = charge.id,
				userId = charge.userId,
				x = charge.position.X,
				y = charge.position.Y,
				z = charge.position.Z,
				radius = charge.radiusStuds,
				fuseMs = math.max(0, math.floor((charge.explodeAt - self._clock:monotonic()) * 1000)),
				mini = charge.mini,
			})
		end
		projection.charges = charges
	end
	return projection
end

-- Shallow, scalar-only copy of per-tool live state (heat, overheated, running, active unit count).
local function sanitizeToolRuntime(toolRuntime: { [string]: any }): { [string]: any }
	local out = {}
	for toolId, rt in pairs(toolRuntime) do
		local copy = {}
		for key, value in pairs(rt) do
			local t = type(value)
			if t == "number" or t == "boolean" or t == "string" then
				copy[key] = value
			elseif key == "units" then
				copy.unitCount = #value
			end
		end
		out[toolId] = copy
	end
	return out
end

-- Per-player round projection for the owning client (bag, cash, levels, contribution).
function RoundService.projectPlayer(self: RoundService, roundId: string, userId: number): { [string]: any }?
	local state = self:playerState(roundId, userId)
	if not state then
		return nil
	end
	return {
		cashCents = state.cashCents,
		carriedStandard = state.carriedStandard,
		carriedRainbow = state.carriedRainbow,
		bagLevel = state.bagLevel,
		handLevels = table.clone(state.handLevels),
		roundTools = table.clone(state.roundTools),
		toolLevels = state.toolLevels,
		equippedTool = state.equippedTool,
		permanentTools = table.clone(state.permanentTools),
		contribution = table.clone(state.contribution),
		saleCount = state.saleCount,
		upgradeCount = state.upgradeCount,
		toolRuntime = sanitizeToolRuntime(state.toolRuntime),
	}
end

function RoundService.count(self: RoundService): number
	local n = 0
	for _ in pairs(self._rounds) do
		n += 1
	end
	return n
end

return RoundService
