--!strict
-- Professor Plume's analysis authority. A party trades a member's unsold Rainbow Feathers for one
-- clue about the Egg; the clue is shared by the whole round and lives in the round's runtime, so it
-- resets with the round and reaches a mid-round joiner in the same snapshot as everything else.
--
-- The trade is one transaction with no yields between the checks and the write: the feathers are
-- deducted and the category unlocked in the same step, so a duplicate request finds the category
-- already analysed and pays nothing. Nothing is consumed on any refusal.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local NestClues = require(Shared.Domain.NestClues)
local PileGrid = require(Shared.Domain.PileGrid)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)

local ClueService = {}
ClueService.__index = ClueService

export type ClueService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_rounds: any,
		_sessions: any,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_analytics: any?,
		unlocked: any, -- (runtime, userId, entry, projection)
		stats: { analyses: number, rejected: number },
	},
	ClueService
))

function ClueService.new(options: {
	config: { [string]: any },
	rounds: any,
	sessions: any,
	getCharacterPosition: (userId: number) -> Vector3?,
	analytics: any?,
}): ClueService
	return setmetatable({
		_config = options.config,
		_rounds = options.rounds,
		_sessions = options.sessions,
		_getCharacterPosition = options.getCharacterPosition,
		_analytics = options.analytics,
		unlocked = Signal.new(),
		stats = { analyses = 0, rejected = 0 },
	}, ClueService)
end

local function reject(self: ClueService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

-- The round's clue state, created on first touch so an older runtime is not special.
function ClueService.state(_self: ClueService, runtime: any): NestClues.State
	if not runtime.clues then
		runtime.clues = NestClues.newState()
	end
	return runtime.clues
end

-- The Egg's pile-local facts for the clue arithmetic. Server-only: this is the one place that
-- reads the exact cell, and only a band leaves it.
function ClueService.eggFacts(_self: ClueService, runtime: any): { worldX: number, worldZ: number, radius: number, depthFraction: number }
	local layout = ChapterLayout[runtime.state.chapter]
	local grid = runtime.grid
	local world = ChapterLayout.cellWorldPosition(layout, grid.width, grid.depth, grid.cellSize, runtime.eggNode.x, runtime.eggNode.z, 0)
	local cell = grid.cells[PileGrid.index(grid.width, runtime.eggNode.x, runtime.eggNode.z)]
	local base = math.max(1, cell and cell.base or 1)
	local slot = runtime.eggSlot or 1
	-- Records above the Egg over the whole column: 0 at the surface, 1 at the sand.
	local depthFraction = math.clamp((base - slot + 1) / base, 0, 1)
	return {
		worldX = world.X,
		worldZ = world.Z,
		radius = math.min(grid.width, grid.depth) * grid.cellSize / 2,
		depthFraction = depthFraction,
	}
end

-- What the clients see for this round.
function ClueService.project(self: ClueService, runtime: any): { [string]: any }
	return NestClues.project(self._config, runtime.clues)
end

-- The trade. `payload` = { sessionToken, category }. `options.trusted` is for server-side callers
-- (Studio hooks, tests) that carry no session token; `options.characterPosition` stands in for a
-- character the server has no body for (a simulated member). Remote requests never set either.
function ClueService.analyze(
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
	-- Once the Egg is out there is nothing left to analyse; Plume says so in his own words.
	if runtime.state.phase == "EggRevealed" or runtime.eggCarrier ~= nil then
		return reject(self, Envelope.Codes.INVALID_STATE, "egg_found")
	end
	if not RoundReducer.acceptsGameplay(runtime.state) then
		return reject(self, Envelope.Codes.INVALID_STATE, "phase")
	end
	local state = runtime.players[userId]
	if not state or not state.alive then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_alive")
	end
	local category = payload.category
	if not NestClues.isCategory(category) then
		return reject(self, Envelope.Codes.INVALID_PAYLOAD, "category")
	end
	local clues = self:state(runtime)
	if clues.unlocked[category] then
		return reject(self, Envelope.Codes.ALREADY_DONE, "already_analyzed")
	end
	local cost = NestClues.nextCost(self._config, clues.count)
	if not cost then
		return reject(self, Envelope.Codes.ALREADY_DONE, "limit")
	end
	if state.carriedRainbow < cost then
		return reject(self, Envelope.Codes.INSUFFICIENT_FUNDS, "insufficient")
	end
	local characterPosition = (options and options.characterPosition) or self._getCharacterPosition(userId)
	if not characterPosition then
		return reject(self, Envelope.Codes.INVALID_STATE, "no_character")
	end
	local layout = ChapterLayout[runtime.state.chapter]
	local station = layout.clueStation
	local flat = Vector3.new(characterPosition.X - station.X, 0, characterPosition.Z - station.Z)
	if flat.Magnitude > self._config.clues.stationRangeStuds then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "station")
	end
	local clue = NestClues.clueFor(self._config, layout, category, self:eggFacts(runtime))
	if not clue then
		return reject(self, Envelope.Codes.INVALID_PAYLOAD, "category")
	end
	-- One transaction: the feathers leave the bag and the category unlocks together.
	state.carriedRainbow -= cost
	clues.count += 1
	local entry = {
		category = clue.category,
		band = clue.band,
		title = clue.title,
		text = clue.text,
		byUserId = userId,
		order = clues.count,
	}
	clues.unlocked[category] = entry
	self.stats.analyses += 1
	if self._analytics then
		self._analytics:track("clue_analyzed", {
			chapter = runtime.state.chapter,
			difficulty = runtime.state.difficulty,
			category = category,
			order = clues.count,
			cost = cost,
		})
	end
	local projection = self:project(runtime)
	self.unlocked:Fire(runtime, userId, entry, projection)
	return Envelope.ok({
		category = category,
		title = clue.title,
		text = clue.text,
		cost = cost,
		carriedRainbow = state.carriedRainbow,
		clues = projection,
	})
end

return ClueService
