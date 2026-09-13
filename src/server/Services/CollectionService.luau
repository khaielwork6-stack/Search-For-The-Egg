--!strict
-- Discrete collection authority for the Hand and the Nest Rake (STATE_MACHINES.md section 4) plus
-- world bundle pickups. Validation order: session/phase -> alive -> tool owned + equipped ->
-- cooldown deadline -> origin plausibility -> ray/range -> bag capacity -> target cells ->
-- modifiers -> atomic removal + award. Clients never submit yields. Overflow policy
-- (`collection.overflowPolicy`): the bag is clamped; Rake overflow becomes a server-owned bundle.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local PileGrid = require(Shared.Domain.PileGrid)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local ToolSpecs = require(Shared.Domain.ToolSpecs)
local EconomyMath = require(Shared.EconomyMath)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)
local PileSurface = require(Shared.Domain.PileSurface)
local RoundModifiers = require(script.Parent.RoundModifiers)
local RoundAwards = require(script.Parent.RoundAwards)

local CollectionService = {}
CollectionService.__index = CollectionService

export type CollectionService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_clock: any,
		_rounds: any,
		_sessions: any,
		_idGen: () -> string,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_getProfileData: (userId: number) -> any?,
		_getEntitlements: ((userId: number) -> { [string]: boolean }?)?,
		_analytics: any?,
		collected: any, -- (userId, runtime, result)
		bagFilled: any, -- (userId, runtime)
		event: any, -- (roundId, payload) bundle events for the ToolEvent broadcast
		stats: { accepted: number, rejected: number, bundlesGathered: number },
	},
	CollectionService
))

export type Aim = {
	hit: Vector3,
	cx: number,
	cz: number,
	minCorner: Vector3,
	layout: any,
}

function CollectionService.new(options: {
	config: { [string]: any },
	clock: any,
	rounds: any,
	sessions: any,
	idGen: (() -> string)?,
	getCharacterPosition: (userId: number) -> Vector3?,
	getProfileData: (userId: number) -> any?,
	getEntitlements: ((userId: number) -> { [string]: boolean }?)?,
	analytics: any?,
}): CollectionService
	local counter = 0
	return setmetatable({
		_config = options.config,
		_clock = options.clock,
		_rounds = options.rounds,
		_sessions = options.sessions,
		_idGen = options.idGen or function()
			counter += 1
			return "bundle-" .. tostring(counter)
		end,
		_getCharacterPosition = options.getCharacterPosition,
		_getProfileData = options.getProfileData,
		_getEntitlements = options.getEntitlements,
		_analytics = options.analytics,
		collected = Signal.new(),
		bagFilled = Signal.new(),
		event = Signal.new(),
		stats = { accepted = 0, rejected = 0, bundlesGathered = 0 },
	}, CollectionService)
end

-- Resolved modifiers for a player: classes + perks (profile), difficulty (round), entitlements.
function CollectionService.modifiers(self: CollectionService, runtime: any, userId: number)
	local entitlements = if self._getEntitlements then self._getEntitlements(userId) else nil
	return RoundModifiers.resolve(self._config, self._getProfileData(userId), runtime.state.difficulty, entitlements)
end

-- Bag capacity for a player from round level, perks, class, and entitlements.
function CollectionService.bagCapacity(self: CollectionService, runtime: any, userId: number): EconomyMath.BagCapacity
	local state = runtime.players[userId]
	local level = self._config.bags.levels[state.bagLevel]
	local modifiers = self:modifiers(runtime, userId)
	return EconomyMath.bagCapacity({
		roundBagLevelCapacity = level.capacity,
		permanentBagPerkMultiplier = 1, -- bagSize perk folds into bagCapacityMultiplier below
		classBagMultiplier = modifiers.bagCapacityMultiplier,
		infiniteBag = modifiers.infiniteBag,
	})
end

