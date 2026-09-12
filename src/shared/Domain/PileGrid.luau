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

return PileGrid
