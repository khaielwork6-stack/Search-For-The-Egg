--!nocheck
-- Professor Plume's clue arithmetic: deterministic bands from the Egg's pile-local place, fixed
-- words, configured costs, and a projection that carries no coordinates.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local NestClues = require(Shared.Domain.NestClues)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1
	local radius = cfg.pile.gridWidth * cfg.pile.cellSizeStuds / 2

	describe("costs", function()
		it("charges the configured Rainbow Feathers in order and stops at the limit", function()
			expect(NestClues.nextCost(cfg, 0)).toBe(cfg.clues.costsRainbow[1])
			expect(NestClues.nextCost(cfg, 1)).toBe(cfg.clues.costsRainbow[2])
			expect(NestClues.nextCost(cfg, NestClues.maxClues(cfg))).toBe(nil)
			expect(NestClues.maxClues(cfg)).toBe(cfg.clues.maxPerRound)
		end)
	end)

	describe("direction", function()
		it("points along the line from the mound to the barn", function()
			local ax, az = NestClues.barnAxis(layout)
			expect(math.abs(ax * ax + az * az - 1)).toBeLessThan(1e-6)
			expect(ax).toBeLessThan(0) -- the barn is west of the mound
			expect(az).toBeLessThan(0) -- and towards the yard gate
		end)

		it("names the barn side, the centre stripe and the fence side deterministically", function()
			local ax, az = NestClues.barnAxis(layout)
			local centre = layout.nestCenter
			local towardsBarn = NestClues.clueFor(cfg, layout, "direction", {
				worldX = centre.X + ax * radius * 0.6,
				worldZ = centre.Z + az * radius * 0.6,
				radius = radius,
				depthFraction = 0.5,
			})
			local middle = NestClues.clueFor(cfg, layout, "direction", {
				worldX = centre.X + ax * radius * 0.05,
				worldZ = centre.Z + az * radius * 0.05,
				radius = radius,
				depthFraction = 0.5,
			})
			local towardsFence = NestClues.clueFor(cfg, layout, "direction", {
				worldX = centre.X - ax * radius * 0.6,
				worldZ = centre.Z - az * radius * 0.6,
				radius = radius,
				depthFraction = 0.5,
			})
			expect(towardsBarn.band).toBe("barn")
			expect(towardsBarn.title).toBe("BARN SIDE")
			expect(middle.band).toBe("center")
			expect(towardsFence.band).toBe("fence")
			-- Sideways of the axis is the centre stripe however far out it is.
			local sideways = NestClues.clueFor(cfg, layout, "direction", {
				worldX = centre.X - az * radius * 0.9,
				worldZ = centre.Z + ax * radius * 0.9,
				radius = radius,
				depthFraction = 0.5,
			})
			expect(sideways.band).toBe("center")
		end)

		it("is exactly the configured edge", function()
			local edge = cfg.clues.direction.sideFraction
			expect(NestClues.directionBand(cfg, edge)).toBe("barn")
			expect(NestClues.directionBand(cfg, edge - 1e-9)).toBe("center")
			expect(NestClues.directionBand(cfg, -edge)).toBe("fence")
			expect(NestClues.directionBand(cfg, -edge + 1e-9)).toBe("center")
		end)
	end)

	describe("depth", function()
		it("splits the spawner's window so every band is reachable", function()
			local egg = cfg.eggSpawn
			expect(NestClues.depthBand(cfg, egg.luckyMinimumRemovalFraction)).toBe("outer")
			expect(NestClues.depthBand(cfg, egg.minimumRemovalFraction)).toBe("outer")
			expect(NestClues.depthBand(cfg, (egg.minimumRemovalFraction + egg.maximumRemovalFraction) / 2)).toBe("middle")
			expect(NestClues.depthBand(cfg, egg.maximumRemovalFraction)).toBe("core")
			expect(NestClues.depthBand(cfg, 1)).toBe("core")
			expect(NestClues.clueFor(cfg, layout, "depth", { worldX = 0, worldZ = 0, radius = radius, depthFraction = 0.99 }).title).toBe(
				"NEST CORE"
			)
		end)

		it("is monotonic: deeper never reads shallower", function()
			local order = { outer = 1, middle = 2, core = 3 }
			local last = 0
			for step = 0, 100 do
				local rank = order[NestClues.depthBand(cfg, step / 100)]
				expect(rank).toBeGreaterThanOrEqual(last)
				last = rank
			end
		end)
	end)

	describe("state and projection", function()
		it("rejects unknown categories and never invents text", function()
			expect(NestClues.isCategory("direction")).toBe(true)
			expect(NestClues.isCategory("distance")).toBe(false)
			expect(NestClues.clueFor(cfg, layout, "distance", { worldX = 0, worldZ = 0, radius = radius, depthFraction = 0.5 })).toBe(nil)
			for category, bands in pairs(NestClues.WORDS) do
				for band, words in pairs(bands) do
					expect(type(words.title)).toBe("string")
					expect(type(words.text)).toBe("string")
					expect(string.find(words.text, "%d")).toBe(nil) -- no numbers in a clue
					expect(NestClues.isCategory(category)).toBe(true)
					expect(#band).toBeGreaterThan(0)
				end
			end
		end)

		it("projects only categories, bands and words - never a position", function()
			local state = NestClues.newState()
			local direction =
				NestClues.clueFor(cfg, layout, "direction", { worldX = -8, worldZ = 366, radius = radius, depthFraction = 0.5 })
			direction.byUserId = 7
			direction.order = 1
			state.unlocked.direction = direction
			state.count = 1
			local projection = NestClues.project(cfg, state)
			expect(projection.count).toBe(1)
			expect(projection.max).toBe(NestClues.maxClues(cfg))
			expect(projection.nextCost).toBe(cfg.clues.costsRainbow[2])
			expect(projection.unlocked.direction.title).toBe(direction.title)
			expect(projection.unlocked.depth).toBe(nil)
			for key in pairs(projection.unlocked.direction) do
				expect(key == "category" or key == "band" or key == "title" or key == "text" or key == "byUserId" or key == "order").toBe(
					true
				)
			end
			local empty = NestClues.project(cfg, nil)
			expect(empty.count).toBe(0)
			expect(empty.nextCost).toBe(cfg.clues.costsRainbow[1])
		end)

		it("picks Plume's line from progress, the bag and the Egg", function()
			local costs = cfg.clues.costsRainbow
			expect(NestClues.lineFor(cfg, 0, 0, false)).toBe(NestClues.LINES.none)
			expect(NestClues.lineFor(cfg, 0, costs[1], false)).toBe(NestClues.LINES.none)
			expect(NestClues.lineFor(cfg, 1, costs[2] - 1, false)).toBe(NestClues.LINES.insufficient)
			expect(NestClues.lineFor(cfg, 1, costs[2], false)).toBe(NestClues.LINES.one)
			expect(NestClues.lineFor(cfg, NestClues.maxClues(cfg), 99, false)).toBe(NestClues.LINES.all)
			expect(NestClues.lineFor(cfg, 0, 99, true)).toBe(NestClues.LINES.found)
		end)
	end)
end
