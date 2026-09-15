--!nocheck
-- Invisible collision shell: one anchored, invisible, non-queryable box per cell, top face on the
-- logical surface minus the inset, re-written only for the touched region, removed on clear.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Server = game:GetService("ServerScriptService").Server
	local Config = require(Shared.Config)
	local PileGrid = require(Shared.Domain.PileGrid)
	local PileSurface = require(Shared.Domain.PileSurface)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local PileTerrainService = require(Server.Services.PileTerrainService)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1

	local function service(parent)
		return PileTerrainService.new({ config = cfg, adapter = PileTerrainService.partsAdapter(parent) })
	end

	describe("Shell", function()
		it("writes one collidable box per cell forming the visible mound body just under the coat, then clears", function()
			local parent = Instance.new("Folder")
			local grid = PileGrid.create(cfg.pile, 1, {}, function()
				return 0.5
			end)
			local runtime = { state = { chapter = "chapter1", roundId = "r" }, grid = grid }
			local svc = service(parent)
			svc:build(runtime)
			local folder = parent:FindFirstChild(cfg.pile.collision.shellFolderName)
			expect(folder).toBeTruthy()
			expect(#folder:GetChildren()).toBe(grid.width * grid.depth)
			local field = PileSurface.buildField(cfg, PileGrid.snapshot(grid), layout)
			local centreIndex = 8 * grid.width + 8 + 1
			local box = folder:FindFirstChild("Shell" .. centreIndex)
			expect(box.Anchored).toBe(true)
			expect(box.CanCollide).toBe(true)
			expect(box.CanQuery).toBe(false)
			-- The body is drawn: a gap between coat feathers must show packed mass, not the ground.
			expect(box.Transparency).toBe(0)
			local cx = field.minX + 8.5 * field.cellSize
			local cz = field.minZ + 8.5 * field.cellSize
			-- It seats a whole rendered stack below the surface so it never buries the coat.
			local visual = cfg.pile.visual
			local full = PileSurface.columnFullHeight(cfg, grid.width, grid.depth, grid.cellSize, 8, 8)
			local records = math.clamp(math.floor(math.max(cfg.pile.minRecordsPerColumn or 1, full / cfg.pile.recordSpacingStuds)), 1, 32)
			local step = math.max(full / records, visual.minSeatStepStuds or 0)
			local slots = PileSurface.coatSlots(cfg, grid.width, grid.depth, grid.cellSize, 8, 8, records, visual.visibleSlotsPerCell)
			local coatSpan = (slots - 1) * step + visual.coatSpanMarginStuds
			local expectedTop = field.baseY + PileSurface.heightAt(field, cx, cz) - cfg.pile.collision.surfaceInsetStuds - coatSpan
			local top = (box.CFrame * CFrame.new(0, box.Size.Y / 2, 0)).Position
			expect(math.abs(top.Y - expectedTop)).toBeLessThan(0.05)
			expect(math.abs(box.Size.X - field.cellSize * cfg.pile.collision.shellOverlap)).toBeLessThan(0.01)
			-- Solid, not a slab: it is axis-aligned and reaches from below the nest floor up to the top,
			-- so no sight line can pass under the body at any angle.
			expect(box.CFrame.UpVector.Y).toBe(1)
			local bottom = (box.CFrame * CFrame.new(0, -box.Size.Y / 2, 0)).Position
			expect(bottom.Y <= math.min(field.groundY, field.baseY) - cfg.pile.collision.bodyBuryStuds + 0.01).toBe(true)
			-- A rewrite of a small region moves only boxes inside it.
			local cell = grid.cells[centreIndex]
			for _ = 1, cell.remaining do
				PileGrid.remove(grid, cell, 1)
			end
			local farIndex = 2 * grid.width + 2 + 1
			local farBefore = folder:FindFirstChild("Shell" .. farIndex).CFrame
			local topBefore = top.Y
			svc:rewrite(runtime, cx - 1, cz - 1, cx + 1, cz + 1)
			local after = (box.CFrame * CFrame.new(0, box.Size.Y / 2, 0)).Position.Y
			expect(after).toBeLessThan(topBefore)
			expect((folder:FindFirstChild("Shell" .. farIndex).CFrame.Position - farBefore.Position).Magnitude).toBeLessThan(1e-6)
			svc:clear(runtime)
			expect(parent:FindFirstChild(cfg.pile.collision.shellFolderName)).toBeNil()
		end)
	end)
end
