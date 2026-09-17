--!strict
-- Professor Plume's analysis authority. A round member pays `plume.rainbowCost` carried Rainbow
-- Feathers, once per round, and receives ONE vague clue about the Egg (PlumeClue holds the rules):
-- a half of the nest, or a depth band. The clue lives on the player's round state, so it resets
-- with the round and reaches only that player's projection.
--
-- The trade is one transaction with no yields between the checks and the write: the feathers are
-- deducted and the clue stored in the same step. Nothing is consumed on any refusal. Requests are
-- rate limited per player here as well as at the remote.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local PlumeClue = require(Shared.Domain.PlumeClue)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)

local ClueService = {}
ClueService.__index = ClueService

export type ClueService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_rounds: any,
		_sessions: any,
		_clock: any,
		_rng: any,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_analytics: any?,
		_lastRequestAt: { [number]: number },
		analysed: any, -- (runtime, userId, clue)
		stats: { analyses: number, rejected: number },
	},
	ClueService
))

function ClueService.new(
	options: {
		config: { [string]: any },
		rounds: any,
		sessions: any,
		clock: any,
		rng: any, -- WeightedRandom-like: :next() -> [0, 1)
		getCharacterPosition: (userId: number) -> Vector3?,
		analytics: any?,
	}
): ClueService
	return setmetatable({
		_config = options.config,
		_rounds = options.rounds,
		_sessions = options.sessions,
		_clock = options.clock,
		_rng = options.rng,
		_getCharacterPosition = options.getCharacterPosition,
		_analytics = options.analytics,
		_lastRequestAt = {},
		analysed = Signal.new(),
		stats = { analyses = 0, rejected = 0 },
	}, ClueService)
end

local function reject(self: ClueService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

-- The analysis. `payload` = { sessionToken }. `options.trusted` is for server-side callers (Studio
-- hooks, tests) that carry no session token; `options.characterPosition` stands in for a character
-- the server has no body for. Remote requests never set either.
function ClueService.analyse(
	self: ClueService,
	userId: number,
	payload: { [string]: any },
	options: { trusted: boolean?, characterPosition: Vector3? }?
): Envelope.Envelope<any>
	local now = self._clock:monotonic()
	local last = self._lastRequestAt[userId]
	if last and now - last < self._config.plume.requestCooldownSeconds then
		return reject(self, Envelope.Codes.RATE_LIMITED, "cooldown")
	end
	self._lastRequestAt[userId] = now
	local runtime = self._rounds:roundOf(userId)
	if not runtime then
		return reject(self, Envelope.Codes.INVALID_STATE, "no_round")
	end
	if not (options and options.trusted) then
		local okToken, tokenErr = self._sessions:validate(userId, payload.sessionToken, "Round")
		if not okToken then
			return reject(self, Envelope.Codes.STALE_TOKEN, tokenErr)
		end
	end
	if not table.find(runtime.state.members, userId) then
		return reject(self, Envelope.Codes.NOT_AUTHORIZED, "not_member")
	end
	local state = runtime.players[userId]
	local refusal = PlumeClue.refusal(self._config, {
		eggOut = runtime.state.phase == "EggRevealed" or runtime.eggCarrier ~= nil,
		searching = RoundReducer.acceptsGameplay(runtime.state),
		used = state ~= nil and state.plumeClue ~= nil,
		carriedRainbow = if state then state.carriedRainbow else 0,
	})
	if refusal == "egg_found" or refusal == "phase" then
		return reject(self, Envelope.Codes.INVALID_STATE, refusal)
	end
	if not state or not state.alive then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_alive")
	end
	if refusal == "used" then
		return reject(self, Envelope.Codes.ALREADY_DONE, "used")
	elseif refusal == "insufficient" then
		return reject(self, Envelope.Codes.INSUFFICIENT_FUNDS, "insufficient")
	end
	local characterPosition = (options and options.characterPosition) or self._getCharacterPosition(userId)
	if not characterPosition then
		return reject(self, Envelope.Codes.INVALID_STATE, "no_character")
	end
	local layout = ChapterLayout[runtime.state.chapter]
	local station = layout.clueStation
	local flat = Vector3.new(characterPosition.X - station.X, 0, characterPosition.Z - station.Z)
	if flat.Magnitude > self._config.plume.stationRangeStuds then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "station")
	end
	-- One transaction: the rainbow feathers leave the bag and the clue is stored together.
	local cost = PlumeClue.cost(self._config)
	local grid = runtime.grid
	local clue = PlumeClue.compose(self._config, {
		width = grid.width,
		depth = grid.depth,
		cellX = runtime.eggNode.x,
		cellZ = runtime.eggNode.z,
		depthFraction = runtime.eggDepthFraction or 0.5,
	}, self._rng:next(), self._rng:next())
	state.carriedRainbow -= cost
	state.plumeClue = clue
	self.stats.analyses += 1
	if self._analytics then
		self._analytics:track("plume_clue", {
			chapter = runtime.state.chapter,
			difficulty = runtime.state.difficulty,
			kind = clue.kind,
			cost = cost,
		})
	end
	self.analysed:Fire(runtime, userId, clue)
	return Envelope.ok({
		clue = table.clone(clue),
		cost = cost,
		carriedRainbow = state.carriedRainbow,
	})
end

-- Drops a player's rate-limit entry when they leave the server.
function ClueService.forget(self: ClueService, userId: number)
	self._lastRequestAt[userId] = nil
end

return ClueService
