--!strict
-- The pile's collision core (ASSUMED A-PILE-01).
--
-- One rule holds this together: **the remaining records are the only thing that decides where the
-- surface is.** The body a player stands on, the coat they see, and the saved grid are three views of
-- that one number, so they cannot disagree.
--
-- They used to. Alongside the records there was a dent map - every accepted strike added a smooth
-- bowl of `digRadiusStuds` (2.2 studs) and `strikeDentDepthStuds`, and those bowls were subtracted
-- from the collision surface and from nothing else. The client seats its feathers at the record
-- surface and has never known dents exist. So a few seconds of vacuuming summed forty bowls, the
-- body under a 2.2-stud circle dropped metres, and the player walked forward into a mound that was
-- still drawn as solid feathers - while the vac had only ever touched a 1.2-stud circle. The dent map
-- is gone. A pit is dug by removing records, which lowers the drawn surface and the body together,
-- and only where the tool actually reached.
--
-- The rewrite throttle went with it. Re-seating the body only every `rewriteEveryRecords` records
-- left collision standing above the coat between thresholds, which is the invisible wall you hit
-- while looking at open air. The touched region is re-seated on every accepted award; it is a few
-- dozen parts having their Size and CFrame set, and correctness is worth more than that.
--
-- Terrain access goes through an injected adapter so the service runs headlessly in tests.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local PileSurface = require(Shared.Domain.PileSurface)
local PileGrid = require(Shared.Domain.PileGrid)
local ChapterLayout = require(Shared.Domain.ChapterLayout)

local PileTerrainService = {}
PileTerrainService.__index = PileTerrainService

export type Adapter = {
	writeMound: (self: Adapter, field: any, config: { [string]: any }) -> number, -- voxels written
	-- Re-seats the columns inside [minX,maxX]x[minZ,maxZ] from the current field.
	writeRegion: (
		self: Adapter,
		field: any,
		config: { [string]: any },
		minX: number,
		minZ: number,
		maxX: number,
		maxZ: number
	) -> number,
	clear: (self: Adapter, field: any) -> (),
	kind: string,
}

export type PileTerrainService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_adapter: Adapter,
		_fields: { [string]: any },
		stats: { builds: number, carves: number, hollows: number, clears: number, voxels: number, regionWrites: number },
	},
	PileTerrainService
))

function PileTerrainService.new(options: { config: { [string]: any }, adapter: Adapter }): PileTerrainService
	return setmetatable({
		_config = options.config,
		_adapter = options.adapter,
		_fields = {},
		stats = { builds = 0, carves = 0, hollows = 0, clears = 0, voxels = 0, regionWrites = 0 },
	}, PileTerrainService)
end

function PileTerrainService.fieldFor(self: PileTerrainService, runtime: any): any
	local layout = ChapterLayout[runtime.state.chapter]
	return PileSurface.buildField(self._config, PileGrid.snapshot(runtime.grid), layout)
end

-- Writes the round's mound. Called once when a round is created.
function PileTerrainService.build(self: PileTerrainService, runtime: any)
	local field = self:fieldFor(runtime)
	local roundId = runtime.state.roundId
	self._fields[roundId] = field
	self.stats.builds += 1
	self.stats.voxels += self._adapter:writeMound(field, self._config)
end

-- Re-seats the mound inside the bounds (plus the configured cell margin) from the current field.
function PileTerrainService.rewrite(self: PileTerrainService, runtime: any, minX: number, minZ: number, maxX: number, maxZ: number)
	local roundId = runtime.state.roundId
	if not self._fields[roundId] then
		return
	end
	-- Update the cached field in place rather than rebuilding every column: the only cells that can
	-- have moved are the ones inside these bounds.
	local field = self._fields[roundId]
	local cellSize = runtime.grid.cellSize
	PileSurface.refreshWindow(
		field,
		runtime.grid.cells,
		(minX - field.minX) / cellSize - 1,
		(minZ - field.minZ) / cellSize - 1,
		(maxX - field.minX) / cellSize,
		(maxZ - field.minZ) / cellSize
	)
	local margin = self._config.pile.collision.rewriteMarginCells * cellSize
	self.stats.regionWrites += 1
	self.stats.voxels += self._adapter:writeRegion(field, self._config, minX - margin, minZ - margin, maxX + margin, maxZ + margin)
