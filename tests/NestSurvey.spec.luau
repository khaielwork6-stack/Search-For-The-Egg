--!nocheck
-- Molly's map: nine fixed regions, the exact adjacency rule, navigation, and a projection with
-- nothing of the Egg in it.

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

	describe("signal", function()
		it("follows the Manhattan rule for all 81 pairs", function()
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

		it("lists the neighbours a weak reading points at", function()
			local middle = NestSurvey.adjacent("B2")
			expect(#middle).toBe(4)
			local corner = NestSurvey.adjacent("A1")
			expect(#corner).toBe(2)
			expect(table.find(corner, "A2") ~= nil).toBe(true)
			expect(table.find(corner, "B1") ~= nil).toBe(true)
			expect(#NestSurvey.adjacent("B3")).toBe(3)
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

		it("describes a region by row and column", function()
			expect(NestSurvey.describe("B2")).toBe("B2 - Middle, centre")
			expect(NestSurvey.describe("A1")).toBe("A1 - Back, barn side")
			expect(NestSurvey.describe("C3")).toBe("C3 - Front, fence side")
		end)

		it("picks Molly's line and states the configured crate", function()
			local cost = NestSurvey.crateCost(cfg)
			expect(cost).toBe(cfg.survey.SurveyCrateCost)
			expect(NestSurvey.lineFor(cfg, { active = false, exposed = false, used = false, carriedStandard = 999 })).toBe(
				NestSurvey.LINES.inactive
			)
			expect(NestSurvey.lineFor(cfg, { active = true, exposed = true, used = false, carriedStandard = 999 })).toBe(
				NestSurvey.LINES.exposed
			)
			expect(NestSurvey.lineFor(cfg, { active = true, exposed = false, used = true, carriedStandard = 999 })).toBe(
				NestSurvey.LINES.used
			)
			local short = NestSurvey.lineFor(cfg, { active = true, exposed = false, used = false, carriedStandard = cost - 1 })
			expect(string.find(short, tostring(cost), 1, true) ~= nil).toBe(true)
			expect(NestSurvey.lineFor(cfg, { active = true, exposed = false, used = false, carriedStandard = cost })).toBe(
				NestSurvey.LINES.ready
			)
		end)

		it("projects region, category and payer only", function()
			expect(NestSurvey.project(nil)).toBe(nil)
			local p = NestSurvey.project({ region = "C1", signal = "weak", byUserId = 5 })
			expect(p.region).toBe("C1")
			expect(p.signal).toBe("weak")
			expect(p.title).toBe("WEAK SIGNAL")
			expect(p.byUserId).toBe(5)
			for key in pairs(p) do
				expect(key == "region" or key == "signal" or key == "title" or key == "short" or key == "text" or key == "byUserId").toBe(
					true
				)
			end
		end)
	end)
end
