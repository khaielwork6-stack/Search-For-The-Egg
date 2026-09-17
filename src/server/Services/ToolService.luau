--!strict
-- Server authority for the Confetti Charge, Feather Vac, and Scout Chick, plus tool equip, round
-- grants (permanent entitlements, class grants, one-round purchases), overflow bundle expiry, and
-- cleanup on death / disconnect / round end. Every yield, timer, RNG roll, and position check
-- happens here; clients only send intents and animate `ToolEvent` payloads.
--
-- Live state lives on the round runtime: `runtime.charges[id]` (thrown charges), `runtime.bundles`
-- (overflow pickups), and `state.toolRuntime.<toolId>` per player (vac heat / chick units).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local PileGrid = require(Shared.Domain.PileGrid)
local PileSurface = require(Shared.Domain.PileSurface)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local ToolSpecs = require(Shared.Domain.ToolSpecs)
local EconomyMath = require(Shared.EconomyMath)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)
local RoundAwards = require(script.Parent.RoundAwards)

local ToolService = {}
ToolService.__index = ToolService

export type ToolService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_clock: any,
		_rounds: any,
		_sessions: any,
		_collection: any,
		_rng: any,
		_idGen: () -> string,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_getEntitlements: ((userId: number) -> { [string]: boolean }?)?,
		_crateBusy: (() -> boolean)?,
		_worldCast: ((origin: Vector3, direction: Vector3, distance: number) -> Vector3?)?,
		_analytics: any?,
		_log: any?,
		_lastTick: number?,
		event: any, -- (roundId, payload, targetUserId?)
		awarded: any, -- (userId, runtime, result) every tool award into a bag
		deposited: any, -- (userId, runtime, sale) Scout Chick deposits
		overheated: any, -- (userId, runtime)
		granted: any, -- (userId, runtime, toolId, source)
		revoked: any, -- (userId, runtime, toolId, reason) a timed loan taken back
		stats: {
			equips: number,
			charges: number,
			explosions: number,
			miniCharges: number,
			rainbow: number,
			vacSeconds: number,
			vacFeathers: number,
			overheats: number,
			chickTrips: number,
			swarms: number,
			bundlesDropped: number,
			bundlesExpired: number,
			ticks: number,
			rejected: number,
			revoked: number,
		},
	},
	ToolService
))

local MAX_TICK_SECONDS = 0.5
local ARRIVE_STUDS = 1.5

function ToolService.new(
	options: {
		config: { [string]: any },
		clock: any,
		rounds: any,
		sessions: any,
		collection: any,
		rng: any, -- WeightedRandom-like: :next() -> [0,1)
		idGen: (() -> string)?,
		getCharacterPosition: (userId: number) -> Vector3?,
		getEntitlements: ((userId: number) -> { [string]: boolean }?)?,
		crateBusy: (() -> boolean)?,
		-- First solid surface along a ray, or nil. Injected so the service stays headless in tests.
		worldCast: ((origin: Vector3, direction: Vector3, distance: number) -> Vector3?)?,
		analytics: any?,
		log: any?,
	}
): ToolService
	local counter = 0
	return setmetatable({
		_config = options.config,
		_clock = options.clock,
		_rounds = options.rounds,
		_sessions = options.sessions,
		_collection = options.collection,
		_rng = options.rng,
		_idGen = options.idGen or function()
			counter += 1
			return "tool-" .. tostring(counter)
		end,
		_getCharacterPosition = options.getCharacterPosition,
		_getEntitlements = options.getEntitlements,
		_crateBusy = options.crateBusy,
		_worldCast = options.worldCast,
		_analytics = options.analytics,
		_log = options.log,
		_lastTick = nil,
		event = Signal.new(),
		awarded = Signal.new(),
		deposited = Signal.new(),
		overheated = Signal.new(),
		granted = Signal.new(),
		revoked = Signal.new(),
		stats = {
			equips = 0,
			charges = 0,
			explosions = 0,
			miniCharges = 0,
			rainbow = 0,
			vacSeconds = 0,
			vacFeathers = 0,
			overheats = 0,
			chickTrips = 0,
			swarms = 0,
			bundlesDropped = 0,
			bundlesExpired = 0,
			ticks = 0,
			rejected = 0,
			revoked = 0,
		},
	}, ToolService)
end

