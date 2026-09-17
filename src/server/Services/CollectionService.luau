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
local FeatherLayout = require(Shared.Domain.FeatherLayout)
local PileSurface = require(Shared.Domain.PileSurface)
local PileTargeting = require(Shared.Domain.PileTargeting)
local RoundModifiers = require(script.Parent.RoundModifiers)
local RoundAwards = require(script.Parent.RoundAwards)

local CollectionService = {}
CollectionService.__index = CollectionService

export type CollectionService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_lineOfSight: ((runtime: any, origin: Vector3, hit: Vector3) -> boolean)?,
		_floorHeight: ((x: number, z: number) -> number?)?,
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
	featherId: number?, -- the record the aim ray strikes (tool aims resolved against the records)
}

-- The rake's sight lines also start from its head, this far above the struck record: the tines see
-- the surface they drag across, not only what the player's eye does.
local RAKE_HEAD_LIFT_STUDS = 1.5

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
	lineOfSight: ((runtime: any, origin: Vector3, hit: Vector3) -> boolean)?,
	floorHeight: ((x: number, z: number) -> number?)?,
}): CollectionService
	local counter = 0
	return setmetatable({
		_config = options.config,
		_lineOfSight = options.lineOfSight,
		_floorHeight = options.floorHeight,
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

-- The seat field: the mound as first built (every cell full). Records are seated on it by slot and
-- never move, exactly as the client seats them. Cached per round grid.
function CollectionService.seatField(self: CollectionService, runtime: any): PileSurface.Field
	local grid = runtime.grid
	local seatField = if runtime.seatFieldGrid == grid then runtime.seatField else nil
	if not seatField then
		local snapshot = PileGrid.snapshot(grid)
		seatField = PileSurface.buildField(self._config, {
			width = grid.width,
			depth = grid.depth,
			cellSize = grid.cellSize,
			remaining = table.clone(snapshot.base),
			base = snapshot.base,
		}, ChapterLayout[runtime.state.chapter])
		runtime.seatField = seatField
		runtime.seatFieldGrid = grid
		runtime.seatCache = { seats = {}, steps = {} }
	end
	return seatField :: PileSurface.Field
end

-- A fresh surface-first targeting model over the live grid (one per tool use).
function CollectionService.targetingModel(self: CollectionService, runtime: any): PileTargeting.Model
	local grid = runtime.grid
	local layout = ChapterLayout[runtime.state.chapter]
	local minCorner = ChapterLayout.gridMinCorner(layout, grid.width, grid.depth, grid.cellSize)
	local seatField = self:seatField(runtime)
	return PileTargeting.newModel(self._config, grid, seatField, minCorner, nil, runtime.seatCache)
end

-- Aim for the area tools (Nest Rake, Feather Vac): the strike is the record the player can see on the
-- aim ray - the client's reticle record when the server agrees it is on the ray and in sight, else
-- the first record the ray enters - never a point on the smoothed surface, which after digging sits
-- studs above or below the drawn records. A ray that meets no record falls back to `resolveAim`
-- (bare floor, harness aims). Origin plausibility and range are validated either way.
function CollectionService.resolveToolAim(
	self: CollectionService,
	runtime: any,
	characterPosition: Vector3,
	origin: any,
	direction: any,
	hintFeatherId: any,
	model: PileTargeting.Model?
): (Aim?, string?, string?)
	local config = self._config
	local interaction = config.interaction
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return nil, Envelope.Codes.INVALID_PAYLOAD, "aim"
	end
	if (origin - characterPosition).Magnitude > interaction.serverPositionToleranceStuds then
		return nil, Envelope.Codes.OUT_OF_RANGE, "origin"
	end
	if direction.Magnitude < 0.01 then
		return nil, Envelope.Codes.INVALID_PAYLOAD, "direction"
	end
	local range = interaction.defaultRangeStuds
	local targeting = model or self:targetingModel(runtime)
	local hit: PileTargeting.Hit? = nil
	if type(hintFeatherId) == "number" then
		hit = PileTargeting.validateHint(targeting, hintFeatherId, origin, direction.Unit, range * 2, interaction.aimMissToleranceStuds)
	end
	if not hit then
		hit = PileTargeting.firstHit(targeting, origin, direction.Unit, range * 2)
	end
	if not hit then
		return CollectionService.resolveAim(config, runtime, characterPosition, origin, direction)
	end
	local point = hit.point
	local flat = Vector3.new(point.X - characterPosition.X, 0, point.Z - characterPosition.Z)
	if flat.Magnitude > range then
		return nil, Envelope.Codes.OUT_OF_RANGE, "range"
	end
	local layout = ChapterLayout[runtime.state.chapter]
	local cell = runtime.grid.cells[hit.cellIndex]
	local aim: Aim = {
		hit = point,
		cx = cell.x,
		cz = cell.z,
		minCorner = Vector3.new(targeting.minX, layout.nestBaseY, targeting.minZ),
		layout = layout,
		featherId = hit.featherId,
	}
	return aim, nil, nil
end

-- One surface-first selection for an area tool use: the exact records it takes, in order.
function CollectionService.selectRecords(
	self: CollectionService,
	model: PileTargeting.Model,
	spec: any,
	origin: Vector3,
	direction: Vector3,
	amount: number,
	fallbackPoint: Vector3?,
	hintFeatherId: any
): PileTargeting.Selection
	local interaction = self._config.interaction
	local grid = model.grid
	local sweep = spec.toolId == "nestRake" and spec.halfWidthStuds ~= nil
	return PileTargeting.select(model, {
		origin = origin,
		direction = direction,
		maxDistance = interaction.defaultRangeStuds * 2,
		amount = amount,
		perCellCap = spec.perCellCap,
		shape = if sweep then "sweep" else "cone",
		radiusStuds = spec.radiusStuds or grid.cellSize,
		halfWidthStuds = spec.halfWidthStuds,
		aheadStuds = spec.aheadStuds,
		reachStuds = spec.reachStuds,
		fallbackPoint = fallbackPoint,
		hintFeatherId = if type(hintFeatherId) == "number" then hintFeatherId else nil,
		hintToleranceStuds = interaction.aimMissToleranceStuds,
		headLiftStuds = if spec.toolId == "nestRake" then RAKE_HEAD_LIFT_STUDS else nil,
	})
end

-- Removes exactly a selection's records from the grid: (removals per cell, total).
function CollectionService.removeSelection(_self: CollectionService, grid: any, selection: PileTargeting.Selection): ({ any }, number)
	local records = table.create(#selection.records)
	for i, record in ipairs(selection.records) do
		records[i] = { cell = grid.cells[record.index], slot = record.slot }
	end
	return PileGrid.removeRecords(grid, records)
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

-- World position of a feather record: on the current logical surface, never below the map floor
-- (owner pits are stepped earth, so the nest floor rises toward the rim).
function CollectionService.featherPosition(
	self: CollectionService,
	runtime: any,
	cell: any,
	slot: number,
	_field: any?,
	minCorner: Vector3?
): Vector3
	local config = self._config
	local grid = runtime.grid
	local layout = ChapterLayout[runtime.state.chapter]
	-- Seats come from the mound as first built (every cell full), exactly as the client seats them,
	-- and each record sits a fixed depth below that surface by slot: a pick never moves a seat.
	local seatField = self:seatField(runtime)
	local corner = minCorner or ChapterLayout.gridMinCorner(layout, grid.width, grid.depth, grid.cellSize)
	local placement = FeatherLayout.placement(config.pile.visual, cell.index, slot, grid.cellSize)
	local position = FeatherLayout.worldPosition(seatField, corner, cell.x, cell.z, placement)
	local step = PileSurface.columnFullHeight(config, grid.width, grid.depth, grid.cellSize, cell.x, cell.z) / math.max(1, cell.base)
	position = Vector3.new(position.X, position.Y + FeatherLayout.seatOffset(config.pile.visual, cell.base, slot, step), position.Z)
	if self._floorHeight then
		local floor = self._floorHeight(position.X, position.Z)
		if floor and floor + 0.1 > position.Y then
			position = Vector3.new(position.X, floor + 0.1, position.Z)
		end
	end
	return position
end

-- Hand click (owner requirement, single-feather pickup): the payload names ONE feather record
-- (featherId). The server verifies the record exists, is untaken, and is exposed (one of the top
-- `visibleSlotsPerCell` untaken slots of its cell, exactly what the client can render and see), that
-- the player is in range of that feather, aiming at it, and has line of sight, then removes exactly
-- that record and awards exactly one feather. Everything else in the cell stays untouched.
function CollectionService._collectFeather(
	self: CollectionService,
	userId: number,
	runtime: any,
	state: any,
	characterPosition: Vector3,
	payload: { [string]: any },
	now: number
): Envelope.Envelope<any>
	local config = self._config
	local interaction = config.interaction
	local cellIndex, slot = FeatherLayout.decode(payload.featherId)
	if not cellIndex or not slot then
		return reject(self, Envelope.Codes.INVALID_PAYLOAD, "feather_id")
	end
	local grid = runtime.grid
	local cell = grid.cells[cellIndex]
	if not cell or slot > cell.base then
		return reject(self, Envelope.Codes.NOT_FOUND, "no_feather")
	end
	if PileGrid.isTaken(cell, slot) then
		return reject(self, Envelope.Codes.ALREADY_DONE, "already_collected")
	end
	-- The window is per column, not a constant: steep rim columns render deeper so the coat covers the
	-- mound body instead of leaving a bare band, and so does a column standing over a freshly dug pit.
	-- The same two pure functions the client renders from.
	--
	-- Whichever window is wider wins. The dug-aware one depends on live neighbour heights, and a client
	-- a delta or two behind us would otherwise be drawing a feather we had already decided was buried;
	-- taking the max means a pick is refused only when it is genuinely under the coat on both readings.
	local cellX, cellZ = (cellIndex - 1) % grid.width, math.floor((cellIndex - 1) / grid.width)
	local minSlots = config.pile.visual.visibleSlotsPerCell
	local exposedCount = math.max(
		PileSurface.coatSlots(config, grid.width, grid.depth, grid.cellSize, cellX, cellZ, cell.base, minSlots),
		PileSurface.coatSlotsAt(
			config,
			grid.width,
			grid.depth,
			grid.cellSize,
			PileSurface.cellHeights(config, grid.width, grid.depth, grid.cellSize, grid.cells),
			cellX,
			cellZ,
			cell.base,
			minSlots
		)
	)
	if not table.find(FeatherLayout.exposedSlots(cell.base, cell.taken, exposedCount), slot) then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_exposed")
	end
	local origin, direction = payload.origin, payload.direction
	if (origin - characterPosition).Magnitude > interaction.serverPositionToleranceStuds then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "origin")
	end
	if direction.Magnitude < 0.01 then
		return reject(self, Envelope.Codes.INVALID_PAYLOAD, "direction")
	end
	local layout = ChapterLayout[runtime.state.chapter]
	local minCorner = ChapterLayout.gridMinCorner(layout, grid.width, grid.depth, grid.cellSize)
	local position = self:featherPosition(runtime, cell, slot, nil, minCorner)
	local flat = Vector3.new(position.X - characterPosition.X, 0, position.Z - characterPosition.Z)
	if flat.Magnitude > interaction.defaultRangeStuds then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "range")
	end
	-- The aim ray must pass within the miss tolerance of the feather and point toward it (a closest-
	-- approach test is robust at arm's length where a small angle is a large miss and vice versa).
	local toFeather = position - origin
	local along = direction.Unit:Dot(toFeather)
	if along < 0 or (toFeather - direction.Unit * along).Magnitude > interaction.aimMissToleranceStuds then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "aim")
	end
	if self._lineOfSight and not self._lineOfSight(runtime, origin, position) then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "line_of_sight")
	end
	local capacity = self:bagCapacity(runtime, userId)
	local carried = state.carriedStandard + state.carriedRainbow
	if not capacity.infinite and capacity.capacity - carried <= 0 then
		return reject(self, Envelope.Codes.INVALID_STATE, "bag_full")
	end
	-- Atomic removal of exactly this record + award of exactly one (single-threaded; no yields).
	local removal = PileGrid.removeFeather(grid, cell, slot)
	if not removal then
		return reject(self, Envelope.Codes.ALREADY_DONE, "already_collected")
	end
	self._rounds:queueDelta(runtime.state.roundId, removal.index, removal.remaining, removal.mask)
	if removal.remaining == 0 then
		state.contribution.cellsRemoved += 1
	end
	local isRainbow = FeatherLayout.isRainbow(self._config, runtime.rainbowSeed or 0, cell.index, slot)
	local award = RoundAwards.award(state, if isRainbow then 0 else 1, if isRainbow then 1 else 0, capacity)
	local cooldown = self:spec(runtime, userId, "hand").cooldownSeconds
	state.cooldownUntil = now + cooldown
	self.stats.accepted += 1
	if self._analytics then
		self._analytics:track("feather_collected", { chapter = runtime.state.chapter, amount = award.standard, tool = "hand" }, userId)
		if award.bagFull then
			self._analytics:track("bag_full", { chapter = runtime.state.chapter, capacity = capacity.capacity }, userId)
		end
	end
	local result = {
		toolId = "hand",
		featherId = payload.featherId,
		slot = slot,
		awarded = award.standard,
		rainbow = award.rainbow,
		removed = 1,
		overflow = 0,
		carried = award.carried,
		carriedRainbow = state.carriedRainbow,
		capacity = award.capacity,
		infinite = award.infinite,
		cellIndex = cell.index,
		remaining = cell.remaining,
		mask = cell.taken,
		base = cell.base,
		cells = { removal },
		cooldownMs = math.floor(cooldown * 1000),
		hitX = position.X,
		hitY = position.Y,
		hitZ = position.Z,
		removedFraction = PileGrid.removedFraction(grid),
		bagFull = award.bagFull,
	}
	self.collected:Fire(userId, runtime, result)
	if award.bagFull then
		self.bagFilled:Fire(userId, runtime)
	end
	return Envelope.ok(result)
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
	-- A client retry that repeats the last request id is acknowledged as a duplicate, never re-awarded.
	local requestId = payload.requestId
	if requestId ~= nil then
		if state.lastCollectRequestId == requestId then
			return reject(self, Envelope.Codes.ALREADY_DONE, "duplicate")
		end
		state.lastCollectRequestId = requestId
	end
	if now < state.cooldownUntil then
		return reject(self, Envelope.Codes.RATE_LIMITED, "cooldown")
	end
	if toolId == "hand" then
		return self:_collectFeather(userId, runtime, state, characterPosition, payload, now)
	end
	local model = self:targetingModel(runtime)
	local aim, aimCode, aimMessage =
		self:resolveToolAim(runtime, characterPosition, payload.origin, payload.direction, payload.featherId, model)
	if not aim then
		return reject(self, aimCode :: string, aimMessage)
	end
	if self._lineOfSight and not self._lineOfSight(runtime, payload.origin, aim.hit) then
		return reject(self, Envelope.Codes.OUT_OF_RANGE, "line_of_sight")
	end
	local capacity = self:bagCapacity(runtime, userId)
	local carried = state.carriedStandard + state.carriedRainbow
	local free = if capacity.infinite then math.huge else capacity.capacity - carried
	if free <= 0 then
		return reject(self, Envelope.Codes.INVALID_STATE, "bag_full")
	end
	local grid = runtime.grid
	local spec = self:spec(runtime, userId, toolId)
	-- Surface first (PileTargeting): the sweep strikes the record under the reticle, then drags
	-- through the exposed records of its fan - top layer first, never a record hidden under or behind
	-- another. A strike on bare ground takes the nearest exposed records within reach. The response
	-- carries exactly these records, and the client animates exactly these.
	local selection = self:selectRecords(model, spec, payload.origin, payload.direction.Unit, spec.amount, aim.hit, payload.featherId)
	if #selection.records == 0 or not selection.strike then
		return reject(self, Envelope.Codes.NOT_FOUND, "no_feathers")
	end
	-- Atomic removal + award (single-threaded server; no yields between these lines).
	-- Rake: removes the full sweep; overflow bundles.
	local removals, removed = self:removeSelection(grid, selection)
	local cellsCleared = 0
	for _, removal in ipairs(removals) do
		self._rounds:queueDelta(runtime.state.roundId, removal.index, removal.remaining, removal.mask)
		if removal.remaining == 0 then
			cellsCleared += 1
		end
	end
	state.contribution.cellsRemoved += cellsCleared
	local rainbowCount = 0
	for _, removal in ipairs(removals) do
		for _, removedSlot in ipairs(removal.slots or {}) do
			if FeatherLayout.isRainbow(self._config, runtime.rainbowSeed or 0, removal.index, removedSlot) then
				rainbowCount += 1
			end
		end
	end
	local award = RoundAwards.award(state, removed - rainbowCount, rainbowCount, capacity)
	local cooldown = spec.cooldownSeconds
	state.cooldownUntil = now + cooldown
	self.stats.accepted += 1

	local primary = grid.cells[selection.records[1].index]
	-- The strike point is the record the sweep struck, so every client effect and the terrain re-seat
	-- originate where the feathers actually left.
	local strike = selection.strike :: Vector3
	local strikeY = math.max(aim.layout.nestBaseY, strike.Y)
	local hitWorld = Vector3.new(strike.X, aim.layout.nestBaseY, strike.Z)
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
		rainbow = award.rainbow,
		removed = removed,
		overflow = award.overflowStandard,
		carried = award.carried,
		carriedRainbow = state.carriedRainbow,
		capacity = award.capacity,
		infinite = award.infinite,
		cellIndex = primary.index,
		remaining = primary.remaining,
		base = primary.base,
		cells = removals,
		featherIds = selection.featherIds,
		cooldownMs = math.floor(cooldown * 1000),
		hitX = hitWorld.X,
		hitY = strikeY,
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
		carriedRainbow = state.carriedRainbow,
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
