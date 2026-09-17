--!nocheck
-- Molly's trade through the real services: validation, the atomic crate, rainbow untouched, three
-- area scans per party at escalating prices, truth against the live Egg, nothing but areas and
-- words in any payload, and the reset.

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
			local result = h.survey(1, "backBarn")
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
			expect(h.survey(1, "backBarn").code).toBe("insufficient_funds")
			expect(state.carriedRainbow).toBe(cost * 2)
		end)

		it("refuses a bad or missing area, a stale token, a stranger, distance, and an exposed Egg", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedStandard = cost * 3
			expect(h.survey(1, "B2").code).toBe("invalid_payload")
			expect(h.survey(1, nil).code).toBe("invalid_payload")
			expect(h.surveys:survey(1, { sessionToken = "nope", region = "backBarn" }).code).toBe("stale_token")
			h.join(2)
			h.standAt(2, layout.surveyStation)
			expect(h.surveys:survey(2, { sessionToken = h.token(2), region = "backBarn" }).code).toBe("invalid_state")
			h.standAt(1, layout.surveyStation + Vector3.new(cfg.survey.stationRangeStuds + 1, 0, 0))
			expect(h.survey(1, "backBarn").code).toBe("out_of_range")
			h.standAt(1, layout.surveyStation)
			expect(h.egg:revealNow(runtime)).toBe(true)
			local result = h.survey(1, "backBarn")
			expect(result.ok).toBe(false)
			expect(result.message).toBe("egg_found")
			expect(runtime.players[1].carriedStandard).toBe(cost * 3)
			expect(runtime.survey).toBe(nil)
		end)

		it("the remote schema accepts the four areas only, with no sub-cell or pin fields", function()
			local NetSchema = require(Shared.Net.NetSchema)
			local Schema = require(Shared.Net.Schema)
			local registry = NetSchema.build(cfg)
			local request = registry.byName.SurveyRequest
			local token = string.rep("a", 16)
			for _, region in ipairs(NestSurvey.REGIONS) do
				expect(Schema.validate(request.payload, { sessionToken = token, region = region }).ok).toBe(true)
			end
			expect(Schema.validate(request.payload, { sessionToken = token, region = "B2" }).ok).toBe(false)
			expect(Schema.validate(request.payload, { sessionToken = token }).ok).toBe(false)
			local select = registry.byName.SurveySelect
			expect(Schema.validate(select.payload, { sessionToken = token }).ok).toBe(true)
			expect(Schema.validate(select.payload, { sessionToken = token, region = "frontFence" }).ok).toBe(true)
			expect(Schema.validate(select.payload, { sessionToken = token, region = "C3" }).ok).toBe(false)
		end)
	end)

	describe("the crates", function()
		it("removes exactly the first crate, once, from normal feathers only", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard, state.carriedRainbow = cost + 7, 3
			local result = h.survey(1, "backBarn")
			expect(result.ok).toBe(true)
			expect(result.data.cost).toBe(cost)
			expect(result.data.region).toBe("backBarn")
			expect(result.data.name).toBe("BACK BARN")
			expect(state.carriedStandard).toBe(7)
			expect(state.carriedRainbow).toBe(3)
			expect(h.surveys.stats.surveys).toBe(1)
			expect(h.surveys.stats.rejected).toBe(0)
		end)

		it("charges 100, 200, 400 in order, any area each time, then refuses a fourth with the limit code", function()
			local h, _, runtime = setup({ 1 })
			local state = runtime.players[1]
			state.carriedStandard = total + 5
			expect(costs[1]).toBe(100)
			expect(costs[2]).toBe(200)
			expect(costs[3]).toBe(400)
			local picks = { "frontFence", "backBarn", "frontFence" }
			local spent = 0
			for index, region in ipairs(picks) do
				local result = h.survey(1, region)
				expect(result.ok).toBe(true)
				expect(result.data.cost).toBe(costs[index])
				spent += costs[index]
				expect(state.carriedStandard).toBe(total + 5 - spent)
				expect(runtime.survey.readings[index].region).toBe(region)
			end
			expect(runtime.survey.count).toBe(3)
			for _ = 1, 3 do
				local again = h.survey(1, "backFence")
				expect(again.ok).toBe(false)
				expect(again.code).toBe("already_done")
				expect(again.message).toBe("limit")
			end
			expect(state.carriedStandard).toBe(5)
			expect(h.surveys.stats.surveys).toBe(3)
		end)

		it("any member can buy the next crate for the same party, and the poorer one is refused", function()
			local h, _, runtime = setup({ 1, 2 })
			runtime.players[1].carriedStandard = costs[1]
			runtime.players[2].carriedStandard = costs[2] + costs[3]
			expect(h.survey(1, "backBarn").ok).toBe(true)
			local broke = h.survey(1, "backFence")
			expect(broke.ok).toBe(false)
			expect(broke.code).toBe("insufficient_funds")
			expect(runtime.players[1].carriedStandard).toBe(0)
			expect(h.survey(2, "backFence").ok).toBe(true)
			expect(h.survey(2, "frontBarn").ok).toBe(true)
			expect(runtime.players[2].carriedStandard).toBe(0)
			expect(runtime.survey.count).toBe(3)
			expect(runtime.survey.readings[1].byUserId).toBe(1)
			expect(runtime.survey.readings[2].byUserId).toBe(2)
			expect(runtime.survey.readings[3].byUserId).toBe(2)
		end)

		it("the live selection is relayed but never commits anything", function()
			local h, _, runtime = setup({ 1, 2 })
			runtime.players[1].carriedStandard = total
			local relayed = {}
			h.surveys.selected:Connect(function(_runtime, userId, region)
				table.insert(relayed, string.format("%s:%s", tostring(userId), tostring(region)))
			end)
			expect(h.surveys:select(1, { sessionToken = h.token(1), region = "frontBarn" }).ok).toBe(true)
			expect(h.surveys:select(1, { sessionToken = h.token(1) }).ok).toBe(true)
			expect(h.surveys:select(1, { sessionToken = h.token(1), region = "Z9" }).code).toBe("invalid_payload")
			expect(#relayed).toBe(2)
			expect(relayed[1]).toBe("1:frontBarn")
			expect(relayed[2]).toBe("1:nil")
			expect(runtime.players[1].carriedStandard).toBe(total)
			expect(runtime.survey).toBe(nil)
			for _, region in ipairs({ "frontBarn", "backBarn", "backFence" }) do
				expect(h.survey(1, region).ok).toBe(true)
			end
			local done = h.surveys:select(1, { sessionToken = h.token(1), region = "frontBarn" })
			expect(done.ok).toBe(false)
			expect(done.message).toBe("limit")
			expect(#relayed).toBe(2)
		end)
	end)

	describe("truth", function()
		it("each reading matches the rule against the live Egg, with exactly one strong area, across rounds", function()
			for seed = 1, 10 do
				local _, _, probe = setup({ 1 }, { seed = seed })
				local grid = probe.grid
				local truth = NestSurvey.regionOfCell(grid.width, grid.depth, probe.eggNode.x, probe.eggNode.z)
				local strongs = 0
				for _, selected in ipairs(NestSurvey.REGIONS) do
					local h, _, rt = setup({ 1 }, { seed = seed })
					expect(rt.eggNode.x).toBe(probe.eggNode.x)
					expect(rt.eggNode.z).toBe(probe.eggNode.z)
					rt.players[1].carriedStandard = cost
					local result = h.survey(1, selected)
					expect(result.ok).toBe(true)
					local want = NestSurvey.signal(cfg, grid.width, grid.depth, selected, rt.eggNode.x, rt.eggNode.z)
					expect(result.data.signal).toBe(want)
					expect(result.data.title).toBe(NestSurvey.WORDS[want].title)
					if want == "strong" then
						strongs += 1
						expect(selected).toBe(truth)
					end
					expect(rt.players[1].carriedStandard).toBe(0)
				end
				expect(strongs).toBe(1)
			end
		end)

		it("the response, the party event and the snapshot carry no Egg position, cell, sub-cell or pin", function()
			local h, roundId, runtime = setup({ 1, 2 })
			runtime.players[2].carriedStandard = total
			local heard = {}
			h.surveys.completed:Connect(function(_runtime, userId, _reading, projection)
				table.insert(heard, { userId = userId, projection = projection })
			end)
			local HttpService = game:GetService("HttpService")
			local forbidden = { "eggNode", "cell", "sub", "pin", "tier", "position", "distance", "actual", "truth" }
			local before = h.rounds:project(roundId, false).survey
			expect(before.count).toBe(0)
			expect(before.usesLeft).toBe(3)
			expect(before.nextCost).toBe(costs[1])
			local responses = {}
			for _, region in ipairs({ "backFence", "frontBarn", "frontFence" }) do
				local result = h.survey(2, region)
				expect(result.ok).toBe(true)
				table.insert(responses, result.data)
			end
			expect(#heard).toBe(3)
			expect(heard[3].userId).toBe(2)
			local snapshot = h.rounds:project(roundId, false)
			expect(snapshot.survey.count).toBe(3)
			expect(snapshot.survey.usesLeft).toBe(0)
			expect(snapshot.survey.nextCost).toBe(nil)
			expect(snapshot.survey.readings[2].region).toBe("frontBarn")
			expect(snapshot.survey.latest.byUserId).toBe(2)
			for _, blob in ipairs({ snapshot.survey, responses[1], responses[2], responses[3], heard[3].projection }) do
				local encoded = HttpService:JSONEncode(blob)
				for _, word in ipairs(forbidden) do
					expect(string.find(encoded, word)).toBe(nil)
				end
			end
			expect(runtime.players[1].carriedStandard).toBe(0)
		end)

		it("resets with the next round", function()
			local h, _, runtime = setup({ 1 })
			runtime.players[1].carriedStandard = total
			for _, region in ipairs({ "backBarn", "backFence", "frontBarn" }) do
				expect(h.survey(1, region).ok).toBe(true)
			end
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
			expect(h.survey(1, "frontFence").data.cost).toBe(costs[1])
		end)
	end)
end
