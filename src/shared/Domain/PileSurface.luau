--!strict
-- Pure pile surface model shared by the server (aim resolution, collision) and the client (coat): the
-- authoritative 16x16 cells become one smooth dome. Every cell holds a column of feather records from
-- the ground to the dome surface (`pile.recordSpacingStuds` apart), so the surface height at any
-- world XZ is
--   apex * domeProfile(normalised radius) * fraction(x, z)
-- where the fraction is the bilinear interpolation of each cell's smoothed 3x3 remaining/base. One
-- record moves the surface by one spacing (barely), and a column dug to its last record reaches the
-- floor: there is always another feather under a feather. `march` walks a ray until it enters the
-- surface from above.

local PileSurface = {}

export type Field = {
	width: number,
	depth: number,
	cellSize: number,
	minX: number,
	minZ: number,
	centreX: number,
	centreZ: number,
	radius: number, -- half of the smaller footprint side
	apex: number,
	baseY: number,
	groundY: number,
	heights: { number }, -- per cell index (1-based, x + z * width + 1)
	fractions: { number }, -- smoothed remaining/base per cell
	depths: { number }, -- smoothed removed-record depth (studs) per cell
	-- Where a column's topmost remaining record actually sits.
	--
	-- `heights` is smoothed over a 3x3, which is what makes the mound read as a dome rather than as
	-- 2,916 steps - but the renderer does not seat records on it. It seats them on the mound as first
	-- built and then walks down one `step` per record taken, so a column dug hard drops by everything
	-- it lost while its smoothed height barely moves, and the neighbours drop although they lost
	-- nothing. Anything that has to line up with the drawn feathers - the body you stand on, above all
	-- - has to use these two instead.
	seatHeights: { number }, -- the mound as first built, before anything was dug
	removed: { number }, -- records taken from each cell
}

PileSurface.RIM_STRETCH = 1.0 -- the mound reaches the floor at the edge of the grid
-- This was 1.15, so the profile only reached zero at 1.15x the grid radius while the grid (and so
-- every rendered record and every body box) stopped at 1.0x. The mound was a truncated dome: its
-- edge was a vertical cliff a stud and a half to three studs tall all the way round, which read as
-- a see-through gap while the body was a gapped slab and as a bare wall once the body was solid.
-- The grid was widened to 54x54 at 0.54 studs so the same footprint, the same silhouette and the
-- same record total now fit inside a dome that actually lands on the sand.
PileSurface.PROFILE_POWER = 1.5 -- rounded-cone haystack silhouette: soft crown, straight steep flanks

-- Dome profile in [0,1] for a normalised radius; 1 at the centre, 0 outside the rim stretch.
function PileSurface.domeProfile(rNorm: number): number
	local r = math.clamp(rNorm / PileSurface.RIM_STRETCH, 0, 1)
	return 1 - r ^ PileSurface.PROFILE_POWER
end

-- Weighted 3x3 average (centre 4, edges 2, corners 1) of `value(index)`.
local function smoothed(width: number, depth: number, x: number, z: number, value: (number) -> number): number
	local total, weightSum = 0, 0
	for dz = -1, 1 do
		for dx = -1, 1 do
			local nx, nz = x + dx, z + dz
			if nx >= 0 and nz >= 0 and nx < width and nz < depth then
				local weight = if dx == 0 and dz == 0 then 4 elseif dx == 0 or dz == 0 then 2 else 1
				total += weight * value(nz * width + nx + 1)
				weightSum += weight
			end
		end
	end
	return if weightSum > 0 then total / weightSum else 0
end

-- Smoothed remaining/base around a cell.
function PileSurface.smoothedFraction(width: number, depth: number, remaining: { number }, base: { number }, x: number, z: number): number
	return smoothed(width, depth, x, z, function(index)
		return remaining[index] / math.max(1, base[index])
	end)
end

-- Smoothed removed-record count around a cell.
function PileSurface.smoothedRemoved(width: number, depth: number, remaining: { number }, base: { number }, x: number, z: number): number
	return smoothed(width, depth, x, z, function(index)
		return math.max(0, base[index] - remaining[index])
	end)
