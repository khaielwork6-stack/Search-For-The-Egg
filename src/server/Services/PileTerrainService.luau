--!strict
-- The pile's collision core (ASSUMED A-PILE-01): the logical mound is written into Roblox Terrain
-- (one voxel material, custom colour) so players stand and walk on a smooth, fully closed, natively
-- collidable surface with no seams or invisible walls. The terrain is a pure function of two server
-- facts, re-written locally after every accepted award:
--   * the logical field (cell health -> geometry: a soft hollow after a few strikes, a crater once a
--     cell and its neighbours empty), and
--   * a dent map of accepted strike points, each lowering the surface by a fixed depth inside the dig
--     radius, so repeated strikes at one spot dig a visible pit and the Egg gets a hollow at reveal.
-- Dents go through the voxel writer (not FillBall, whose small radii miss 4-stud voxel centres).
-- Terrain access goes through an injected adapter so the service runs headlessly in tests.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local PileSurface = require(Shared.Domain.PileSurface)
local PileGrid = require(Shared.Domain.PileGrid)
local ChapterLayout = require(Shared.Domain.ChapterLayout)

local PileTerrainService = {}
PileTerrainService.__index = PileTerrainService

export type DentAt = (x: number, z: number) -> number

export type Adapter = {
	writeMound: (self: Adapter, field: any, config: { [string]: any }, dentAt: DentAt) -> number, -- voxels written
	-- Re-writes the columns inside [minX,maxX]x[minZ,maxZ]; never raises an existing voxel.
	writeRegion: (
		self: Adapter,
		field: any,
		config: { [string]: any },
		dentAt: DentAt,
		minX: number,
		minZ: number,
		maxX: number,
		maxZ: number
	) -> number,
	clear: (self: Adapter, field: any) -> (),
	kind: string,
}

type Dent = { x: number, z: number, radius: number, depth: number }

export type PileTerrainService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_adapter: Adapter,
		_fields: { [string]: any },
		_dents: { [string]: { Dent } },
		stats: { builds: number, carves: number, hollows: number, clears: number, voxels: number, regionWrites: number },
	},
	PileTerrainService
))

function PileTerrainService.new(options: { config: { [string]: any }, adapter: Adapter }): PileTerrainService
	return setmetatable({
		_config = options.config,
		_adapter = options.adapter,
		_fields = {},
		_dents = {},
		stats = { builds = 0, carves = 0, hollows = 0, clears = 0, voxels = 0, regionWrites = 0 },
	}, PileTerrainService)
end

function PileTerrainService.fieldFor(self: PileTerrainService, runtime: any): any
	local layout = ChapterLayout[runtime.state.chapter]
	return PileSurface.buildField(self._config, PileGrid.snapshot(runtime.grid), layout)
end

-- Total dent depth at a world XZ: smooth falloff inside each dent's radius, summed.
function PileTerrainService.dentDepthAt(self: PileTerrainService, runtime: any, x: number, z: number): number
	local dents = self._dents[runtime.state.roundId]
	if not dents then
		return 0
	end
	local total = 0
	for _, dent in ipairs(dents) do
		local dx, dz = x - dent.x, z - dent.z
		local d = math.sqrt(dx * dx + dz * dz)
		if d < dent.radius then
			local t = 1 - d / dent.radius
			total += dent.depth * t * t * (3 - 2 * t) -- smoothstep bowl
		end
	end
	return total
end

function PileTerrainService._dentSampler(self: PileTerrainService, runtime: any): DentAt
	return function(x, z)
		return self:dentDepthAt(runtime, x, z)
	end
end

-- Writes the round's mound. Called once when a round is created.
function PileTerrainService.build(self: PileTerrainService, runtime: any)
	local field = self:fieldFor(runtime)
	local roundId = runtime.state.roundId
	self._fields[roundId] = field
	self._dents[roundId] = {}
	self.stats.builds += 1
	self.stats.voxels += self._adapter:writeMound(field, self._config, self:_dentSampler(runtime))
end

-- Records a dent (no terrain write; callers re-write the region afterwards).
function PileTerrainService.carveAt(self: PileTerrainService, runtime: any, x: number, z: number, radius: number, depth: number)
	local dents = self._dents[runtime.state.roundId]
	if not dents then
		return
	end
	table.insert(dents, { x = x, z = z, radius = radius, depth = depth })
	self.stats.carves += 1