local function reject(self: ToolService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

local function track(self: ToolService, name: string, props: { [string]: any }, userId: number?)
	if self._analytics then
		self._analytics:track(name, props, userId)
	end
end

local function roll(self: ToolService): number
	return self._rng:next()
end

function ToolService.spec(self: ToolService, runtime: any, userId: number, toolId: string): any
	return self._collection:spec(runtime, userId, toolId)
end

local function vacRuntime(state: any): any
	local rt = state.toolRuntime.featherVac
	if not rt then
		rt = { heat = 0, running = false, overheated = false, carry = 0, pulled = 0, aimX = 0, aimZ = 0 }
		state.toolRuntime.featherVac = rt
	end
	return rt
end

-- The nozzle ray the suction follows: every tick selects from this ray, surface first.
local function setVacAim(rt: any, aim: any, payload: any)
	rt.aimX, rt.aimZ = aim.cx, aim.cz
	rt.aimHitX, rt.aimHitY, rt.aimHitZ = aim.hit.X, aim.hit.Y, aim.hit.Z
	rt.aimOrigin = payload.origin
	rt.aimDirection = payload.direction.Unit
	rt.aimFeatherId = if type(payload.featherId) == "number" then payload.featherId else nil
end

local function chickRuntime(state: any): any
	local rt = state.toolRuntime.scoutChick
	if not rt then
		rt = { active = false, units = {}, trips = 0 }
		state.toolRuntime.scoutChick = rt
	end
	return rt
end

local function chargeRuntime(state: any): any
	local rt = state.toolRuntime.confettiCharge
	if not rt then
		rt = { nextThrowAt = 0, liveChargeId = nil, thrown = 0 }
		state.toolRuntime.confettiCharge = rt
	end
	return rt
end

local function dropBundle(self: ToolService, runtime: any, position: Vector3, standard: number, rainbow: number): any?
	local now = self._clock:monotonic()
	local bundle =
		RoundAwards.dropBundle(runtime, self._idGen, position, standard, rainbow, now + self._config.collection.overflowBundleSeconds)
	if bundle then
		self.stats.bundlesDropped += 1
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
	return bundle
end

-- Grants at round start: permanent entitlements (owned tool at max levels when
-- `permanentIncludesMaxUpgrades`) and the class-driven Scout Chick round grant.
function ToolService.grantStartingTools(self: ToolService, runtime: any): { [number]: { string } }
	local granted: { [number]: { string } } = {}
	local cfg = self._config
	for userId, state in pairs(runtime.players) do
		granted[userId] = {}
		local entitlements = if self._getEntitlements then self._getEntitlements(userId) else nil
		for _, toolId in ipairs(ToolSpecs.TOOL_IDS) do
			if entitlements and entitlements[toolId .. "Permanent"] then
				state.roundTools[toolId] = true
				state.permanentTools[toolId] = true
				if cfg.tools[toolId].permanentIncludesMaxUpgrades then
					state.toolLevels[toolId] = ToolSpecs.maxLevels(cfg, toolId)
				end
				table.insert(granted[userId], toolId)
				track(self, "tool_acquired", { chapter = runtime.state.chapter, tool = toolId, source = "permanent" }, userId)
				self.granted:Fire(userId, runtime, toolId, "permanent")
			end
		end
		local modifiers = self._collection:modifiers(runtime, userId)
		if modifiers.entitlements.scoutChickRoundGrant and not state.roundTools.scoutChick then
			state.roundTools.scoutChick = true
			table.insert(granted[userId], "scoutChick")
			track(self, "tool_acquired", { chapter = runtime.state.chapter, tool = "scoutChick", source = "class" }, userId)
			self.granted:Fire(userId, runtime, "scoutChick", "class")
		end
		if #granted[userId] > 0 then
			self.event:Fire(runtime.state.roundId, { kind = "tools_granted", tools = granted[userId], userId = userId }, userId)
		end
	end
	return granted
end

-- Verified permanent-pass grant during a live round (Phase 5): the tool is owned for the rest of
-- the round at the configured maximum levels, exactly as a start-of-round permanent grant.
function ToolService.grantPermanentNow(self: ToolService, userId: number, toolId: string): boolean
	local runtime = self._rounds:roundOf(userId)
	if not runtime or not ToolSpecs.isTool(toolId) then
		return false
	end
	local state = runtime.players[userId]
	if not state or state.permanentTools[toolId] then
		return false
	end
	local cfg = self._config
	state.roundTools[toolId] = true
	state.permanentTools[toolId] = true
	if cfg.tools[toolId].permanentIncludesMaxUpgrades then
		state.toolLevels[toolId] = ToolSpecs.maxLevels(cfg, toolId)
	end
	track(self, "tool_acquired", { chapter = runtime.state.chapter, tool = toolId, source = "permanent" }, userId)
	self.granted:Fire(userId, runtime, toolId, "permanent")
	self.event:Fire(runtime.state.roundId, { kind = "tools_granted", tools = { toolId }, userId = userId }, userId)
	return true
end

-- One-round grant interface (Phase 5 receipts, tests, debug). Levels stay at the round's values.
function ToolService.grantOneRound(self: ToolService, userId: number, toolId: string, source: string): boolean
	local runtime = self._rounds:roundOf(userId)
	if not runtime or not ToolSpecs.isTool(toolId) then
		return false
	end
	local state = runtime.players[userId]
	if not state or state.roundTools[toolId] then
		return false
	end
	state.roundTools[toolId] = true
	track(self, "tool_acquired", { chapter = runtime.state.chapter, tool = toolId, source = source }, userId)
	self.granted:Fire(userId, runtime, toolId, source)
	self.event:Fire(runtime.state.roundId, { kind = "tools_granted", tools = { toolId }, userId = userId }, userId)
	return true
end

-- Timed loan (Professor Plume's Egg Sense rod): the tool is owned for `seconds`, equipped at once,
-- and taken back by `tick` when the time is up, or sooner on death, leaving or the round ending.
-- A second loan while one is live simply extends the first; nothing is ever owned twice.
function ToolService.grantTimed(self: ToolService, userId: number, toolId: string, seconds: number, source: string): boolean
	local runtime = self._rounds:roundOf(userId)
	if not runtime or not ToolSpecs.isLentTool(toolId) or not (seconds > 0) then
		return false
	end
	local state = runtime.players[userId]
	if not state then
		return false
	end
	local now = self._clock:monotonic()
	local rt = state.toolRuntime[toolId]
	local fresh = not state.roundTools[toolId] or rt == nil
	state.roundTools[toolId] = true
	state.toolRuntime[toolId] = { expiresAt = now + seconds, activeSeconds = seconds, grantedAt = now }
	if fresh then
		track(self, "tool_acquired", { chapter = runtime.state.chapter, tool = toolId, source = source }, userId)
		self.granted:Fire(userId, runtime, toolId, source)
	end
	-- Equip before the event: the projection pushed on `tools_granted` must already carry the rod as
	-- the equipped tool, or the client syncs straight back to the hand a frame after raising it.
	self:equip(userId, toolId)
	self.event:Fire(runtime.state.roundId, {
		kind = "tools_granted",
		tools = { toolId },
		userId = userId,
		expiresInMs = math.floor(seconds * 1000 + 0.5),
		equipped = true,
	}, userId)
	return true
end

-- Seconds a timed loan has left, or nil when the player holds no live loan of that tool.
function ToolService.timedRemaining(self: ToolService, userId: number, toolId: string): number?
	local runtime = self._rounds:roundOf(userId)
	local state = runtime and runtime.players[userId]
	if not runtime or not state or not state.roundTools[toolId] then
		return nil
	end
	local rt = state.toolRuntime[toolId]
	if not rt or type(rt.expiresAt) ~= "number" then
		return nil
	end
	local remaining = rt.expiresAt - self._clock:monotonic()
	return if remaining > 0 then remaining else nil
end

-- Takes a lent tool back: ownership and its runtime go, the hand comes back up if it was equipped,
-- and the owner hears why. Nothing happens when the player does not hold it.
function ToolService._revokeTimed(self: ToolService, runtime: any, userId: number, state: any, toolId: string, reason: string): boolean
	if not state.roundTools[toolId] then
		return false
	end
	state.roundTools[toolId] = nil
	state.toolRuntime[toolId] = nil
	local wasEquipped = state.equippedTool == toolId
	if wasEquipped then
		state.equippedTool = "hand"
		self.event:Fire(runtime.state.roundId, { kind = "tool_equipped", userId = userId, toolId = "hand" })
	end
	self.stats.revoked += 1
	track(self, "tool_revoked", { chapter = runtime.state.chapter, tool = toolId, reason = reason }, userId)
	self.event:Fire(
		runtime.state.roundId,
		{ kind = "tools_revoked", tools = { toolId }, userId = userId, reason = reason, wasEquipped = wasEquipped },
		userId
	)
	self.revoked:Fire(userId, runtime, toolId, reason)
	return true
end

function ToolService._revokeAllTimed(self: ToolService, runtime: any, userId: number, state: any, reason: string)
	for _, toolId in ipairs(ToolSpecs.LENT_TOOL_IDS) do
		self:_revokeTimed(runtime, userId, state, toolId, reason)
	end
end

function ToolService._tickTimed(self: ToolService, runtime: any, userId: number, state: any, now: number)
	for _, toolId in ipairs(ToolSpecs.LENT_TOOL_IDS) do
		local rt = state.toolRuntime[toolId]
		if state.roundTools[toolId] and (rt == nil or type(rt.expiresAt) ~= "number" or now >= rt.expiresAt) then
			self:_revokeTimed(runtime, userId, state, toolId, "expired")
		end
	end
end

-- Equip: server records the active tool; discrete actions are refused for an unequipped tool.
function ToolService.equip(self: ToolService, userId: number, toolId: string): Envelope.Envelope<any>
	local runtime = self._rounds:roundOf(userId)
	if not runtime then
		return reject(self, Envelope.Codes.INVALID_STATE, "no_round")
	end
	local state = runtime.players[userId]
	if not state then
		return reject(self, Envelope.Codes.INVALID_STATE, "no_state")
	end
	if toolId ~= "hand" and (not ToolSpecs.isEquippable(toolId) or not state.roundTools[toolId]) then
		return reject(self, Envelope.Codes.NOT_AUTHORIZED, "tool")
	end
	if state.equippedTool == "featherVac" and toolId ~= "featherVac" then
		self:_stopVac(runtime, userId, state, "unequipped")
	end
	state.equippedTool = toolId
	self.stats.equips += 1
	self.event:Fire(runtime.state.roundId, { kind = "tool_equipped", userId = userId, toolId = toolId })
	return Envelope.ok({ toolId = toolId })
end

-- payload: { sessionToken, toolId, origin, direction }
function ToolService.actionBegin(self: ToolService, userId: number, payload: { [string]: any }): Envelope.Envelope<any>
	local runtime, state, characterPosition, gateCode, gateMessage = self._collection:gate(userId, payload.sessionToken)
	if not runtime or not state or not characterPosition then
		return reject(self, gateCode :: string, gateMessage)
	end
	local toolId = payload.toolId
	if toolId ~= "confettiCharge" and toolId ~= "featherVac" and toolId ~= "scoutChick" then
		return reject(self, Envelope.Codes.INVALID_PAYLOAD, "tool")
	end
	if not state.roundTools[toolId] then
		return reject(self, Envelope.Codes.NOT_AUTHORIZED, "tool")
	end
	if state.equippedTool ~= toolId then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_equipped")
	end
	local now = self._clock:monotonic()
	if toolId == "confettiCharge" then
		return self:_throwCharge(runtime, userId, state, characterPosition, payload, now)
	elseif toolId == "featherVac" then
		return self:_startVac(runtime, userId, state, characterPosition, payload, now)
	end
	return self:_deployChick(runtime, userId, state, characterPosition, now)
end

-- payload: { sessionToken, toolId }
function ToolService.actionEnd(self: ToolService, userId: number, payload: { [string]: any }): Envelope.Envelope<any>
	local runtime, state, _, gateCode, gateMessage = self._collection:gate(userId, payload.sessionToken)
	if not runtime or not state then
		return reject(self, gateCode :: string, gateMessage)
	end
	local toolId = payload.toolId
	if toolId == "featherVac" then
		local rt = vacRuntime(state)
		local wasRunning = rt.running
		if wasRunning then
			self:_stopVac(runtime, userId, state, "released")
		end
		return Envelope.ok({ toolId = toolId, wasRunning = wasRunning, heat = rt.heat, overheated = rt.overheated })
	elseif toolId == "scoutChick" then
		local rt = chickRuntime(state)
		local wasActive = rt.active
		self:_recallChick(runtime, userId, state, "recalled")
		return Envelope.ok({ toolId = toolId, wasActive = wasActive })
	elseif toolId == "confettiCharge" then
		return Envelope.ok({ toolId = toolId })
	end
	return reject(self, Envelope.Codes.INVALID_PAYLOAD, "tool")
end

-- payload: { sessionToken, toolId, origin, direction }. The Feather Vac follows the reticle: every
-- update re-resolves the aim against the nest; an aim that leaves the nest or the player's range
-- stops the suction at once (the client never pulls from a stale point).
function ToolService.actionAim(self: ToolService, userId: number, payload: { [string]: any }): Envelope.Envelope<any>
	local runtime, state, characterPosition, gateCode, gateMessage = self._collection:gate(userId, payload.sessionToken)
	if not runtime or not state or not characterPosition then
		return reject(self, gateCode :: string, gateMessage)
	end
	if payload.toolId ~= "featherVac" then
		return reject(self, Envelope.Codes.INVALID_PAYLOAD, "tool")
	end
	local rt = vacRuntime(state)
	if not rt.running then
		return Envelope.ok({ running = false })
	end
	local aim = self._collection:resolveToolAim(runtime, characterPosition, payload.origin, payload.direction, payload.featherId)
	if not aim then
		self:_stopVac(runtime, userId, state, "range")
		return Envelope.ok({ running = false, reason = "range", heat = rt.heat })
	end
	setVacAim(rt, aim, payload)
	return Envelope.ok({ running = true, aimX = aim.hit.X, aimZ = aim.hit.Z, heat = rt.heat })
end

-- Confetti Charge ---------------------------------------------------------------------------

function ToolService._throwCharge(
	self: ToolService,
	runtime: any,
	userId: number,
	state: any,
	characterPosition: Vector3,
	payload: any,
	now: number
)
	local rt = chargeRuntime(state)
	if now < rt.nextThrowAt then
		return reject(self, Envelope.Codes.RATE_LIMITED, "cooldown")
	end
	if rt.liveChargeId and runtime.charges[rt.liveChargeId] then
		return reject(self, Envelope.Codes.INVALID_STATE, "charge_live")
	end
	local spec = self:spec(runtime, userId, "confettiCharge")
	local landing, aimCode, aimMessage =
		self:_resolveThrowLanding(runtime, characterPosition, payload.origin, payload.direction, spec.throwDistanceStuds)
	if not landing then
		return reject(self, aimCode :: string, aimMessage)
	end
	local charge = self:_spawnCharge(runtime, userId, landing, spec, spec.fuseSeconds, false, now)
	rt.liveChargeId = charge.id
	rt.nextThrowAt = now + spec.cooldownSeconds
	rt.thrown += 1
	self.stats.charges += 1
	track(
		self,
		"tool_action",
		{ chapter = runtime.state.chapter, tool = "confettiCharge", action = "throw", fuse = spec.fuseSeconds },
		userId
	)
	return Envelope.ok({
		chargeId = charge.id,
		fuseMs = math.floor(spec.fuseSeconds * 1000),
		cooldownMs = math.floor(spec.cooldownSeconds * 1000),
		radius = spec.radiusStuds,
		x = landing.X,
		y = landing.Y,
		z = landing.Z,
	})
end

-- Where a thrown charge lands.
--
-- Deliberately not `CollectionService.resolveAim`, which is the aim rule for reaching into the pile:
-- it marches the mound, refuses a ray that is not pointing downward, and refuses anything outside
-- the nest footprint. A charge is thrown, not reached with, so it goes wherever the player is
-- looking: the nearest of the mound surface and the first solid thing in the world, within the
-- configured range. Nothing here consults where the feathers are, so the landing point can never be
-- pulled towards the pile; a throw across the yard lands across the yard and simply finds no
-- feathers when it goes off.
--
-- Three exploit gates, in order: the client's claimed origin has to be within
-- `serverPositionToleranceStuds` of where the server has the character, the ray stops at the first
-- solid surface so a charge cannot be placed through a wall, and the landing is clamped to the
-- configured range measured flat from the character.
function ToolService._resolveThrowLanding(
	self: ToolService,
	runtime: any,
	characterPosition: Vector3,
	origin: Vector3,
	direction: Vector3,
	rangeStuds: number
): (Vector3?, string?, string?)
	local interaction = self._config.interaction
	if (origin - characterPosition).Magnitude > interaction.serverPositionToleranceStuds then
		return nil, Envelope.Codes.OUT_OF_RANGE, "origin"
	end
	if direction.Magnitude < 0.01 then
		return nil, Envelope.Codes.INVALID_PAYLOAD, "direction"
	end
	local unit = direction.Unit
	local layout = ChapterLayout[runtime.state.chapter]
	local grid = runtime.grid
	local field = PileSurface.buildField(self._config, PileGrid.snapshot(grid), layout)
	local function surfaceY(x: number, z: number): number
		-- The mound where there is mound, the nest floor everywhere else.
		return field.baseY + PileSurface.heightAt(field, x, z)
	end

	local best: Vector3? = PileSurface.march(field, origin, unit, rangeStuds, 0.5)
	if self._worldCast then
		local worldHit = self._worldCast(origin, unit, rangeStuds)
		if worldHit and (best == nil or (worldHit - origin).Magnitude < ((best :: Vector3) - origin).Magnitude) then
			best = worldHit
		end
	end
	if best == nil then
		-- Open air for the whole throw: it carries to the end of its range and drops to the ground.
		local far = origin + unit * rangeStuds
		local drop = self._config.tools.confettiCharge.throwFloorDropStuds
		local floor = if self._worldCast then self._worldCast(far, Vector3.new(0, -1, 0), drop) else nil
		best = floor or Vector3.new(far.X, surfaceY(far.X, far.Z), far.Z)
	end
	local landing = best :: Vector3
	local flat = Vector3.new(landing.X - characterPosition.X, 0, landing.Z - characterPosition.Z)
	if flat.Magnitude > rangeStuds then
		-- Aiming past the arm's reach throws as far as the arm reaches rather than refusing.
		local edge = characterPosition + flat.Unit * rangeStuds
		local drop = self._config.tools.confettiCharge.throwFloorDropStuds
		local above = Vector3.new(edge.X, landing.Y + drop * 0.5, edge.Z)
		local floor = if self._worldCast then self._worldCast(above, Vector3.new(0, -1, 0), drop) else nil
		landing = floor or Vector3.new(edge.X, surfaceY(edge.X, edge.Z), edge.Z)
	end
	return landing
end

function ToolService._spawnCharge(
	self: ToolService,
	runtime: any,
	userId: number,
	position: Vector3,
	spec: any,
	fuse: number,
	mini: boolean,
	now: number
)
	local charge = {
		id = self._idGen(),
		userId = userId,
		position = position,
		explodeAt = now + fuse,
		radiusStuds = spec.radiusStuds,
		yield = spec.yield,
		rainbowChance = spec.rainbowChance,
		miniChargeChance = spec.miniChargeChance,
		miniChargeCount = spec.miniChargeCount,
		miniChargeFuseSeconds = spec.miniChargeFuseSeconds,
		craterDepthRecords = spec.craterDepthRecords,
		mini = mini,
	}
	runtime.charges[charge.id] = charge
	self.event:Fire(runtime.state.roundId, {
		kind = "charge_thrown",
		chargeId = charge.id,
		userId = userId,
		x = position.X,
		y = position.Y,
		z = position.Z,
		radius = spec.radiusStuds,
		fuseMs = math.floor(fuse * 1000),
		mini = mini,
	})
	return charge
end

function ToolService._explode(self: ToolService, runtime: any, charge: any, now: number)
	-- Remove first so a re-entrant tick can never award the same charge twice.
	runtime.charges[charge.id] = nil
	local state = runtime.players[charge.userId]
	if state then
		local rt = chargeRuntime(state)
		if rt.liveChargeId == charge.id then
			rt.liveChargeId = nil
		end
	end
	local grid = runtime.grid
	local layout = ChapterLayout[runtime.state.chapter]
	local minCorner = ChapterLayout.gridMinCorner(layout, grid.width, grid.depth, grid.cellSize)
	local cells = PileGrid.cellsWithinStuds(grid, charge.position.X - minCorner.X, charge.position.Z - minCorner.Z, charge.radiusStuds)
	-- Only what fits in the owner's bag leaves the nest: a full bag never destroys feathers it cannot
	-- carry (owner requirement); an infinite bag takes the whole yield. A dead owner's blast still
	-- clears and bundles (nothing is awarded, nothing is lost).
	local amount = charge.yield
	local capacity = if state then self._collection:bagCapacity(runtime, charge.userId) else nil
	if state and state.alive and capacity and not capacity.infinite then
		amount = math.max(0, math.min(amount, capacity.capacity - (state.carriedStandard + state.carriedRainbow)))
	end
	-- Crater: a bowl from the landing point outwards (deep in the middle, a lip around it).
	local removals, total = PileGrid.removeBowl(grid, cells, amount, charge.craterDepthRecords or 14)
	local cleared = 0
	for _, removal in ipairs(removals) do
		self._rounds:queueDelta(runtime.state.roundId, removal.index, removal.remaining, removal.mask)
		if removal.remaining == 0 then
			cleared += 1
		end
	end
	local rainbow = 0
	for _ = 1, total do
		if roll(self) < charge.rainbowChance then
			rainbow += 1
		end
	end
	local standard = total - rainbow
	self.stats.explosions += 1
	self.stats.rainbow += rainbow
	local award = nil
	if state and state.alive and total > 0 and capacity then
		state.contribution.cellsRemoved += cleared
		award = RoundAwards.award(state, standard, rainbow, capacity)
		if award.overflowStandard + award.overflowRainbow > 0 then
			dropBundle(self, runtime, charge.position, award.overflowStandard, award.overflowRainbow)
		end
	elseif total > 0 then
		dropBundle(self, runtime, charge.position, standard, rainbow)
	end
	self.event:Fire(runtime.state.roundId, {
		kind = "charge_exploded",
		chargeId = charge.id,
		userId = charge.userId,
		x = charge.position.X,
		y = charge.position.Y,
		z = charge.position.Z,
		radius = charge.radiusStuds,
		removed = total,
		rainbow = rainbow,
		cells = removals,
		mini = charge.mini,
	})
	track(self, "tool_action", {
		chapter = runtime.state.chapter,
		tool = "confettiCharge",
		action = "explode",
		removed = total,
		rainbow = rainbow,
		mini = charge.mini,
	}, charge.userId)
	if award then
		self.awarded:Fire(charge.userId, runtime, {
			toolId = "confettiCharge",
			awarded = award.standard + award.rainbow,
			rainbow = award.rainbow,
			removed = total,
			overflow = award.overflowStandard + award.overflowRainbow,
			carried = award.carried,
			carriedRainbow = state.carriedRainbow,
			capacity = award.capacity,
			infinite = award.infinite,
			bagFull = award.bagFull,
			hitX = charge.position.X,
			hitY = charge.position.Y + 1.5,
			hitZ = charge.position.Z,
			removedFraction = PileGrid.removedFraction(grid),
			cells = removals,
		})
	end
	-- Blast Artist mini-charges: only when the resolved modifier grants them, never on a mini itself.
	if not charge.mini and charge.miniChargeCount > 0 and roll(self) < charge.miniChargeChance then
		for _ = 1, charge.miniChargeCount do
			local angle = roll(self) * math.pi * 2
			local distance = roll(self) * charge.radiusStuds
			local position = charge.position + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
			self:_spawnCharge(runtime, charge.userId, position, charge, charge.miniChargeFuseSeconds, true, now)
			self.stats.miniCharges += 1
		end
	end
end

-- Feather Vac -------------------------------------------------------------------------------

function ToolService._startVac(
	self: ToolService,
	runtime: any,
	userId: number,
	state: any,
	characterPosition: Vector3,
	payload: any,
	now: number
)
	local rt = vacRuntime(state)
	if rt.overheated then
		return reject(self, Envelope.Codes.INVALID_STATE, "overheated")
	end
	if rt.running then
		return reject(self, Envelope.Codes.ALREADY_DONE, "running")
	end
	local aim, aimCode, aimMessage =
		self._collection:resolveToolAim(runtime, characterPosition, payload.origin, payload.direction, payload.featherId)
	if not aim then
		return reject(self, aimCode :: string, aimMessage)
	end
	local capacity = self._collection:bagCapacity(runtime, userId)
	if not capacity.infinite and (state.carriedStandard + state.carriedRainbow) >= capacity.capacity then
		return reject(self, Envelope.Codes.INVALID_STATE, "bag_full")
	end
	local spec = self:spec(runtime, userId, "featherVac")
	rt.running = true
	setVacAim(rt, aim, payload)
	rt.startedAt = now
	self.event:Fire(runtime.state.roundId, {
		kind = "vac_state",
		userId = userId,
		state = "running",
		heat = rt.heat,
		runtimeSeconds = spec.runtimeSeconds,
		coolingSeconds = spec.coolingSeconds,
		aimX = aim.hit.X,
		aimZ = aim.hit.Z,
	})
	track(self, "tool_action", { chapter = runtime.state.chapter, tool = "featherVac", action = "start", heat = rt.heat }, userId)
	return Envelope.ok({
		heat = rt.heat,
		runtimeSeconds = spec.runtimeSeconds,
		coolingSeconds = spec.coolingSeconds,
		perSecond = spec.perSecond,
	})
end

function ToolService._stopVac(self: ToolService, runtime: any, userId: number, state: any, reason: string)
	local rt = vacRuntime(state)
	if not rt.running then
		return
	end
	rt.running = false
	rt.carry = 0
	self.event:Fire(runtime.state.roundId, {
		kind = "vac_state",
		userId = userId,
		state = if rt.overheated then "overheated" else "idle",
		reason = reason,
		heat = rt.heat,
	})
	track(
		self,
		"tool_action",
		{ chapter = runtime.state.chapter, tool = "featherVac", action = "stop", reason = reason, heat = rt.heat },
		userId
	)
end

function ToolService._tickVac(self: ToolService, runtime: any, userId: number, state: any, dt: number, now: number)
	local rt = state.toolRuntime.featherVac
	if not rt then
		return
	end
	local spec = self:spec(runtime, userId, "featherVac")
	if rt.running then
		local characterPosition = self._getCharacterPosition(userId)
		if not state.alive or not characterPosition then
			self:_stopVac(runtime, userId, state, "no_character")
			return
		end
		local grid = runtime.grid
		local layout = ChapterLayout[runtime.state.chapter]
		local aimWorld = ChapterLayout.cellWorldPosition(layout, grid.width, grid.depth, grid.cellSize, rt.aimX, rt.aimZ, 0)
		local flat = Vector3.new(aimWorld.X - characterPosition.X, 0, aimWorld.Z - characterPosition.Z)
		if flat.Magnitude > self._config.interaction.defaultRangeStuds + grid.cellSize then
			self:_stopVac(runtime, userId, state, "range")
			return
		end
		rt.heat = math.min(spec.runtimeSeconds, rt.heat + dt)
		self.stats.vacSeconds += dt
		if rt.heat >= spec.runtimeSeconds then
			rt.overheated = true
			rt.overheatedAt = now
			self.stats.overheats += 1
			self:_stopVac(runtime, userId, state, "overheated")
			track(
				self,
				"tool_overheated",
				{ chapter = runtime.state.chapter, tool = "featherVac", coolingSeconds = spec.coolingSeconds },
				userId
			)
			self.overheated:Fire(userId, runtime)
			return
		end
		rt.carry += spec.perSecond * dt
		local whole = math.floor(rt.carry)
		if whole < 1 then
			return
		end
		rt.carry -= whole
		local capacity = self._collection:bagCapacity(runtime, userId)
		local carried = state.carriedStandard + state.carriedRainbow
		local free = if capacity.infinite then math.huge else capacity.capacity - carried
		if free <= 0 then
			self:_stopVac(runtime, userId, state, "bag_full")
			return
		end
		-- Surface first (PileTargeting): the nozzle ray strikes the record under the reticle and the
		-- suction takes the exposed records around it, nearest first, top layer before anything under
		-- it - never a record hidden under or behind another. A bare spot pulls the nearest exposed
		-- records within reach; the vac never wanders to a fuller patch on its own.
		local amount = math.min(whole, if free == math.huge then whole else free)
		local fallback = Vector3.new(rt.aimHitX or aimWorld.X, rt.aimHitY or aimWorld.Y, rt.aimHitZ or aimWorld.Z)
		local origin = rt.aimOrigin or (fallback + Vector3.new(0, 4, 0))
		local direction = rt.aimDirection or Vector3.new(0, -1, 0)
		local model = self._collection:targetingModel(runtime)
		local selection = self._collection:selectRecords(model, spec, origin, direction, amount, fallback, rt.aimFeatherId)
		if #selection.records == 0 then
			rt.carry = 0
			return
		end
		local removals, total = self._collection:removeSelection(grid, selection)
		if total == 0 then
			return
		end
		local strike = selection.strike or fallback
		local cleared = 0
		for _, removal in ipairs(removals) do
			self._rounds:queueDelta(runtime.state.roundId, removal.index, removal.remaining, removal.mask)
			if removal.remaining == 0 then
				cleared += 1
			end
		end
		state.contribution.cellsRemoved += cleared
		local award = RoundAwards.award(state, total, 0, capacity)
		rt.pulled += award.standard
		self.stats.vacFeathers += award.standard
		-- Every pulled record by id, for the nozzle animation on every client in the round.
		self.event:Fire(runtime.state.roundId, {
			kind = "vac_pull",
			userId = userId,
			cells = removals,
			featherIds = selection.featherIds,
			awarded = award.standard,
			x = strike.X,
			y = strike.Y,
			z = strike.Z,
		})
		self.awarded:Fire(userId, runtime, {
			toolId = "featherVac",
			awarded = award.standard,
			removed = total,
			overflow = 0,
			carried = award.carried,
			carriedRainbow = state.carriedRainbow,
			capacity = award.capacity,
			infinite = award.infinite,
			bagFull = award.bagFull,
			hitX = strike.X,
			hitY = strike.Y + 1,
			hitZ = strike.Z,
			removedFraction = PileGrid.removedFraction(grid),
			cells = removals,
			featherIds = selection.featherIds,
			heat = rt.heat,
		})
		if award.bagFull then
			self:_stopVac(runtime, userId, state, "bag_full")
		end
	elseif rt.heat > 0 then
		rt.heat = math.max(0, rt.heat - dt * (spec.runtimeSeconds / spec.coolingSeconds))
		if rt.heat == 0 and rt.overheated then
			rt.overheated = false
			self.event:Fire(runtime.state.roundId, { kind = "vac_state", userId = userId, state = "ready", heat = 0 })
		end
	end
end

-- Scout Chick -------------------------------------------------------------------------------

function ToolService._newUnit(self: ToolService, position: Vector3, oneTrip: boolean): any
	return {
		id = self._idGen(),
		state = "ToPile",
		position = position,
		targetX = nil,
		targetZ = nil,
		load = 0,
		timer = 0,
		oneTrip = oneTrip,
		trips = 0,
	}
end

function ToolService._chickEvent(self: ToolService, runtime: any, userId: number, unit: any, extra: { [string]: any }?)
	local payload: { [string]: any } = {
		kind = "chick_state",
		userId = userId,
		unitId = unit.id,
		state = unit.state,
		x = unit.position.X,
		y = unit.position.Y,
		z = unit.position.Z,
		load = unit.load,
		oneTrip = unit.oneTrip,
	}
	if extra then
		for key, value in pairs(extra) do
			payload[key] = value
		end
	end
	self.event:Fire(runtime.state.roundId, payload)
end

function ToolService._deployChick(self: ToolService, runtime: any, userId: number, state: any, characterPosition: Vector3, now: number)
	local rt = chickRuntime(state)
	if rt.active then
		return reject(self, Envelope.Codes.ALREADY_DONE, "active")
	end
	local spec = self:spec(runtime, userId, "scoutChick")
	local unit = self:_newUnit(characterPosition, false)
	rt.active = true
	rt.units = { unit }
	rt.deployedAt = now
	self:_chickEvent(runtime, userId, unit, { speed = spec.moveSpeed, capacity = spec.capacity })
	track(self, "tool_action", { chapter = runtime.state.chapter, tool = "scoutChick", action = "deploy" }, userId)
	return Envelope.ok({ unitId = unit.id, moveSpeed = spec.moveSpeed, capacity = spec.capacity, grasp = spec.grasp })
end

function ToolService._recallChick(self: ToolService, runtime: any, userId: number, state: any, reason: string)
	local rt = chickRuntime(state)
	if not rt.active then
		return
	end
	for _, unit in ipairs(rt.units) do
		if unit.load > 0 then
			dropBundle(self, runtime, unit.position, unit.load, 0)
		end
		unit.state = "Docked"
		self:_chickEvent(runtime, userId, unit, { reason = reason, removed = true })
	end
	rt.units = {}
	rt.active = false
	track(self, "tool_action", { chapter = runtime.state.chapter, tool = "scoutChick", action = "recall", reason = reason }, userId)
end

local function moveToward(unit: any, target: Vector3, step: number): boolean
	local delta = target - unit.position
	local distance = delta.Magnitude
	if distance <= math.max(step, ARRIVE_STUDS) then
		unit.position = target
		return true
	end
	unit.position = unit.position + delta.Unit * step
	return false
end

function ToolService._tickChick(self: ToolService, runtime: any, userId: number, state: any, dt: number)
	local rt = state.toolRuntime.scoutChick
	if not rt or not rt.active then
		return
	end
	if not state.alive then
		self:_recallChick(runtime, userId, state, "death")
		return
	end
	local spec = self:spec(runtime, userId, "scoutChick")
	local grid = runtime.grid
	local layout = ChapterLayout[runtime.state.chapter]
	local minCorner = ChapterLayout.gridMinCorner(layout, grid.width, grid.depth, grid.cellSize)
	local walkY = layout.chickPathY or layout.nestBaseY
	local sellStation = Vector3.new(layout.sellStation.X, walkY, layout.sellStation.Z)
	local step = spec.moveSpeed * dt
	local remaining = {}
	for _, unit in ipairs(rt.units) do
		local keep = true
		if unit.state == "ToPile" then
			if unit.targetX == nil then
				local cx, cz = PileGrid.cellAt(grid, unit.position.X - minCorner.X, unit.position.Z - minCorner.Z)
				cx = math.clamp(cx, 0, grid.width - 1)
				cz = math.clamp(cz, 0, grid.depth - 1)
				local reach = math.max(grid.width, grid.depth)
				local target = PileGrid.findRichTarget(grid, cx, cz, reach, spec.capacity) or PileGrid.findTarget(grid, cx, cz, reach)
				if not target then
					-- Pile empty: deliver whatever is carried, or dock.
					if unit.load > 0 then
						unit.state = "ToSeller"
					else
						unit.state = "Docked"
						keep = false
					end
					self:_chickEvent(runtime, userId, unit, { removed = not keep })
				else
					unit.targetX, unit.targetZ = target.x, target.z
					local world = ChapterLayout.cellWorldPosition(layout, grid.width, grid.depth, grid.cellSize, target.x, target.z, 0)
					self:_chickEvent(
						runtime,
						userId,
						unit,
						{ targetX = world.X, targetY = world.Y, targetZ = world.Z, speed = spec.moveSpeed }
					)
				end
			end
			if keep and unit.state == "ToPile" and unit.targetX ~= nil then
				local world = ChapterLayout.cellWorldPosition(layout, grid.width, grid.depth, grid.cellSize, unit.targetX, unit.targetZ, 0)
				if moveToward(unit, world, step) then
					unit.state = "Collecting"
					unit.timer = 0
					self:_chickEvent(runtime, userId, unit, { intervalSeconds = spec.collectIntervalSeconds })
				end
			end
		elseif unit.state == "Collecting" then
			unit.timer += dt
			while unit.timer >= spec.collectIntervalSeconds and unit.state == "Collecting" do
				unit.timer -= spec.collectIntervalSeconds
				local cell = PileGrid.findTarget(grid, unit.targetX, unit.targetZ, 1)
				if not cell then
					unit.targetX, unit.targetZ = nil, nil
					unit.state = if unit.load > 0 then "ToSeller" else "ToPile"
					self:_chickEvent(runtime, userId, unit, { speed = spec.moveSpeed })
					break
				end
				local removal = PileGrid.remove(grid, cell, math.min(spec.grasp, spec.capacity - unit.load))
				self._rounds:queueDelta(runtime.state.roundId, removal.index, removal.remaining, removal.mask)
				if removal.remaining == 0 then
					state.contribution.cellsRemoved += 1
				end
				unit.load += removal.removed
				if unit.load >= spec.capacity then
					unit.state = "ToSeller"
					unit.targetX, unit.targetZ = nil, nil
					self:_chickEvent(runtime, userId, unit, {
						targetX = sellStation.X,
						targetY = sellStation.Y,
						targetZ = sellStation.Z,
						speed = spec.moveSpeed,
					})
				end
			end
		elseif unit.state == "ToSeller" then
			if moveToward(unit, sellStation, step) then
				unit.timer = 0
				if self._crateBusy and self._crateBusy() then
					-- The crate is away on its run: perch and wait for it to come back.
					unit.state = "Waiting"
					self:_chickEvent(runtime, userId, unit, {})
				else
					unit.state = "Depositing"
					self:_chickEvent(runtime, userId, unit, { depositSeconds = spec.depositSeconds })
				end
			end
		elseif unit.state == "Waiting" then
			if not (self._crateBusy and self._crateBusy()) then
				unit.state = "Depositing"
				unit.timer = 0
				self:_chickEvent(runtime, userId, unit, { depositSeconds = spec.depositSeconds })
			end
		elseif unit.state == "Depositing" then
			unit.timer += dt
			if self._crateBusy and self._crateBusy() and unit.timer < spec.depositSeconds then
				-- A run started under it: hold the trade until the crate is back.
				unit.state = "Waiting"
				self:_chickEvent(runtime, userId, unit, {})
			elseif unit.timer >= spec.depositSeconds then
				local sale = self:_deposit(runtime, userId, state, unit)
				unit.trips += 1
				rt.trips += 1
				self.stats.chickTrips += 1
				unit.load = 0
				if unit.oneTrip then
					unit.state = "Docked"
					keep = false
					self:_chickEvent(runtime, userId, unit, { removed = true, cents = sale.finalCents })
				else
					unit.state = "ToPile"
					unit.targetX, unit.targetZ = nil, nil
					self:_chickEvent(runtime, userId, unit, { cents = sale.finalCents, speed = spec.moveSpeed })
					-- Automation Expert swarm proc: extra one-trip helpers spawn from the crate.
					if spec.swarmCount > 0 and roll(self) < spec.swarmChance then
						self.stats.swarms += 1
						for _ = 1, spec.swarmCount do
							local helper = self:_newUnit(sellStation, true)
							table.insert(remaining, helper)
							self:_chickEvent(runtime, userId, helper, { speed = spec.moveSpeed, swarm = true })
						end
					end
				end
			end
		end
		if keep then
			table.insert(remaining, unit)
		end
	end
	rt.units = remaining
	if #rt.units == 0 then
		rt.active = false
	end
end

-- Deposits a unit's load at the crate for the owner only (same math as SellingService).
function ToolService._deposit(self: ToolService, runtime: any, userId: number, state: any, unit: any)
	local modifiers = self._collection:modifiers(runtime, userId)
	local sale = EconomyMath.computeSale({ standardCount = unit.load, rainbowCount = 0 }, {
		standardCents = EconomyMath.dollarsToCents(self._config.selling.cashPerStandardFeather),
		rainbowMultiplier = self._config.selling.rainbowFeatherMultiplier,
		classSellMultiplier = modifiers.sellMultiplier,
		perkSellMultiplier = 1,
	})
	local maximumCents = EconomyMath.dollarsToCents(self._config.currencies.cash.maximum)
	state.cashCents = EconomyMath.addBounded(state.cashCents, sale.finalCents, maximumCents)
	state.contribution.feathersCollected += unit.load
	local result = {
		toolId = "scoutChick",
		unitId = unit.id,
		feathers = unit.load,
		finalCents = sale.finalCents,
		cashCents = state.cashCents,
		multiplier = modifiers.sellMultiplier,
	}
	track(
		self,
		"chick_trip",
		{ chapter = runtime.state.chapter, feathers = unit.load, cents = sale.finalCents, oneTrip = unit.oneTrip },
		userId
	)
	track(
		self,
		"sell_completed",
		{ chapter = runtime.state.chapter, feathers = unit.load, cents = sale.finalCents, source = "scoutChick" },
		userId
	)
	self.deposited:Fire(userId, runtime, result)
	return result
end

-- Tick / cleanup ----------------------------------------------------------------------------

function ToolService.tick(self: ToolService): number
	local now = self._clock:monotonic()
	local dt = if self._lastTick then math.clamp(now - self._lastTick, 0, MAX_TICK_SECONDS) else 0
	self._lastTick = now
	self.stats.ticks += 1
	local processed = 0
	for _, runtime in pairs(self._rounds:all()) do
		if not RoundReducer.acceptsGameplay(runtime.state) then
			if next(runtime.charges) ~= nil or next(runtime.bundles) ~= nil then
				self:onRoundEnded(runtime)
			end
			continue
		end
		processed += 1
		-- Charges (explode due ones; minis spawned during this pass wait for the next tick).
		for _, charge in pairs(table.clone(runtime.charges)) do
			if now >= charge.explodeAt then
				self:_explode(runtime, charge, now)
			end
		end
		for userId, state in pairs(runtime.players) do
			self:_tickVac(runtime, userId, state, dt, now)
			self:_tickChick(runtime, userId, state, dt)
			self:_tickTimed(runtime, userId, state, now)
		end
		for _, bundleId in ipairs(RoundAwards.expireBundles(runtime, now)) do
			self.stats.bundlesExpired += 1
			self.event:Fire(runtime.state.roundId, { kind = "bundle_removed", bundleId = bundleId, expired = true })
		end
	end
	return processed
end

-- Death: the vac stops (heat persists), chick units recall (loads become bundles), live charges stay
-- server-owned and still explode (their yield bundles if the owner is dead).
function ToolService.onDeath(self: ToolService, userId: number)
	local runtime = self._rounds:roundOf(userId)
	local state = runtime and runtime.players[userId]
	if not runtime or not state then
		return
	end
	self:_stopVac(runtime, userId, state, "death")
	self:_recallChick(runtime, userId, state, "death")
	self:_revokeAllTimed(runtime, userId, state, "death")
end

function ToolService.onLeave(self: ToolService, userId: number)
	local runtime = self._rounds:roundOf(userId)
	local state = runtime and runtime.players[userId]
	if not runtime or not state then
		return
	end
	self:_stopVac(runtime, userId, state, "left")
	self:_recallChick(runtime, userId, state, "left")
	self:_revokeAllTimed(runtime, userId, state, "left")
end

function ToolService.onRoundEnded(self: ToolService, runtime: any)
	table.clear(runtime.charges)
	table.clear(runtime.bundles)
	for userId, state in pairs(runtime.players) do
		self:_revokeAllTimed(runtime, userId, state, "round_ended")
		table.clear(state.toolRuntime)
	end
end

-- Snapshot of a player's live tool state for debug/verification.
function ToolService.inspect(self: ToolService, userId: number): { [string]: any }?
	local runtime = self._rounds:roundOf(userId)
	local state = runtime and runtime.players[userId]
	if not runtime or not state then
		return nil
	end
	local units = {}
	local chick = state.toolRuntime.scoutChick
	if chick then
		for _, unit in ipairs(chick.units) do
			table.insert(units, { id = unit.id, state = unit.state, load = unit.load, trips = unit.trips, oneTrip = unit.oneTrip })
		end
	end
	local charges = {}
	for _, charge in pairs(runtime.charges) do
		if charge.userId == userId then
			table.insert(charges, { id = charge.id, mini = charge.mini, radius = charge.radiusStuds })
		end
	end
	local bundles = 0
	for _ in pairs(runtime.bundles) do
		bundles += 1
	end
	return {
		equippedTool = state.equippedTool,
		roundTools = table.clone(state.roundTools),
		permanentTools = table.clone(state.permanentTools),
		toolLevels = state.toolLevels,
		vac = state.toolRuntime.featherVac,
		eggSense = state.toolRuntime.eggSense and { remaining = self:timedRemaining(userId, "eggSense") } or nil,
		chick = chick and { active = chick.active, trips = chick.trips, units = units } or nil,
		charges = charges,
		bundles = bundles,
		stats = table.clone(self.stats),
	}
end

return ToolService
