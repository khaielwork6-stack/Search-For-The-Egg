--!nocheck
-- Molly's map: four large named areas fixed to the yard, the STRONG / WEAK / NO SIGNAL rule with its
-- configurable border margin, the escalating crates, navigation, and a projection that carries only
-- areas and words.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local NestSurvey = require(Shared.Domain.NestSurvey)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))

	-- A config with a chosen margin, for exact rule checks independent of the shipped value.
	local function withMargin(margin)
		return { survey = { weakBorderFraction = margin, crateCosts = cfg.survey.crateCosts, maxPerRound = cfg.survey.maxPerRound } }
	end

	describe("areas", function()
		it("names four areas, fixed to the yard, each with a readable label", function()
			expect(#NestSurvey.REGIONS).toBe(4)
			for _, region in ipairs(NestSurvey.REGIONS) do
				expect(NestSurvey.isRegion(region)).toBe(true)
				expect(#NestSurvey.name(region)).toBeGreaterThan(0)
			end
			expect(NestSurvey.name("backBarn")).toBe("BACK BARN")
			expect(NestSurvey.name("frontFence")).toBe("FRONT FENCE")
			expect(NestSurvey.isRegion("B2")).toBe(false)
			expect(NestSurvey.isRegion("backbarn")).toBe(false)
			expect(NestSurvey.isRegion(nil)).toBe(false)
			expect(NestSurvey.LANDMARKS.left).toBe("BARN")
			expect(NestSurvey.LANDMARKS.right).toBe("FENCE")
			expect(NestSurvey.LANDMARKS.top).toBe("BACK")
			expect(NestSurvey.LANDMARKS.bottom).toBe("FRONT")
		end)

		it("splits the grid into halves: barn is x low, back is z low", function()
			local w, d = cfg.pile.gridWidth, cfg.pile.gridDepth
			expect(NestSurvey.regionOfCell(w, d, 0, 0)).toBe("backBarn")
			expect(NestSurvey.regionOfCell(w, d, w - 1, 0)).toBe("backFence")
			expect(NestSurvey.regionOfCell(w, d, 0, d - 1)).toBe("frontBarn")
			expect(NestSurvey.regionOfCell(w, d, w - 1, d - 1)).toBe("frontFence")
			-- Every cell belongs to exactly one area, and the four areas share the grid evenly.
			local counts = {}
			for x = 0, w - 1 do
				for z = 0, d - 1 do
					local region = NestSurvey.regionOfCell(w, d, x, z)
					counts[region] = (counts[region] or 0) + 1
				end
			end
			for _, region in ipairs(NestSurvey.REGIONS) do
				expect(counts[region]).toBe((w // 2) * (d // 2))
			end
		end)

		it("steps between areas on the 2x2 and clamps at the edges", function()
			expect(NestSurvey.step("backBarn", 0, 1)).toBe("backFence")
			expect(NestSurvey.step("backBarn", 1, 0)).toBe("frontBarn")
			expect(NestSurvey.step("backBarn", -1, -1)).toBe("backBarn")
			expect(NestSurvey.step("frontFence", 1, 1)).toBe("frontFence")
			expect(NestSurvey.step("frontFence", -1, -1)).toBe("backBarn")
		end)
	end)

	describe("signal", function()
		it("is strong only for the Egg's own area", function()
			local w, d = 40, 40
			for x = 0, w - 1, 3 do
				for z = 0, d - 1, 3 do
					local truth = NestSurvey.regionOfCell(w, d, x, z)
					local strongs = 0
					for _, region in ipairs(NestSurvey.REGIONS) do
						local signal = NestSurvey.signal(cfg, w, d, region, x, z)
						if signal == "strong" then
							strongs += 1
							expect(region).toBe(truth)
						end
					end
					expect(strongs).toBe(1)
				end
			end
		end)

		it("is weak within the margin past the chosen area's border, none beyond it", function()
			local config = withMargin(0.1)
			local w, d = 100, 100
			-- Cell centres at (x + 0.5) / 100: x = 55 sits 0.055 past the barn/fence line.
			expect(NestSurvey.signal(config, w, d, "backBarn", 55, 10)).toBe("weak")
			expect(NestSurvey.signal(config, w, d, "backBarn", 59, 10)).toBe("weak") -- 0.095
			expect(NestSurvey.signal(config, w, d, "backBarn", 60, 10)).toBe("none") -- 0.105
			expect(NestSurvey.signal(config, w, d, "backBarn", 90, 10)).toBe("none")
			-- Across the back/front line, the same.
			expect(NestSurvey.signal(config, w, d, "backBarn", 10, 55)).toBe("weak")
			expect(NestSurvey.signal(config, w, d, "backBarn", 10, 60)).toBe("none")
			-- Just across the centre corner: weak on both axes at once.
			expect(NestSurvey.signal(config, w, d, "backBarn", 52, 52)).toBe("weak")
			expect(NestSurvey.signal(config, w, d, "backBarn", 52, 70)).toBe("none")
			-- The Egg's own area stays strong right up to the border.
			expect(NestSurvey.signal(config, w, d, "backFence", 50, 49)).toBe("strong")
			expect(NestSurvey.signal(config, w, d, "backBarn", 50, 49)).toBe("weak")
		end)

		it("a zero margin means only strong or none", function()
			local config = withMargin(0)
			local w, d = 54, 54
			for x = 0, w - 1, 5 do
				for z = 0, d - 1, 5 do
					for _, region in ipairs(NestSurvey.REGIONS) do
						expect(NestSurvey.signal(config, w, d, region, x, z) ~= "weak").toBe(true)
					end
				end
			end
		end)

		it("ships a margin inside [0, 0.5) and every word has a title and a line", function()
			expect(cfg.survey.weakBorderFraction >= 0).toBe(true)
			expect(cfg.survey.weakBorderFraction < 0.5).toBe(true)
			for _, key in ipairs({ "strong", "weak", "none" }) do
				local words = NestSurvey.WORDS[key]
				expect(#words.title).toBeGreaterThan(0)
				expect(#words.short).toBeGreaterThan(0)
				expect(#words.text).toBeGreaterThan(0)
			end
			expect(NestSurvey.WORDS.strong.title).toBe("STRONG SIGNAL")
			expect(NestSurvey.WORDS.weak.title).toBe("WEAK SIGNAL")
			expect(NestSurvey.WORDS.none.title).toBe("NO SIGNAL")
		end)
	end)

	describe("crates", function()
		it("prices three surveys in ascending order and none after", function()
			expect(NestSurvey.maxSurveys(cfg)).toBe(3)
			expect(NestSurvey.nextCost(cfg, 0)).toBe(100)
			expect(NestSurvey.nextCost(cfg, 1)).toBe(200)
			expect(NestSurvey.nextCost(cfg, 2)).toBe(400)
			expect(NestSurvey.nextCost(cfg, 3)).toBe(nil)
		end)

		it("picks Molly's line from the round and the bag", function()
			expect(NestSurvey.lineFor(cfg, { active = true, exposed = true, count = 0, carriedStandard = 999 })).toBe(
				NestSurvey.LINES.exposed
			)
			expect(NestSurvey.lineFor(cfg, { active = false, exposed = false, count = 0, carriedStandard = 999 })).toBe(
				NestSurvey.LINES.inactive
			)
			expect(NestSurvey.lineFor(cfg, { active = true, exposed = false, count = 3, carriedStandard = 999 })).toBe(
				NestSurvey.LINES.used
			)
			expect(NestSurvey.lineFor(cfg, { active = true, exposed = false, count = 1, carriedStandard = 199 })).toBe(
				string.format(NestSurvey.LINES.insufficient, 200)
			)
			expect(NestSurvey.lineFor(cfg, { active = true, exposed = false, count = 1, carriedStandard = 200 })).toBe(
				NestSurvey.LINES.ready
			)
		end)
	end)

	describe("projection", function()
		it("carries areas, words and counters only", function()
			local state = NestSurvey.newState()
			table.insert(state.readings, { index = 1, region = "frontFence", signal = "weak", byUserId = 7 })
			state.count = 1
			local projection = NestSurvey.project(cfg, state)
			expect(projection.count).toBe(1)
			expect(projection.usesLeft).toBe(2)
			expect(projection.nextCost).toBe(200)
			expect(projection.latest.region).toBe("frontFence")
			expect(projection.latest.name).toBe("FRONT FENCE")
			expect(projection.latest.title).toBe("WEAK SIGNAL")
			local encoded = game:GetService("HttpService"):JSONEncode(projection)
			for _, word in ipairs({ "cell", "sub", "pin", "tier", "eggNode", "position", "distance" }) do
				expect(string.find(encoded, word)).toBe(nil)
			end
			local empty = NestSurvey.project(cfg, nil)
			expect(empty.count).toBe(0)
			expect(empty.usesLeft).toBe(3)
			expect(empty.nextCost).toBe(100)
			expect(#empty.readings).toBe(0)
		end)

		it("keeps the latest reading of each area", function()
			local latest = NestSurvey.latestByRegion({
				{ region = "backBarn", signal = "none" },
				{ region = "frontBarn", signal = "weak" },
				{ region = "backBarn", signal = "strong" },
				{ region = "nowhere", signal = "strong" },
			})
			expect(latest.backBarn.signal).toBe("strong")
			expect(latest.frontBarn.signal).toBe("weak")
			expect(latest.nowhere).toBe(nil)
		end)
	end)
end