end

-- Re-writes the mound inside the bounds (plus the configured cell margin) from the current field
-- and dent map.
function PileTerrainService.rewrite(self: PileTerrainService, runtime: any, minX: number, minZ: number, maxX: number, maxZ: number)
	local roundId = runtime.state.roundId
	if not self._fields[roundId] then
		return
	end
	local field = self:fieldFor(runtime)
	self._fields[roundId] = field
	local margin = self._config.pile.collision.rewriteMarginCells * runtime.grid.cellSize
	self.stats.regionWrites += 1
	self.stats.voxels += self._adapter:writeRegion(
		field,
		self._config,
		self:_dentSampler(runtime),
		minX - margin,
		minZ - margin,
		maxX + margin,
		maxZ + margin
	)
end

-- Reacts to an accepted collection/tool award: the primary strike dents the dig radius, a sweep
-- (several cells) dents each touched cell more lightly, and the neighbourhood is re-written.
function PileTerrainService.onAwarded(self: PileTerrainService, runtime: any, result: { [string]: any })
	local collision = self._config.pile.collision
	if not self._fields[runtime.state.roundId] then
		return
	end
	local grid = runtime.grid
	local layout = ChapterLayout[runtime.state.chapter]
	local minCorner = ChapterLayout.gridMinCorner(layout, grid.width, grid.depth, grid.cellSize)
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	local function include(x: number, z: number)
		minX, minZ = math.min(minX, x), math.min(minZ, z)
		maxX, maxZ = math.max(maxX, x), math.max(maxZ, z)
	end
	-- Voxels are re-written only when a touched cell crosses a record threshold (every N records
	-- or empty), so a single pick never shifts the collision surface under the coat; dents are
	-- recorded every time and land with the next rewrite.
	local every = collision.rewriteEveryRecords
	local due = false
	local cells = result.cells
	if type(cells) == "table" then
		for _, removal in ipairs(cells) do
			local cell = grid.cells[removal.index]
			if cell and removal.removed and removal.removed > 0 then
				local lx, lz = PileGrid.cellCenter(grid, cell)
				include(minCorner.X + lx, minCorner.Z + lz)
				if cell.index ~= result.cellIndex then
					self:carveAt(runtime, minCorner.X + lx, minCorner.Z + lz, collision.sweepDigRadiusStuds, collision.sweepDentDepthStuds)
				end
				local removedSoFar = cell.base - cell.remaining
				if cell.remaining == 0 or removedSoFar % every == 0 or removal.removed >= every then
					due = true
				end
			end
		end
	end
	if type(result.hitX) == "number" and type(result.hitZ) == "number" then
		include(result.hitX, result.hitZ)
		self:carveAt(runtime, result.hitX, result.hitZ, collision.digRadiusStuds, collision.strikeDentDepthStuds)
	end
	if minX < math.huge and due then
		self:rewrite(runtime, minX, minZ, maxX, maxZ)
	end
end

-- Opens a hollow around the Egg the moment it is revealed so it never clips through the core.
function PileTerrainService.openEggHollow(self: PileTerrainService, runtime: any, position: Vector3)
	local collision = self._config.pile.collision
	local field = self._fields[runtime.state.roundId]
	local remainingHeight = if field then PileSurface.heightAt(field, position.X, position.Z) else 0
	self:carveAt(
		runtime,
		position.X,
		position.Z,
		collision.eggHollowRadiusStuds,
		math.max(collision.eggHollowDepthStuds, remainingHeight + 1)
	)
	self.stats.hollows += 1
	local r = collision.eggHollowRadiusStuds
	self:rewrite(runtime, position.X - r, position.Z - r, position.X + r, position.Z + r)
end

-- Removes the round's mound (round returned / abandoned).
function PileTerrainService.clear(self: PileTerrainService, runtime: any)
	local roundId = runtime.state.roundId
	local field = self._fields[roundId]
	if not field then
		return
	end
	self._adapter:clear(field)
	self._fields[roundId] = nil
	self._dents[roundId] = nil
	self.stats.clears += 1
end

