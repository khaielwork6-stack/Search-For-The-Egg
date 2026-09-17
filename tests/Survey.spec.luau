--!nocheck
-- Molly's trade through the real services: validation, the atomic crate, rainbow untouched, three
-- narrowing scans per party at escalating prices, truth against the live Egg, no coordinates until
-- the pin, and the reset.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local NestSurvey = require(Shared.Domain.NestSurvey)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1
	local costs = cfg.survey.crateCosts
	local cost = costs[1]
	local total = costs[1] + costs[2] + costs[3]

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
			expect(h.survey(1, nil).code).toBe("invalid_payload")
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

	describe("the crates", function()
		it("removes exactly the first crate, once, from normal feathers only", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = cost + 7, 3
			local result = h.survey(1, "B2")
			expect(result.ok).toBe(true)
			expect(result.data.cost).toBe(cost)
			expect(result.data.tier).toBe(1)
			expect(state.carriedStandard).toBe(7)
			expect(state.carriedRainbow).toBe(3)
			expect(h.surveys.stats.surveys).toBe(1)
			expect(h.surveys.stats.rejected).toBe(0)
		end)

		it("charges 100, 200, 400 in order, then refuses a fourth with the limit code", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard = total + 5
			expect(costs[1]).toBe(100)
			expect(costs[2]).toBe(200)
			expect(costs[3]).toBe(400)
			local first = h.survey(1, "B2")
			expect(first.ok).toBe(true)
			expect(first.data.cost).toBe(costs[1])
			expect(state.carriedStandard).toBe(total + 5 - costs[1])
			-- The second crate needs a sub-cell; the price rises.
			expect(h.survey(1, "B2").message).toBe("sub")
			local second = h.survey(1, "B2", 5)
			expect(second.ok).toBe(true)
			expect(second.data.tier).toBe(2)
			expect(second.data.cost).toBe(costs[2])
			expect(state.carriedStandard).toBe(total + 5 - costs[1] - costs[2])
			-- The pin ignores whatever the payload names.
			local third = h.survey(1, "A1", 9)
			expect(third.ok).toBe(true)
			expect(third.data.tier).toBe(3)
			expect(third.data.cost).toBe(costs[3])
			expect(state.carriedStandard).toBe(5)
			expect(runtime.survey.count).toBe(3)
			for _ = 1, 3 do
				local again = h.survey(1, "B2", 5)
				expect(again.ok).toBe(false)
				expect(again.code).toBe("already_done")
				expect(again.message).toBe("limit")
			end
			expect(state.carriedStandard).toBe(5)
			expect(h.surveys.stats.surveys).toBe(3)
		end)

		it("the second crate must name a sub-cell of the region the first one read", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard = total
			expect(h.survey(1, "A1").ok).toBe(true)
			local wrong = h.survey(1, "C3", 4)
			expect(wrong.ok).toBe(false)
			expect(wrong.code).toBe("invalid_payload")
			expect(wrong.message).toBe("wrong_region")
			expect(h.survey(1, "A1", 0).message).toBe("sub")
			expect(h.survey(1, "A1", 10).message).toBe("sub")
			expect(h.survey(1, "A1", 2.5).message).toBe("sub")
			expect(state.carriedStandard).toBe(total - costs[1])
			expect(runtime.survey.count).toBe(1)
			local right = h.survey(1, "A1", 4)
			expect(right.ok).toBe(true)
			expect(right.data.region).toBe("A1")
			expect(right.data.sub).toBe(4)
			expect(right.data.id).toBe("A1-4")
		end)

		it("the pin comes only after two readings and always as the third", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedStandard = total
			expect(h.survey(1, "B2").data.tier).toBe(1)
			expect(h.survey(1, "B2", 1).data.tier).toBe(2)
			local pin = h.survey(1)
			expect(pin.ok).toBe(true)
			expect(pin.data.tier).toBe(3)
			expect(pin.data.signal).toBe("pin")
			expect(pin.data.cellX).toBe(runtime.eggNode.x)
			expect(pin.data.cellZ).toBe(runtime.eggNode.z)
			expect(runtime.survey.readings[3].tier).toBe(3)
		end)

		it("any member can buy the next crate for the same party, and the poorer one is refused", function()
			local h, _, runtime = setup({ 1, 2 })
			runtime.players[1].carriedStandard = costs[1]
			runtime.players[2].carriedStandard = costs[2] + costs[3]
			expect(h.survey(1, "A1").ok).toBe(true)
			-- Member 1 is now broke: the second crate is refused, nothing leaves the bag.
			local broke = h.survey(1, "A1", 5)
			expect(broke.ok).toBe(false)
			expect(broke.code).toBe("insufficient_funds")
			expect(runtime.players[1].carriedStandard).toBe(0)
			-- Member 2 buys tiers 2 and 3 for the party.
			local second = h.survey(2, "A1", 5)
			expect(second.ok).toBe(true)
			expect(second.data.byUserId == nil or second.data.byUserId == 2).toBe(true)
			expect(runtime.survey.readings[2].byUserId).toBe(2)
			expect(h.survey(2).ok).toBe(true)
			expect(runtime.players[2].carriedStandard).toBe(0)
			expect(runtime.survey.count).toBe(3)
			expect(runtime.survey.readings[1].byUserId).toBe(1)
			expect(runtime.survey.readings[3].byUserId).toBe(2)
		end)

		it("the live selection is relayed with its tier but never commits anything", function()
			local h, _, runtime = setup({ 1, 2 })
			runtime.players[1].carriedStandard = total
			local relayed = {}
			h.surveys.selected:Connect(function(_runtime, userId, region, sub, tier)
				table.insert(relayed, string.format("%s:%s:%s:%s", tostring(userId), tostring(region), tostring(sub), tostring(tier)))
			end)
			expect(h.surveys:select(1, { sessionToken = h.token(1), region = "C2" }).ok).toBe(true)
			expect(h.surveys:select(1, { sessionToken = h.token(1) }).ok).toBe(true)
			expect(h.surveys:select(1, { sessionToken = h.token(1), region = "Z9" }).code).toBe("invalid_payload")
			expect(h.surveys:select(1, { sessionToken = h.token(1), region = "C2", sub = 12 }).code).toBe("invalid_payload")
			expect(#relayed).toBe(2)
			expect(relayed[1]).toBe("1:C2:nil:region")
			expect(relayed[2]).toBe("1:nil:nil:region")
			expect(runtime.players[1].carriedStandard).toBe(total)
			expect(runtime.survey).toBe(nil)
			-- After the first reading the relay names the sub-cell tier; after the third it stops.
			expect(h.survey(1, "C2").ok).toBe(true)
			expect(h.surveys:select(1, { sessionToken = h.token(1), region = "C2", sub = 7 }).ok).toBe(true)
			expect(relayed[3]).toBe("1:C2:7:subcell")
			expect(h.survey(1, "C2", 7).ok).toBe(true)
			expect(h.surveys:select(1, { sessionToken = h.token(1) }).data.tier).toBe("pin")
			expect(h.survey(1).ok).toBe(true)
			local done = h.surveys:select(1, { sessionToken = h.token(1), region = "C2" })
			expect(done.ok).toBe(false)
			expect(done.message).toBe("limit")
			expect(#relayed).toBe(4)
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

		it("the sub-cell reading is strong only on the Egg's patch, and the pin lands on its cell", function()
			for seed = 1, 4 do
				local h, _, runtime = setup({ 1 }, { seed = seed })
				local truthRegion, truthSub = h.surveys:eggLocation(runtime)
				expect(NestSurvey.regionOfCell(runtime.grid.width, runtime.grid.depth, runtime.eggNode.x, runtime.eggNode.z)).toBe(
					truthRegion
				)
				local strongs = 0
				for _, sub in ipairs(NestSurvey.SUBS) do
					local hh, _, rt = setup({ 1 }, { seed = seed })
					rt.players[1].carriedStandard = total
					expect(hh.survey(1, truthRegion).data.signal).toBe("strong")
					local result = hh.survey(1, truthRegion, sub)
					expect(result.ok).toBe(true)
					expect(result.data.signal).toBe(NestSurvey.subSignal(cfg, truthRegion, sub, truthRegion, truthSub))
					if result.data.signal == "strong" then
						strongs += 1
						expect(sub).toBe(truthSub)
					end
					local pin = hh.survey(1)
					expect(pin.data.region).toBe(truthRegion)
					expect(pin.data.sub).toBe(truthSub)
					expect(pin.data.cellX).toBe(rt.eggNode.x)
					expect(pin.data.cellZ).toBe(rt.eggNode.z)
					expect(rt.players[1].carriedStandard).toBe(0)
				end
				expect(strongs).toBe(1)
			end
		end)

		it("the projection and the snapshot carry no Egg position until the pin", function()
			local h, roundId, runtime = setup({ 1, 2 })
			runtime.players[2].carriedStandard = total
			local heard = {}
			h.surveys.completed:Connect(function(_runtime, userId, _reading, projection)
				table.insert(heard, { userId = userId, projection = projection })
			end)
			local HttpService = game:GetService("HttpService")
			local forbidden = { "eggNode", "cellX", "cellZ", "worldX", "position", "distance", "actual", "truth" }
			-- Before any scan the snapshot already prices the first crate.
			local before = h.rounds:project(roundId, false).survey
			expect(before.count).toBe(0)
			expect(before.usesLeft).toBe(3)
			expect(before.nextCost).toBe(costs[1])
			expect(before.nextTier).toBe("region")
			expect(h.survey(2, "B2").ok).toBe(true)
			expect(h.survey(2, "B2", 5).ok).toBe(true)
			expect(#heard).toBe(2)
			expect(heard[2].userId).toBe(2)
			local snapshot = h.rounds:project(roundId, false)
			expect(snapshot.survey.count).toBe(2)
			expect(snapshot.survey.usesLeft).toBe(1)
			expect(snapshot.survey.nextCost).toBe(costs[3])
			expect(snapshot.survey.nextTier).toBe("pin")
			expect(snapshot.survey.readings[1].region).toBe("B2")
			expect(snapshot.survey.readings[2].id).toBe("B2-5")
			expect(snapshot.survey.latest.byUserId).toBe(2)
			local encoded = HttpService:JSONEncode(snapshot.survey)
			for _, word in ipairs(forbidden) do
				expect(string.find(encoded, word)).toBe(nil)
			end
			-- The pin is the one reading allowed to name the cell, and only that reading.
			expect(h.survey(2).ok).toBe(true)
			local pinned = h.rounds:project(roundId, false).survey
			expect(pinned.readings[3].cellX).toBe(runtime.eggNode.x)
			expect(pinned.readings[3].cellZ).toBe(runtime.eggNode.z)
			expect(pinned.usesLeft).toBe(0)
			expect(pinned.nextCost).toBe(nil)
			for i = 1, 2 do
				local encodedReading = HttpService:JSONEncode(pinned.readings[i])
				expect(string.find(encodedReading, "cellX")).toBe(nil)
			end
			-- Member 1 paid nothing and shares the readings.
			expect(runtime.players[1].carriedStandard).toBe(0)
		end)

		it("resets with the next round", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedStandard = total
			expect(h.survey(1, "B2").ok).toBe(true)
			expect(h.survey(1, "B2", 5).ok).toBe(true)
			expect(h.survey(1).ok).toBe(true)
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
			local fresh = h.rounds:project(roundId2, false).survey
			expect(fresh.count).toBe(0)
			expect(fresh.usesLeft).toBe(3)
			expect(fresh.nextCost).toBe(costs[1])
			h.standAt(1, layout.surveyStation)
			runtime2.players[1].carriedStandard = cost
			expect(h.survey(1, "A3").data.cost).toBe(costs[1])
		end)
	end)
end