end

-- Reacts to an accepted award by re-seating the body under every cell the tool actually took from.
--
-- No dents and no threshold. The award already tells us which cells lost records, and a lost record
-- is the whole of what lowers this mound; re-seating exactly those cells is both the correct surface
-- and the smallest possible write. A tool that reached one cell moves one column, which is why a
-- vacuum can no longer hollow out ground it never pointed at.
function PileTerrainService.onAwarded(self: PileTerrainService, runtime: any, result: { [string]: any })
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
	local cells = result.cells
	if type(cells) == "table" then
		for _, removal in ipairs(cells) do
			local cell = grid.cells[removal.index]
			if cell and removal.removed and removal.removed > 0 then
				local lx, lz = PileGrid.cellCenter(grid, cell)
				include(minCorner.X + lx, minCorner.Z + lz)
			end
		end
	end
	if minX < math.huge then
		self:rewrite(runtime, minX, minZ, maxX, maxZ)
	end
end

-- Opens a hollow around the Egg the moment it is revealed so it never clips through the mound.
--
-- This used to add one very deep dent, which moved the body and left the coat drawn across the top of
-- the hole. It now takes the records out of the columns inside the radius, the same way a tool does:
-- the clients get the removals as ordinary deltas and stop drawing those feathers, the body follows
-- the records down, and the hollow is a real hole in the mound rather than a hole in the collision.
function PileTerrainService.openEggHollow(
	self: PileTerrainService,
	runtime: any,
	position: Vector3,
	onRemoved: ((index: number, remaining: number, mask: number) -> ())?
)
	local collision = self._config.pile.collision
	if not self._fields[runtime.state.roundId] then
		return
	end
	local grid = runtime.grid
	local layout = ChapterLayout[runtime.state.chapter]
	local minCorner = ChapterLayout.gridMinCorner(layout, grid.width, grid.depth, grid.cellSize)
	local r = collision.eggHollowRadiusStuds
	local depth = collision.eggHollowDepthStuds
	local spacing = math.max(self._config.pile.recordSpacingStuds, 1e-3)
	for _, cell in ipairs(PileGrid.cellsWithinStuds(grid, position.X - minCorner.X, position.Z - minCorner.Z, r)) do
		if cell.remaining > 0 then
			local lx, lz = PileGrid.cellCenter(grid, cell)
			local dx, dz = minCorner.X + lx - position.X, minCorner.Z + lz - position.Z
			-- A bowl, not a cylinder: deepest over the Egg and feathering out to nothing at the rim,
			-- so the hollow reads as something that was dug rather than punched.
			local t = math.clamp(1 - math.sqrt(dx * dx + dz * dz) / math.max(r, 1e-3), 0, 1)
			local wanted = math.floor(depth * t * t * (3 - 2 * t) / spacing + 0.5)
			local removed = 0
			while removed < wanted and cell.remaining > 0 do
				local slot = PileGrid.topSlot(cell)
				if not slot then
					break
				end
				if not PileGrid.removeFeather(grid, cell, slot) then
					break
				end
				removed += 1
			end
			if removed > 0 and onRemoved then
				onRemoved(cell.index, cell.remaining, cell.taken)
			end
		end
	end
	self.stats.hollows += 1
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
	self.stats.clears += 1
end

