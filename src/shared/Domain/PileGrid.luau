--!strict
-- Pure logical pile grid (MASTER_SPEC section 6 "Pile model"): a width x depth array of cells with
-- integer remaining feathers. The server owns the only mutable instance per round; clients receive
-- snapshots/deltas. No Roblox instances here so it runs headlessly and in Studio identically.

local PileGrid = {}

export type Cell = {
	index: number, -- 1-based, row-major (z * width + x + 1)
	x: number, -- 0-based column
	z: number, -- 0-based row
	base: number, -- feathers at round start
	remaining: number,
}

export type Grid = {
	width: number,
	depth: number,
	cellSize: number,
	cells: { Cell },
	total: number, -- feathers at round start
	removed: number,
	version: number, -- increments on every mutation
}

export type Removal = { index: number, remaining: number, removed: number }

function PileGrid.index(width: number, x: number, z: number): number
	return z * width + x + 1
end

-- Builds a grid from config. `healthMultiplier` (difficulty) scales density; `coverCells` (set of
-- indexes) receive `coverDepthMultiplier` density so the Egg stays buried longer. `roll` is an
-- injected [0,1) function for surface variance.
function PileGrid.create(
	pileConfig: { [string]: any },
	healthMultiplier: number,
	coverCells: { [number]: boolean },
	roll: () -> number
): Grid
	local width, depth = pileConfig.gridWidth, pileConfig.gridDepth
	local cells: { Cell } = {}
	local total = 0
	for z = 0, depth - 1 do
		for x = 0, width - 1 do
			local index = PileGrid.index(width, x, z)
			local variance = 1 + (roll() * 2 - 1) * pileConfig.surfaceVariance
			local base = pileConfig.baseFeathersPerCell * healthMultiplier * variance
			if coverCells[index] then
				base *= pileConfig.coverDepthMultiplier
			end
			local rounded = math.max(1, math.floor(base + 0.5))
			cells[index] = { index = index, x = x, z = z, base = rounded, remaining = rounded }
			total += rounded
		end
	end
	return { width = width, depth = depth, cellSize = pileConfig.cellSizeStuds, cells = cells, total = total, removed = 0, version = 1 }
end

function PileGrid.get(grid: Grid, x: number, z: number): Cell?
	if x < 0 or z < 0 or x >= grid.width or z >= grid.depth then
		return nil
	end
	return grid.cells[PileGrid.index(grid.width, x, z)]
end

