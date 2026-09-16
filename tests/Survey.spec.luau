--!nocheck
-- Molly's trade through the real services: validation, the atomic crate, rainbow untouched, one
-- scan per party, truth against the live Egg, no coordinates, and the reset.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local NestSurvey = require(Shared.Domain.NestSurvey)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1
	local cost = cfg.survey.SurveyCrateCost

	local function setup(members, options)
		local h = GameplayHarness.new(cfg, options)
		for _, userId in ipairs(members) do
			h.join(userId)
		end
		local roundId, runtime = h.startRound(members)
		for _, userId in ipairs(members) do
			h.standAt(userId, layout.surveyStation + Vector3.new(0, 0, 3))
		end
		return h, roundId, runtime
	end

	describe("validation", function()
		it("refuses under the crate size and consumes nothing", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = cost - 1, 40
			local result = h.survey(1, "B2")
			expect(result.ok).toBe(false)
			expect(result.code).toBe("insufficient_funds")
			expect(state.carriedStandard).toBe(cost - 1)
			expect(state.carriedRainbow).toBe(40)
			expect(runtime.survey).toBe(nil)
		end)

		it("rainbow feathers never count towards the crate", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = 0, cost * 2
			expect(h.survey(1, "B2").code).toBe("insufficient_funds")
			expect(state.carriedRainbow).toBe(cost * 2)
		end)

		it("refuses a bad region, a stale token, a stranger, distance, and an exposed Egg", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedStandard = cost * 3
			expect(h.survey(1, "D4").code).toBe("invalid_payload")
			expect(h.surveys:survey(1, { sessionToken = "nope", region = "B2" }).code).toBe("stale_token")
			h.join(2)
			h.standAt(2, layout.surveyStation)
			expect(h.surveys:survey(2, { sessionToken = h.token(2), region = "B2" }).code).toBe("invalid_state")
			h.standAt(1, layout.surveyStation + Vector3.new(cfg.survey.stationRangeStuds + 1, 0, 0))
			expect(h.survey(1, "B2").code).toBe("out_of_range")
			h.standAt(1, layout.surveyStation)
			expect(h.egg:revealNow(runtime)).toBe(true)
			local result = h.survey(1, "B2")
			expect(result.ok).toBe(false)
			expect(result.message).toBe("egg_found")
			expect(runtime.players[1].carriedStandard).toBe(cost * 3)
			expect(runtime.survey).toBe(nil)
		end)
	end)

	describe("the crate", function()
		it("removes exactly the crate, once, from normal feathers only", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = cost + 7, 3
			local result = h.survey(1, "B2")
			expect(result.ok).toBe(true)
			expect(result.data.cost).toBe(cost)
			expect(state.carriedStandard).toBe(7)
			expect(state.carriedRainbow).toBe(3)
			expect(h.surveys.stats.surveys).toBe(1)
			expect(h.surveys.stats.rejected).toBe(0)
		end)

		it("is one per party: repeats and other members are refused and lose nothing", function()
			local h, _, runtime = setup({ 1, 2 })
			runtime.players[1].carriedStandard = cost * 2
			runtime.players[2].carriedStandard = cost * 2
			expect(h.survey(1, "A1").ok).toBe(true)
			for _ = 1, 4 do
				local again = h.survey(1, "A2")
				expect(again.ok).toBe(false)
				expect(again.message).toBe("already_surveyed")
			end
			local other = h.survey(2, "C3")
			expect(other.ok).toBe(false)
			expect(other.message).toBe("already_surveyed")
			expect(runtime.players[1].carriedStandard).toBe(cost)
			expect(runtime.players[2].carriedStandard).toBe(cost * 2)
			expect(runtime.survey.region).toBe("A1")
		end)

		it("the live selection is relayed but never commits anything", function()
			local h, _, runtime = setup({ 1, 2 })
			runtime.players[1].carriedStandard = cost
			local relayed = {}
			h.surveys.selected:Connect(function(_runtime, userId, region)
				table.insert(relayed, tostring(userId) .. ":" .. tostring(region))
			end)
			expect(h.surveys:select(1, { sessionToken = h.token(1), region = "C2" }).ok).toBe(true)
			expect(h.surveys:select(1, { sessionToken = h.token(1) }).ok).toBe(true)
			expect(h.surveys:select(1, { sessionToken = h.token(1), region = "Z9" }).code).toBe("invalid_payload")
			expect(#relayed).toBe(2)
			expect(relayed[1]).toBe("1:C2")
			expect(relayed[2]).toBe("1:nil")
			expect(runtime.players[1].carriedStandard).toBe(cost)
			expect(runtime.survey).toBe(nil)
		end)
	end)

	describe("truth", function()
		it("strong only for the true region, weak by adjacency, none elsewhere - across rounds", function()
			local seenRegions = {}
			for seed = 1, 12 do
				local h, _, runtime = setup({ 1 }, { seed = seed })
				local truth = h.surveys:eggRegion(runtime)
				seenRegions[truth] = true
				-- Every region's reading, against the rule, from a fresh party each time.
				for _, selected in ipairs(NestSurvey.REGIONS) do
					local hh, _, rt = setup({ 1 }, { seed = seed })
					rt.players[1].carriedStandard = cost
					local result = hh.survey(1, selected)
					expect(result.ok).toBe(true)
					local want = NestSurvey.signal(cfg, selected, truth)
					expect(result.data.signal).toBe(want)
					if result.data.signal == "strong" then
						expect(selected).toBe(truth)
					end
					expect(rt.players[1].carriedStandard).toBe(0)
				end
			end
			-- The candidate node list reaches more than one region.
			local _, _, runtime = setup({ 1 })
			local regions = {}
			for _, node in ipairs(runtime.nodes) do
				regions[NestSurvey.regionOfCell(runtime.grid.width, runtime.grid.depth, node.x, node.z)] = true
			end
			local count = 0
			for _ in pairs(regions) do
				count += 1
			end
			expect(count).toBeGreaterThan(3)
		end)

		it("the projection and the snapshot carry no Egg position", function()
			local h, roundId, runtime = setup({ 1, 2 })
			runtime.players[2].carriedStandard = cost
			local heard = {}
			h.surveys.completed:Connect(function(_runtime, userId, _state, projection)
				table.insert(heard, { userId = userId, projection = projection })
			end)
			expect(h.survey(2, "B2").ok).toBe(true)
			expect(#heard).toBe(1)
			expect(heard[1].userId).toBe(2)
			local snapshot = h.rounds:project(roundId, false)
			expect(snapshot.survey.region).toBe("B2")
			expect(snapshot.survey.byUserId).toBe(2)
			expect(snapshot.survey.signal == "strong" or snapshot.survey.signal == "weak" or snapshot.survey.signal == "none").toBe(true)
			local encoded = game:GetService("HttpService"):JSONEncode(snapshot.survey)
			for _, forbidden in ipairs({ "eggNode", "cellX", "cellZ", "worldX", "position", "distance", "actual", "truth" }) do
				expect(string.find(encoded, forbidden)).toBe(nil)
			end
			-- Member 1 paid nothing and shares the reading.
			expect(runtime.players[1].carriedStandard).toBe(0)
		end)

		it("resets with the next round", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedStandard = cost
			expect(h.survey(1, "B2").ok).toBe(true)
			expect(h.egg:revealNow(runtime)).toBe(true)
			h.standAt(1, h.egg:position(runtime))
			expect(h.egg:claim(1, h.token(1)).ok).toBe(true)
			h.standAt(1, layout.farmer)
			expect(h.egg:deliver(1, h.token(1)).ok).toBe(true)
			h.clock:advance(cfg.round.resultScreenAutoContinueSeconds + 5)
			h.rounds:tick()
			local roundId2, runtime2 = h.startRound({ 1 })
			expect(runtime2 ~= runtime).toBe(true)
			expect(runtime2.survey).toBe(nil)
			expect(h.rounds:project(roundId2, false).survey).toBe(nil)
		end)
	end)
end
