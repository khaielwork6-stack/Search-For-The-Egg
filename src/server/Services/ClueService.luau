--!strict
-- Professor Plume's lending authority. A party member trades carried normal feathers for a timed
-- loan of the Egg Sense rod; the loan count is shared by the whole round and lives in the round's
-- runtime, so it resets with the round and reaches a mid-round joiner in the same snapshot as
-- everything else. The rod itself is a ToolService timed grant: ToolService owns the expiry and
-- takes the tool back; this service only decides who may borrow, at what price, and answers the
-- rod's readings while a loan is live.
--
-- The trade is one transaction with no yields between the checks and the write: the feathers are
-- deducted and the rod granted in the same step. Nothing is consumed on any refusal.
--
-- A reading (`aim`) never reveals the Egg: the server computes the heat from the aim point and the
-- Egg's position and returns the quantised heat alone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local EggSense = require(Shared.Domain.EggSense)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)

local ClueService = {}
ClueService.__index = ClueService

ClueService.TOOL_ID = "eggSense"

export type ClueService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_rounds: any,
		_sessions: any,
		_tools: any,
		_clock: any,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_getEggPosition: (runtime: any) -> Vector3?,
		_analytics: any?,
		lent: any, -- (runtime, userId, projection)
		stats: { loans: number, readings: number, rejected: number },
	},
	ClueService
))

function ClueService.new(options: {
	config: { [string]: any },
	rounds: any,
	sessions: any,
	tools: any,
	clock: any,
	getCharacterPosition: (userId: number) -> Vector3?,
	getEggPosition: (runtime: any) -> Vector3?,
	analytics: any?,
}): ClueService
	return setmetatable({
		_config = options.config,
		_rounds = options.rounds,
		_sessions = options.sessions,
		_tools = options.tools,
		_clock = options.clock,
		_getCharacterPosition = options.getCharacterPosition,
		_getEggPosition = options.getEggPosition,
		_analytics = options.analytics,
		lent = Signal.new(),
		stats = { loans = 0, readings = 0, rejected = 0 },
	}, ClueService)
end

local function reject(self: ClueService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

-- The round's loan book, created on first touch so an older runtime is not special.
function ClueService.state(_self: ClueService, runtime: any): EggSense.State
	if not runtime.plume then
		runtime.plume = EggSense.newState()
	end
	return runtime.plume
end

-- What the clients see for this round.
function ClueService.project(self: ClueService, runtime: any): { [string]: any }
	return EggSense.project(self._config, runtime.plume, self._clock:monotonic())
end

local function eggIsOut(runtime: any): boolean
	return runtime.state.phase == "EggRevealed" or runtime.eggCarrier ~= nil
end

-- The loan. `payload` = { sessionToken }. `options.trusted` is for server-side callers (Studio
-- hooks, tests) that carry no session token; `options.characterPosition` stands in for a character
-- the server has no body for (a simulated member). Remote requests never set either.
function ClueService.lend(
	self: ClueService,
	userId: number,
	payload: { [string]: any },
	options: { trusted: boolean?, characterPosition: Vector3? }?
): Envelope.Envelope<any>
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
	-- Once the Egg is out there is nothing left to sense; Plume says so in his own words.
	if eggIsOut(runtime) then
		return reject(self, Envelope.Codes.INVALID_STATE, "egg_found")
	end
	if not RoundReducer.acceptsGameplay(runtime.state) then
		return reject(self, Envelope.Codes.INVALID_STATE, "phase")
	end
	local state = runtime.players[userId]
	if not state or not state.alive then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_alive")
	end
	if self._tools:timedRemaining(userId, ClueService.TOOL_ID) then
		return reject(self, Envelope.Codes.ALREADY_DONE, "active")
	end
	local book = self:state(runtime)
	local cost = EggSense.nextCost(self._config, book.count)
	if not cost then
		return reject(self, Envelope.Codes.ALREADY_DONE, "limit")
	end
	if state.carriedStandard < cost then
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
	local activeSeconds = self._config.plume.rod.activeSeconds
	-- One transaction: the feathers leave the bag, the loan is booked and the rod is granted together.
	state.carriedStandard -= cost
	book.count += 1
	book.activeUntilByUserId[userId] = self._clock:monotonic() + activeSeconds
	local granted = self._tools:grantTimed(userId, ClueService.TOOL_ID, activeSeconds, "plume")
	if not granted then
		-- Cannot happen past the checks above (the player is in the round and the tool id is lent),
		-- but a refusal must never keep the feathers.
		state.carriedStandard += cost
		book.count -= 1
		book.activeUntilByUserId[userId] = nil
		return reject(self, Envelope.Codes.INTERNAL, "grant_failed")
	end
	self.stats.loans += 1
	if self._analytics then
		self._analytics:track("rod_lent", {
			chapter = runtime.state.chapter,
			difficulty = runtime.state.difficulty,
			order = book.count,
			cost = cost,
		})
	end
	local projection = self:project(runtime)
	self.lent:Fire(runtime, userId, projection)
	return Envelope.ok({
		cost = cost,
		carriedStandard = state.carriedStandard,
		usesLeft = projection.usesLeft,
		nextCost = projection.nextCost,
		activeSeconds = activeSeconds,
		plume = projection,
	})
end

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- A reading. `payload` = { sessionToken, x, y, z }: the world point under the borrower's crosshair.
-- Answers { heat } only while the caller's loan is live and the Egg is still hidden; the Egg's
-- position never leaves this function.
function ClueService.aim(
	self: ClueService,
	userId: number,
	payload: { [string]: any },
	options: { trusted: boolean? }?
): Envelope.Envelope<any>
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
	if not finite(payload.x) or not finite(payload.y) or not finite(payload.z) then
		return reject(self, Envelope.Codes.INVALID_PAYLOAD, "point")
	end
	if eggIsOut(runtime) or not RoundReducer.acceptsGameplay(runtime.state) then
		return reject(self, Envelope.Codes.INVALID_STATE, "egg_found")
	end
	local state = runtime.players[userId]
	if not state or not state.alive then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_alive")
	end
	local remaining = self._tools:timedRemaining(userId, ClueService.TOOL_ID)
	if not remaining then
		return reject(self, Envelope.Codes.INVALID_STATE, "inactive")
	end
	if state.equippedTool ~= ClueService.TOOL_ID then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_equipped")
	end
	-- The point must be on or about the mound: anything further out than the rod could ever warm
	-- to is not an aim, it is a probe.
	local layout = ChapterLayout[runtime.state.chapter]
	local grid = runtime.grid
	local halfWidth = math.max(grid.width, grid.depth) * grid.cellSize / 2
	local centre = layout.nestCenter
	local reach = halfWidth + self._config.plume.rod.radiusStuds
	local dx, dz = payload.x - centre.X, payload.z - centre.Z
	if dx * dx + dz * dz > reach * reach or math.abs(payload.y - centre.Y) > reach then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "point")
	end
	local egg = self._getEggPosition(runtime)
	if not egg then
		return reject(self, Envelope.Codes.INVALID_STATE, "no_egg")
	end
	local heat = EggSense.heatFor(self._config, { x = payload.x, y = payload.y, z = payload.z }, { x = egg.X, y = egg.Y, z = egg.Z })
	self.stats.readings += 1
	return Envelope.ok({ heat = heat, remainingMs = math.floor(remaining * 1000 + 0.5) })
end

return ClueService
