--!strict
-- Egg reveal and claim authority (STATE_MACHINES.md section 7). The Egg is concealed until its
-- cover cells are cleared AND the round's removed fraction reaches the node's depth (ASSUMED
-- A-EGG-03/07). Reveal happens once; claim requires proximity and the first valid claim wins.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local PileGrid = require(Shared.Domain.PileGrid)
local PileSurface = require(Shared.Domain.PileSurface)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)

local EggService = {}
EggService.__index = EggService

export type EggService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_rounds: any,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_clock: any,
		_analytics: any?,
		revealed: any, -- (runtime, position)
		claimed: any, -- (runtime, userId)
		carried: any, -- (runtime, userId)
		dropped: any, -- (runtime, userId, position)
		stats: { reveals: number, claims: number, rejected: number, pickups: number, drops: number },
	},
	EggService
))

function EggService.new(options: {
	config: { [string]: any },
	rounds: any,
	clock: any,
	getCharacterPosition: (userId: number) -> Vector3?,
	analytics: any?,
}): EggService
	return setmetatable({
		_config = options.config,
		_rounds = options.rounds,
		_clock = options.clock,
		_getCharacterPosition = options.getCharacterPosition,
		_analytics = options.analytics,
		revealed = Signal.new(),
		claimed = Signal.new(),
		carried = Signal.new(),
		dropped = Signal.new(),
		stats = { reveals = 0, claims = 0, rejected = 0, pickups = 0, drops = 0 },
	}, EggService)
end

-- World position of the Egg for a runtime (server-only; never projected before reveal). In a
-- chapter whose layout places the Egg at the exit (Moonlit Cellar), the mound hides the key instead
-- and the Egg waits at the ladder.
function EggService.position(self: EggService, runtime: any): Vector3
	local layout = ChapterLayout[runtime.state.chapter]
	if layout.eggAtExit then
		return layout.eggExit
	end
	return self:buriedPosition(runtime)
end

-- Height of the Egg inside its column: just above the record below it.
function EggService.buriedHeight(self: EggService, runtime: any): number
	local grid = runtime.grid
	local cell = grid.cells[PileGrid.index(grid.width, runtime.eggNode.x, runtime.eggNode.z)]
	local full = PileSurface.columnFullHeight(self._config, grid.width, grid.depth, grid.cellSize, runtime.eggNode.x, runtime.eggNode.z)
	local slot = runtime.eggSlot or 1
	return full * (slot - 1) / math.max(1, cell.base) + 1
end

-- World position of whatever the mound hides (the Egg in Chapter 1, the key in Chapter 2).
function EggService.buriedPosition(self: EggService, runtime: any): Vector3
	local layout = ChapterLayout[runtime.state.chapter]
	local grid = runtime.grid
	return ChapterLayout.cellWorldPosition(
		layout,
		grid.width,
		grid.depth,
		grid.cellSize,
		runtime.eggNode.x,
		runtime.eggNode.z,
		self:buriedHeight(runtime)
	)
end

-- True once every record covering the Egg (its own column, slots >= eggSlot) has been collected.
function EggService.coverCleared(_self: EggService, runtime: any): boolean
	local grid = runtime.grid
	local cell = grid.cells[PileGrid.index(grid.width, runtime.eggNode.x, runtime.eggNode.z)]
	local top = PileGrid.topSlot(cell)
	return top == nil or top < (runtime.eggSlot or 1)
end

-- Optional hook: when set and it returns true for a runtime, uncovering the buried node hands
-- control to the hook (Chapter 2 reveals the key) instead of revealing the Egg.
function EggService.setUncoverHook(self: EggService, hook: ((runtime: any, position: Vector3) -> boolean)?)
	(self :: any)._uncoverHook = hook
end

-- Marks the Egg revealed now (puzzle chapters call this when their last stage opens). Returns
-- true when the reveal happened on this call.
function EggService.revealNow(self: EggService, runtime: any): boolean
	if runtime.state.phase ~= "Searching" then
		return false
	end
	local next = self._rounds:markEggRevealed(runtime.state.roundId)
	if not next then
		return false
	end
	self.stats.reveals += 1
	local position = self:position(runtime)
	if self._analytics then
		self._analytics:track("egg_revealed", {
			chapter = runtime.state.chapter,
			difficulty = runtime.state.difficulty,
			removedFraction = PileGrid.removedFraction(runtime.grid),
			elapsedMs = RoundReducer.elapsedMs(next, self._clock:nowMs()),
		})
	end
	self.revealed:Fire(runtime, position)
	return true
end