end

-- Builds the field from a grid-like table { width, depth, cellSize, remaining[], base[] } and the
-- chapter layout (nest centre / base height).
function PileSurface.buildField(cfg: { [string]: any }, grid: { [string]: any }, layout: { [string]: any }): Field
	local width, depth, cellSize = grid.width, grid.depth, grid.cellSize
	local halfW, halfD = width * cellSize / 2, depth * cellSize / 2
	local centre = layout.nestCenter
	local apex = cfg.pile.maxVisualHeightStuds
	local radius = math.min(halfW, halfD)
	local heights, fractions, depths = table.create(width * depth, 0), table.create(width * depth, 0), table.create(width * depth, 0)
	local seatHeights, removed = table.create(width * depth, 0), table.create(width * depth, 0)
	for z = 0, depth - 1 do
		for x = 0, width - 1 do
			local index = z * width + x + 1
			local cx = (x + 0.5) * cellSize - halfW
			local cz = (z + 0.5) * cellSize - halfD
			local rNorm = math.sqrt(cx * cx + cz * cz) / radius
			local fraction = PileSurface.smoothedFraction(width, depth, grid.remaining, grid.base, x, z)
			fractions[index] = fraction
			local full = apex * PileSurface.domeProfile(rNorm)
			depths[index] = full * (1 - fraction)
			heights[index] = full * fraction
			-- The seat baseline is the mound with every column full - which is what `heights` is at
			-- round start, since the smoothed fraction of an all-full neighbourhood is 1 - so it is
			-- simply the dome. This is the surface the renderer placed the stacks on and never revises.
			seatHeights[index] = full
			local cellBase = math.max(1, grid.base[index] or 1)
			removed[index] = math.max(0, cellBase - (grid.remaining[index] or cellBase))
		end
	end
	return {
		width = width,
		depth = depth,
		cellSize = cellSize,
		minX = centre.X - halfW,
		minZ = centre.Z - halfD,
		centreX = centre.X,
		centreZ = centre.Z,
		radius = radius,
		apex = apex,
		baseY = layout.nestBaseY,
		groundY = layout.groundY or layout.nestBaseY,
		heights = heights,
		fractions = fractions,
		depths = depths,
		seatHeights = seatHeights,
		removed = removed,
	}
end

-- The Y offset (above baseY) of a column's topmost remaining record: where the renderer drew it.
function PileSurface.columnTop(field: Field, x: number, z: number, step: number): number
	if x < 0 or z < 0 or x >= field.width or z >= field.depth then
		return 0
	end
	local index = z * field.width + x + 1
	return math.max(0, (field.seatHeights[index] or 0) - (field.removed[index] or 0) * step)
end

-- Recomputes one window of the field in place, instead of rebuilding all 2,916 columns.
--
-- The body is re-seated after every accepted award now, and a full `buildField` there meant smoothing
-- the entire grid and allocating three fresh arrays for a swing that moved four cells. Only the cells
-- that changed - plus the one-cell halo the 3x3 smoothing reaches - can have moved, so only those are
-- recomputed. Reads the live cells directly, so no snapshot is allocated either.
function PileSurface.refreshWindow(field: Field, cells: { any }, minCellX: number, minCellZ: number, maxCellX: number, maxCellZ: number)
	local halfW, halfD = field.width * field.cellSize / 2, field.depth * field.cellSize / 2
	local function fractionOf(index: number): number
		local cell = cells[index]
		if not cell then
			return 0
		end
		return cell.remaining / math.max(1, cell.base)
	end
	local x0 = math.max(0, math.floor(minCellX) - 1)
	local z0 = math.max(0, math.floor(minCellZ) - 1)
	local x1 = math.min(field.width - 1, math.ceil(maxCellX) + 1)
	local z1 = math.min(field.depth - 1, math.ceil(maxCellZ) + 1)
	for z = z0, z1 do
		for x = x0, x1 do
			local index = z * field.width + x + 1
			local cx = (x + 0.5) * field.cellSize - halfW
			local cz = (z + 0.5) * field.cellSize - halfD
			local rNorm = math.sqrt(cx * cx + cz * cz) / field.radius
			local fraction = smoothed(field.width, field.depth, x, z, fractionOf)
			local full = field.apex * PileSurface.domeProfile(rNorm)
			field.fractions[index] = fraction
			field.depths[index] = full * (1 - fraction)
			field.heights[index] = full * fraction
			local cell = cells[index]
			if cell then
				field.removed[index] = math.max(0, cell.base - cell.remaining)
			end
		end
	end