-- Converts a local offset (studs, relative to the grid's min corner) to integer cell coordinates.
function PileGrid.cellAt(grid: Grid, localX: number, localZ: number): (number, number)
	return math.floor(localX / grid.cellSize), math.floor(localZ / grid.cellSize)
end

-- Cell center in local studs (relative to min corner).
function PileGrid.cellCenter(grid: Grid, cell: Cell): (number, number)
	return (cell.x + 0.5) * grid.cellSize, (cell.z + 0.5) * grid.cellSize
end

-- Finds the nearest non-empty cell within `radius` cells of (x, z), preferring the exact cell.
function PileGrid.findTarget(grid: Grid, x: number, z: number, radius: number): Cell?
	local exact = PileGrid.get(grid, x, z)
	if exact and exact.remaining > 0 then
		return exact
	end
	local best: Cell? = nil
	local bestDistance = math.huge
	for dz = -radius, radius do
		for dx = -radius, radius do
			local cell = PileGrid.get(grid, x + dx, z + dz)
			if cell and cell.remaining > 0 then
				local distance = dx * dx + dz * dz
				if distance < bestDistance then
					best, bestDistance = cell, distance
				end
			end
		end
	end
	return best
end

-- Atomically removes up to `amount` from the cell. Returns the removal (removed may be 0).
function PileGrid.remove(grid: Grid, cell: Cell, amount: number): Removal
	assert(amount >= 0 and amount % 1 == 0, "amount must be a non-negative integer")
	local removed = math.min(cell.remaining, amount)
	cell.remaining -= removed
	grid.removed += removed
	if removed > 0 then
		grid.version += 1
	end
	return { index = cell.index, remaining = cell.remaining, removed = removed }
end

function PileGrid.removedFraction(grid: Grid): number
	if grid.total == 0 then
		return 1
	end
	return grid.removed / grid.total
end

function PileGrid.allCleared(grid: Grid, indexes: { number }): boolean
	for _, index in ipairs(indexes) do
		local cell = grid.cells[index]
		if not cell or cell.remaining > 0 then
			return false
		end
	end
	return true
end

-- Client snapshot: compact arrays (remaining per cell, base per cell) plus dimensions.
function PileGrid.snapshot(grid: Grid): { [string]: any }
	local remaining = table.create(#grid.cells)
	local base = table.create(#grid.cells)
	for index, cell in ipairs(grid.cells) do
		remaining[index] = cell.remaining
		base[index] = cell.base
	end
	return {
		width = grid.width,
		depth = grid.depth,
		cellSize = grid.cellSize,
		remaining = remaining,
		base = base,
		total = grid.total,
		removed = grid.removed,
		version = grid.version,
	}
end

-- Non-empty cells within `radius` cells of (x, z), nearest first (ties by index). Used by area tools.
function PileGrid.cellsWithin(grid: Grid, x: number, z: number, radius: number): { Cell }
	local out: { Cell } = {}
	local distances: { [number]: number } = {}
	for dz = -radius, radius do
		for dx = -radius, radius do
			local cell = PileGrid.get(grid, x + dx, z + dz)
			if cell and cell.remaining > 0 then
				table.insert(out, cell)
				distances[cell.index] = dx * dx + dz * dz
			end
		end
	end
	table.sort(out, function(a, b)
		if distances[a.index] == distances[b.index] then
			return a.index < b.index
		end
		return distances[a.index] < distances[b.index]
	end)
	return out
end

-- Non-empty cells whose centre lies within `radiusStuds` of the local point, nearest first.
function PileGrid.cellsWithinStuds(grid: Grid, localX: number, localZ: number, radiusStuds: number): { Cell }
	local out: { Cell } = {}
	local distances: { [number]: number } = {}
	local r2 = radiusStuds * radiusStuds
	for _, cell in ipairs(grid.cells) do
		if cell.remaining > 0 then
			local cx, cz = PileGrid.cellCenter(grid, cell)
			local d2 = (cx - localX) ^ 2 + (cz - localZ) ^ 2
			if d2 <= r2 then
				table.insert(out, cell)
				distances[cell.index] = d2
			end
		end
	end
	table.sort(out, function(a, b)
		if distances[a.index] == distances[b.index] then
			return a.index < b.index
		end
		return distances[a.index] < distances[b.index]
	end)
	return out
end

-- Removes up to `amount` feathers spread round-robin across `cells` (one per cell per pass), so a
-- sweep touches each eligible cell at most once per pass and never exceeds the total. Returns the
-- per-cell removals (only cells that lost feathers) and the total removed.
function PileGrid.removeSpread(grid: Grid, cells: { Cell }, amount: number): ({ Removal }, number)
	assert(amount >= 0 and amount % 1 == 0, "amount must be a non-negative integer")
	local taken: { [number]: number } = {}
	local remainingAmount = amount
	local progress = true
	while remainingAmount > 0 and progress do
		progress = false
		for _, cell in ipairs(cells) do
			if remainingAmount <= 0 then
				break
			end
			if cell.remaining > 0 then
				cell.remaining -= 1
				grid.removed += 1
				taken[cell.index] = (taken[cell.index] or 0) + 1
				remainingAmount -= 1
				progress = true
			end
		end
	end
	local removals: { Removal } = {}
	local total = 0
	for _, cell in ipairs(cells) do
		local removed = taken[cell.index]
		if removed then
			grid.version += 1
			table.insert(removals, { index = cell.index, remaining = cell.remaining, removed = removed })
			total += removed
		end
	end
	return removals, total
end

return PileGrid
