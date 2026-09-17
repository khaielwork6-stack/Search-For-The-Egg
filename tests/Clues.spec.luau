--!nocheck
-- Professor Plume's analysis through the real services: validation, the atomic Rainbow Feather
-- deduction, once per round per player, the server-side rate limit, one vague clue that matches the
-- live Egg, nothing of the Egg's place anywhere, no rod or lent tool left behind, and the reset.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local PlumeClue = require(Shared.Domain.PlumeClue)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1
	local cost = cfg.plume.rainbowCost
	local cooldown = cfg.plume.requestCooldownSeconds

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

	-- Past the per-player cooldown, so consecutive checks in one test are not rate limited.
	local function wait(h)
		h.clock:advance(cooldown + 0.01)
	end

	describe("validation", function()
		it("refuses without enough Rainbow Feathers and consumes nothing", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = 5000, cost - 1
			local result = h.analyse(1)
			expect(result.ok).toBe(false)
			expect(result.code).toBe("insufficient_funds")
			expect(result.message).toBe("insufficient")
			expect(state.carriedStandard).toBe(5000)
			expect(state.carriedRainbow).toBe(cost - 1)
			expect(state.plumeClue).toBe(nil)
		end)

		it("refuses a stale token and a stranger to the round", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedRainbow = cost
			expect(h.clues:analyse(1, { sessionToken = "not-the-token" }).code).toBe("stale_token")
			h.join(2)
			h.standAt(2, layout.clueStation)
			expect(h.clues:analyse(2, { sessionToken = h.token(2) }).code).toBe("invalid_state")
			expect(runtime.players[1].carriedRainbow).toBe(cost)
		end)

		it("refuses from across the yard", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedRainbow = cost
			h.standAt(1, layout.clueStation + Vector3.new(cfg.plume.stationRangeStuds + 1, 0, 0))
			local result = h.analyse(1)
			expect(result.code).toBe("out_of_range")
			expect(runtime.players[1].carriedRainbow).toBe(cost)
		end)

		it("refuses once the Egg is out", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedRainbow = cost
			expect(h.egg:revealNow(runtime)).toBe(true)
			local result = h.analyse(1)
			expect(result.ok).toBe(false)
			expect(result.message).toBe("egg_found")
			expect(runtime.players[1].carriedRainbow).toBe(cost)
		end)

		it("refuses outside the searching phase", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local party = h.parties:create(1, "chapter1", "normal")
			h.parties:start(1, party.partyId)
			h.clock:advance(cfg.round.countdownSeconds)
			h.parties:tick()
			local runtime = h.rounds:roundOf(1)
			expect(runtime ~= nil).toBe(true)
			runtime.players[1].carriedRainbow = cost
			h.standAt(1, layout.clueStation)
			local result = h.analyse(1)
			expect(result.ok).toBe(false)
			expect(result.message).toBe("phase")
			expect(runtime.players[1].carriedRainbow).toBe(cost)
		end)

		it("the remote carries only the session token and Plume's old remotes are gone", function()
			local NetSchema = require(Shared.Net.NetSchema)
			local registry = NetSchema.build(cfg)
			expect(registry.byName.PlumeAnalyse ~= nil).toBe(true)
			expect(registry.byName.PlumeLend).toBe(nil)
			expect(registry.byName.PlumeLent).toBe(nil)
			expect(registry.byName.RodAim).toBe(nil)
		end)
	end)

	describe("the analysis", function()
		it("takes exactly the cost in Rainbow Feathers, never normal ones, and stores one clue", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = 321, cost + 4
			local result = h.analyse(1)
			expect(result.ok).toBe(true)
			expect(result.data.cost).toBe(cost)
			expect(result.data.carriedRainbow).toBe(4)
			expect(state.carriedRainbow).toBe(4)
			expect(state.carriedStandard).toBe(321)
			local clue = result.data.clue
			expect(clue.kind == "direction" or clue.kind == "depth").toBe(true)
			expect(#clue.text).toBeGreaterThan(0)
			expect(state.plumeClue.key).toBe(clue.key)
			expect(h.clues.stats.analyses).toBe(1)
		end)

		it("works once per round per player: a second try is refused and costs nothing", function()
			local h, _, runtime = setup({ 1, 2 })
			runtime.players[1].carriedRainbow = cost * 5
			runtime.players[2].carriedRainbow = cost
			expect(h.analyse(1).ok).toBe(true)
			wait(h)
			local again = h.analyse(1)
			expect(again.ok).toBe(false)
			expect(again.code).toBe("already_done")
			expect(again.message).toBe("used")
			expect(runtime.players[1].carriedRainbow).toBe(cost * 4)
			-- Another member still has their own analysis.
			expect(h.analyse(2).ok).toBe(true)
			expect(runtime.players[2].carriedRainbow).toBe(0)
			expect(h.clues.stats.analyses).toBe(2)
		end)

		it("rate limits a burst server-side, and a spam charges at most once", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedRainbow = cost * 10
			local codes = {}
			for _ = 1, 6 do
				local result = h.analyse(1)
				table.insert(codes, if result.ok then "ok" else result.message)
			end
			expect(codes[1]).toBe("ok")
			for i = 2, 6 do
				expect(codes[i]).toBe("cooldown")
			end
			expect(runtime.players[1].carriedRainbow).toBe(cost * 9)
			wait(h)
			expect(h.analyse(1).message).toBe("used")
			expect(runtime.players[1].carriedRainbow).toBe(cost * 9)
		end)

		it("the clue matches the live Egg and both kinds occur across rolls", function()
			local kinds = {}
			for seed = 1, 16 do
				local h, _, runtime = setup({ 1 }, { clueSeed = seed * 104729 + 7 })
				runtime.players[1].carriedRainbow = cost
				local result = h.analyse(1)
				expect(result.ok).toBe(true)
				local clue = result.data.clue
				kinds[clue.kind] = true
				local grid = runtime.grid
				local u = (runtime.eggNode.x + 0.5) / grid.width
				local v = (runtime.eggNode.z + 0.5) / grid.depth
				if clue.kind == "direction" then
					if clue.key == "barn" then
						expect(u < 0.5).toBe(true)
					elseif clue.key == "fence" then
						expect(u >= 0.5).toBe(true)
					elseif clue.key == "back" then
						expect(v < 0.5).toBe(true)
					else
						expect(clue.key).toBe("front")
						expect(v >= 0.5).toBe(true)
					end
				else
					expect(clue.key).toBe(PlumeClue.depthOf(cfg, runtime.eggDepthFraction))
				end
			end
			expect(kinds.direction).toBe(true)
			expect(kinds.depth).toBe(true)
		end)

		it("reveals nothing precise: no position, no cell, no rod, no heat, and only the payer's projection carries it", function()
			local h, roundId, runtime = setup({ 1, 2 })
			runtime.players[1].carriedRainbow = cost
			local toolEventsBefore = #h.toolEvents
			local result = h.analyse(1)
			expect(result.ok).toBe(true)
			local HttpService = game:GetService("HttpService")
			local mine = h.rounds:projectPlayer(roundId, 1)
			expect(mine.plumeClue.key).toBe(result.data.clue.key)
			expect(h.rounds:projectPlayer(roundId, 2).plumeClue).toBe(nil)
			local snapshot = h.rounds:project(roundId, false)
			expect(snapshot.plume).toBe(nil)
			for _, blob in ipairs({ result.data, mine.plumeClue, snapshot }) do
				local encoded = HttpService:JSONEncode(blob)
				for _, word in ipairs({ "eggNode", "cellX", "cellZ", "heat", "eggSense", "worldX", "distance" }) do
					expect(string.find(encoded, word)).toBe(nil)
				end
			end
			-- No tool changed hands and nothing was equipped.
			expect(runtime.players[1].equippedTool).toBe("hand")
			expect(runtime.players[1].roundTools.eggSense).toBe(nil)
			expect(#h.toolEvents).toBe(toolEventsBefore)
		end)
	end)

	describe("rounds", function()
		it("the clue and the once-per-round lock reset with the next round", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedRainbow = cost
			expect(h.analyse(1).ok).toBe(true)
			expect(h.egg:revealNow(runtime)).toBe(true)
			h.standAt(1, h.egg:position(runtime))
			expect(h.egg:claim(1, h.token(1)).ok).toBe(true)
			h.standAt(1, layout.farmer)
			expect(h.egg:deliver(1, h.token(1)).ok).toBe(true)
			h.clock:advance(cfg.round.resultScreenAutoContinueSeconds + 5)
			h.rounds:tick()
			local roundId2, runtime2 = h.startRound({ 1 })
			expect(runtime2 ~= runtime).toBe(true)
			expect(runtime2.players[1].plumeClue).toBe(nil)
			expect(h.rounds:projectPlayer(roundId2, 1).plumeClue).toBe(nil)
			h.standAt(1, layout.clueStation)
			runtime2.players[1].carriedRainbow = cost
			wait(h)
			expect(h.analyse(1).ok).toBe(true)
		end)
	end)
end
