--!nocheck
-- Surface-first targeting for the Nest Rake and the Feather Vac (PileTargeting): the strike is the
-- first record the aim meets, a record hidden under or behind another is never taken before it, the
-- top layer goes first, and a use never takes more than its count.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local PileSurface = require(Shared.Domain.PileSurface)
	local PileGrid = require(Shared.Domain.PileGrid)
	local PileTargeting = require(Shared.Domain.PileTargeting)
	local FeatherLayout = require(Shared.Domain.FeatherLayout)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local layout = ChapterLayout.chapter1

	-- The round's real pile: full-depth columns, no variance.
	local function newPile()
		local pile = cfg.pile
		local grid = PileGrid.create(pile, 1, {}, function()
			return 0.5
		end, function(x, z)
			return PileSurface.columnRecords(cfg, pile.gridWidth, pile.gridDepth, pile.cellSizeStuds, x, z)
		end)
		local snapshot = PileGrid.snapshot(grid)
		local seatField = PileSurface.buildField(cfg, {
			width = grid.width,
			depth = grid.depth,
			cellSize = grid.cellSize,
			remaining = table.clone(snapshot.base),
			base = snapshot.base,
		}, layout)
		local minCorner = ChapterLayout.gridMinCorner(layout, grid.width, grid.depth, grid.cellSize)
		return grid, seatField, minCorner
	end

	local function model(grid, seatField, minCorner)
		return PileTargeting.newModel(cfg, grid, seatField, minCorner)
	end

	local function cellAt(grid, x, z)
		return grid.cells[PileGrid.index(grid.width, x, z)]
	end

	local function vac(origin, direction, amount, extra)
		local query = {
			origin = origin,
			direction = direction,
			maxDistance = 30,
			amount = amount,
			shape = "cone",
			radiusStuds = cfg.tools.featherVac.suctionRadiusStuds,
			reachStuds = cfg.tools.featherVac.reachStuds,
			perCellCap = cfg.tools.featherVac.maxPerCellPerTick,
		}
		for key, value in pairs(extra or {}) do
			query[key] = value
		end
		return query
	end

	local function indexOf(list, value)
		return table.find(list, value) or math.huge
	end

	describe("Exposure", function()
		it("a record directly below the surface record under the reticle is hidden and never chosen before it", function()
			local grid, seatField, minCorner = newPile()
			local cx, cz = grid.width // 2, grid.depth // 2
			local cell = cellAt(grid, cx, cz)
			local top, below = cell.base, cell.base - 1
			local m = model(grid, seatField, minCorner)
			local topSeat = PileTargeting.seat(m, cell, top)
			-- The player stands a little off the column and looks down at its top record.
			local origin = topSeat + Vector3.new(1.5, 5, 1)
			local direction = (topSeat - origin).Unit
			expect(PileTargeting.visibleFrom(m, cell, top, origin)).toBe(true)
			expect(PileTargeting.visibleFrom(m, cell, below, origin)).toBe(false)
			local hit = PileTargeting.firstHit(m, origin, direction, 30)
			expect(hit).toBeTruthy()
			-- Straight down the reticle the first record met is a top record (this column's, or a
			-- neighbour's slab overlapping it), never one under the coat.
			local hitCell = grid.cells[hit.cellIndex]
			expect(hit.slot).toBe(hitCell.base)

			-- Even when the client names the buried record, the server refuses it and strikes the surface.
			local hinted = PileTargeting.select(
				m,
				vac(origin, direction, 12, { hintFeatherId = FeatherLayout.featherId(cell.index, below), hintToleranceStuds = 2 })
			)
			expect(#hinted.featherIds).toBe(12)
			expect(hinted.primary).toBe(hit.featherId)
			local belowId = FeatherLayout.featherId(cell.index, below)
			local topId = FeatherLayout.featherId(cell.index, top)
			expect(indexOf(hinted.featherIds, belowId) > indexOf(hinted.featherIds, topId)).toBe(true)

			-- Naming the surface record itself makes it the strike and the first record taken.
			local m2 = model(grid, seatField, minCorner)
			local aimed = PileTargeting.select(m2, vac(origin, direction, 12, { hintFeatherId = topId, hintToleranceStuds = 2 }))
			expect(aimed.featherIds[1]).toBe(topId)
			expect(aimed.primary).toBe(topId)
			expect(table.find(aimed.featherIds, belowId)).toBeNil()
		end)

		it("a record behind a blocking record along the ray is not chosen", function()
			local grid, seatField, minCorner = newPile()
			local cx, cz = grid.width // 2, grid.depth // 2
			-- A trench on the +X side: column (cx, cz) is its wall, (cx - 1, cz) stands behind the wall.
			for dx = 1, 6 do
				for dz = -3, 3 do
					local pit = cellAt(grid, cx + dx, cz + dz)
					PileGrid.remove(grid, pit, pit.remaining)
				end
			end
			local m = model(grid, seatField, minCorner)
			local wall = cellAt(grid, cx, cz)
			local frontSlot = wall.base - 8
			local seat = PileTargeting.seat(m, wall, frontSlot)
			-- Standing in the trench, looking straight into the wall record.
			local origin = seat + Vector3.new(1.6, 0.05, 0)
			local direction = (seat - origin).Unit
			local front = PileTargeting.firstHit(m, origin, direction, 30)
			expect(front).toBeTruthy()
			expect(front.cellIndex).toBe(wall.index)
			-- The record the same line meets inside the column behind the wall.
			local cellSize = grid.cellSize
			local behindCell = cellAt(grid, cx - 1, cz)
			local behindCentreX = minCorner.X + (cx - 1 + 0.5) * cellSize
			local probe = origin + direction * ((origin.X - behindCentreX) / -direction.X)
			local occupant, behindSlot = PileTargeting.occupantAt(m, probe)
			expect(occupant).toBe(behindCell)
			local behindId = FeatherLayout.featherId(behindCell.index, behindSlot)
			expect(PileTargeting.visibleFrom(m, wall, front.slot, origin)).toBe(true)
			expect(PileTargeting.visibleFrom(m, behindCell, behindSlot, origin)).toBe(false)
			-- A hint naming the hidden record is refused; a one-record use takes the front record.
			expect(PileTargeting.validateHint(m, behindId, origin, direction, 30, 2)).toBeNil()
			local one = PileTargeting.select(m, vac(origin, direction, 1, { hintFeatherId = behindId, hintToleranceStuds = 2 }))
			expect(#one.featherIds).toBe(1)
			expect(one.featherIds[1]).toBe(front.featherId)
			-- A full nozzle on the same line: the covered record is never among the first layer, and
			-- never before the record covering it.
			local m2 = model(grid, seatField, minCorner)
			local suction = PileTargeting.select(m2, vac(origin, direction, 8))
			expect(suction.featherIds[1]).toBe(front.featherId)
			expect(table.find(suction.featherIds, behindId)).toBeNil()
		end)

		it("a dug neighbour exposes the pit wall: the wall's records are visible from inside the pit", function()
			local grid, seatField, minCorner = newPile()
			local cx, cz = grid.width // 2, grid.depth // 2
			local wall = cellAt(grid, cx, cz)
			for dx = 1, 3 do
				for dz = -1, 1 do
					local pit = cellAt(grid, cx + dx, cz + dz)
					PileGrid.remove(grid, pit, pit.remaining)
				end
			end
			local m = model(grid, seatField, minCorner)
			local slot = wall.base - 6
			local seat = PileTargeting.seat(m, wall, slot)
			local eye = Vector3.new(seat.X + 1.4, seat.Y + 0.2, seat.Z)
			expect(PileTargeting.visibleFrom(m, wall, slot, eye)).toBe(true)
			-- From above the wall column the same record is buried under its own column.
			expect(PileTargeting.visibleFrom(m, wall, slot, seat + Vector3.new(-0.3, 6, 0))).toBe(false)
		end)
	end)

	describe("Selection", function()
		it("is surface first: the strike leads, the whole top layer goes before any record beneath it", function()
			local grid, seatField, minCorner = newPile()
			local cx, cz = grid.width // 2, grid.depth // 2
			local cell = cellAt(grid, cx, cz)
			local m = model(grid, seatField, minCorner)
			local seat = PileTargeting.seat(m, cell, cell.base)
			local origin = seat + Vector3.new(0.5, 5, 0.5)
			local direction = (seat - origin).Unit
			local selection = PileTargeting.select(m, vac(origin, direction, 10))
			expect(#selection.featherIds).toBe(10)
			local hit = PileTargeting.firstHit(model(grid, seatField, minCorner), origin, direction, 30)
			expect(selection.featherIds[1]).toBe(hit.featherId)
			expect(selection.primary).toBe(hit.featherId)
			-- Plenty of top records lie inside the nozzle radius, so every pick is a column top.
			for _, record in ipairs(selection.records) do
				expect(record.slot).toBe(grid.cells[record.index].base)
			end
			-- Ordered by distance from the strike after the strike itself.
			local strike = selection.strike
			local last = 0
			for i = 2, #selection.records do
				local record = selection.records[i]
				local d = (PileTargeting.seat(model(grid, seatField, minCorner), grid.cells[record.index], record.slot) - strike).Magnitude
				expect(d + 1e-9).toBeGreaterThanOrEqual(last)
				last = d
			end
		end)

		it("never takes more than the tool's count or the per-column cap, and digs a column top down", function()
			local grid, seatField, minCorner = newPile()
			local cx, cz = grid.width // 2, grid.depth // 2
			local cell = cellAt(grid, cx, cz)
			local seat = PileTargeting.seat(model(grid, seatField, minCorner), cell, cell.base)
			local origin = seat + Vector3.new(0.4, 5, 0.3)
			local direction = (seat - origin).Unit
			for _, amount in ipairs({ 1, 5, 26 }) do
				local selection = PileTargeting.select(model(grid, seatField, minCorner), vac(origin, direction, amount))
				expect(#selection.featherIds).toBe(amount)
			end
			-- A deep use: more than the top layer inside a small nozzle, so it peels layers.
			local m = model(grid, seatField, minCorner)
			local deep = PileTargeting.select(m, vac(origin, direction, 40, { radiusStuds = 0.8, perCellCap = 3 }))
			expect(#deep.featherIds).toBeGreaterThan(0)
			expect(#deep.featherIds).toBeLessThanOrEqual(40)
			local perCell = {}
			local seen = {}
			for i, record in ipairs(deep.records) do
				perCell[record.index] = (perCell[record.index] or 0) + 1
				expect(perCell[record.index]).toBeLessThanOrEqual(3)
				local id = FeatherLayout.featherId(record.index, record.slot)
				expect(seen[id]).toBeNil()
				seen[id] = i
				-- Every record above it in its column was present and was taken first.
				local column = grid.cells[record.index]
				for above = record.slot + 1, column.base do
					expect(seen[FeatherLayout.featherId(record.index, above)]).toBeTruthy()
				end
			end
			-- Selection does not touch the grid: the service removes exactly what was chosen.
			expect(grid.removed).toBe(0)
			local records = {}
			for _, record in ipairs(deep.records) do
				table.insert(records, { cell = grid.cells[record.index], slot = record.slot })
			end
			local removals, total = PileGrid.removeRecords(grid, records)
			expect(total).toBe(#deep.featherIds)
			local removedIds = {}
			for _, removal in ipairs(removals) do
				for _, slot in ipairs(removal.slots) do
					removedIds[FeatherLayout.featherId(removal.index, slot)] = true
				end
				expect(removal.mask).toBe(grid.cells[removal.index].taken)
			end
			for _, id in ipairs(deep.featherIds) do
				expect(removedIds[id]).toBe(true)
			end
		end)

		it("the rake sweep takes exposed top records inside its fan, led by the record under the reticle", function()
			local grid, seatField, minCorner = newPile()
			local cx, cz = grid.width // 2 + 6, grid.depth // 2
			local cell = cellAt(grid, cx, cz)
			local m = model(grid, seatField, minCorner)
			local seat = PileTargeting.seat(m, cell, cell.base)
			local origin = seat + Vector3.new(4, 4, 0)
			local direction = (seat - origin).Unit
			local rake = cfg.tools.nestRake
			local query = {
				origin = origin,
				direction = direction,
				maxDistance = 30,
				amount = cfg.toolUpgrades.nestRake.sweep[1].yield,
				shape = "sweep",
				radiusStuds = rake.sweepRadiusStuds,
				halfWidthStuds = rake.sweepHalfWidthStuds,
				aheadStuds = rake.sweepAheadStuds,
				perCellCap = rake.maxPerCellPerSweep,
				headLiftStuds = 1.5,
				hintFeatherId = FeatherLayout.featherId(cell.index, cell.base),
				hintToleranceStuds = 2,
			}
			local selection = PileTargeting.select(m, query)
			expect(#selection.featherIds).toBe(query.amount)
			expect(selection.featherIds[1]).toBe(FeatherLayout.featherId(cell.index, cell.base))
			local flat = Vector3.new(direction.X, 0, direction.Z).Unit
			for _, record in ipairs(selection.records) do
				local column = grid.cells[record.index]
				expect(record.slot).toBe(column.base)
				local p = PileTargeting.seat(model(grid, seatField, minCorner), column, record.slot)
				local v = p - selection.strike
				local lateral = math.abs(v.X * flat.Z - v.Z * flat.X)
				local along = v.X * flat.X + v.Z * flat.Z
				expect(lateral).toBeLessThanOrEqual(rake.sweepHalfWidthStuds + 1e-6)
				expect(along).toBeLessThanOrEqual(rake.sweepAheadStuds + 1e-6)
				expect(along).toBeGreaterThanOrEqual(-rake.sweepRadiusStuds - 1e-6)
			end
		end)
	end)
end
