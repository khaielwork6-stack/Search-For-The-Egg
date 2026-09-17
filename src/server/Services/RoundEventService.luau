--!strict
-- The round's one short mid-round event (RoundEvents holds the pure rules). When a round reaches
-- Searching it rolls, once, whether an event happens, which one, and when (a fraction of the round's
-- time limit). At that moment the event starts only if the round is still Searching; otherwise it is
-- cancelled for good. An active event hard-ends after its duration, or as soon as the round leaves
-- Searching (the Egg revealed), and the round never gets a second one.
--
--   Rainbow Rush  converts a capped number of buried standard records into Rainbow Feathers
--                 (`runtime.rainbowOverrides`). Conversions only: nothing is added or removed, the
--                 Egg's surroundings are excluded, and the conversions outlive the Rush.
--   Supply Drop   a crate lands at a preset spot; members deposit NORMAL feathers from their bags
--                 (never from the pile) until it reaches its target; a filled crate pays every
--                 contributor cash by share, floored and capped.
--   Chick Rescue  a trapped chick at a preset spot on the nest's edge; completed holds free it, and
--                 every member who held pays out a small gem reward once.
--
-- Every request is validated here (session, membership, phase, alive, distance, caps); the world
-- models and the broadcast are injected (`world`, `announce`) so the rules run headless in tests.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local PileGrid = require(Shared.Domain.PileGrid)
local FeatherLayout = require(Shared.Domain.FeatherLayout)
local RoundEvents = require(Shared.Domain.RoundEvents)
local EconomyMath = require(Shared.EconomyMath)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)

local RoundEventService = {}
RoundEventService.__index = RoundEventService

export type RoundEventService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_clock: any,
		_rounds: any,
		_sessions: any,
		_rng: any,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_getProfile: (userId: number) -> any?,
		_announce: (runtime: any, payload: { [string]: any }) -> (),
		_nameOf: (userId: number) -> string,
		_world: any?,
		_counter: number,
		event: any, -- (runtime, payload) start / update / end, for the RoundEvent broadcast
		rewarded: any, -- (runtime, userId, reward)
		stats: { planned: number, started: number, cancelled: number, ended: number, rejected: number, conversions: number },
	},
	RoundEventService
))

function RoundEventService.new(options: {
	config: { [string]: any },
	clock: any,
	rounds: any,
	sessions: any,
	rng: any,
	getCharacterPosition: (userId: number) -> Vector3?,
	getProfile: (userId: number) -> any?,
	announce: ((runtime: any, payload: { [string]: any }) -> ())?,
	nameOf: ((userId: number) -> string)?,
	world: any?,
}): RoundEventService
	return setmetatable({
		_config = options.config,
		_clock = options.clock,
		_rounds = options.rounds,
		_sessions = options.sessions,
		_rng = options.rng,
		_getCharacterPosition = options.getCharacterPosition,
		_getProfile = options.getProfile,
		_announce = options.announce or function() end,
		_nameOf = options.nameOf or function()
			return "A forager"
		end,
		_world = options.world,
		_counter = 0,
		event = Signal.new(),
		rewarded = Signal.new(),
		stats = { planned = 0, started = 0, cancelled = 0, ended = 0, rejected = 0, conversions = 0 },
	}, RoundEventService)
end

