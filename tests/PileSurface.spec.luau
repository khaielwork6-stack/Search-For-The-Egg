--!nocheck
-- Shared pile surface (A-UX-07): dome shape from the logical cells, continuous height field, ray
-- march that enters from above only, and server aim resolution against the dome.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local PileSurface = require(Shared.Domain.PileSurface)
	local PileGrid = require(Shared.Domain.PileGrid)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local GameplayHarness = require(ServerStorage.Tests.Helpers.GameplayHarness)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1

	local function fullGrid()
		local grid = PileGrid.create(cfg.pile, 1, {}, function()
			return 0.5
		end)
		return grid, PileGrid.snapshot(grid)
	end

	describe("Field", function()
		it("is a dome: tallest at the centre, lower at the rim, never above the configured apex", function()
			local _, snapshot = fullGrid()
			local field = PileSurface.buildField(cfg, snapshot, layout)
			local cx, cz = field.width // 2, field.depth // 2
			local centre = PileSurface.columnHeight(field, cx, cz)
			local mid = PileSurface.columnHeight(field, cx // 2, cz)
			local rim = PileSurface.columnHeight(field, 0, cz)
			expect(centre).toBeGreaterThan(mid)
			expect(mid).toBeGreaterThan(rim)
			expect(rim).toBeGreaterThan(0)
			expect(centre).toBeLessThanOrEqual(cfg.pile.maxVisualHeightStuds)
			expect(centre).toBeGreaterThan(cfg.pile.maxVisualHeightStuds * 0.85)
			expect(PileSurface.domeProfile(0)).toBe(1)
			expect(PileSurface.domeProfile(2)).toBe(0)
		end)

		it("one record barely moves the surface; an emptied column reaches the floor", function()
			local grid, snapshot = fullGrid()
			local before = PileSurface.buildField(cfg, snapshot, layout)
			local cx, cz = grid.width // 2, grid.depth // 2
			local cell = grid.cells[PileGrid.index(grid.width, cx, cz)]
			PileGrid.remove(grid, cell, 1)
			local one = PileSurface.buildField(cfg, PileGrid.snapshot(grid), layout)
			local full = PileSurface.columnHeight(before, cx, cz)
			local drop = full - PileSurface.columnHeight(one, cx, cz)
			-- Centre weight 4/16 of one record's share of the column.
			expect(drop).toBeCloseTo(full * (1 / cell.base) * 4 / 16, 1e-9)
			expect(PileSurface.columnHeight(one, cx + cx // 2, cz)).toBeCloseTo(PileSurface.columnHeight(before, cx + cx // 2, cz), 1e-9)
			PileGrid.remove(grid, cell, cell.remaining)
			local after = PileSurface.buildField(cfg, PileGrid.snapshot(grid), layout)
			expect(PileSurface.columnHeight(after, cx, cz)).toBeLessThan(PileSurface.columnHeight(one, cx, cz))
			expect(PileSurface.columnHeight(after, cx + 1, cz)).toBeLessThan(PileSurface.columnHeight(before, cx + 1, cz))
			for _, c in ipairs(grid.cells) do
				PileGrid.remove(grid, c, c.remaining)
			end
			local empty = PileSurface.buildField(cfg, PileGrid.snapshot(grid), layout)
			for x = 0, grid.width - 1 do
				expect(PileSurface.columnHeight(empty, x, cz)).toBe(0)
			end
			-- Full-depth columns: records follow the dome, capped at the mask width.
			local records = PileSurface.columnRecords(cfg, grid.width, grid.depth, grid.cellSize, cx, cz)
			expect(records).toBeCloseTo(
				PileSurface.columnFullHeight(cfg, grid.width, grid.depth, grid.cellSize, cx, cz) / cfg.pile.recordSpacingStuds,
				1e-9
			)
			expect(PileSurface.columnRecords(cfg, grid.width, grid.depth, grid.cellSize, 0, 0)).toBeGreaterThanOrEqual(1)
		end)

		it("interpolates a continuous height between columns and returns 0 outside the nest", function()
			local _, snapshot = fullGrid()
			local field = PileSurface.buildField(cfg, snapshot, layout)
			local centre = layout.nestCenter
			local h0 = PileSurface.heightAt(field, centre.X, centre.Z)
			local h1 = PileSurface.heightAt(field, centre.X + 1, centre.Z)
			local h2 = PileSurface.heightAt(field, centre.X + 2.5, centre.Z)
			expect(h0).toBeGreaterThan(0)
			expect(math.abs(h0 - h1)).toBeLessThan(1)
			expect(h1).toBeGreaterThanOrEqual(h2)
			expect(PileSurface.heightAt(field, centre.X + 100, centre.Z)).toBe(0)
			-- Column centres agree with the continuous surface, and the rim meets the floor just
			-- outside the footprint (no cliff at the grid edge).
			local column = ChapterLayout.cellWorldPosition(layout, field.width, field.depth, cfg.pile.cellSizeStuds, 3, 11, 0)
			expect(PileSurface.heightAt(field, column.X, column.Z)).toBeCloseTo(PileSurface.columnHeight(field, 3, 11), 1e-3)
			local radius = field.radius
			local edge = PileSurface.heightAt(field, centre.X + radius, centre.Z)
			local beyond = PileSurface.heightAt(field, centre.X + radius * PileSurface.RIM_STRETCH + 0.01, centre.Z)
			expect(edge).toBeGreaterThan(0)
			expect(edge).toBeLessThan(cfg.pile.maxVisualHeightStuds * 0.5)
			expect(beyond).toBe(0)
			local normal = PileSurface.normalAt(field, centre.X + radius * 0.5, centre.Z)
			expect(normal.Y).toBeGreaterThan(0)
			expect(normal.X).toBeGreaterThan(0) -- slopes down away from the centre
		end)
	end)

	describe("March", function()
		it("hits the dome face from outside and misses rays that start inside or point away", function()
			local _, snapshot = fullGrid()
			local field = PileSurface.buildField(cfg, snapshot, layout)
			local centre = layout.nestCenter
			local origin = Vector3.new(centre.X, layout.nestBaseY + 3, centre.Z - (field.radius + 6))
			local hit = PileSurface.march(field, origin, Vector3.new(0, 0.15, 1).Unit, 40, 0.5)
			expect(hit).toBeTruthy()
			expect(hit.Z).toBeGreaterThan(origin.Z)
			expect(math.abs(hit.Y - (layout.nestBaseY + PileSurface.heightAt(field, hit.X, hit.Z)))).toBeLessThan(0.15)
			local away = PileSurface.march(field, origin, Vector3.new(0, 0, -1), 40, 0.5)
			expect(away).toBeNil()
			local inside = PileSurface.march(field, Vector3.new(centre.X, layout.nestBaseY + 2, centre.Z), Vector3.new(0, -1, 0), 10, 0.5)
			expect(inside).toBeNil()
		end)
	end)

	describe("Server aim", function()
		it("resolves an upward aim at the dome face from the rim to a nearby cell within range (area tools)", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local CollectionService = require(game:GetService("ServerScriptService").Server.Services.CollectionService)
			local centre = layout.nestCenter
			local radius = runtime.grid.width * runtime.grid.cellSize / 2
			local standing = Vector3.new(centre.X, layout.nestBaseY + 2, centre.Z - (radius + 4))
			local origin = standing + Vector3.new(0, 1.5, 0)
			local aim = CollectionService.resolveAim(cfg, runtime, standing, origin, Vector3.new(0, 0.2, 1).Unit)
			expect(aim).toBeTruthy()
			-- The cell hit sits on the near face, not across the mound.
			expect(aim.hit.Z).toBeLessThan(centre.Z)
			expect(aim.cz).toBeLessThan(runtime.grid.depth / 2)
			-- A ray that starts inside the mound (no surface entry) resolves through the aim plane.
			local inside = Vector3.new(centre.X, layout.nestBaseY + 2, centre.Z)
			local fallback = CollectionService.resolveAim(cfg, runtime, inside, inside + Vector3.new(0, 1.5, 0), Vector3.new(0, -1, 0))
			expect(fallback).toBeTruthy()
			-- A hit on the mound's skirt (past the logical footprint but under the surface) resolves to
			-- the nearest edge cell instead of "outside_nest".
			local foot = radius * PileSurface.RIM_STRETCH
			local skirtStanding = Vector3.new(centre.X, layout.nestBaseY + 2, centre.Z - (foot + 5))
			local skirtOrigin = Vector3.new(centre.X, layout.nestBaseY + 3.5, centre.Z - (foot + 5))
			local skirt = CollectionService.resolveAim(
				cfg,
				runtime,
				skirtStanding,
				skirtOrigin,
				(Vector3.new(centre.X, layout.nestBaseY + 0.6, centre.Z - (foot - 1.5)) - skirtOrigin).Unit
			)
			expect(skirt).toBeTruthy()
			expect(skirt.cz).toBeGreaterThanOrEqual(-1) -- one row past the footprint at most, never "outside_nest"
			expect(PileGrid.findTarget(runtime.grid, skirt.cx, skirt.cz, 1).z).toBe(0) -- resolves to the edge row
			local _, code, message = CollectionService.resolveAim(cfg, runtime, standing, origin, Vector3.new(0, 0, -1))
			expect(code).toBe("out_of_range")
			expect(message).toBe("aim")
			-- The hand harness aim lands on exactly the requested column's exposed feather.
			local exact = h.collectAt(1, runtime, 3, 12)
			expect(exact.ok).toBe(true)
			expect(exact.data.cellIndex).toBe(12 * runtime.grid.width + 3 + 1)
			expect(runtime.grid.cells[12 * runtime.grid.width + 3 + 1].remaining).toBeLessThan(
				runtime.grid.cells[12 * runtime.grid.width + 3 + 1].base
			)
		end)

		describe("Rainbow Feathers", function()
			it("are a deterministic, seed-dependent subset of records at about the configured rate", function()
				local FeatherLayout = require(Shared.Domain.FeatherLayout)
				local cfgRainbow = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
				local chance = cfgRainbow.pile.rainbowChance
				expect(chance).toBeGreaterThan(0)
				local hits, total = 0, 0
				for cell = 1, 400 do
					for slot = 1, 8 do
						total += 1
						local a = FeatherLayout.isRainbow(cfgRainbow, 4242, cell, slot)
						expect(FeatherLayout.isRainbow(cfgRainbow, 4242, cell, slot)).toBe(a)
						if a then
							hits += 1
						end
					end
				end
				local rate = hits / total
				expect(rate).toBeGreaterThan(chance * 0.4)
				expect(rate).toBeLessThan(chance * 2.5)
				local differs = false
				for cell = 1, 50 do
					if FeatherLayout.isRainbow(cfgRainbow, 1, cell, 1) ~= FeatherLayout.isRainbow(cfgRainbow, 2, cell, 1) then
						differs = true
					end
				end
				expect(differs).toBe(true)
			end)
		end)
	end)
end
