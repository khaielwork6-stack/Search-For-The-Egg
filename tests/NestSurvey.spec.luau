--!nocheck
-- Molly's map: nine fixed regions, nine sub-cells inside each, the exact adjacency rule at both
-- scales, the escalating crates, navigation, and a projection with nothing of the Egg in it until
-- the pin.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local NestSurvey = require(Shared.Domain.NestSurvey)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))

	describe("regions", function()
		it("names nine regions, fixed to the yard", function()
			expect(#NestSurvey.REGIONS).toBe(9)
			expect(NestSurvey.isRegion("B2")).toBe(true)
			expect(NestSurvey.isRegion("D1")).toBe(false)
			expect(NestSurvey.isRegion("b2")).toBe(false)
			expect(NestSurvey.LANDMARKS.left).toBe("BARN")
			expect(NestSurvey.LANDMARKS.right).toBe("FENCE")
			expect(NestSurvey.LANDMARKS.top).toBe("BACK")
			expect(NestSurvey.LANDMARKS.bottom).toBe("FRONT")
		end)

		it("splits the grid into thirds: barn column is x low, back row is z low", function()
			local w, d = cfg.pile.gridWidth, cfg.pile.gridDepth
			expect(NestSurvey.regionOfCell(w, d, 0, 0)).toBe("A1")
			expect(NestSurvey.regionOfCell(w, d, w - 1, 0)).toBe("A3")
			expect(NestSurvey.regionOfCell(w, d, 0, d - 1)).toBe("C1")
			expect(NestSurvey.regionOfCell(w, d, w - 1, d - 1)).toBe("C3")
			expect(NestSurvey.regionOfCell(w, d, w // 2, d // 2)).toBe("B2")
			expect(NestSurvey.regionOfCell(w, d, w // 3 - 1, d // 2)).toBe("B1")
			expect(NestSurvey.regionOfCell(w, d, w // 3, d // 2)).toBe("B2")
			-- The offset form agrees with the cell form at every cell.
			local half = w * cfg.pile.cellSizeStuds / 2
			for x = 0, w - 1, 7 do
				for z = 0, d - 1, 7 do
					local dx = (x + 0.5) * cfg.pile.cellSizeStuds - half
					local dz = (z + 0.5) * cfg.pile.cellSizeStuds - half
					expect(NestSurvey.regionOfOffset(half, half, dx, dz)).toBe(NestSurvey.regionOfCell(w, d, x, z))
				end
			end
		end)
	end)

	describe("sub-cells", function()
		it("number nine patches in reading order and step between them", function()
			expect(#NestSurvey.SUBS).toBe(9)
			expect(NestSurvey.isSub(1)).toBe(true)
			expect(NestSurvey.isSub(9)).toBe(true)
			expect(NestSurvey.isSub(0)).toBe(false)
			expect(NestSurvey.isSub(10)).toBe(false)
			expect(NestSurvey.isSub(4.5)).toBe(false)
			expect(NestSurvey.isSub("5")).toBe(false)
			local r, c = NestSurvey.subRowCol(1)
			expect(r).toBe(1)
			expect(c).toBe(1)
			r, c = NestSurvey.subRowCol(6)
			expect(r).toBe(2)
			expect(c).toBe(3)
			expect(NestSurvey.subAt(3, 2)).toBe(8)
			expect(NestSurvey.stepSub(5, -1, 0)).toBe(2)
			expect(NestSurvey.stepSub(5, 0, 1)).toBe(6)
			expect(NestSurvey.stepSub(1, -1, -1)).toBe(1)
			expect(NestSurvey.stepSub(9, 1, 1)).toBe(9)
			expect(NestSurvey.id("B2")).toBe("B2")
			expect(NestSurvey.id("B2", 5)).toBe("B2-5")
		end)

		it("splits a region's cell span into thirds, corner to corner", function()
			local w, d = cfg.pile.gridWidth, cfg.pile.gridDepth
			-- The whole grid: the first cell is A1's patch 1, the last is C3's patch 9.
			expect(NestSurvey.subCellOfCell(w, d, "A1", 0, 0)).toBe(1)
			expect(NestSurvey.subCellOfCell(w, d, "C3", w - 1, d - 1)).toBe(9)
			-- Inside B2 the patches tile the region: every cell of the region lands in exactly one,
			-- the numbering runs barn -> fence then back -> front, and all nine are used.
			local seen = {}
			local previousRowSub = nil
			for z = 0, d - 1 do
				for x = 0, w - 1 do
					if NestSurvey.regionOfCell(w, d, x, z) == "B2" then
						local sub = NestSurvey.subCellOfCell(w, d, "B2", x, z)
						expect(NestSurvey.isSub(sub)).toBe(true)
						seen[sub] = (seen[sub] or 0) + 1
						local region2, sub2 = NestSurvey.locate(w, d, x, z)
						expect(region2).toBe("B2")
						expect(sub2).toBe(sub)
						local sr, sc = NestSurvey.subRowCol(sub)
						local fx, fz = NestSurvey.fractionInRegion(w, d, x, z)
						expect(math.floor(fx * 3) + 1).toBe(sc)
						expect(math.floor(fz * 3) + 1).toBe(sr)
						if previousRowSub then
							expect(sub >= previousRowSub).toBe(true)
						end
						previousRowSub = if x == w - 1 then nil else sub
					else
						previousRowSub = nil
					end
				end
			end
			for sub = 1, 9 do
				expect((seen[sub] or 0) > 0).toBe(true)
			end
			-- Patch sizes are balanced: no patch holds more than twice the cells of another.
			local smallest, largest = math.huge, 0
			for _, n in pairs(seen) do
				smallest, largest = math.min(smallest, n), math.max(largest, n)
			end
			expect(largest <= smallest * 2).toBe(true)
		end)
	end)

	describe("signal", function()
		it("follows the Manhattan rule for all 81 region pairs", function()
			for _, selected in ipairs(NestSurvey.REGIONS) do
				for _, actual in ipairs(NestSurvey.REGIONS) do
					local sr, sc = NestSurvey.rowCol(selected)
					local ar, ac = NestSurvey.rowCol(actual)
					local distance = math.abs(sr - ar) + math.abs(sc - ac)
					local want = if distance == 0 then "strong" elseif distance == 1 then "weak" else "none"
					expect(NestSurvey.signal(cfg, selected, actual)).toBe(want)
				end
			end
		end)

		it("matches the brief's examples", function()
			expect(NestSurvey.signal(cfg, "B2", "B2")).toBe("strong")
			for _, near in ipairs({ "A2", "B1", "B3", "C2" }) do
				expect(NestSurvey.signal(cfg, "B2", near)).toBe("weak")
			end
			for _, far in ipairs({ "A1", "A3", "C1", "C3" }) do
				expect(NestSurvey.signal(cfg, "B2", far)).toBe("none")
			end
			expect(NestSurvey.signal(cfg, "A1", "C3")).toBe("none")
			expect(NestSurvey.signal(cfg, "A1", "A3")).toBe("none")
		end)

		it("reads sub-cells by the same rule on the fine lattice, across region borders", function()
			-- Inside one region.
			expect(NestSurvey.subSignal(cfg, "B2", 5, "B2", 5)).toBe("strong")
			for _, near in ipairs({ 2, 4, 6, 8 }) do
				expect(NestSurvey.subSignal(cfg, "B2", 5, "B2", near)).toBe("weak")
			end
			for _, far in ipairs({ 1, 3, 7, 9 }) do
				expect(NestSurvey.subSignal(cfg, "B2", 5, "B2", far)).toBe("none")
			end
			-- Across the border: B2's patch 6 (east edge) touches B3's patch 4 (west edge).
			expect(NestSurvey.subSignal(cfg, "B2", 6, "B3", 4)).toBe("weak")
			expect(NestSurvey.subSignal(cfg, "B2", 6, "B3", 5)).toBe("none")
			expect(NestSurvey.subSignal(cfg, "B2", 6, "B3", 6)).toBe("none")
			-- B2's patch 2 (north edge) touches A2's patch 8 (south edge).
			expect(NestSurvey.subSignal(cfg, "B2", 2, "A2", 8)).toBe("weak")
			expect(NestSurvey.subSignal(cfg, "B2", 5, "A2", 8)).toBe("none")
			-- Far regions never hum.
			for _, sub in ipairs(NestSurvey.SUBS) do
				expect(NestSurvey.subSignal(cfg, "A1", sub, "C3", 5)).toBe("none")
			end
			local fr, fc = NestSurvey.fineRowCol("C3", 9)
			expect(fr).toBe(9)
			expect(fc).toBe(9)
		end)

		it("lists the neighbours a weak reading points at", function()
			local middle = NestSurvey.adjacent("B2")
			expect(#middle).toBe(4)
			local corner = NestSurvey.adjacent("A1")
			expect(#corner).toBe(2)
			expect(table.find(corner, "A2") ~= nil).toBe(true)
			expect(table.find(corner, "B1") ~= nil).toBe(true)
			expect(#NestSurvey.adjacent("B3")).toBe(3)
			expect(#NestSurvey.adjacentSubs(5)).toBe(4)
			expect(#NestSurvey.adjacentSubs(1)).toBe(2)
			expect(table.find(NestSurvey.adjacentSubs(1), 2) ~= nil).toBe(true)
			expect(table.find(NestSurvey.adjacentSubs(1), 4) ~= nil).toBe(true)
		end)
	end)

	describe("crates and tiers", function()
		it("prices three surveys in ascending order and stops at the limit", function()
			local costs = NestSurvey.costs(cfg)
			expect(#costs).toBe(3)
			expect(costs[1]).toBe(100)
			expect(costs[2]).toBe(200)
			expect(costs[3]).toBe(400)
			expect(NestSurvey.crateCost(cfg)).toBe(100)
			expect(NestSurvey.maxSurveys(cfg)).toBe(3)
			expect(NestSurvey.nextCost(cfg, 0)).toBe(100)
			expect(NestSurvey.nextCost(cfg, 1)).toBe(200)
			expect(NestSurvey.nextCost(cfg, 2)).toBe(400)
			expect(NestSurvey.nextCost(cfg, 3)).toBe(nil)
			expect(NestSurvey.nextCost(cfg, 7)).toBe(nil)
			expect(NestSurvey.nextTier(cfg, 0)).toBe("region")
			expect(NestSurvey.nextTier(cfg, 1)).toBe("subcell")
			expect(NestSurvey.nextTier(cfg, 2)).toBe("pin")
			expect(NestSurvey.nextTier(cfg, 3)).toBe(nil)
			expect(NestSurvey.tierAt(1)).toBe("region")
			expect(NestSurvey.tierAt(2)).toBe("subcell")
			expect(NestSurvey.tierAt(3)).toBe("pin")
			expect(NestSurvey.tierAt(9)).toBe("pin")
			-- A config that allows fewer surveys than it prices stops earlier.
			local capped = { survey = { crateCosts = { 100, 200, 400 }, maxPerRound = 2 } }
			expect(NestSurvey.maxSurveys(capped)).toBe(2)
			expect(NestSurvey.nextCost(capped, 2)).toBe(nil)
		end)

		it("the validator wants ascending integer costs and a limit within them", function()
			local raw = require(ServerStorage.SFE.SystemConfig)
			local function withSurvey(patch)
				local copy = table.clone(raw)
				local survey = table.clone(raw.survey)
				for key, value in pairs(patch) do
					survey[key] = value
				end
				copy.survey = survey
				return Config.validate(copy)
			end
			expect(withSurvey({}).ok).toBe(true)
			expect(withSurvey({ crateCosts = {} }).ok).toBe(false)
			expect(withSurvey({ crateCosts = { 100, 100, 400 } }).ok).toBe(false)
			expect(withSurvey({ crateCosts = { 400, 200, 100 } }).ok).toBe(false)
			expect(withSurvey({ crateCosts = { 100, 200.5, 400 } }).ok).toBe(false)
			expect(withSurvey({ maxPerRound = 4 }).ok).toBe(false)
			expect(withSurvey({ maxPerRound = 0 }).ok).toBe(false)
			expect(withSurvey({ maxPerRound = 2 }).ok).toBe(true)
		end)
	end)

	describe("navigation and words", function()
		it("steps across the grid and stops at the edges", function()
			expect(NestSurvey.step("B2", -1, 0)).toBe("A2")
			expect(NestSurvey.step("B2", 0, 1)).toBe("B3")
			expect(NestSurvey.step("A1", -1, -1)).toBe("A1")
			expect(NestSurvey.step("C3", 1, 1)).toBe("C3")
			-- Every region is reachable from B2 within two steps.
			local reached = {}
			for _, a in ipairs({ -1, 0, 1 }) do
				for _, b in ipairs({ -1, 0, 1 }) do
					reached[NestSurvey.step("B2", a, b)] = true
				end
			end
			local n = 0
			for _ in pairs(reached) do
				n += 1
			end
			expect(n).toBe(9)
		end)

		it("describes a region by row and column, and a patch by its number", function()
			expect(NestSurvey.describe("B2")).toBe("B2 - Middle, centre")
			expect(NestSurvey.describe("A1")).toBe("A1 - Back, barn side")
			expect(NestSurvey.describe("C3")).toBe("C3 - Front, fence side")
			expect(NestSurvey.describe("C3", 7)).toBe("C3-7 - Front, fence side, patch 7")
		end)

		it("picks Molly's line per tier and states the next crate", function()
			expect(NestSurvey.lineFor(cfg, { active = false, exposed = false, count = 0, carriedStandard = 999 })).toBe(
				NestSurvey.LINES.inactive
			)
			expect(NestSurvey.lineFor(cfg, { active = true, exposed = true, count = 0, carriedStandard = 999 })).toBe(
				NestSurvey.LINES.exposed
			)
			expect(NestSurvey.lineFor(cfg, { active = true, exposed = false, count = 3, carriedStandard = 999 })).toBe(
				NestSurvey.LINES.used
			)
			local short = NestSurvey.lineFor(cfg, { active = true, exposed = false, count = 1, carriedStandard = 199 })
			expect(string.find(short, "200", 1, true) ~= nil).toBe(true)
			expect(NestSurvey.lineFor(cfg, { active = true, exposed = false, count = 0, carriedStandard = 100 })).toBe(
				NestSurvey.LINES.ready[1]
			)
			local second = NestSurvey.lineFor(cfg, { active = true, exposed = false, count = 1, carriedStandard = 200, region = "B2" })
			expect(string.find(second, "B2", 1, true) ~= nil).toBe(true)
			expect(NestSurvey.lineFor(cfg, { active = true, exposed = false, count = 2, carriedStandard = 400 })).toBe(
				NestSurvey.LINES.ready[3]
			)
			expect(NestSurvey.warning(cfg)).toBe("Three surveys per round. Each one digs closer.")
			expect(NestSurvey.WORDS.pin.title).toBe("NEST PINNED")
			expect(NestSurvey.TIER_WORDS.pin.scan).toBe("PIN THE NEST")
		end)

		it("projects the readings, the count and the next crate, never the Egg until the pin", function()
			local empty = NestSurvey.project(cfg, nil)
			expect(#empty.readings).toBe(0)
			expect(empty.count).toBe(0)
			expect(empty.latest).toBe(nil)
			expect(empty.max).toBe(3)
			expect(empty.usesLeft).toBe(3)
			expect(empty.nextCost).toBe(100)
			expect(empty.nextTier).toBe("region")
			local state = NestSurvey.newState()
			table.insert(state.readings, { tier = 1, region = "C1", signal = "weak", byUserId = 5 })
			table.insert(state.readings, { tier = 2, region = "C1", sub = 3, signal = "strong", byUserId = 6 })
			state.count = 2
			local p = NestSurvey.project(cfg, state)
			expect(p.count).toBe(2)
			expect(p.usesLeft).toBe(1)
			expect(p.nextCost).toBe(400)
			expect(p.nextTier).toBe("pin")
			expect(p.readings[1].region).toBe("C1")
			expect(p.readings[1].id).toBe("C1")
			expect(p.readings[1].signal).toBe("weak")
			expect(p.readings[1].title).toBe("WEAK SIGNAL")
			expect(p.readings[1].byUserId).toBe(5)
			expect(p.readings[2].id).toBe("C1-3")
			expect(p.readings[2].sub).toBe(3)
			expect(p.latest.byUserId).toBe(6)
			for _, reading in ipairs(p.readings) do
				for key in pairs(reading) do
					expect(
						key == "tier"
							or key == "region"
							or key == "sub"
							or key == "id"
							or key == "signal"
							or key == "title"
							or key == "short"
							or key == "text"
							or key == "byUserId"
					).toBe(true)
				end
			end
			-- A reading that carries a cell before tier 3 is scrubbed; the pin keeps it.
			local leaky = NestSurvey.projectReading({ tier = 1, region = "A1", signal = "none", cellX = 4, cellZ = 9, byUserId = 1 })
			expect(leaky.cellX).toBe(nil)
			expect(leaky.cellZ).toBe(nil)
			table.insert(state.readings, { tier = 3, region = "C1", sub = 3, signal = "pin", cellX = 4, cellZ = 40, byUserId = 5 })
			state.count = 3
			local pinned = NestSurvey.project(cfg, state)
			expect(pinned.usesLeft).toBe(0)
			expect(pinned.nextCost).toBe(nil)
			expect(pinned.nextTier).toBe(nil)
			expect(pinned.readings[3].cellX).toBe(4)
			expect(pinned.readings[3].cellZ).toBe(40)
			expect(pinned.readings[3].title).toBe("NEST PINNED")
		end)
	end)
end