-- Discrete tool spec (Hand or Rake) for a player.
function CollectionService.spec(self: CollectionService, runtime: any, userId: number, toolId: string): any
	local state = runtime.players[userId]
	local modifiers = self:modifiers(runtime, userId)
	if toolId == "hand" then
		return ToolSpecs.hand(self._config, state.handLevels, modifiers)
	end
	return ToolSpecs.resolve(self._config, toolId, state.toolLevels[toolId], modifiers)
end

function CollectionService.handAmount(self: CollectionService, runtime: any, userId: number): number
	return self:spec(runtime, userId, "hand").amount
end

function CollectionService.handCooldown(self: CollectionService, runtime: any, userId: number): number
	return self:spec(runtime, userId, "hand").cooldownSeconds
end

local function reject(self: CollectionService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

-- Resolves an aim ray against the pile surface plane and checks plausibility/range. Shared by the
-- discrete tools and by ToolService (charge throws, vac aim). Returns the aim or (nil, code, message).
function CollectionService.resolveAim(
	config: { [string]: any },
	runtime: any,
	characterPosition: Vector3,
	origin: Vector3,
	direction: Vector3,
	rangeStuds: number?
): (Aim?, string?, string?)
	local interaction = config.interaction
	if (origin - characterPosition).Magnitude > interaction.serverPositionToleranceStuds then
		return nil, Envelope.Codes.OUT_OF_RANGE, "origin"
	end
	if direction.Magnitude < 0.01 then
		return nil, Envelope.Codes.INVALID_PAYLOAD, "direction"
	end
	direction = direction.Unit
	local layout = ChapterLayout[runtime.state.chapter]
	local range = rangeStuds or interaction.defaultRangeStuds
	-- The mound is a dome (PileSurface, A-UX-07): resolve the aim against the same surface the client
	-- renders, entering from above. A ray that starts inside the mound or misses it falls back to the
	-- mid-height plane so aims from the harness and from cleared floors still resolve.
	local grid = runtime.grid
	local field = PileSurface.buildField(config, PileGrid.snapshot(grid), layout)
	local hit = PileSurface.march(field, origin, direction, range * 2, 0.5)
	if not hit then
		local planeY = layout.nestBaseY + config.pile.aimPlaneHeightStuds
		if direction.Y > -0.02 then
			return nil, Envelope.Codes.OUT_OF_RANGE, "aim"
		end
		local t = (planeY - origin.Y) / direction.Y
		if t < 0 or t > range * 2 then
			return nil, Envelope.Codes.OUT_OF_RANGE, "aim"
		end
		hit = origin + direction * t
	end
	local flat = Vector3.new(hit.X - characterPosition.X, 0, hit.Z - characterPosition.Z)
	if flat.Magnitude > range then
		return nil, Envelope.Codes.OUT_OF_RANGE, "range"
	end
	local minCorner = ChapterLayout.gridMinCorner(layout, grid.width, grid.depth, grid.cellSize)
	local cx, cz = PileGrid.cellAt(grid, hit.X - minCorner.X, hit.Z - minCorner.Z)
	if cx < -1 or cz < -1 or cx > grid.width or cz > grid.depth then
		-- The mound's skirt (rim stretch) hangs past the logical footprint; a hit on that visible
		-- surface belongs to the nearest edge cell rather than being "outside the nest".
		if PileSurface.heightAt(field, hit.X, hit.Z) <= 0 then
			return nil, Envelope.Codes.OUT_OF_RANGE, "outside_nest"
		end
		cx = math.clamp(cx, 0, grid.width - 1)
		cz = math.clamp(cz, 0, grid.depth - 1)
	end
	return { hit = hit, cx = cx, cz = cz, minCorner = minCorner, layout = layout }, nil, nil
end

-- Common gate for gameplay requests: round, token, phase, alive, character.
function CollectionService.gate(self: CollectionService, userId: number, token: any): (any?, any?, Vector3?, string?, string?)
	local runtime = self._rounds:roundOf(userId)
	if not runtime then
		return nil, nil, nil, Envelope.Codes.INVALID_STATE, "no_round"
	end
	local okToken, tokenErr = self._sessions:validate(userId, token, "Round")
	if not okToken then
		return nil, nil, nil, Envelope.Codes.STALE_TOKEN, tokenErr
	end
	if not RoundReducer.acceptsGameplay(runtime.state) then
		return nil, nil, nil, Envelope.Codes.INVALID_STATE, "phase"
	end
	local state = runtime.players[userId]
	if not state or not state.alive then
		return nil, nil, nil, Envelope.Codes.INVALID_STATE, "not_alive"
	end
	local characterPosition = self._getCharacterPosition(userId)
	if not characterPosition then
		return nil, nil, nil, Envelope.Codes.INVALID_STATE, "no_character"
	end
	return runtime, state, characterPosition, nil, nil
end

-- payload: { sessionToken, origin: Vector3, direction: Vector3, toolId }
function CollectionService.collect(self: CollectionService, userId: number, payload: { [string]: any }): Envelope.Envelope<any>
	local runtime, state, characterPosition, gateCode, gateMessage = self:gate(userId, payload.sessionToken)
	if not runtime or not state or not characterPosition then
		return reject(self, gateCode :: string, gateMessage)
	end
	local toolId = payload.toolId
	if (toolId ~= "hand" and toolId ~= "nestRake") or not state.roundTools[toolId] then
		return reject(self, Envelope.Codes.NOT_AUTHORIZED, "tool")
	end
	if state.equippedTool ~= toolId then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_equipped")
	end
	local now = self._clock:monotonic()
	if now < state.cooldownUntil then
		return reject(self, Envelope.Codes.RATE_LIMITED, "cooldown")
	end
	local aim, aimCode, aimMessage =
		CollectionService.resolveAim(self._config, runtime, characterPosition, payload.origin, payload.direction)
	if not aim then
		return reject(self, aimCode :: string, aimMessage)
	end
	local capacity = self:bagCapacity(runtime, userId)
	local carried = state.carriedStandard + state.carriedRainbow
	local free = if capacity.infinite then math.huge else capacity.capacity - carried
	if free <= 0 then
		return reject(self, Envelope.Codes.INVALID_STATE, "bag_full")
	end
	local grid = runtime.grid
	local spec = self:spec(runtime, userId, toolId)
	local cells: { PileGrid.Cell }
	if spec.radiusCells > 0 then
		cells = PileGrid.cellsWithin(grid, aim.cx, aim.cz, spec.radiusCells)
	else
		local target = PileGrid.findTarget(grid, aim.cx, aim.cz, 1)
		cells = if target then { target } else {}
	end
	if #cells == 0 then
		return reject(self, Envelope.Codes.NOT_FOUND, "no_feathers")
	end
	-- Atomic removal + award (single-threaded server; no yields between these lines).
	-- Hand: removes only what fits (nothing wasted). Rake: removes the full sweep; overflow bundles.
	local amount = spec.amount
	if toolId == "hand" then
		amount = math.min(amount, if free == math.huge then amount else free)
	end
	local removals, removed = PileGrid.removeSpread(grid, cells, amount)
	local cellsCleared = 0
	for _, removal in ipairs(removals) do
		self._rounds:queueDelta(runtime.state.roundId, removal.index, removal.remaining)
		if removal.remaining == 0 then
			cellsCleared += 1
		end
	end
	state.contribution.cellsRemoved += cellsCleared
	local award = RoundAwards.award(state, removed, 0, capacity)
	local cooldown = spec.cooldownSeconds
	state.cooldownUntil = now + cooldown
	self.stats.accepted += 1

	local primary = cells[1]
	local worldX, worldZ = PileGrid.cellCenter(grid, primary)
	local hitWorld = Vector3.new(aim.minCorner.X + worldX, aim.layout.nestBaseY, aim.minCorner.Z + worldZ)
	local bundle = nil
	if award.overflowStandard > 0 then
		bundle = RoundAwards.dropBundle(
			runtime,
			self._idGen,
			hitWorld,
			award.overflowStandard,
			0,
			now + self._config.collection.overflowBundleSeconds
		)
	end
	if self._analytics then
		self._analytics:track("feather_collected", { chapter = runtime.state.chapter, amount = award.standard, tool = toolId }, userId)
		if toolId ~= "hand" then
			self._analytics:track(
				"tool_action",
				{ chapter = runtime.state.chapter, tool = toolId, action = "sweep", removed = removed, cells = #removals },
				userId
			)
		end
		if award.bagFull then
			self._analytics:track("bag_full", { chapter = runtime.state.chapter, capacity = capacity.capacity }, userId)
		end
	end
	local result = {
		toolId = toolId,
		awarded = award.standard,
		removed = removed,
		overflow = award.overflowStandard,
		carried = award.carried,
		capacity = award.capacity,
		infinite = award.infinite,
		cellIndex = primary.index,
		remaining = primary.remaining,
		base = primary.base,
		cells = removals,
		cooldownMs = math.floor(cooldown * 1000),
		hitX = hitWorld.X,
		hitZ = hitWorld.Z,
		removedFraction = PileGrid.removedFraction(grid),
		bagFull = award.bagFull,
		bundleId = bundle and bundle.id or nil,
	}
	self.collected:Fire(userId, runtime, result)
	if bundle then
		self.event:Fire(runtime.state.roundId, {
			kind = "bundle_dropped",
			bundleId = bundle.id,
			x = bundle.position.X,
			y = bundle.position.Y,
			z = bundle.position.Z,
			standard = bundle.standard,
			rainbow = bundle.rainbow,
			expiresInMs = math.floor(self._config.collection.overflowBundleSeconds * 1000),
		})
	end
	if award.bagFull then
		self.bagFilled:Fire(userId, runtime)
	end
	return Envelope.ok(result)
end

-- payload: { sessionToken, bundleId }. Any present member may gather a bundle within range; the bag
-- is clamped and the remainder stays in the world until it expires.
function CollectionService.gatherBundle(self: CollectionService, userId: number, payload: { [string]: any }): Envelope.Envelope<any>
	local runtime, state, characterPosition, gateCode, gateMessage = self:gate(userId, payload.sessionToken)
	if not runtime or not state or not characterPosition then
		return reject(self, gateCode :: string, gateMessage)
	end
	local bundle = runtime.bundles[payload.bundleId]
	if not bundle then
		return reject(self, Envelope.Codes.NOT_FOUND, "bundle")
	end
	local flat = Vector3.new(characterPosition.X - bundle.position.X, 0, characterPosition.Z - bundle.position.Z)
	if flat.Magnitude > self._config.interaction.defaultRangeStuds then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "bundle")
	end
	local capacity = self:bagCapacity(runtime, userId)
	local award, emptied = RoundAwards.gatherBundle(runtime, payload.bundleId, state, capacity)
	if not award or (award.standard + award.rainbow) == 0 then
		return reject(self, Envelope.Codes.INVALID_STATE, "bag_full")
	end
	self.stats.bundlesGathered += 1
	local result = {
		toolId = "bundle",
		bundleId = payload.bundleId,
		awarded = award.standard + award.rainbow,
		rainbow = award.rainbow,
		carried = award.carried,
		capacity = award.capacity,
		infinite = award.infinite,
		bagFull = award.bagFull,
		emptied = emptied,
		hitX = bundle.position.X,
		hitZ = bundle.position.Z,
		cooldownMs = 0,
		removedFraction = PileGrid.removedFraction(runtime.grid),
	}
	if self._analytics then
		self._analytics:track("feather_collected", { chapter = runtime.state.chapter, amount = result.awarded, tool = "bundle" }, userId)
	end
	self.collected:Fire(userId, runtime, result)
	self.event:Fire(runtime.state.roundId, {
		kind = if emptied then "bundle_removed" else "bundle_changed",
		bundleId = payload.bundleId,
		standard = bundle.standard,
		rainbow = bundle.rainbow,
		byUserId = userId,
	})
	if award.bagFull then
		self.bagFilled:Fire(userId, runtime)
	end
	return Envelope.ok(result)
end

return CollectionService