-- Surface height (world Y) the collision core intends at a world XZ: analytic field minus dents,
-- never below the base. Used by tests and the Studio debug hooks.
function PileTerrainService.intendedSurfaceY(self: PileTerrainService, runtime: any, x: number, z: number): number
	if not self._fields[runtime.state.roundId] then
		return 0
	end
	local field = self:fieldFor(runtime) -- the live logical surface, not the last voxel write
	local height = PileSurface.heightAt(field, x, z) - self:dentDepthAt(runtime, x, z)
	return field.baseY + math.max(0, height)
end

-- ---------------------------------------------------------------------------------------------
-- Adapters
-- ---------------------------------------------------------------------------------------------

-- Real terrain adapter (server only).
function PileTerrainService.terrainAdapter(terrain: Terrain): Adapter
	local adapter = { kind = "terrain" }
	-- Writes the field's columns inside the bounds. When `lowerOnly` is set the existing voxels are
	-- read first and never raised.
	local function writeColumns(field, config, dentAt: DentAt, minX, minZ, maxX, maxZ, lowerOnly)
		local collision = config.pile.collision
		local material = (Enum.Material :: any)[collision.material] or Enum.Material.Snow
		local resolution = collision.voxelResolution
		local inset = collision.surfaceInsetStuds
		local minCorner = Vector3.new(minX - resolution, field.baseY - resolution, minZ - resolution)
		local maxCorner = Vector3.new(maxX + resolution, field.baseY + field.apex + resolution, maxZ + resolution)
		local region = Region3.new(minCorner, maxCorner):ExpandToGrid(resolution)
		local size = region.Size / resolution
		local nx, ny, nz = math.floor(size.X + 0.5), math.floor(size.Y + 0.5), math.floor(size.Z + 0.5)
		local existing: any = nil
		if lowerOnly then
			local _, occupancy = terrain:ReadVoxels(region, resolution)
			existing = occupancy
		end
		local materials = table.create(nx)
		local occupancy = table.create(nx)
		local origin = region.CFrame.Position - region.Size / 2
		local written = 0
		for ix = 1, nx do
			local mats, occs = table.create(ny), table.create(ny)
			local wx = origin.X + (ix - 0.5) * resolution
			for iy = 1, ny do
				local rowMats, rowOccs = table.create(nz), table.create(nz)
				local wy = origin.Y + (iy - 0.5) * resolution
				for iz = 1, nz do
					local wz = origin.Z + (iz - 0.5) * resolution
					-- Fraction of the voxel below the intended surface (sampled at the voxel centre XZ).
					local height = PileSurface.heightAt(field, wx, wz) - dentAt(wx, wz) - inset
					local surface = field.baseY + math.max(0, height)
					local bottom = wy - resolution / 2
					local fill = math.clamp((surface - bottom) / resolution, 0, 1)
					if wy < field.baseY - resolution / 2 or height <= 0 then
						fill = 0 -- never write below the nest floor or where the mound is gone
					end
					if existing then
						fill = math.min(fill, existing[ix][iy][iz])
					end
					rowMats[iz] = if fill > 0.02 then material else Enum.Material.Air
					rowOccs[iz] = if fill > 0.02 then fill else 0
					if fill > 0.02 then
						written += 1
					end
				end
				mats[iy], occs[iy] = rowMats, rowOccs
			end
			materials[ix], occupancy[ix] = mats, occs
		end
		terrain:WriteVoxels(region, resolution, materials, occupancy)
		return written
	end
	function adapter.writeMound(_, field, config, dentAt)
		local collision = config.pile.collision
		local material = (Enum.Material :: any)[collision.material] or Enum.Material.Snow
		terrain:SetMaterialColor(material, Color3.fromRGB(collision.color[1], collision.color[2], collision.color[3]))
		local rim = field.radius * PileSurface.RIM_STRETCH
		return writeColumns(
			field,
			config,
			dentAt,
			field.centreX - rim,
			field.centreZ - rim,
			field.centreX + rim,
			field.centreZ + rim,
			false
		)
	end
	function adapter.writeRegion(_, field, config, dentAt, minX, minZ, maxX, maxZ)
		return writeColumns(field, config, dentAt, minX, minZ, maxX, maxZ, true)
	end
	function adapter.clear(_, field)
		local rim = field.radius * PileSurface.RIM_STRETCH + 8
		local region = Region3.new(
			Vector3.new(field.centreX - rim, field.baseY - 4, field.centreZ - rim),
			Vector3.new(field.centreX + rim, field.baseY + field.apex + 8, field.centreZ + rim)
		):ExpandToGrid(4)
		terrain:FillRegion(region, 4, Enum.Material.Air)
	end
	return (adapter :: any) :: Adapter
