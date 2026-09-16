--!nocheck
-- Professor Plume's trade through the real services: validation, the atomic deduction, the party
-- share, truthfulness against the live Egg, and the reset between rounds.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local NestClues = require(Shared.Domain.NestClues)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1
	local costs = cfg.clues.costsRainbow

	local function setup(members, options)
		local h = GameplayHarness.new(cfg, options)
		for _, userId in ipairs(members) do
			h.join(userId)
		end
		local roundId, runtime = h.startRound(members)
		for _, userId in ipairs(members) do
			h.standAt(userId, layout.clueStation + Vector3.new(0, 0, 3))
		end
		return h, roundId, runtime
	end

	describe("validation", function()
		it("refuses without enough unsold Rainbow Feathers and consumes nothing", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = 9, costs[1] - 1
			local result = h.analyze(1, "direction")
			expect(result.ok).toBe(false)
			expect(result.code).toBe("insufficient_funds")
			expect(state.carriedRainbow).toBe(costs[1] - 1)
			expect(state.carriedStandard).toBe(9)
			expect(h.clues:project(runtime).count).toBe(0)
			expect(next(h.clues:state(runtime).unlocked)).toBe(nil)
		end)

		it("refuses an unknown category, a stale token, and a stranger to the round", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedRainbow = 20
			expect(h.analyze(1, "distance").code).toBe("invalid_payload")
			expect(h.clues:analyze(1, { sessionToken = "not-the-token", category = "depth" }).code).toBe("stale_token")
			h.join(2)
			h.standAt(2, layout.clueStation)
			expect(h.clues:analyze(2, { sessionToken = h.token(2), category = "depth" }).code).toBe("invalid_state")
			expect(runtime.players[1].carriedRainbow).toBe(20)
		end)

		it("refuses from across the yard", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedRainbow = 20
			h.standAt(1, layout.clueStation + Vector3.new(cfg.clues.stationRangeStuds + 1, 0, 0))
			local result = h.analyze(1, "direction")
			expect(result.code).toBe("out_of_range")
			expect(runtime.players[1].carriedRainbow).toBe(20)
		end)

		it("refuses once the Egg is out", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedRainbow = 20
			expect(h.egg:revealNow(runtime)).toBe(true)
			local result = h.analyze(1, "direction")
			expect(result.ok).toBe(false)
			expect(result.message).toBe("egg_found")
			expect(runtime.players[1].carriedRainbow).toBe(20)
		end)
	end)

	describe("the trade", function()
		it("takes exactly the first then the second cost, and only Rainbow Feathers", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = 12, costs[1] + costs[2] + 1
			local first = h.analyze(1, "direction")
			expect(first.ok).toBe(true)
			expect(first.data.cost).toBe(costs[1])
			expect(state.carriedRainbow).toBe(costs[2] + 1)
			expect(state.carriedStandard).toBe(12)
			local second = h.analyze(1, "depth")
			expect(second.ok).toBe(true)
			expect(second.data.cost).toBe(costs[2])
			expect(state.carriedRainbow).toBe(1)
			expect(state.carriedStandard).toBe(12)
			expect(h.clues.stats.analyses).toBe(2)
		end)

		it("never sells the same category twice, and a spam of requests charges once", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedRainbow = 30
			expect(h.analyze(1, "depth").ok).toBe(true)
			for _ = 1, 5 do
				local again = h.analyze(1, "depth")
				expect(again.ok).toBe(false)
				expect(again.message).toBe("already_analyzed")
			end
			expect(state.carriedRainbow).toBe(30 - costs[1])
			expect(h.clues:project(runtime).count).toBe(1)
		end)

		it("holds the per-round limit even with feathers to spare", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedRainbow = 30
			expect(h.analyze(1, "direction").ok).toBe(true)
			expect(h.analyze(1, "depth").ok).toBe(true)
			local projection = h.clues:project(runtime)
			expect(projection.count).toBe(NestClues.maxClues(cfg))
			expect(projection.nextCost).toBe(nil)
			expect(runtime.players[1].carriedRainbow).toBe(30 - costs[1] - costs[2])
		end)

		it("the second clue must be the other category", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedRainbow = 30
			expect(h.analyze(1, "direction").ok).toBe(true)
			expect(h.analyze(1, "direction").message).toBe("already_analyzed")
			expect(h.analyze(1, "depth").ok).toBe(true)
		end)

		it("selling afterwards sells only what is left", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = 5, costs[1] + 2
			expect(h.analyze(1, "direction").ok).toBe(true)
			h.standAt(1, layout.sellStation + Vector3.new(0, 0, 4))
			local sale = h.selling:sell(1, h.token(1))
			expect(sale.ok).toBe(true)
			expect(sale.data.rainbowCount).toBe(2)
			expect(sale.data.standardCount).toBe(5)
			expect(state.carriedRainbow).toBe(0)
		end)
	end)

	describe("truth", function()
		it("every clue matches the server's Egg, across many rounds", function()
			local seen = { direction = {}, depth = {} }
			for seed = 1, 24 do
				local h, _, runtime = setup({ 1 }, { seed = seed })
				runtime.players[1].carriedRainbow = 30
				local facts = h.clues:eggFacts(runtime)
				local eggWorld = h.egg:position(runtime)
				expect(math.abs(facts.worldX - eggWorld.X)).toBeLessThan(1e-6)
				expect(math.abs(facts.worldZ - eggWorld.Z)).toBeLessThan(1e-6)
				local direction = h.analyze(1, "direction").data
				local depth = h.analyze(1, "depth").data
				local expectDirection = NestClues.directionBand(cfg, NestClues.sideFraction(layout, facts.radius, eggWorld.X, eggWorld.Z))
				local expectDepth = NestClues.depthBand(cfg, facts.depthFraction)
				expect(direction.title).toBe(NestClues.WORDS.direction[expectDirection].title)
				expect(depth.title).toBe(NestClues.WORDS.depth[expectDepth].title)
				expect(direction.text).toBe(NestClues.WORDS.direction[expectDirection].text)
				seen.direction[expectDirection] = true
				seen.depth[expectDepth] = true
				-- The depth fraction is the removal fraction the spawner rolled, within a record.
				local base =
					runtime.grid.cells[require(Shared.Domain.PileGrid).index(runtime.grid.width, runtime.eggNode.x, runtime.eggNode.z)].base
				expect(math.abs(facts.depthFraction - runtime.eggDepthFraction)).toBeLessThanOrEqual(1 / base + 1e-6)
			end
			-- The bands are not decorative. The depth roll varies by seed; the harness's node choice does
			-- not, so direction coverage is checked over the round's real candidate node list.
			local depths = 0
			for _ in pairs(seen.depth) do
				depths += 1
			end
			expect(depths).toBeGreaterThan(1)
			local h, _, runtime = setup({ 1 })
			local facts = h.clues:eggFacts(runtime)
			local directions = {}
			for _, node in ipairs(runtime.nodes) do
				local world = ChapterLayout.cellWorldPosition(
					layout,
					runtime.grid.width,
					runtime.grid.depth,
					runtime.grid.cellSize,
					node.x,
					node.z,
					0
				)
				local clue = NestClues.clueFor(cfg, layout, "direction", {
					worldX = world.X,
					worldZ = world.Z,
					radius = facts.radius,
					depthFraction = 0.5,
				})
				directions[clue.band] = true
			end
			expect(directions.barn).toBe(true)
			expect(directions.center).toBe(true)
			expect(directions.fence).toBe(true)
		end)

		it("the projection carries no coordinates and reaches every member through the snapshot", function()
			local h, roundId, runtime = setup({ 1, 2 })
			runtime.players[2].carriedRainbow = 30
			local heard = {}
			h.clues.unlocked:Connect(function(_runtime, userId, entry, projection)
				table.insert(heard, { userId = userId, entry = entry, projection = projection })
			end)
			expect(h.analyze(2, "direction").ok).toBe(true)
			expect(#heard).toBe(1)
			expect(heard[1].userId).toBe(2)
			local snapshot = h.rounds:project(roundId, false)
			expect(snapshot.clues.count).toBe(1)
			expect(snapshot.clues.unlocked.direction.title).toBe(heard[1].entry.title)
			expect(snapshot.clues.unlocked.direction.byUserId).toBe(2)
			expect(snapshot.clues.unlocked.depth).toBe(nil)
			local encoded = game:GetService("HttpService"):JSONEncode(snapshot.clues)
			expect(string.find(encoded, "worldX")).toBe(nil)
			expect(string.find(encoded, "eggSlot")).toBe(nil)
			expect(string.find(encoded, "depthFraction")).toBe(nil)
			expect(string.find(encoded, "sideFraction")).toBe(nil)
			-- Member 1 paid nothing and shares the clue.
			expect(runtime.players[1].carriedRainbow).toBe(0)
		end)

		it("resets with the next round", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedRainbow = 30
			expect(h.analyze(1, "direction").ok).toBe(true)
			expect(h.clues:project(runtime).count).toBe(1)
			-- Finish the round and start another with the same player.
			expect(h.egg:revealNow(runtime)).toBe(true)
			h.standAt(1, h.egg:position(runtime))
			expect(h.egg:claim(1, h.token(1)).ok).toBe(true)
			h.standAt(1, layout.farmer)
			expect(h.egg:deliver(1, h.token(1)).ok).toBe(true)
			h.clock:advance(cfg.round.resultScreenAutoContinueSeconds + 5)
			h.rounds:tick()
			local roundId2, runtime2 = h.startRound({ 1 })
			expect(runtime2 ~= runtime).toBe(true)
			expect(runtime2.clues).toBe(nil)
			expect(h.rounds:project(roundId2, false).clues.count).toBe(0)
			expect(h.rounds:project(roundId2, false).clues.nextCost).toBe(costs[1])
		end)
	end)
end
