--!nocheck
-- The round's one mid-round event through the real services: the plan and its window, one event per
-- round, cancellation after a reveal, Rainbow Rush conversions (buried standard records only, the count
-- unchanged, capped, away from the Egg, and honoured by the award), Supply Drop deposits from bags with
-- caps, target and the cash split, Chick Rescue holds with distance and once-per-player gems, spots
-- off the pile, and an Egg that never moves.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Server = game:GetService("ServerScriptService").Server
	local Config = require(Shared.Config)
	local WeightedRandom = require(Shared.WeightedRandom)
	local PileGrid = require(Shared.Domain.PileGrid)
	local PileSurface = require(Shared.Domain.PileSurface)
	local FeatherLayout = require(Shared.Domain.FeatherLayout)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local RoundEvents = require(Shared.Domain.RoundEvents)
	local RoundEventService = require(Server.Services.RoundEventService)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local events = cfg.roundEvents
	local layout = ChapterLayout.chapter1

	-- An RNG that answers `values` first, then a seeded sequence.
	local function scripted(values, seed)
		local fallback = WeightedRandom.fromSeed(seed or 5)
		local i = 0
		return WeightedRandom.fromFunction(function()
			i += 1
			local value = values[i]
			if value ~= nil then
				return value
			end
			return fallback:next()
		end)
	end

	local function ofKind(announced, kind)
		local out = {}
		for _, payload in ipairs(announced) do
			if payload.kind == kind then
				table.insert(out, payload)
			end
		end
		return out
	end

	-- Kind rolls for equal weights in KINDS order.
	local KIND_ROLL = { rainbowRush = 0.1, supplyDrop = 0.5, chickRescue = 0.9 }

	local function setup(members, rngValues, options)
		local h = GameplayHarness.new(cfg, options)
		for _, userId in ipairs(members) do
			h.join(userId)
		end
		local roundId, runtime = h.startRound(members)
		local announced = {}
		local fired = {}
		local service = RoundEventService.new({
			config = cfg,
			clock = h.clock,
			rounds = h.rounds,
			sessions = h.sessions,
			rng = scripted(rngValues or {}),
			getCharacterPosition = function(userId)
				return h.positions[userId]
			end,
			getProfile = function(userId)
				return h.profiles:get(userId)
			end,
			announce = function(_runtime, payload)
				table.insert(announced, payload)
			end,
			nameOf = function(userId)
				return "P" .. tostring(userId)
			end,
		})
		service.event:Connect(function(_runtime, payload)
			table.insert(fired, payload)
		end)
		return h, roundId, runtime, service, announced, fired
	end

	-- Plans `kind` on the first tick and runs the clock to its start.
	local function runTo(h, runtime, service)
		service:tick()
		local plan = runtime.roundEvent
		h.clock:advance(math.max(0, plan.startAt - h.clock:monotonic()))
		service:tick()
		return runtime.roundEvent
	end

	local function eggSnapshot(h, runtime)
		return {
			id = runtime.eggNode.id,
			x = runtime.eggNode.x,
			z = runtime.eggNode.z,
			slot = runtime.eggSlot,
			position = h.egg:position(runtime),
		}
	end

	local function expectEggUnchanged(h, runtime, before)
		expect(runtime.eggNode.id).toBe(before.id)
		expect(runtime.eggNode.x).toBe(before.x)
		expect(runtime.eggNode.z).toBe(before.z)
		expect(runtime.eggSlot).toBe(before.slot)
		expect((h.egg:position(runtime) - before.position).Magnitude).toBeLessThan(1e-6)
	end

	describe("the plan", function()
		it("rolls chance, kind and a start inside the window of the round's time limit", function()
			local limit = RoundEvents.roundSeconds(cfg)
			expect(limit).toBe(cfg.round.maximumRoundSeconds)
			local values = { 0.2, 0.5, 0 }
			local i = 0
			local plan = RoundEvents.plan(cfg, function()
				i += 1
				return values[i]
			end)
			expect(plan.kind).toBe("supplyDrop")
			expect(plan.delaySeconds).toBeCloseTo(events.startFraction[1] * limit, 1e-6)
			local late = { 0.2, 0.9, 0.999999 }
			i = 0
			plan = RoundEvents.plan(cfg, function()
				i += 1
				return late[i]
			end)
			expect(plan.kind).toBe("chickRescue")
			expect(plan.delaySeconds).toBeLessThanOrEqual(events.startFraction[2] * limit)
			local none = { events.chance, 0.1, 0.1 }
			i = 0
			expect(RoundEvents.plan(cfg, function()
				i += 1
				return none[i]
			end)).toBeNil()
		end)

		it("is deterministic from the injected RNG", function()
			local a = RoundEvents.plan(cfg, function()
				return 0.3
			end)
			local b = RoundEvents.plan(cfg, function()
				return 0.3
			end)
			expect(a.kind).toBe(b.kind)
			expect(a.delaySeconds).toBe(b.delaySeconds)
		end)
	end)

	describe("one event per round", function()
		it("starts at its moment, hard-ends after its duration, and never runs a second", function()
			local h, _, runtime, service = setup({ 1 }, { 0.1, KIND_ROLL.chickRescue, 0.5 })
			service:tick()
			expect(runtime.roundEvent.status).toBe("scheduled")
			h.clock:advance(runtime.roundEvent.startAt - h.clock:monotonic() - 1)
			service:tick()
			expect(runtime.roundEvent.status).toBe("scheduled")
			h.clock:advance(1)
			service:tick()
			expect(runtime.roundEvent.status).toBe("active")
			expect(runtime.roundEvent.kind).toBe("chickRescue")
			h.clock:advance(events.events.chickRescue.durationSeconds)
			service:tick()
			expect(runtime.roundEvent.status).toBe("ended")
			expect(runtime.roundEvent.result).toBe("expired")
			for _ = 1, 20 do
				h.clock:advance(120)
				service:tick()
			end
			expect(service.stats.started).toBe(1)
			expect(service.stats.planned).toBe(1)
			for _, kind in ipairs(RoundEvents.KINDS) do
				local ok, err = service:start(runtime, kind)
				expect(ok).toBe(false)
				expect(err).toBe("already_ran")
			end
		end)

		it("a round that rolled no event stays without one", function()
			local h, _, runtime, service = setup({ 1 }, { 0.99, 0.1, 0.1 })
			service:tick()
			expect(runtime.roundEvent.status).toBe("none")
			for _ = 1, 20 do
				h.clock:advance(120)
				service:tick()
			end
			expect(service.stats.started).toBe(0)
			expect(service.stats.planned).toBe(1)
		end)

		it("is cancelled when the Egg is revealed before its moment", function()
			local h, _, runtime, service, _, fired = setup({ 1 }, { 0.1, KIND_ROLL.supplyDrop, 0.2 })
			service:tick()
			expect(runtime.roundEvent.status).toBe("scheduled")
			expect(h.egg:revealNow(runtime)).toBe(true)
			h.clock:advance(runtime.roundEvent.startAt - h.clock:monotonic() + 1)
			service:tick()
			expect(runtime.roundEvent.status).toBe("cancelled")
			expect(service.stats.started).toBe(0)
			expect(#fired).toBe(0)
			expect(service:start(runtime, "supplyDrop")).toBe(false)
		end)

		it("an active event ends the moment the Egg is revealed", function()
			local h, _, runtime, service = setup({ 1 }, { 0.1, KIND_ROLL.chickRescue, 0.2 })
			runTo(h, runtime, service)
			expect(runtime.roundEvent.status).toBe("active")
			h.egg:revealNow(runtime)
			service:tick()
			expect(runtime.roundEvent.status).toBe("ended")
			expect(runtime.roundEvent.result).toBe("interrupted")
		end)

		it("projects nothing while scheduled and never carries the Egg", function()
			local h, roundId, runtime, service = setup({ 1 }, { 0.1, KIND_ROLL.supplyDrop, 0.2 })
			service:tick()
			expect(h.rounds:project(roundId, false).event).toBeNil()
			runTo(h, runtime, service)
			local projection = h.rounds:project(roundId, true).event
			expect(projection.kind).toBe("supplyDrop")
			expect(projection.name).toBe("SUPPLY DROP")
			expect(projection.target).toBe(RoundEvents.supplyTarget(cfg, 1))
			for key in pairs(projection) do
				expect(string.find(string.lower(key), "egg", 1, true)).toBeNil()
			end
		end)
	end)

	describe("Rainbow Rush", function()
		local function rush(options)
			local h, roundId, runtime, service, announced, fired = setup({ 1 }, { 0.1, KIND_ROLL.rainbowRush, 0.2 }, options)
			local grid = runtime.grid
			local before = {
				total = grid.total,
				removed = grid.removed,
				remaining = 0,
				rainbow = 0,
				egg = eggSnapshot(h, runtime),
			}
			for _, cell in ipairs(grid.cells) do
				before.remaining += cell.remaining
				for slot = 1, cell.base do
					if FeatherLayout.isRainbowRecord(cfg, runtime, cell.index, slot) then
						before.rainbow += 1
					end
				end
			end
			runTo(h, runtime, service)
			return h, roundId, runtime, service, before, announced, fired
		end

		it("converts only buried standard records, within the cap, and the count never changes", function()
			local h, _, runtime, service, before = rush()
			local grid = runtime.grid
			local event = runtime.roundEvent
			expect(event.status).toBe("active")
			local ids = event.conversions
			expect(#ids).toBeGreaterThan(0)
			expect(#ids).toBeLessThanOrEqual(events.events.rainbowRush.maxConversions)
			local heights = PileSurface.cellHeights(cfg, grid.width, grid.depth, grid.cellSize, grid.cells)
			local minSlots = cfg.pile.visual.visibleSlotsPerCell
			local cellsUsed = {}
			for _, id in ipairs(ids) do
				local index, slot = FeatherLayout.decode(id)
				local cell = grid.cells[index]
				expect(PileGrid.isTaken(cell, slot)).toBe(false)
				-- Standard before the Rush: the seeded roll says no.
				expect(FeatherLayout.isRainbow(cfg, runtime.rainbowSeed, index, slot)).toBe(false)
				expect(FeatherLayout.isRainbowRecord(cfg, runtime, index, slot)).toBe(true)
				-- Buried: not among the records the server accepts a pick from.
				local window = math.max(
					PileSurface.coatSlots(cfg, grid.width, grid.depth, grid.cellSize, cell.x, cell.z, cell.base, minSlots),
					PileSurface.coatSlotsAt(cfg, grid.width, grid.depth, grid.cellSize, heights, cell.x, cell.z, cell.base, minSlots)
				)
				expect(table.find(FeatherLayout.exposedSlots(cell.base, cell.taken, window), slot)).toBeNil()
				expect(cellsUsed[index]).toBeNil()
				cellsUsed[index] = true
			end
			-- Conversions only: nothing added, nothing removed, rainbow count up by exactly the conversions.
			local remaining, rainbow = 0, 0
			for _, cell in ipairs(grid.cells) do
				remaining += cell.remaining
				for slot = 1, cell.base do
					if FeatherLayout.isRainbowRecord(cfg, runtime, cell.index, slot) then
						rainbow += 1
					end
				end
			end
			expect(grid.total).toBe(before.total)
			expect(grid.removed).toBe(before.removed)
			expect(remaining).toBe(before.remaining)
			expect(rainbow).toBe(before.rainbow + #ids)
			expectEggUnchanged(h, runtime, before.egg)
			expect(service.stats.conversions).toBe(#ids)
		end)

		it("keeps every conversion outside the Egg exclusion and spread over the nest", function()
			local _, _, runtime = rush()
			local grid = runtime.grid
			local exclusion = events.events.rainbowRush.eggExclusionStuds
			local quadrants = {}
			for _, id in ipairs(runtime.roundEvent.conversions) do
				local index = FeatherLayout.decode(id)
				local cell = grid.cells[index]
				local dx = (cell.x - runtime.eggNode.x) * grid.cellSize
				local dz = (cell.z - runtime.eggNode.z) * grid.cellSize
				expect(math.sqrt(dx * dx + dz * dz)).toBeGreaterThan(exclusion)
				quadrants[(if cell.x < grid.width / 2 then 0 else 1) + (if cell.z < grid.depth / 2 then 0 else 2)] = true
			end
			local count = 0
			for _ in pairs(quadrants) do
				count += 1
			end
			expect(count).toBe(4)
		end)

		it("respects the cap exactly when candidates are plentiful", function()
			local _, _, runtime = rush()
			local cap = events.events.rainbowRush.maxConversions
			local grid = runtime.grid
			local more = RoundEvents.rushConversions(cfg, grid, runtime, runtime.eggNode.x, runtime.eggNode.z, function()
				return 0.42
			end)
			expect(#more).toBe(cap)
		end)

		it("replicates the overrides, pays a converted record as rainbow, and keeps them after the Rush", function()
			local h, roundId, runtime, service, _, _, fired = rush()
			local ids = runtime.roundEvent.conversions
			expect(fired[1].type).toBe("start")
			expect(#fired[1].rainbowOverrides).toBe(#ids)
			local snapshot = h.rounds:project(roundId, true)
			expect(#snapshot.pile.rainbowOverrides).toBe(#ids)
			-- Dig one converted record's column down to it and pick it by hand.
			local index, slot = FeatherLayout.decode(ids[1])
			local cell = runtime.grid.cells[index]
			for above = cell.base, slot + 1, -1 do
				PileGrid.removeFeather(runtime.grid, cell, above)
			end
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = 0, 0
			local result = h.collectAt(1, runtime, cell.x, cell.z, "hand")
			expect(result.ok).toBe(true)
			expect(result.data.featherId).toBe(ids[1])
			expect(result.data.rainbow).toBe(1)
			expect(state.carriedRainbow).toBe(1)
			service:tick()
			expect(runtime.roundEvent.progress).toBe(1)
			h.clock:advance(events.events.rainbowRush.durationSeconds)
			service:tick()
			expect(runtime.roundEvent.status).toBe("ended")
			for _, id in ipairs(ids) do
				expect(runtime.rainbowOverrides[id]).toBe(true)
			end
		end)
	end)

	describe("Supply Drop", function()
		local function drop(members)
			local h, roundId, runtime, service, announced, fired = setup(members, { 0.1, KIND_ROLL.supplyDrop, 0.2, 0 })
			local egg = eggSnapshot(h, runtime)
			runTo(h, runtime, service)
			local event = runtime.roundEvent
			for _, userId in ipairs(members) do
				h.standAt(userId, event.position + Vector3.new(2, 3, 0))
			end
			local function deposit(userId)
				return service:deposit(userId, { sessionToken = h.token(userId) })
			end
			return h, roundId, runtime, service, deposit, announced, egg, fired
		end

		it("lands on a preset spot off the pile, scaled to the players present", function()
			local _, _, runtime = drop({ 1, 2 })
			local event = runtime.roundEvent
			expect(RoundEvents.onPile(cfg, layout.nestCenter, event.position, 2)).toBe(false)
			local spot = events.events.supplyDrop.spots[1]
			expect(event.position.X).toBe(spot[1])
			expect(event.position.Z).toBe(spot[3])
			expect(event.target).toBe(RoundEvents.supplyTarget(cfg, 2))
			expect(event.target).toBeGreaterThan(RoundEvents.supplyTarget(cfg, 1))
		end)

		it("takes normal feathers from the bag, never rainbow and never the pile, per request", function()
			local _, _, runtime, service, deposit = drop({ 1 })
			local state = runtime.players[1]
			local removedBefore = runtime.grid.removed
			state.carriedStandard, state.carriedRainbow = 80, 5
			local result = deposit(1)
			expect(result.ok).toBe(true)
			local perRequest = events.events.supplyDrop.depositPerRequest
			expect(result.data.deposited).toBe(perRequest)
			expect(state.carriedStandard).toBe(80 - perRequest)
			expect(state.carriedRainbow).toBe(5)
			expect(runtime.grid.removed).toBe(removedBefore)
			expect(runtime.roundEvent.progress).toBe(perRequest)
			state.carriedStandard = 0
			local empty = deposit(1)
			expect(empty.ok).toBe(false)
			expect(empty.code).toBe("insufficient_funds")
			expect(service.stats.rejected).toBe(1)
		end)

		it("refuses a stale token, a stranger, distance, and an event of another kind", function()
			local h, _, runtime, service, deposit = drop({ 1 })
			runtime.players[1].carriedStandard = 40
			expect(service:deposit(1, { sessionToken = "nope-nope" }).code).toBe("stale_token")
			expect(service:rescue(1, { sessionToken = h.token(1) }).message).toBe("no_event")
			h.standAt(1, runtime.roundEvent.position + Vector3.new(events.events.supplyDrop.rangeStuds + 1, 0, 0))
			expect(deposit(1).code).toBe("out_of_range")
			h.join(9)
			expect(service:deposit(9, { sessionToken = "abcdefghij" }).code).toBe("invalid_state")
			expect(runtime.players[1].carriedStandard).toBe(40)
			expect(runtime.roundEvent.progress).toBe(0)
		end)

		it("caps each player, stops at the target and pays cash by share within floor and cap", function()
			local h, _, runtime, service, deposit, announced, egg = drop({ 1, 2 })
			local spec = events.events.supplyDrop
			local event = runtime.roundEvent
			local p1, p2 = runtime.players[1], runtime.players[2]
			p1.carriedStandard, p2.carriedStandard = 1000, 1000
			local cash1, cash2 = p1.cashCents, p2.cashCents
			local given = 0
			while true do
				local result = deposit(1)
				if not result.ok then
					expect(result.message).toBe("player_cap")
					break
				end
				given += result.data.deposited
			end
			expect(given).toBe(math.min(spec.depositPerPlayerCap, event.target))
			expect(p1.cashCents).toBe(cash1) -- nothing paid before the crate is full
			local filled
			while true do
				local result = deposit(2)
				expect(result.ok).toBe(true)
				if result.data.filled then
					filled = result
					break
				end
			end
			expect(event.progress).toBe(event.target)
			expect(event.status).toBe("ended")
			expect(event.result).toBe("completed")
			local rewards = RoundEvents.supplyRewards(cfg, event.contributors, event.target)
			expect(p1.cashCents - cash1).toBe(rewards[1])
			expect(p2.cashCents - cash2).toBe(rewards[2])
			expect(filled.data.rewardCents).toBe(rewards[2])
			for _, cents in pairs(rewards) do
				expect(cents).toBeGreaterThanOrEqual(spec.rewardFloorCents)
				expect(cents).toBeLessThanOrEqual(spec.rewardCapCents)
			end
			-- One start line for the round, one named reward per contributor, and no round-wide "filled"
			-- line because every present member contributed.
			expect(#ofKind(announced, "roundEventStart")).toBe(1)
			local lines = ofKind(announced, "roundEventReward")
			expect(#lines).toBe(2)
			expect(lines[1].userId ~= nil).toBe(true)
			expect(lines[1].text).never.toBe(lines[2].text)
			expect(#ofKind(announced, "roundEventEnd")).toBe(0)
			-- A larger share never pays less.
			if event.contributors[1] > event.contributors[2] then
				expect(rewards[1]).toBeGreaterThanOrEqual(rewards[2])
			end
			expect(deposit(1).message).toBe("no_event")
			expectEggUnchanged(h, runtime, egg)
			expect(service.stats.started).toBe(1)
		end)

		it("splits proportionally and clamps to the floor and cap", function()
			local spec = events.events.supplyDrop
			local target = spec.target * 4
			local rewards = RoundEvents.supplyRewards(cfg, { [1] = target - 1, [2] = 1, [3] = 0 }, target)
			expect(rewards[1]).toBe(spec.rewardCapCents)
			expect(rewards[2]).toBe(spec.rewardFloorCents)
			expect(rewards[3]).toBeNil()
			local even = RoundEvents.supplyRewards(cfg, { [1] = 60, [2] = 60 }, 120)
			expect(even[1]).toBe(even[2])
			expect(even[1]).toBe(
				math.clamp(math.floor(spec.rewardPoolCents * 120 / spec.target / 2 + 0.5), spec.rewardFloorCents, spec.rewardCapCents)
			)
		end)

		it("pays nothing when the crate is not filled in time", function()
			local h, _, runtime, service, deposit, announced = drop({ 1 })
			local state = runtime.players[1]
			state.carriedStandard = 30
			local cash = state.cashCents
			expect(deposit(1).ok).toBe(true)
			h.clock:advance(events.events.supplyDrop.durationSeconds)
			service:tick()
			expect(runtime.roundEvent.status).toBe("ended")
			expect(runtime.roundEvent.result).toBe("expired")
			expect(state.cashCents).toBe(cash)
			expect(state.carriedStandard).toBe(0)
			expect(#ofKind(announced, "roundEventReward")).toBe(0)
			expect(ofKind(announced, "roundEventEnd")[1].text).toBe(RoundEventService.ANNOUNCE.expired.supplyDrop.text)
			state.carriedStandard = 30
			expect(deposit(1).ok).toBe(false)
		end)
	end)

	describe("Chick Rescue", function()
		local function chick(members, options)
			local h, roundId, runtime, service, announced = setup(members, { 0.1, KIND_ROLL.chickRescue, 0.2, 0.6 }, options)
			local egg = eggSnapshot(h, runtime)
			runTo(h, runtime, service)
			local event = runtime.roundEvent
			for _, userId in ipairs(members) do
				h.standAt(userId, event.position + Vector3.new(0, 3, 3))
			end
			local function rescue(userId)
				return service:rescue(userId, { sessionToken = h.token(userId) })
			end
			return h, roundId, runtime, service, rescue, announced, egg
		end

		it("every preset spot sits off the pile, at the nest edge", function()
			for _, kind in ipairs({ "supplyDrop", "chickRescue" }) do
				for _, spot in ipairs(events.events[kind].spots) do
					local position = Vector3.new(spot[1], spot[2], spot[3])
					expect(RoundEvents.onPile(cfg, layout.nestCenter, position, 2)).toBe(false)
					expect((Vector3.new(position.X, 0, position.Z) - Vector3.new(layout.nestCenter.X, 0, layout.nestCenter.Z)).Magnitude).toBeLessThan(
						40
					)
				end
			end
		end)

		it("chooses its spot independently of where the Egg is", function()
			local runtimes = {}
			local eggs = {}
			for seed = 11, 60 do
				local _, _, runtime = chick({ 1 }, { seed = seed * 7919 * 104729 })
				if not eggs[runtime.eggNode.id] then
					eggs[runtime.eggNode.id] = true
					table.insert(runtimes, runtime)
				end
				if #runtimes >= 3 then
					break
				end
			end
			-- Rounds whose Eggs lie in different places draw the same spot from the same roll.
			expect(#runtimes).toBeGreaterThanOrEqual(2)
			for _, runtime in ipairs(runtimes) do
				expect(runtime.roundEvent.position).toBe(runtimes[1].roundEvent.position)
			end
		end)

		it("validates distance and paces holds per player", function()
			local h, _, runtime, service, rescue = chick({ 1 })
			h.standAt(1, runtime.roundEvent.position + Vector3.new(events.events.chickRescue.rangeStuds + 0.5, 0, 0))
			local far = rescue(1)
			expect(far.code).toBe("out_of_range")
			expect(runtime.roundEvent.progress).toBe(0)
			h.standAt(1, runtime.roundEvent.position + Vector3.new(1, 0, 0))
			expect(rescue(1).ok).toBe(true)
			local quick = rescue(1)
			expect(quick.code).toBe("rate_limited")
			expect(runtime.roundEvent.progress).toBe(1)
			expect(service:deposit(1, { sessionToken = h.token(1) }).message).toBe("no_event")
		end)

		it("frees the chick and pays every contributor gems exactly once", function()
			local h, _, runtime, service, rescue, announced, egg = chick({ 1, 2 })
			local spec = events.events.chickRescue
			local gems1 = h.profile(1).data.currencies.gems
			local gems2 = h.profile(2).data.currencies.gems
			expect(rescue(1).ok).toBe(true)
			expect(rescue(2).ok).toBe(true)
			h.clock:advance(spec.holdSeconds)
			local last
			for _ = 3, spec.holdsRequired do
				last = rescue(1)
				expect(last.ok).toBe(true)
				h.clock:advance(spec.holdSeconds)
			end
			expect(last.data.freed).toBe(true)
			expect(last.data.gems).toBe(spec.gemReward)
			expect(runtime.roundEvent.result).toBe("completed")
			expect(h.profile(1).data.currencies.gems - gems1).toBe(spec.gemReward)
			expect(h.profile(2).data.currencies.gems - gems2).toBe(spec.gemReward)
			local lines = ofKind(announced, "roundEventReward")
			expect(#lines).toBe(2)
			expect(lines[1].text).never.toBe(lines[2].text)
			local again = rescue(2)
			expect(again.ok).toBe(false)
			expect(h.profile(2).data.currencies.gems - gems2).toBe(spec.gemReward)
			expectEggUnchanged(h, runtime, egg)
			expect(service.stats.started).toBe(1)
		end)

		it("every contributor's reward line survives the announcement path's repeat hold", function()
			local AnnouncementService = require(Server.Services.AnnouncementService)
			local h, _, runtime, service = chick({ 1, 2 })
			local delivered = {}
			local announcements = AnnouncementService.new({
				send = function(player, remote, payload)
					table.insert(delivered, { userId = player.UserId, remote = remote, payload = payload })
				end,
				getPlayers = function()
					return {}
				end,
				clock = h.clock,
			})
			-- The same routing init.server applies: a reward to its contributor only.
			service._announce = function(_runtime, payload)
				local recipients = {}
				for _, userId in ipairs(runtime.state.members) do
					if (payload.userId == nil or payload.userId == userId) and not table.find(payload.exceptUserIds or {}, userId) then
						table.insert(recipients, GameplayHarness.fakePlayer(userId))
					end
				end
				announcements:announce(recipients, payload)
			end
			local spec = events.events.chickRescue
			expect(service:rescue(1, { sessionToken = h.token(1) }).ok).toBe(true)
			expect(service:rescue(2, { sessionToken = h.token(2) }).ok).toBe(true)
			h.clock:advance(spec.holdSeconds)
			for _ = 3, spec.holdsRequired do
				expect(service:rescue(1, { sessionToken = h.token(1) }).ok).toBe(true)
				h.clock:advance(spec.holdSeconds)
			end
			local rewardsFor = {}
			for _, entry in ipairs(delivered) do
				expect(entry.remote).toBe("Announcement")
				if entry.payload.kind == "roundEventReward" then
					rewardsFor[entry.userId] = (rewardsFor[entry.userId] or 0) + 1
				end
			end
			expect(rewardsFor[1]).toBe(1)
			expect(rewardsFor[2]).toBe(1)
			expect(announcements.stats.suppressed).toBe(0)
		end)

		it("pays nobody when the chick is not freed in time", function()
			local h, _, runtime, service, rescue, announced = chick({ 1 })
			local gems = h.profile(1).data.currencies.gems
			expect(rescue(1).ok).toBe(true)
			h.clock:advance(events.events.chickRescue.durationSeconds)
			service:tick()
			expect(runtime.roundEvent.result).toBe("expired")
			expect(h.profile(1).data.currencies.gems).toBe(gems)
			expect(#ofKind(announced, "roundEventReward")).toBe(0)
			expect(#ofKind(announced, "roundEventEnd")).toBe(1)
		end)

		it("tells the members who did not help that it was done", function()
			local h, _, runtime, _, rescue, announced = chick({ 1, 2 })
			h.standAt(2, runtime.roundEvent.position + Vector3.new(30, 0, 30))
			local spec = events.events.chickRescue
			for _ = 1, spec.holdsRequired do
				expect(rescue(1).ok).toBe(true)
				h.clock:advance(spec.holdSeconds)
			end
			local done = ofKind(announced, "roundEventEnd")
			expect(#done).toBe(1)
			expect(done[1].text).toBe(RoundEventService.ANNOUNCE.completed.chickRescue.text)
			expect(table.find(done[1].exceptUserIds, 1) ~= nil).toBe(true)
			expect(table.find(done[1].exceptUserIds, 2)).toBeNil()
			expect(#ofKind(announced, "roundEventReward")).toBe(1)
		end)
	end)

	describe("config and net", function()
		it("keeps durations within 30-45 seconds and declares the placeholder chirp", function()
			for _, kind in ipairs(RoundEvents.KINDS) do
				local seconds = events.events[kind].durationSeconds
				expect(seconds >= 30 and seconds <= 45).toBe(true)
			end
			local chirp = cfg.audio.roles["event.chirp"]
			expect(chirp).toBeTruthy()
			expect(chirp.evidence).toBe("PLACEHOLDER - owner to replace")
		end)

		it("the action remote names only an action", function()
			local NetSchema = require(Shared.Net.NetSchema)
			local Schema = require(Shared.Net.Schema)
			local registry = NetSchema.build(cfg)
			local request = registry.byName.RoundEventAction
			local token = string.rep("a", 16)
			expect(Schema.validate(request.payload, { sessionToken = token, action = "deposit" }).ok).toBe(true)
			expect(Schema.validate(request.payload, { sessionToken = token, action = "rescue" }).ok).toBe(true)
			expect(Schema.validate(request.payload, { sessionToken = token, action = "claim" }).ok).toBe(false)
			expect(Schema.validate(request.payload, { sessionToken = token, action = "deposit", amount = 500 }).ok).toBe(false)
			expect(registry.byName.RoundEvent.direction).toBe("serverToClient")
		end)
	end)
end