-- Evaluates the reveal condition after a pile change. Returns true when the Egg was revealed now.
function EggService.checkReveal(self: EggService, runtime: any): boolean
	if runtime.state.phase ~= "Searching" then
		return false
	end
	local coverCleared = self:coverCleared(runtime)
	runtime.eggCoverCleared = coverCleared
	if not coverCleared then
		return false
	end
	local hook = (self :: any)._uncoverHook
	if hook and hook(runtime, self:buriedPosition(runtime)) then
		return false -- the chapter took the uncover (key found); the Egg comes later
	end
	local next = self._rounds:markEggRevealed(runtime.state.roundId)
	if not next then
		return false
	end
	self.stats.reveals += 1
	local position = self:position(runtime)
	if self._analytics then
		self._analytics:track("egg_revealed", {
			chapter = runtime.state.chapter,
			difficulty = runtime.state.difficulty,
			removedFraction = PileGrid.removedFraction(runtime.grid),
			elapsedMs = RoundReducer.elapsedMs(next, self._clock:nowMs()),
		})
	end
	self.revealed:Fire(runtime, position)
	return true
end

-- Where the Egg must be handed over; nil for chapters without a Farmer (the claim itself wins).
function EggService.farmerPosition(_self: EggService, runtime: any): Vector3?
	local layout = ChapterLayout[runtime.state.chapter]
	return layout.farmer
end

function EggService.carrier(_self: EggService, runtime: any): number?
	return runtime.eggCarrier
end

local function winNow(self: EggService, runtime: any, userId: number, token: any): Envelope.Envelope<any>
	local next, err = self._rounds:claim(runtime.state.roundId, userId, token)
	if not next then
		self.stats.rejected += 1
		local code = if err == "stale_token"
			then Envelope.Codes.STALE_TOKEN
			elseif err == "already_won" then Envelope.Codes.ALREADY_DONE
			else Envelope.Codes.INVALID_STATE
		return Envelope.fail(code, err)
	end
	runtime.eggCarrier = nil
	self.stats.claims += 1
	self.claimed:Fire(runtime, userId)
	return Envelope.ok({ finderUserId = userId, elapsedMs = next.victory and next.victory.elapsedMs or 0 })
end

-- Picking the Egg up at its resting place. With a Farmer in the chapter this only makes the
-- player the carrier (the win comes from `deliver`); without one it is the win itself.
function EggService.claim(self: EggService, userId: number, token: any): Envelope.Envelope<any>
	local runtime = self._rounds:roundOf(userId)
	if not runtime then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.INVALID_STATE, "no_round")
	end
	if not RoundReducer.acceptsClaim(runtime.state) then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.INVALID_STATE, if runtime.state.victory then "already_won" else "not_revealed")
	end
	if runtime.eggCarrier then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.INVALID_STATE, if runtime.eggCarrier == userId then "already_carrying" else "carried")
	end
	local characterPosition = self._getCharacterPosition(userId)
	if not characterPosition then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.INVALID_STATE, "no_character")
	end
	local position = self:position(runtime)
	if (characterPosition - position).Magnitude > self._config.eggSpawn.claimRadiusStuds then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.OUT_OF_RANGE, "egg")
	end
	if not self:farmerPosition(runtime) then
		return winNow(self, runtime, userId, token)
	end
	local okToken, tokenErr = self._rounds:validateToken(userId, token)
	if not okToken then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.STALE_TOKEN, tokenErr)
	end
	runtime.eggCarrier = userId
	self.stats.pickups += 1
	self.carried:Fire(runtime, userId)
	return Envelope.ok({ carrierUserId = userId, carrying = true })
end

-- Handing the Egg to the Farmer: the carrier, in range, wins the round.
function EggService.deliver(self: EggService, userId: number, token: any): Envelope.Envelope<any>
	local runtime = self._rounds:roundOf(userId)
	if not runtime then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.INVALID_STATE, "no_round")
	end
	if not RoundReducer.acceptsClaim(runtime.state) then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.INVALID_STATE, if runtime.state.victory then "already_won" else "not_revealed")
	end
	if runtime.eggCarrier ~= userId then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.INVALID_STATE, "not_carrier")
	end
	local farmer = self:farmerPosition(runtime)
	local characterPosition = self._getCharacterPosition(userId)
	if not farmer or not characterPosition then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.INVALID_STATE, "no_character")
	end
	local flat = Vector3.new(characterPosition.X - farmer.X, 0, characterPosition.Z - farmer.Z)
	if flat.Magnitude > (self._config.eggSpawn.deliverRadiusStuds or self._config.eggSpawn.claimRadiusStuds) then
		self.stats.rejected += 1
		return Envelope.fail(Envelope.Codes.OUT_OF_RANGE, "farmer")
	end
	return winNow(self, runtime, userId, token)
end

-- The carrier died or left: the Egg goes back to where it was uncovered.
function EggService.drop(self: EggService, userId: number): boolean
	local runtime = self._rounds:roundOf(userId)
	if not runtime or runtime.eggCarrier ~= userId then
		return false
	end
	runtime.eggCarrier = nil
	self.stats.drops += 1
	self.dropped:Fire(runtime, userId, self:position(runtime))
	return true
end

return EggService
