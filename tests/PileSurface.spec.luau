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
			local centre = PileSurface.columnHeight(field, 8, 8)
			local mid = PileSurface.columnHeight(field, 4, 8)
			local rim = PileSurface.columnHeight(field, 0, 8)
			expect(centre).toBeGreaterThan(mid)
			expect(mid).toBeGreaterThan(rim)
			expect(rim).toBeGreaterThan(0)
			expect(centre).toBeLessThanOrEqual(cfg.pile.maxVisualHeightStuds)
			expect(centre).toBeGreaterThan(cfg.pile.maxVisualHeightStuds * 0.85)
			expect(PileSurface.domeProfile(0)).toBe(1)
			expect(PileSurface.domeProfile(2)).toBe(0)
		end)

		it("clearing cells lowers a soft hollow and an empty grid is flat", function()
			local grid, snapshot = fullGrid()
			local before = PileSurface.buildField(cfg, snapshot, layout)
			local centreIndex = 8 * grid.width + 8 + 1
			local cell = grid.cells[centreIndex]
			PileGrid.remove(grid, cell, cell.remaining)
			local after = PileSurface.buildField(cfg, PileGrid.snapshot(grid), layout)
			expect(PileSurface.columnHeight(after, 8, 8)).toBeLessThan(PileSurface.columnHeight(before, 8, 8))
			expect(PileSurface.columnHeight(after, 9, 8)).toBeLessThan(PileSurface.columnHeight(before, 9, 8))
			expect(PileSurface.columnHeight(after, 12, 8)).toBeCloseTo(PileSurface.columnHeight(before, 12, 8), 1e-9)
			for _, c in ipairs(grid.cells) do
				PileGrid.remove(grid, c, c.remaining)
			end
			local empty = PileSurface.buildField(cfg, PileGrid.snapshot(grid), layout)
			for x = 0, grid.width - 1 do
				expect(PileSurface.columnHeight(empty, x, 8)).toBe(0)
			end
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
			local column = ChapterLayout.cellWorldPosition(layout, 16, 16, cfg.pile.cellSizeStuds, 3, 11, 0)
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
		it("resolves an upward aim at the dome face from the rim to a nearby cell within range", function()
			local h = GameplayHarness.new(cfg)
			h.join(1)
			local _, runtime = h.startRound({ 1 })
			local centre = layout.nestCenter
			local radius = runtime.grid.width * runtime.grid.cellSize / 2
			local standing = Vector3.new(centre.X, layout.nestBaseY + 2, centre.Z - (radius + 4))
			h.standAt(1, standing)
			h.clock:advance(1)
			local origin = standing + Vector3.new(0, 1.5, 0)
			local result = h.collection:collect(
				1,
				{ sessionToken = h.token(1), origin = origin, direction = Vector3.new(0, 0.2, 1).Unit, toolId = "hand" }
			)
			expect(result.ok).toBe(true)
			expect(result.data.awarded).toBe(1)
			-- The cell hit sits on the near face, not across the mound.
			expect(result.data.hitZ).toBeLessThan(centre.Z)
			-- A ray that starts inside the mound (no surface entry) resolves through the aim plane.
			h.standAt(1, Vector3.new(centre.X, layout.nestBaseY + 2, centre.Z))
			h.clock:advance(1)
			local fallback = h.collection:collect(1, {
				sessionToken = h.token(1),
				origin = Vector3.new(centre.X, layout.nestBaseY + 3.5, centre.Z),
				direction = Vector3.new(0, -1, 0),
				toolId = "hand",
			})
			expect(fallback.ok).toBe(true)
			-- A hit on the mound's skirt (past the logical footprint but under the surface) resolves to
			-- the nearest edge cell instead of "outside_nest".
			local foot = radius * PileSurface.RIM_STRETCH
			h.standAt(1, Vector3.new(centre.X, layout.nestBaseY + 2, centre.Z - (foot + 5)))
			h.clock:advance(1)
			local skirt = h.collection:collect(1, {
				sessionToken = h.token(1),
				origin = Vector3.new(centre.X, layout.nestBaseY + 3.5, centre.Z - (foot + 5)),
				direction = (Vector3.new(centre.X, layout.nestBaseY + 0.6, centre.Z - (foot - 1.5)) - Vector3.new(
					centre.X,
					layout.nestBaseY + 3.5,
					centre.Z - (foot + 5)
				)).Unit,
				toolId = "hand",
			})
			expect(skirt.ok).toBe(true)
			expect(skirt.data.hitZ).toBeLessThan(centre.Z - (radius - 2)) -- resolved edge-row cell centre
			local hitCell = runtime.grid.cells[skirt.data.cellIndex]
			expect(hitCell.z).toBe(0) -- the nearest edge row, never "outside_nest"
			expect(hitCell.remaining).toBeLessThan(hitCell.base)
			-- The harness aim lands on exactly the requested column.
			local exact = h.collectAt(1, runtime, 3, 12)
			expect(exact.ok).toBe(true)
			expect(runtime.grid.cells[12 * runtime.grid.width + 3 + 1].remaining).toBeLessThan(
				runtime.grid.cells[12 * runtime.grid.width + 3 + 1].base
			)
		end)
	end)
end