end

-- Invisible part shell (server only; `pile.collision.kind = "parts"`): one anchored, invisible,
-- non-queryable box per cell, tilted to the local slope with its top face on the logical surface
-- (minus the inset), overlapping its neighbours so there are no seams. Players stand and walk on
-- it; nothing of it is ever visible, and it never blocks a pick raycast. Re-writes move the boxes
-- of the touched region only. Any leftover terrain under the nest is cleared on the first write.
local function collisionVisible(config): boolean
	return config.pile.collision.visible ~= false
end

-- Body shade for one cell. A single flat colour over 2300 boxes reads as a plastic wall wherever
-- the coat thins; a small deterministic jitter per cell reads as compressed feather mass instead.
local function shellColor(config, index: number): Color3
	local rgb = config.pile.collision.color
	local base = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	local jitter = config.pile.collision.bodyShadeJitter or 0
	if jitter <= 0 then
		return base
	end
	local n = math.sin(index * 12.9898) * 43758.5453
	local t = 1 + ((n - math.floor(n)) - 0.5) * 2 * jitter
	return Color3.new(math.clamp(base.R * t, 0, 1), math.clamp(base.G * t, 0, 1), math.clamp(base.B * t, 0, 1))
end

local function shellMaterial(config): Enum.Material
	-- The body is a part, not terrain, so it gets its own material: a fine weave reads as compressed
	-- feather mass where the coat thins, where SmoothPlastic read as a moulded wall.
	local name = config.pile.collision.bodyMaterial or config.pile.collision.material
	return (Enum.Material :: any)[name] or Enum.Material.SmoothPlastic
end

