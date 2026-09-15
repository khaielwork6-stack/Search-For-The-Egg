--!strict
-- Pure logical pile grid (MASTER_SPEC section 6 "Pile model"): a width x depth array of cells, each
-- holding `base` individually collectible feather records (slots 1..base; `taken` is a bitmask of
-- collected slots, `remaining` the count still present). The server owns the only mutable instance
-- per round; clients receive snapshots/deltas (remaining + mask per cell). No Roblox instances here so
-- it runs headlessly and in Studio identically.

local PileGrid = {}

PileGrid.MAX_SLOTS = 32 -- one bit per record in the taken mask (bit32)

export type Cell = {
	index: number, -- 1-based, row-major (z * width + x + 1)
	x: number, -- 0-based column
	z: number, -- 0-based row
	base: number, -- feathers at round start
	remaining: number,
	taken: number, -- bitmask: bit (slot - 1) set when that feather has been collected
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

export type Removal = { index: number, remaining: number, removed: number, mask: number, slots: { number } }

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
	roll: () -> number,
	columnRecords: ((x: number, z: number) -> number)?
): Grid
	local width, depth = pileConfig.gridWidth, pileConfig.gridDepth
	local cells: { Cell } = {}
	local total = 0
	for z = 0, depth - 1 do
		for x = 0, width - 1 do
			local index = PileGrid.index(width, x, z)
			local variance = 1 + (roll() * 2 - 1) * pileConfig.surfaceVariance
			-- Full-depth columns (the real pile): records from the floor to the dome surface; the flat
			-- per-cell count is the headless default.
			local perCell = if columnRecords then columnRecords(x, z) else pileConfig.baseFeathersPerCell
			local base = perCell * healthMultiplier * variance
			if coverCells[index] then
				base *= pileConfig.coverDepthMultiplier
			end
			local rounded = math.clamp(math.floor(base + 0.5), 1, PileGrid.MAX_SLOTS)
			cells[index] = { index = index, x = x, z = z, base = rounded, remaining = rounded, taken = 0 }
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

-- Nearest cell (within `radius` cells of (x, z)) whose 3x3 neighbourhood still holds at least
-- `minimumRecords` feathers, preferring the exact cell; nil when none qualifies. Area workers use it
-- so they do not walk to a one-feather rim column and come back with a partial load.
function PileGrid.findRichTarget(grid: Grid, x: number, z: number, radius: number, minimumRecords: number): Cell?
	local best: Cell? = nil
	local bestDistance = math.huge
	for dz = -radius, radius do
		for dx = -radius, radius do
			local cell = PileGrid.get(grid, x + dx, z + dz)
			if cell and cell.remaining > 0 then
				local around = 0
				for nz = -1, 1 do
					for nx = -1, 1 do
						local neighbour = PileGrid.get(grid, cell.x + nx, cell.z + nz)
						if neighbour then
							around += neighbour.remaining
						end
					end
				end
				if around >= minimumRecords then
					local distance = dx * dx + dz * dz
					if distance < bestDistance then
						best, bestDistance = cell, distance
					end
				end
			end
		end
	end
	return best
end

local function slotBit(slot: number): number
	return bit32.lshift(1, slot - 1)
end

function PileGrid.isTaken(cell: Cell, slot: number): boolean
	return bit32.band(cell.taken, slotBit(slot)) ~= 0
end

-- Highest untaken slot of a cell (the top of its stack), or nil when empty.
function PileGrid.topSlot(cell: Cell): number?
	for slot = cell.base, 1, -1 do
		if not PileGrid.isTaken(cell, slot) then
			return slot
		end
	end
	return nil
end

-- Removes exactly one specific feather record. Returns the removal, or nil when the slot is invalid
-- or already taken (nothing changes).
function PileGrid.removeFeather(grid: Grid, cell: Cell, slot: number): Removal?
	if slot < 1 or slot > cell.base or slot % 1 ~= 0 or PileGrid.isTaken(cell, slot) then
		return nil
	end
	cell.taken = bit32.bor(cell.taken, slotBit(slot))
	cell.remaining -= 1
	grid.removed += 1
	grid.version += 1
	return { index = cell.index, remaining = cell.remaining, removed = 1, mask = cell.taken, slots = { slot } }
end

