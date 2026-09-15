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
		it("writes one collidable, invisible box per cell topped at the surface, then clears", function()
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
			local mid = math.floor(grid.width / 2)
			local centreIndex = mid * grid.width + mid + 1
			local box = folder:FindFirstChild("Shell" .. centreIndex)
			expect(box.Anchored).toBe(true)
			expect(box.CanCollide).toBe(true)
			expect(box.CanQuery).toBe(false)
			-- Invisible. A visible body had to sit below the whole coat so it would not bury the records,
			-- and once the coat deepened to cover a pit wall that put the thing you stand on eleven studs
			-- under the feathers you can see. It hides nothing now, so it can top out at the surface.
			expect(box.Transparency).toBe(1)
			local cx = field.minX + (mid + 0.5) * field.cellSize
			local cz = field.minZ + (mid + 0.5) * field.cellSize
			-- You stand where the feathers are: the top face is the column's topmost remaining record,
			-- which is what the renderer draws - not the 3x3-smoothed surface, which on a dug column
			-- stands above the highest feather left and on its neighbours sits below feathers that
			-- never moved.
			local visual = cfg.pile.visual
			local full = PileSurface.columnFullHeight(cfg, grid.width, grid.depth, grid.cellSize, mid, mid)
			local records = math.clamp(math.floor(math.max(cfg.pile.minRecordsPerColumn or 1, full / cfg.pile.recordSpacingStuds)), 1, 32)
			local step = math.max(full / records, visual.minSeatStepStuds or 0)
			local expectedTop = field.baseY + PileSurface.columnTop(field, mid, mid, step) - cfg.pile.collision.surfaceInsetStuds
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
