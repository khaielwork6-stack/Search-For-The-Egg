--!strict
-- Hand collection authority (STATE_MACHINES.md section 4). Validation order: session/phase ->
-- alive -> tool -> cooldown deadline -> origin plausibility -> ray/range -> bag capacity -> target
-- cells -> modifiers -> atomic removal + award. Clients never submit yields.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local PileGrid = require(Shared.Domain.PileGrid)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local EconomyMath = require(Shared.EconomyMath)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)
local RoundModifiers = require(script.Parent.RoundModifiers)

local CollectionService = {}
CollectionService.__index = CollectionService

export type CollectionService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_clock: any,
		_rounds: any,
		_sessions: any,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_getProfileData: (userId: number) -> any?,
		_analytics: any?,
		collected: any, -- (userId, runtime, result)
		bagFilled: any, -- (userId, runtime)
		stats: { accepted: number, rejected: number },
	},
	CollectionService
))

function CollectionService.new(options: {
	config: { [string]: any },
	clock: any,
	rounds: any,
	sessions: any,
	getCharacterPosition: (userId: number) -> Vector3?,
	getProfileData: (userId: number) -> any?,
	analytics: any?,
}): CollectionService
	return setmetatable({
		_config = options.config,
		_clock = options.clock,
		_rounds = options.rounds,
		_sessions = options.sessions,
		_getCharacterPosition = options.getCharacterPosition,
		_getProfileData = options.getProfileData,
		_analytics = options.analytics,
		collected = Signal.new(),
		bagFilled = Signal.new(),
		stats = { accepted = 0, rejected = 0 },
	}, CollectionService)
end

-- Bag capacity for a player from round level, perks, class, and entitlements.
function CollectionService.bagCapacity(self: CollectionService, runtime: any, userId: number): EconomyMath.BagCapacity
	local state = runtime.players[userId]
	local level = self._config.bags.levels[state.bagLevel]
	local modifiers = RoundModifiers.resolve(self._config, self._getProfileData(userId), runtime.state.difficulty, nil)
	return EconomyMath.bagCapacity({
		roundBagLevelCapacity = level.capacity,
		permanentBagPerkMultiplier = 1, -- bagSize perk folds into bagCapacityMultiplier below
		classBagMultiplier = modifiers.bagCapacityMultiplier,
		infiniteBag = modifiers.infiniteBag,
	})
end

function CollectionService.handAmount(self: CollectionService, runtime: any, userId: number): number
	local state = runtime.players[userId]
	local grasp = self._config.handUpgrades.grasp[state.handLevels.grasp + 1]
	local modifiers = RoundModifiers.resolve(self._config, self._getProfileData(userId), runtime.state.difficulty, nil)
	return math.max(1, math.floor(grasp.amount * modifiers.handGrabMultiplier * modifiers.toolYieldMultiplier + 0.5))
end

function CollectionService.handCooldown(self: CollectionService, runtime: any, userId: number): number
	local state = runtime.players[userId]
	local hold = self._config.handUpgrades.hold[state.handLevels.hold + 1]
	if hold and hold.enabled and hold.intervalSeconds then
		return hold.intervalSeconds
	end
	return self._config.collection.baseHandCooldownSeconds
end