-- Atomically removes up to `amount` feathers from the top of the cell's stack (area tools, debug).
-- Returns the removal (removed may be 0).
function PileGrid.remove(grid: Grid, cell: Cell, amount: number): Removal
	assert(amount >= 0 and amount % 1 == 0, "amount must be a non-negative integer")
	local slots = {}
	local removed = 0
	while removed < amount do
		local slot = PileGrid.topSlot(cell)
		if not slot then
			break
		end
		cell.taken = bit32.bor(cell.taken, slotBit(slot))
		cell.remaining -= 1
		grid.removed += 1
		removed += 1
		table.insert(slots, slot)
	end
	if removed > 0 then
		grid.version += 1
	end
	return { index = cell.index, remaining = cell.remaining, removed = removed, mask = cell.taken, slots = slots }
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
	local masks = table.create(#grid.cells)
	for index, cell in ipairs(grid.cells) do
		remaining[index] = cell.remaining
		base[index] = cell.base
		masks[index] = cell.taken
	end
	return {
		width = grid.width,
		depth = grid.depth,
		cellSize = grid.cellSize,
		remaining = remaining,
		base = base,
		masks = masks,
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
-- Focused removal: `cells` come sorted by distance with a weight each (centre high, rim low); each
-- cell gets a quota of `amount` in proportion to its weight and gives up that many records from its
-- top, leftovers round-robin. The result is a dent that is deep where the tool struck and shallow
-- at the edge, instead of one record from every cell.
function PileGrid.removeFocused(grid: Grid, cells: { Cell }, weights: { number }, amount: number): ({ Removal }, number)
	assert(amount >= 0 and amount % 1 == 0, "amount must be a non-negative integer")
	local taken: { [number]: { number } } = {}
	local total = 0
	local function take(cell: Cell, count: number): number
		local got = 0
		while got < count do
			local slot = PileGrid.topSlot(cell)
			if not slot then
				break
			end
			cell.taken = bit32.bor(cell.taken, slotBit(slot))
			cell.remaining -= 1
			grid.removed += 1
			taken[cell.index] = taken[cell.index] or {}
			table.insert(taken[cell.index], slot)
			got += 1
		end
		return got
	end
	local weightSum = 0
	for i = 1, #cells do
		weightSum += math.max(0, weights[i] or 0)
	end
	local remainingAmount = amount
	if weightSum > 0 then
		for i, cell in ipairs(cells) do
			if remainingAmount <= 0 then
				break
			end
			local quota = math.min(remainingAmount, math.floor(amount * math.max(0, weights[i] or 0) / weightSum + 0.5))
			remainingAmount -= take(cell, quota)
		end
	end
	-- Leftovers (rounding, exhausted cells): one at a time from the centre outward.
	local progress = true
	while remainingAmount > 0 and progress do
		progress = false
		for _, cell in ipairs(cells) do
			if remainingAmount <= 0 then
				break
			end
			if take(cell, 1) == 1 then
				remainingAmount -= 1
				progress = true
			end
		end
	end
	local removals: { Removal } = {}
	for _, cell in ipairs(cells) do
		local slots = taken[cell.index]
		if slots then
			grid.version += 1
			table.insert(removals, { index = cell.index, remaining = cell.remaining, removed = #slots, mask = cell.taken, slots = slots })
			total += #slots
		end
	end
	return removals, total
end

-- Centre-heavy weights for cells sorted by distance from a strike: the struck cell takes `focus`
-- of the yield, the rest falls off with distance.
function PileGrid.focusWeights(grid: Grid, cells: { Cell }, localX: number, localZ: number, radiusStuds: number, focus: number): { number }
	local weights: { number } = {}
	local ringSum = 0
	for i, cell in ipairs(cells) do
		local cx, cz = PileGrid.cellCenter(grid, cell)
		local d = math.sqrt((cx - localX) ^ 2 + (cz - localZ) ^ 2)
		local w = if i == 1 then 0 else math.max(0.05, (1 - d / math.max(radiusStuds, 0.01)) ^ 2)
		weights[i] = w
		ringSum += w
	end
	if #cells > 0 then
		weights[1] = if #cells == 1 then 1 else (ringSum * focus / math.max(0.01, 1 - focus))
	end
	return weights
end

function PileGrid.removeSpread(grid: Grid, cells: { Cell }, amount: number): ({ Removal }, number)
	assert(amount >= 0 and amount % 1 == 0, "amount must be a non-negative integer")
	local taken: { [number]: { number } } = {}
	local remainingAmount = amount
	local progress = true
	while remainingAmount > 0 and progress do
		progress = false
		for _, cell in ipairs(cells) do
			if remainingAmount <= 0 then
				break
			end
			local slot = PileGrid.topSlot(cell)
			if slot then
				cell.taken = bit32.bor(cell.taken, slotBit(slot))
				cell.remaining -= 1
				grid.removed += 1
				taken[cell.index] = taken[cell.index] or {}
				table.insert(taken[cell.index], slot)
				remainingAmount -= 1
				progress = true
			end
		end
	end
	local removals: { Removal } = {}
	local total = 0
	for _, cell in ipairs(cells) do
		local slots = taken[cell.index]
		if slots then
			grid.version += 1
			table.insert(removals, { index = cell.index, remaining = cell.remaining, removed = #slots, mask = cell.taken, slots = slots })
			total += #slots
		end
	end
	return removals, total
end

return PileGrid