-- The banner lines. Start and end go to the round; a reward goes to its contributor by name (the
-- announcement path holds an identical line back for a moment, so each one must read differently),
-- and the round-wide "filled" line then goes only to the members who did not contribute.
RoundEventService.ANNOUNCE = table.freeze({
	start = table.freeze({
		rainbowRush = table.freeze({ text = "RAINBOW RUSH!", sub = "Rainbow Feathers are hiding just under the surface", tone = "rainbow" }),
		supplyDrop = table.freeze({ text = "SUPPLY DROP!", sub = "Fill the crate with normal feathers for a cash bonus", tone = "gold" }),
		chickRescue = table.freeze({ text = "CHICK RESCUE!", sub = "Follow the chirps and free the chick for gems", tone = "info" }),
	}),
	completed = table.freeze({
		supplyDrop = table.freeze({ text = "SUPPLY DROP FILLED!", sub = "Contributors earned a cash bonus", tone = "success" }),
		chickRescue = table.freeze({ text = "CHICK RESCUED!", sub = "Rescuers earned gems", tone = "success" }),
	}),
	expired = table.freeze({
		rainbowRush = table.freeze({ text = "RAINBOW RUSH OVER", sub = "The rainbow feathers stay in the nest", tone = "info" }),
		supplyDrop = table.freeze({ text = "SUPPLY DROP MISSED", sub = "The crate was not filled in time", tone = "info" }),
		chickRescue = table.freeze({ text = "CHICK RESCUE OVER", sub = "Nobody freed the chick in time", tone = "info" }),
	}),
	cashReward = "%s earned +%s!",
	cashRewardSub = "Supply Drop bonus",
	gemReward = "%s earned +%d gems!",
	gemRewardSub = "Chick rescued",
})

local function announce(self: RoundEventService, runtime: any, kind: string, line: any, extra: { [string]: any }?)
	local payload: { [string]: any } = { kind = kind, text = line.text, sub = line.sub, tone = line.tone }
	for key, value in pairs(extra or {}) do
		payload[key] = value
	end
	self._announce(runtime, payload)
end