local function reject(self: CollectionService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

-- payload: { sessionToken, origin: Vector3, direction: Vector3, toolId }
function CollectionService.collect(self: CollectionService, userId: number, payload: { [string]: any }): Envelope.Envelope<any>
	local runtime = self._rounds:roundOf(userId)
	if not runtime then
		return reject(self, Envelope.Codes.INVALID_STATE, "no_round")
	end
	local okToken, tokenErr = self._sessions:validate(userId, payload.sessionToken, "Round")
	if not okToken then
		return reject(self, Envelope.Codes.STALE_TOKEN, tokenErr)
	end
	if not RoundReducer.acceptsGameplay(runtime.state) then
		return reject(self, Envelope.Codes.INVALID_STATE, "phase")
	end
	local state = runtime.players[userId]
	if not state or not state.alive then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_alive")
	end
	if payload.toolId ~= "hand" or not state.roundTools.hand then
		return reject(self, Envelope.Codes.NOT_AUTHORIZED, "tool")
	end
	local now = self._clock:monotonic()
	if now < state.cooldownUntil then
		return reject(self, Envelope.Codes.RATE_LIMITED, "cooldown")
	end
	local characterPosition = self._getCharacterPosition(userId)
	if not characterPosition then
		return reject(self, Envelope.Codes.INVALID_STATE, "no_character")
	end
	local interaction = self._config.interaction
	local origin: Vector3 = payload.origin
	if (origin - characterPosition).Magnitude > interaction.serverPositionToleranceStuds then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "origin")
	end
	local direction: Vector3 = payload.direction
	if direction.Magnitude < 0.01 then
		return reject(self, Envelope.Codes.INVALID_PAYLOAD, "direction")
	end
	direction = direction.Unit
	-- Ray vs the pile surface plane (nest base + half the visual height).
	local layout = ChapterLayout[runtime.state.chapter]
	local planeY = layout.nestBaseY + self._config.pile.maxVisualHeightStuds * 0.5
	if direction.Y > -0.02 then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "aim")
	end
	local t = (planeY - origin.Y) / direction.Y
	if t < 0 or t > interaction.defaultRangeStuds * 2 then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "aim")
	end
	local hit = origin + direction * t
	local flat = Vector3.new(hit.X - characterPosition.X, 0, hit.Z - characterPosition.Z)
	if flat.Magnitude > interaction.defaultRangeStuds then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "range")
	end
	local grid = runtime.grid
	local minCorner = ChapterLayout.gridMinCorner(layout, grid.width, grid.depth, grid.cellSize)
	local cx, cz = PileGrid.cellAt(grid, hit.X - minCorner.X, hit.Z - minCorner.Z)
	if cx < -1 or cz < -1 or cx > grid.width or cz > grid.depth then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "outside_nest")
	end
	local capacity = self:bagCapacity(runtime, userId)
	local carried = state.carriedStandard + state.carriedRainbow
	local free = if capacity.infinite then math.huge else capacity.capacity - carried
	if free <= 0 then
		return reject(self, Envelope.Codes.INVALID_STATE, "bag_full")
	end
	local target = PileGrid.findTarget(grid, cx, cz, 1)
	if not target then
		return reject(self, Envelope.Codes.NOT_FOUND, "no_feathers")
	end
	-- Atomic removal + award (single-threaded server; no yields between these lines).
	local amount = self:handAmount(runtime, userId)
	local accepted = math.min(amount, if free == math.huge then amount else free)
	local removal = PileGrid.remove(grid, target, accepted)
	state.carriedStandard += removal.removed
	state.contribution.feathersCollected += removal.removed
	if removal.remaining == 0 then
		state.contribution.cellsRemoved += 1
	end
	local cooldown = self:handCooldown(runtime, userId)
	state.cooldownUntil = now + cooldown
	self._rounds:queueDelta(runtime.state.roundId, removal.index, removal.remaining)
	self.stats.accepted += 1

	local nowCarried = state.carriedStandard + state.carriedRainbow
	local bagFull = not capacity.infinite and nowCarried >= capacity.capacity
	if self._analytics then
		self._analytics:track("feather_collected", { chapter = runtime.state.chapter, amount = removal.removed, tool = "hand" }, userId)
		if bagFull then
			self._analytics:track("bag_full", { chapter = runtime.state.chapter, capacity = capacity.capacity }, userId)
		end
	end
	local worldX, worldZ = PileGrid.cellCenter(grid, target)
	local result = {
		awarded = removal.removed,
		carried = nowCarried,
		capacity = if capacity.infinite then -1 else capacity.capacity,
		infinite = capacity.infinite,
		cellIndex = removal.index,
		remaining = removal.remaining,
		base = target.base,
		cooldownMs = math.floor(cooldown * 1000),
		hitX = minCorner.X + worldX,
		hitZ = minCorner.Z + worldZ,
		removedFraction = PileGrid.removedFraction(grid),
		bagFull = bagFull,
	}
	self.collected:Fire(userId, runtime, result)
	if bagFull then
		self.bagFilled:Fire(userId, runtime)
	end
	return Envelope.ok(result)
end

return CollectionService
