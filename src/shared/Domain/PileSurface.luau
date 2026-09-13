--!strict
-- Pure pile surface model shared by the server (aim resolution, collision) and the client (coat): the
-- authoritative 16x16 cells become one smooth dome. The surface height at any world XZ is
--   max(0, apex * domeProfile(normalised radius) - depth(x, z))
-- where the dome profile is a continuous rounded cone (1 at the centre, 0 at the rim stretch) and
-- depth is the bilinear interpolation of each cell's smoothed 3x3 removed-record count times
-- `pile.depthPerFeatherStuds`, so one pick barely moves the surface and a well-dug area becomes a
-- bowl a few studs deep - never a collapse to the floor. `march` walks a ray until it enters the
-- surface from above.
-- Presentation constants are ASSUMED (A-UX-07); the logical grid, yields, and cells are untouched.

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
	heights: { number }, -- per cell index (1-based, x + z * width + 1)
	fractions: { number }, -- smoothed remaining/base per cell
	depths: { number }, -- smoothed removed-record depth (studs) per cell
}

PileSurface.RIM_STRETCH = 1.15 -- the mound reaches the floor at the edge of the nest base cylinder
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
	local step = cfg.pile.depthPerFeatherStuds
	local heights, fractions, depths = table.create(width * depth, 0), table.create(width * depth, 0), table.create(width * depth, 0)
	for z = 0, depth - 1 do
		for x = 0, width - 1 do
			local index = z * width + x + 1
			local cx = (x + 0.5) * cellSize - halfW
			local cz = (z + 0.5) * cellSize - halfD
			local rNorm = math.sqrt(cx * cx + cz * cz) / radius
			fractions[index] = PileSurface.smoothedFraction(width, depth, grid.remaining, grid.base, x, z)
			local dug = PileSurface.smoothedRemoved(width, depth, grid.remaining, grid.base, x, z) * step
			depths[index] = dug
			heights[index] = math.max(0, apex * PileSurface.domeProfile(rNorm) - dug)
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
		heights = heights,
		fractions = fractions,
		depths = depths,
	}
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
	return math.max(0, field.apex * profile - PileSurface.depthAt(field, worldX, worldZ))
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