end

-- Column height by cell coordinates (0 outside the grid).
function PileSurface.columnHeight(field: Field, x: number, z: number): number
	if x < 0 or z < 0 or x >= field.width or z >= field.depth then
		return 0
	end
	return field.heights[z * field.width + x + 1]
end

local function bilinear(field: Field, values: { number }, worldX: number, worldZ: number): number
	local fx = math.clamp((worldX - field.minX) / field.cellSize - 0.5, 0, field.width - 1)
	local fz = math.clamp((worldZ - field.minZ) / field.cellSize - 0.5, 0, field.depth - 1)
	local x0, z0 = math.floor(fx), math.floor(fz)
	local tx, tz = fx - x0, fz - z0
	local function at(x: number, z: number): number
		x = math.clamp(x, 0, field.width - 1)
		z = math.clamp(z, 0, field.depth - 1)
		return values[z * field.width + x + 1]
	end
	local top = at(x0, z0) + (at(x0 + 1, z0) - at(x0, z0)) * tx
	local bottom = at(x0, z0 + 1) + (at(x0 + 1, z0 + 1) - at(x0, z0 + 1)) * tx
	return top + (bottom - top) * tz
end

-- Smoothed remaining fraction at a world XZ, bilinear between cell centres (edge-clamped).
function PileSurface.fractionAt(field: Field, worldX: number, worldZ: number): number
	return bilinear(field, field.fractions, worldX, worldZ)
end

-- Dug depth (studs) at a world XZ.
function PileSurface.depthAt(field: Field, worldX: number, worldZ: number): number
	return bilinear(field, field.depths, worldX, worldZ)
end

-- Surface height (above baseY) at a world XZ: continuous dome profile minus the dug depth; 0 outside
-- the rim stretch.
function PileSurface.heightAt(field: Field, worldX: number, worldZ: number): number
	local dx, dz = worldX - field.centreX, worldZ - field.centreZ
	local profile = PileSurface.domeProfile(math.sqrt(dx * dx + dz * dz) / field.radius)
	if profile <= 0 then
		return 0
	end
	return field.apex * profile * PileSurface.fractionAt(field, worldX, worldZ)
end

-- Full (undepleted) column height of a cell from the dome profile alone; needs no field.
function PileSurface.columnFullHeight(cfg: { [string]: any }, width: number, depth: number, cellSize: number, x: number, z: number): number
	local halfW, halfD = width * cellSize / 2, depth * cellSize / 2
	local radius = math.min(halfW, halfD)
	local cx = (x + 0.5) * cellSize - halfW
	local cz = (z + 0.5) * cellSize - halfD
	return cfg.pile.maxVisualHeightStuds * PileSurface.domeProfile(math.sqrt(cx * cx + cz * cz) / radius)
end

-- Records a column holds: its full height divided by the record spacing (at least one).
function PileSurface.columnRecords(cfg: { [string]: any }, width: number, depth: number, cellSize: number, x: number, z: number): number
	-- Rim columns follow the dome down to a single record, which made an edge sweep pay +1 while the
	-- same swing on the slope paid a full yield. A floor keeps the reward legible; the mound's shape
	-- is untouched because height is remaining/base, and a full column is 1 whatever the base is.
	local full = PileSurface.columnFullHeight(cfg, width, depth, cellSize, x, z)
	if full <= 0 then
		return 0 -- outside the dome: no height, so no records and nothing to aim at
	end
	local floorRecords = math.max(1, cfg.pile.minRecordsPerColumn or 1)
	return math.max(floorRecords, full / cfg.pile.recordSpacingStuds)