-- Surface height (world Y) the collision core intends at a world XZ: analytic field minus dents,
-- never below the base. Used by tests and the Studio debug hooks.
function PileTerrainService.intendedSurfaceY(self: PileTerrainService, runtime: any, x: number, z: number): number
	if not self._fields[runtime.state.roundId] then
		return 0
	end
	local field = self:fieldFor(runtime) -- the live logical surface, not the last voxel write
	local height = PileSurface.heightAt(field, x, z)
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
	local function writeColumns(field, config, minX, minZ, maxX, maxZ, lowerOnly)
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
					local height = PileSurface.heightAt(field, wx, wz) - inset
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
	function adapter.writeMound(_, field, config)
		local collision = config.pile.collision
		local material = (Enum.Material :: any)[collision.material] or Enum.Material.Snow
		terrain:SetMaterialColor(material, Color3.fromRGB(collision.color[1], collision.color[2], collision.color[3]))
		local rim = field.radius * PileSurface.RIM_STRETCH
		return writeColumns(field, config, field.centreX - rim, field.centreZ - rim, field.centreX + rim, field.centreZ + rim, false)
	end
	function adapter.writeRegion(_, field, config, minX, minZ, maxX, maxZ)
		return writeColumns(field, config, minX, minZ, maxX, maxZ, true)
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
	-- One solid, axis-aligned, ground-anchored column per cell, invisible, topped at the surface.
	--
	-- It used to be visible and seated a whole coat-depth below the surface, and those two facts were
	-- locked together: an opaque body standing among the coat would bury the records under its own top,
	-- so it had to start beneath the deepest one. That was tolerable while the coat was a 1-stud skin.
	-- Once the coat deepened to cover the wall of a dug pit, the same rule put the body eleven studs
	-- under the feathers on those columns, and eleven studs is a player falling through a wall they can
	-- see. Visible and shallow was not an option either: that is the pale block showing through the
	-- side of every hole.
	--
	-- Invisible unties the knot. Nothing it overlaps is hidden, so it can top out just under the surface
	-- - you stand where the feathers are - while the coat's lower records stay visible and go on
	-- covering the drop to the neighbour. What stops a sight line going under the mound is the coat
	-- being deep enough, which is now measured per column against the mound as it actually is.
	--
	-- This used to be a thin slab tilted to the local surface normal. Wherever the dome is steep the
	-- neighbouring slabs rotate away from each other, the overlap opens, and the slab's lower edge
	-- hangs studs above the sand: a low sight line then goes between two slabs, under the coat, and
	-- straight out the far side of the mound. That is the see-through band the owner kept seeing at
	-- the foot of the pile, and no amount of coat density can close it, because the hole is behind
	-- the coat. A vertical box that starts below the sand and ends just under the rendered records
	-- cannot open a gap at any camera angle: its sides are parallel, it overlaps its neighbours by
	-- `shellOverlap`, and there is nothing underneath it to look into.
	local function seat(field, config, index: number, x: number, z: number): (CFrame, Vector3)
		local collision = config.pile.collision
		local cx = field.minX + (x + 0.5) * field.cellSize
		local cz = field.minZ + (z + 0.5) * field.cellSize
		local ground = field.groundY or field.baseY
		-- The top of the column's topmost remaining record, which is the feather the player's feet
		-- should meet. Not `heightAt`: that is smoothed over a 3x3, and the renderer does not seat on
		-- it, so on a freshly dug column the smoothed surface stands well above the highest feather
		-- left and on its neighbours it sits below feathers that never moved.
		local top = field.baseY + math.max(0, PileSurface.columnTop(config, field, x, z) - collision.surfaceInsetStuds)
		-- No floor under `top`. A lip forced above the sand here used to stop a low sight line slipping
		-- under the mound's cut-off edge, but the dome reaches the sand on its own now, so all the lip
		-- did was stand the outermost ring of boxes on the ground as bare bricks beyond the coat.
		local floor = math.min(ground, field.baseY) - (collision.bodyBuryStuds or 2)
		local height = math.max(top - floor, 0.05)
		local size = field.cellSize * collision.shellOverlap
		local _ = index
		return CFrame.new(cx, floor + height / 2, cz), Vector3.new(size, height, size)
	end
	local function write(field, config, minX: number?, minZ: number?, maxX: number?, maxZ: number?): number
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
				local frame, size = seat(field, config, index, x, z)
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
	function adapter.writeMound(_, field, config)
		if terrain then
			local rim = field.radius * PileSurface.RIM_STRETCH + 8
			local region = Region3.new(
				Vector3.new(field.centreX - rim, field.baseY - 4, field.centreZ - rim),
				Vector3.new(field.centreX + rim, field.baseY + field.apex + 8, field.centreZ + rim)
			):ExpandToGrid(4)
			terrain:FillRegion(region, 4, Enum.Material.Air)
		end
		return write(field, config)
	end
	function adapter.writeRegion(_, field, config, minX, minZ, maxX, maxZ)
		return write(field, config, minX, minZ, maxX, maxZ)
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
	function adapter.writeRegion(self, field, _config, minX, minZ, maxX, maxZ)
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