local function reject(self: RoundEventService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

local function roll(self: RoundEventService): () -> number
	return function()
		return self._rng:next()
	end
end

function RoundEventService.project(self: RoundEventService, runtime: any): { [string]: any }?
	return RoundEvents.project(runtime.roundEvent, self._clock:nowMs())
end

local function fire(self: RoundEventService, runtime: any, kind: string, extra: { [string]: any }?)
	local payload: { [string]: any } = {
		type = kind,
		roundId = runtime.state.roundId,
		event = self:project(runtime),
	}
	for key, value in pairs(extra or {}) do
		payload[key] = value
	end
	self.event:Fire(runtime, payload)
end

-- Rolls the round's plan once, the first time the round is seen Searching.
function RoundEventService._plan(self: RoundEventService, runtime: any, now: number)
	local plan = RoundEvents.plan(self._config, roll(self))
	self.stats.planned += 1
	if not plan then
		runtime.roundEvent = { status = "none" }
		return
	end
	runtime.roundEvent = { status = "scheduled", kind = plan.kind, startAt = now + plan.delaySeconds }
end

-- Starts `kind` now on a Searching round. Refuses once the round has had its event.
function RoundEventService.start(self: RoundEventService, runtime: any, kind: string): (boolean, string?)
	if not RoundEvents.isKind(kind) then
		return false, "kind"
	end
	if runtime.state.phase ~= "Searching" then
		return false, "phase"
	end
	local existing = runtime.roundEvent
	if existing and (existing.status == "active" or existing.status == "ended" or existing.status == "cancelled") then
		return false, "already_ran"
	end
	local now = self._clock:monotonic()
	local nowMs = self._clock:nowMs()
	local spec = self._config.roundEvents.events[kind]
	self._counter += 1
	local event: { [string]: any } = {
		id = runtime.state.roundId .. ":" .. tostring(self._counter),
		kind = kind,
		status = "active",
		startedAt = now,
		endAt = now + spec.durationSeconds,
		startedAtMs = nowMs,
		endsAtMs = nowMs + math.floor(spec.durationSeconds * 1000 + 0.5),
		contributors = {},
		rewarded = {},
	}
	local layout = ChapterLayout[runtime.state.chapter]
	if kind == "rainbowRush" then
		local grid = runtime.grid
		local ids = RoundEvents.rushConversions(self._config, grid, runtime, runtime.eggNode.x, runtime.eggNode.z, roll(self))
		runtime.rainbowOverrides = runtime.rainbowOverrides or {}
		for _, id in ipairs(ids) do
			runtime.rainbowOverrides[id] = true
		end
		event.conversions = ids
		event.progress = 0
		event.target = #ids
		self.stats.conversions += #ids
	elseif kind == "supplyDrop" then
		event.position = RoundEvents.pickSpot(spec.spots, self._rng:next())
		event.target = RoundEvents.supplyTarget(self._config, #RoundReducer.presentMembers(runtime.state))
		event.progress = 0
	elseif kind == "chickRescue" then
		event.position = RoundEvents.pickSpot(spec.spots, self._rng:next())
		event.target = RoundEvents.holdsRequired(self._config)
		event.progress = 0
		event.lastHoldAt = {}
	end
	-- A spot is a fixed preset off the pile; the layout is only read to keep that promise.
	if event.position and layout and RoundEvents.onPile(self._config, layout.nestCenter, event.position, 1) then
		return false, "spot_on_pile"
	end
	runtime.roundEvent = event
	self.stats.started += 1
	if self._world then
		self._world:spawn(runtime, event)
	end
	fire(self, runtime, "start", if kind == "rainbowRush" then { rainbowOverrides = table.clone(event.conversions) } else nil)
	announce(self, runtime, "roundEventStart", RoundEventService.ANNOUNCE.start[kind], { position = event.position })
	return true, nil
end

-- Ends the active event. `result` is "completed", "expired" or "interrupted".
function RoundEventService._finish(self: RoundEventService, runtime: any, result: string)
	local event = runtime.roundEvent
	if not event or event.status ~= "active" then
		return
	end
	event.status = "ended"
	event.result = result
	event.endsAtMs = math.min(event.endsAtMs, self._clock:nowMs())
	self.stats.ended += 1
	if self._world then
		self._world:despawn(runtime, event)
	end
	fire(self, runtime, "end")
	if result == "completed" then
		-- Contributors already heard their own reward; everyone else hears that it was done.
		local except = {}
		for contributor in pairs(event.contributors) do
			table.insert(except, contributor)
		end
		local line = RoundEventService.ANNOUNCE.completed[event.kind]
		if line and #except < #RoundReducer.presentMembers(runtime.state) then
			announce(self, runtime, "roundEventEnd", line, { exceptUserIds = except, position = event.position })
		end
	elseif result == "expired" then
		local line = RoundEventService.ANNOUNCE.expired[event.kind]
		if line then
			announce(self, runtime, "roundEventEnd", line)
		end
	end
end

-- Rainbow Rush progress: how many converted records have been collected so far.
local function rushCollected(runtime: any, event: any): number
	local grid = runtime.grid
	local count = 0
	for _, id in ipairs(event.conversions or {}) do
		local index, slot = FeatherLayout.decode(id)
		local cell = index and grid.cells[index]
		if cell and slot and PileGrid.isTaken(cell, slot) then
			count += 1
		end
	end
	return count
end

-- Advances every round's event: plans, starts, cancels, progress and the hard end.
function RoundEventService.tick(self: RoundEventService): number
	local now = self._clock:monotonic()
	local changed = 0
	for _, runtime in pairs(self._rounds:all()) do
		local phase = runtime.state.phase
		local event = runtime.roundEvent
		if not event then
			if phase == "Searching" then
				self:_plan(runtime, now)
				event = runtime.roundEvent
			else
				continue
			end
		end
		if event.status == "scheduled" then
			if phase ~= "Searching" then
				-- The Egg was revealed (or the round ended) before the event's moment: no event.
				event.status = "cancelled"
				self.stats.cancelled += 1
				changed += 1
			elseif now >= event.startAt then
				local ok = self:start(runtime, event.kind)
				if not ok then
					event.status = "cancelled"
					self.stats.cancelled += 1
				end
				changed += 1
			end
		elseif event.status == "active" then
			if phase ~= "Searching" then
				self:_finish(runtime, "interrupted")
				changed += 1
			elseif now >= event.endAt then
				self:_finish(runtime, "expired")
				changed += 1
			elseif event.kind == "rainbowRush" then
				local collected = rushCollected(runtime, event)
				if collected ~= event.progress then
					event.progress = collected
					fire(self, runtime, "update")
					changed += 1
				end
			end
		end
	end
	return changed
end

-- A round going back to the lobby takes its event's world with it.
function RoundEventService.onRoundReturned(self: RoundEventService, runtime: any)
	local event = runtime.roundEvent
	if event and event.status == "active" then
		event.status = "ended"
		event.result = "interrupted"
		self.stats.ended += 1
		if self._world then
			self._world:despawn(runtime, event)
		end
	end
end

-- Shared gate for event requests. Returns (runtime, state, position) or a refusal.
function RoundEventService._gate(
	self: RoundEventService,
	userId: number,
	payload: { [string]: any },
	kind: string,
	options: { trusted: boolean?, characterPosition: Vector3? }?
): (any?, any?, Envelope.Envelope<any>?)
	local runtime = self._rounds:roundOf(userId)
	if not runtime then
		return nil, nil, reject(self, Envelope.Codes.INVALID_STATE, "no_round")
	end
	if not (options and options.trusted) then
		local okToken, tokenErr = self._sessions:validate(userId, payload.sessionToken, "Round")
		if not okToken then
			return nil, nil, reject(self, Envelope.Codes.STALE_TOKEN, tokenErr)
		end
	end
	if not table.find(runtime.state.members, userId) then
		return nil, nil, reject(self, Envelope.Codes.NOT_AUTHORIZED, "not_member")
	end
	if not RoundReducer.acceptsGameplay(runtime.state) then
		return nil, nil, reject(self, Envelope.Codes.INVALID_STATE, "phase")
	end
	local state = runtime.players[userId]
	if not state or not state.alive then
		return nil, nil, reject(self, Envelope.Codes.INVALID_STATE, "not_alive")
	end
	local event = runtime.roundEvent
	if not event or event.status ~= "active" or event.kind ~= kind then
		return nil, nil, reject(self, Envelope.Codes.INVALID_STATE, "no_event")
	end
	if self._clock:monotonic() >= event.endAt then
		return nil, nil, reject(self, Envelope.Codes.INVALID_STATE, "event_over")
	end
	local position = (options and options.characterPosition) or self._getCharacterPosition(userId)
	if not position then
		return nil, nil, reject(self, Envelope.Codes.INVALID_STATE, "no_character")
	end
	local spec = self._config.roundEvents.events[kind]
	local flat = Vector3.new(position.X - event.position.X, 0, position.Z - event.position.Z)
	if flat.Magnitude > spec.rangeStuds then
		return nil, nil, reject(self, Envelope.Codes.OUT_OF_RANGE, "range")
	end
	return runtime, state, nil
end

-- Supply Drop deposit: NORMAL feathers from the caller's bag, at most `depositPerRequest` per call
-- and `depositPerPlayerCap` per player per event, never past the target. `payload` = { sessionToken }.
function RoundEventService.deposit(
	self: RoundEventService,
	userId: number,
	payload: { [string]: any },
	options: { trusted: boolean?, characterPosition: Vector3? }?
): Envelope.Envelope<any>
	local runtime, state, refused = self:_gate(userId, payload, "supplyDrop", options)
	if not runtime then
		return refused :: Envelope.Envelope<any>
	end
	local event = runtime.roundEvent
	local spec = self._config.roundEvents.events.supplyDrop
	local mine = event.contributors[userId] or 0
	if event.progress >= event.target then
		return reject(self, Envelope.Codes.ALREADY_DONE, "filled")
	end
	if mine >= spec.depositPerPlayerCap then
		return reject(self, Envelope.Codes.ALREADY_DONE, "player_cap")
	end
	if state.carriedStandard <= 0 then
		return reject(self, Envelope.Codes.INSUFFICIENT_FUNDS, "no_feathers")
	end
	local amount = math.min(state.carriedStandard, spec.depositPerRequest, spec.depositPerPlayerCap - mine, event.target - event.progress)
	-- One step, no yield: the feathers leave the bag and land in the crate together. Rainbow Feathers
	-- are never read.
	state.carriedStandard -= amount
	event.contributors[userId] = mine + amount
	event.progress += amount
	local filled = event.progress >= event.target
	local rewards: { [number]: number } = {}
	if filled then
		rewards = RoundEvents.supplyRewards(self._config, event.contributors, event.target)
		local maximumCents = EconomyMath.dollarsToCents(self._config.currencies.cash.maximum)
		for contributor, cents in pairs(rewards) do
			local contributorState = runtime.players[contributor]
			if contributorState and not event.rewarded[contributor] then
				event.rewarded[contributor] = true
				contributorState.cashCents = EconomyMath.addBounded(contributorState.cashCents, cents, maximumCents)
				local reward = { kind = "cash", cents = cents, cashCents = contributorState.cashCents }
				self.rewarded:Fire(runtime, contributor, reward)
				announce(self, runtime, "roundEventReward", {
					text = string.format(RoundEventService.ANNOUNCE.cashReward, self._nameOf(contributor), EconomyMath.formatCents(cents)),
					sub = RoundEventService.ANNOUNCE.cashRewardSub,
					tone = "gold",
				}, { userId = contributor, position = event.position })
			end
		end
	end
	fire(self, runtime, "update")
	if filled then
		self:_finish(runtime, "completed")
	end
	return Envelope.ok({
		deposited = amount,
		mine = event.contributors[userId],
		progress = event.progress,
		target = event.target,
		filled = filled,
		carriedStandard = state.carriedStandard,
		rewardCents = rewards[userId],
	})
end

-- Chick Rescue hold: one completed hold per `holdSeconds` per player; the chick is freed at
-- `holdsRequired` holds and every member who held is paid `gemReward` once. `payload` = { sessionToken }.
function RoundEventService.rescue(
	self: RoundEventService,
	userId: number,
	payload: { [string]: any },
	options: { trusted: boolean?, characterPosition: Vector3? }?
): Envelope.Envelope<any>
	local runtime, _state, refused = self:_gate(userId, payload, "chickRescue", options)
	if not runtime then
		return refused :: Envelope.Envelope<any>
	end
	local event = runtime.roundEvent
	local spec = self._config.roundEvents.events.chickRescue
	local now = self._clock:monotonic()
	local last = event.lastHoldAt[userId]
	if last and now - last < spec.holdSeconds then
		return reject(self, Envelope.Codes.RATE_LIMITED, "hold")
	end
	event.lastHoldAt[userId] = now
	event.contributors[userId] = (event.contributors[userId] or 0) + 1
	event.progress += 1
	local freed = event.progress >= event.target
	local gems = nil
	if freed then
		local maximum = self._config.currencies.gems.maximum
		for contributor in pairs(event.contributors) do
			if event.rewarded[contributor] then
				continue
			end
			event.rewarded[contributor] = true
			local profile = self._getProfile(contributor)
			if not profile or not profile:isActive() then
				continue
			end
			local granted = spec.gemReward
			profile:update(function(data)
				local balance, added = EconomyMath.addBounded(data.currencies.gems, spec.gemReward, maximum)
				data.currencies.gems = balance
				granted = added
			end)
			if contributor == userId then
				gems = granted
			end
			self.rewarded:Fire(runtime, contributor, { kind = "gems", gems = granted })
			announce(self, runtime, "roundEventReward", {
				text = string.format(RoundEventService.ANNOUNCE.gemReward, self._nameOf(contributor), granted),
				sub = RoundEventService.ANNOUNCE.gemRewardSub,
				tone = "gold",
			}, { userId = contributor, position = event.position })
		end
	end
	fire(self, runtime, "update")
	if freed then
		self:_finish(runtime, "completed")
	end
	return Envelope.ok({ progress = event.progress, target = event.target, freed = freed, gems = gems })
end

-- Request dispatch for the RoundEventAction remote. `payload` = { sessionToken, action }.
function RoundEventService.action(self: RoundEventService, userId: number, payload: { [string]: any }): Envelope.Envelope<any>
	if payload.action == "deposit" then
		return self:deposit(userId, payload)
	elseif payload.action == "rescue" then
		return self:rescue(userId, payload)
	end
	return reject(self, Envelope.Codes.INVALID_PAYLOAD, "action")
end

return RoundEventService