end

-- Records a column renders (and the server therefore accepts) at the top of its stack.
--
-- A fixed count is wrong on a dome. The coat is a skin `slots * step` studs deep laid on the
-- surface; where the surface drops faster than that per cell, the skin of one ring ends above the
-- skin of the ring outside it and a band of bare mound body shows between them. That band is what
-- reads as a smooth wall around the foot of the pile. Deepening the coat exactly where the slope
-- demands it costs parts only on the steep rings and covers the body with real, pickable records.
--
-- Pure function of the config and the grid, so the client renders and the server accepts the same
-- window without either sending the other a number.
function PileSurface.coatSlots(
	cfg: { [string]: any },
	width: number,
	depth: number,
	cellSize: number,
	x: number,
	z: number,
	base: number,
	minSlots: number,
	maxSlots: number?
): number
	local visual = cfg.pile.visual
	local maxSlots = maxSlots or visual.maxVisibleSlotsPerCell or minSlots
	local cap = math.min(maxSlots, math.max(1, base))
	if cap <= minSlots then
		return math.min(minSlots, cap)
	end
	local full = PileSurface.columnFullHeight(cfg, width, depth, cellSize, x, z)
	if full <= 0 then
		return minSlots
	end
	local step = math.max(full / math.max(1, base), visual.minSeatStepStuds or 0)
	if step <= 1e-4 then
		return minSlots
	end
	-- Height lost over one cell straight outward from the centre: the drop the coat has to span.
	local dx, dz = (x + 0.5) - width / 2, (z + 0.5) - depth / 2
	local r = math.sqrt(dx * dx + dz * dz)
	local drop = 0
	if r > 1e-4 then
		local outward = PileSurface.columnFullHeight(cfg, width, depth, cellSize, x + dx / r, z + dz / r)
		drop = math.max(full - outward, 0)
	end
	local span = drop * (visual.coatDropCoverage or 1.35) + (visual.coatDropMarginStuds or 0.2)
	local needed = math.ceil(span / step) + 1
	return math.clamp(needed, minSlots, cap)
end

-- Slots a column should render given the mound as it stands right now.
--
-- `coatSlots` above measures the drop off the undug dome, which is correct until somebody digs. A
-- vacuum sinks one column several studs below the one next to it; the neighbour's coat, sized for the
-- dome's gentle slope, then ends far above the new floor and the packed body shows through as a flat
-- wall down the side of the hole. That wall is what reads as white blocks inside the pile.
--
-- Measuring the drop against the neighbours' current heights covers a fresh pit wall with real,
-- pickable feathers, and costs extra slots only beside holes somebody actually dug. With every cell
-- full it agrees with `coatSlots`, because then the neighbour drop *is* the dome drop.
export type HeightOf = (x: number, z: number) -> number

function PileSurface.coatSlotsAt(
	cfg: { [string]: any },
	width: number,
	depth: number,
	cellSize: number,
	heightOf: HeightOf,
	x: number,
	z: number,
	base: number,
	minSlots: number,
	maxSlots: number?
): number
	local visual = cfg.pile.visual
	local cap = math.min(maxSlots or visual.maxVisibleSlotsPerCell or minSlots, math.max(1, base))
	if cap <= minSlots then
		return math.min(minSlots, cap)
	end
	local full = PileSurface.columnFullHeight(cfg, width, depth, cellSize, x, z)
	if full <= 0 then
		return minSlots
	end
	local step = math.max(full / math.max(1, base), visual.minSeatStepStuds or 0)
	if step <= 1e-4 then
		return minSlots
	end
	local here = heightOf(x, z)
	local drop = 0
	-- Past the rim the neighbour is the ground, which is the same case as a column dug to nothing.
	for _, offset in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
		drop = math.max(drop, here - heightOf(x + offset[1], z + offset[2]))
	end
	local span = drop * (visual.coatDropCoverage or 1.35) + (visual.coatDropMarginStuds or 0.2)
	return math.clamp(math.ceil(span / step) + 1, minSlots, cap)