function PileTerrainService.partsAdapter(parent: Instance, terrain: Terrain?): Adapter
	local adapter = { kind = "parts" }
	local folder: Folder? = nil
	local boxes: { [number]: BasePart } = {}
	local function ensureFolder(config): Folder
		if folder and folder.Parent then
			return folder
		end
		local existing = parent:FindFirstChild(config.pile.collision.shellFolderName)
		if existing and existing:IsA("Folder") then
			existing:Destroy()
		end
		local created = Instance.new("Folder")
		created.Name = config.pile.collision.shellFolderName
		created.Parent = parent
		folder = created
		boxes = {}
		return created
	end
	-- How deep the client's rendered coat reaches below the surface of a column. The coat only draws
	-- the top `visibleSlotsPerCell` records, so away from the crown it is a thin shell sitting well
	-- above the ground; the mound body has to start just under it or a low angle sees straight
	-- underneath the rim and out the other side.
	local function coatSpan(config, field, x: number, z: number): number
		local visual = config.pile.visual
		local full = PileSurface.columnFullHeight(config, field.width, field.depth, field.cellSize, x, z)
		local records = math.clamp(math.floor(math.max(config.pile.minRecordsPerColumn or 1, full / config.pile.recordSpacingStuds)), 1, 32)
		local step = math.max(full / records, visual.minSeatStepStuds or 0)
		-- The window is per column: a steep rim column renders deeper, so the body has to sit deeper
		-- under it too or the coat's own lower records would be buried inside the body.
		local slots = PileSurface.coatSlots(config, field.width, field.depth, field.cellSize, x, z, records, visual.visibleSlotsPerCell)
		return (slots - 1) * step + (visual.coatSpanMarginStuds or 0.35)
	end

	-- One solid, axis-aligned, ground-anchored column per cell.
	--
	-- This used to be a thin slab tilted to the local surface normal. Wherever the dome is steep the
	-- neighbouring slabs rotate away from each other, the overlap opens, and the slab's lower edge
	-- hangs studs above the sand: a low sight line then goes between two slabs, under the coat, and
	-- straight out the far side of the mound. That is the see-through band the owner kept seeing at
	-- the foot of the pile, and no amount of coat density can close it, because the hole is behind
	-- the coat. A vertical box that starts below the sand and ends just under the rendered records
	-- cannot open a gap at any camera angle: its sides are parallel, it overlaps its neighbours by
	-- `shellOverlap`, and there is nothing underneath it to look into.
	local function seat(field, config, dentAt: DentAt, index: number, x: number, z: number): (CFrame, Vector3)
		local collision = config.pile.collision
		local cx = field.minX + (x + 0.5) * field.cellSize
		local cz = field.minZ + (z + 0.5) * field.cellSize
		local ground = field.groundY or field.baseY
		local surface = PileSurface.heightAt(field, cx, cz) - dentAt(cx, cz)
		local top = field.baseY + math.max(0, surface - collision.surfaceInsetStuds - coatSpan(config, field, x, z))
		-- At the lip the coat is barely a stud tall, so subtracting a whole coat span drops the body
		-- under the sand. Wherever there is any mound above the floor the body keeps a face above it.
		if surface > (collision.lipSurfaceStuds or 0.1) then
			top = math.max(top, ground + (collision.lipHeightStuds or 0.25))
		end
		local floor = math.min(ground, field.baseY) - (collision.bodyBuryStuds or 2)
		local height = math.max(top - floor, 0.05)
		local size = field.cellSize * collision.shellOverlap
		local _ = index
		return CFrame.new(cx, floor + height / 2, cz), Vector3.new(size, height, size)
	end
	local function write(field, config, dentAt: DentAt, minX: number?, minZ: number?, maxX: number?, maxZ: number?): number
		local container = ensureFolder(config)
		local written = 0
		for z = 0, field.depth - 1 do
			for x = 0, field.width - 1 do
				local cx = field.minX + (x + 0.5) * field.cellSize
				local cz = field.minZ + (z + 0.5) * field.cellSize
				if minX and (cx < minX or cx > maxX or cz < minZ or cz > maxZ) then
					continue
				end
				local index = z * field.width + x + 1
				local frame, size = seat(field, config, dentAt, index, x, z)
				local box = boxes[index]
				if not box then
					box = Instance.new("Part")
					box.Name = "Shell" .. index
					box.Anchored = true
					box.CanCollide = true
					box.CanQuery = false
					box.CanTouch = false
					box.CastShadow = false
					-- Visible: this is the packed body of the mound under the loose coat, so a gap
					-- between feathers shows compressed feather mass instead of the ground.
					box.Transparency = if collisionVisible(config) then 0 else 1
					box.Color = shellColor(config, index)
					box.Material = shellMaterial(config)
					box.Parent = container
					boxes[index] = box
				end
				box.Size = size
				box.CFrame = frame
				written += 1
			end
		end
		return written
	end
	function adapter.writeMound(_, field, config, dentAt)
		if terrain then
			local rim = field.radius * PileSurface.RIM_STRETCH + 8
			local region = Region3.new(
				Vector3.new(field.centreX - rim, field.baseY - 4, field.centreZ - rim),
				Vector3.new(field.centreX + rim, field.baseY + field.apex + 8, field.centreZ + rim)
			):ExpandToGrid(4)
			terrain:FillRegion(region, 4, Enum.Material.Air)
		end
		return write(field, config, dentAt)
	end
	function adapter.writeRegion(_, field, config, dentAt, minX, minZ, maxX, maxZ)
		return write(field, config, dentAt, minX, minZ, maxX, maxZ)
	end
	function adapter.clear(_, _field)
		if folder then
			folder:Destroy()
			folder = nil
			boxes = {}
		end
	end
	return (adapter :: any) :: Adapter
end

-- Mock adapter (tests, headless): records every call.
function PileTerrainService.mockAdapter(): Adapter
	local adapter: any = { kind = "mock", writes = 0, regionWrites = {}, clears = 0 }
	function adapter.writeMound(self, field)
		self.writes += 1
		self.field = field
		return field.width * field.depth
	end
	function adapter.writeRegion(self, field, _config, _dentAt, minX, minZ, maxX, maxZ)
		self.field = field
		table.insert(self.regionWrites, { minX = minX, minZ = minZ, maxX = maxX, maxZ = maxZ })
		return 0
	end
	function adapter.clear(self)
		self.clears += 1
		self.regionWrites = {}
	end
	return adapter :: Adapter
end

return PileTerrainService