end

-- A height sampler over a built field.
function PileSurface.fieldHeights(field: Field): HeightOf
	return function(x: number, z: number): number
		return PileSurface.columnHeight(field, x, z)
	end
end

-- A height sampler straight off the live grid cells, for callers that hold no field. Same number the
-- field would report: the dome profile scaled by the smoothed remaining fraction.
function PileSurface.cellHeights(cfg: { [string]: any }, width: number, depth: number, cellSize: number, cells: { any }): HeightOf
	local function fractionOf(index: number): number
		local cell = cells[index]
		if not cell then
			return 0
		end
		return cell.remaining / math.max(1, cell.base)
	end
	return function(x: number, z: number): number
		if x < 0 or z < 0 or x >= width or z >= depth then
			return 0
		end
		local full = PileSurface.columnFullHeight(cfg, width, depth, cellSize, x, z)
		if full <= 0 then
			return 0
		end
		return full * smoothed(width, depth, x, z, fractionOf)
	end
end

-- Undepleted mound height at a world XZ (the dome with every cell full).
function PileSurface.fullHeightAt(field: Field, worldX: number, worldZ: number): number
	local dx, dz = worldX - field.centreX, worldZ - field.centreZ
	return field.apex * PileSurface.domeProfile(math.sqrt(dx * dx + dz * dz) / field.radius)
end

-- Surface slope at a world XZ as (dh/dx, dh/dz) for orienting shingles and mesh normals.
function PileSurface.gradientAt(field: Field, worldX: number, worldZ: number): (number, number)
	local d = field.cellSize * 0.35
	local dx = (PileSurface.heightAt(field, worldX + d, worldZ) - PileSurface.heightAt(field, worldX - d, worldZ)) / (2 * d)
	local dz = (PileSurface.heightAt(field, worldX, worldZ + d) - PileSurface.heightAt(field, worldX, worldZ - d)) / (2 * d)
	return dx, dz
end

-- Unit surface normal at a world XZ.
function PileSurface.normalAt(field: Field, worldX: number, worldZ: number): Vector3
	local gx, gz = PileSurface.gradientAt(field, worldX, worldZ)
	return Vector3.new(-gx, 1, -gz).Unit
end

-- True when the world XZ lies inside the logical footprint.
function PileSurface.insideFootprint(field: Field, worldX: number, worldZ: number): boolean
	return worldX >= field.minX
		and worldZ >= field.minZ
		and worldX <= field.minX + field.width * field.cellSize
		and worldZ <= field.minZ + field.depth * field.cellSize
end

-- Walks the ray from `origin` along `direction` (unit) and returns the first point where it enters
-- the surface from above, or nil. A ray that starts below the surface (inside the mound) yields
-- nil so callers can fall back to their previous behaviour.
function PileSurface.march(field: Field, origin: Vector3, direction: Vector3, maxDistance: number, step: number?): Vector3?
	local stride = step or 0.5
	local previousAbove: boolean? = nil
	local previousT = 0
	local t = 0
	while t <= maxDistance do
		local p = origin + direction * t
		-- Beyond the rim the surface is the floor itself (height 0), so the test is one comparison
		-- everywhere and the bisection below brackets the true crossing on the steep flanks.
		local surface = field.baseY + PileSurface.heightAt(field, p.X, p.Z)
		local above = p.Y > surface
		if previousAbove == true and not above then
			-- Refine between the last point above and this point below.
			local lo, hi = previousT, t
			for _ = 1, 10 do -- ~0.0005 stud precision along the ray; the flanks are steep
				local mid = (lo + hi) / 2
				local q = origin + direction * mid
				if q.Y > field.baseY + PileSurface.heightAt(field, q.X, q.Z) then
					lo = mid
				else
					hi = mid
				end
			end
			return origin + direction * hi
		end
		previousAbove = above
		previousT = t
		t += stride
	end
	return nil
end

return PileSurface
