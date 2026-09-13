--!strict
-- Client visual layer for the logical pile: an enormous, ridiculously dense mountain of loose feathers
-- that players dig from the outside (owner requirement, docs/HANDOFF_PHASE4.md; ASSUMED A-UX-07). The
-- server keeps its 16x16 logical cells; the client renders the shared PileSurface field as:
--   1. The mound body: one runtime EditableMesh heightfield (warm beige, low-frequency "fluff" noise so
--      the silhouette is uneven) that is never meant to be seen - it only closes gaps between feathers.
--   2. The feather coat: thousands of anchored clones of the repo Feather mesh (shared geometry, so the
--      renderer batches them; no physics, no collisions, no queries, no per-frame work). Feathers are
--      planned per cell and stacked in depth - flat on the coat, half-buried, upright, and clumps that
--      pile on each other - with many orientations, sizes, and warm cream-to-beige tints, hashed per
--      feather so nothing repeats. Deltas thin the touched cells' feathers and re-seat the rest on the
--      lowered surface (live dents). Placement is spread over frames so a build never hitches.
--      (Baking the coat into runtime EditableMeshes was tried and rejected: the client's editable-mesh
--      memory budget allows only a handful of chunks in Play.)
--   3. Invisible per-column colliders that keep players outside and drop with the surface.
--   4. Pooled clones for the few animated feathers (stream-to-bag, reveal spiral).
-- Without the mesh API the body falls back to one ellipsoid; without the Feather asset the coat uses
-- plain parts (placeholder-tagged).

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local AssetManifest = require(Shared.Design.AssetManifest)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local PileSurface = require(Shared.Domain.PileSurface)

local PileVisualController = {}
PileVisualController.__index = PileVisualController

type Feather = {
	cell: number, -- logical cell index (1-based)
	rank: number, -- 1-based order within the cell; higher ranks vanish first as the cell empties
	ox: number, -- seat offset from the cell centre (studs)
	oz: number,
	yaw: number,
	pitch: number, -- tip lift off the surface (radians)
	roll: number, -- twist about the quill
	depth: number, -- along the surface normal (negative = buried)
	length: number,
	width: number,
	bend: number,
	visible: boolean,
}

type Coat = {
	feathers: { Feather },
	instanced: { [number]: BasePart }, -- one clone per visible feather (index = plan index)
}

type Column = {
	collider: Part,
	base: number,
	remaining: number,
	x: number,
	z: number,
	count: number, -- feathers planned for this cell
}

type Dome = {
	part: BasePart,
	mesh: any?,
	vertexIds: { number },
	normalIds: { number },
	segments: number,
	half: number,
}

export type PileVisualController = typeof(setmetatable(
	{} :: {
		_round: any,
		_quality: any,
		_accessibility: any,
		_vfx: any,
		_audio: any,
		_config: { [string]: any },
		_folder: Folder?,
		_columns: { [number]: Column },
		_coat: Coat,
		_dome: Dome?,
		_pool: { BasePart },
		_streaming: number,
		_layout: any,
		_grid: { [string]: any }?,
		_field: PileSurface.Field?,
		_building: boolean,
		_pendingDeltas: { { [string]: any } },
		_generation: number,
		_trove: Trove.Trove,
		stats: { dents: number, streamed: number, feathersPlaced: number, domeKind: string, coatKind: string, reseats: number },
	},
	PileVisualController
))

-- Presentation constants (A-UX-07). Counts come from config (A-UX-02); shapes and ratios live here.
local FEATHER_MIN_LENGTH, FEATHER_MAX_LENGTH = 1.9, 4.4
local TEMPLATE_SIZE = Vector3.new(0.54, 1.44, 0.13) -- repo Feather mesh extents (scaled per feather)
local CLUMP_SHARE = 0.32 -- share of a cell's feathers that arrive as stacked clumps
local CLUMP_MIN, CLUMP_MAX = 6, 12
local FLUFF_NOISE = 0.55 -- studs of low-frequency surface noise (uneven silhouette)
local PLACE_PER_FRAME = 400 -- clones placed per frame during a build
local FALLBACK_SCALE = 2.4 -- pooled animated feathers
local MESH_SEGMENTS_BY_TIER = { low = 32, medium = 48, high = 64 }
local CREAM = Color3.fromRGB(252, 246, 232)
local BEIGE = Color3.fromRGB(230, 212, 180)
local DOME_COLOR = Color3.fromRGB(236, 222, 194)
local DOME_COLOR_DEEP = Color3.fromRGB(218, 200, 166)
local TINTS = { CREAM, Color3.fromRGB(246, 238, 220), Color3.fromRGB(240, 228, 204), BEIGE }

function PileVisualController.new(
	deps: { round: any, quality: any, accessibility: any, vfx: any, audio: any, config: { [string]: any } }
): PileVisualController
	local self = setmetatable({
		_round = deps.round,
		_quality = deps.quality,
		_accessibility = deps.accessibility,
		_vfx = deps.vfx,
		_audio = deps.audio,
		_config = deps.config,
		_folder = nil,
		_columns = {},
		_coat = { feathers = {}, instanced = {} },
		_dome = nil,
		_pool = {},
		_streaming = 0,
		_layout = ChapterLayout.chapter1,
		_grid = nil,
		_field = nil,
		_building = false,
		_pendingDeltas = {},
		_generation = 0,
		_trove = Trove.new(),
		stats = { dents = 0, streamed = 0, feathersPlaced = 0, domeKind = "none", coatKind = "none", reseats = 0 },
	}, PileVisualController)
	self._trove:add(deps.round.snapshot:Connect(function(payload)
		if payload.pile then
			self:build(payload.pile, payload.chapter)
		end
	end))
	self._trove:add(deps.round.delta:Connect(function(payload)
		self:applyDelta(payload)
	end))
	self._trove:add(deps.round.phaseChanged:Connect(function(phase)
		if phase == "Returning" or phase == "Abandoned" then
			self:clear()
		end
	end))
	return self
end

-- Deterministic per-index pseudo-random in [0,1) so rebuilds are stable and there is no visible order.
local function hash(index: number, salt: number): number
	local n = math.sin(index * 12.9898 + salt * 78.233) * 43758.5453
	return n - math.floor(n)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Low-frequency "fluff" noise so the coat and the body silhouette are uneven, never a clean cone.
local function fluff(wx: number, wz: number): number
	return FLUFF_NOISE
		* (
			0.6 * math.sin(wx * 0.61 + 1.3) * math.cos(wz * 0.53 + 0.4)
			+ 0.4 * math.sin(wx * 1.7 + wz * 0.9) * math.sin(wz * 1.9 - wx * 0.7)
		)
end

local function acquireFeather(self: PileVisualController): BasePart
	local feather = table.remove(self._pool)
	if feather then
		feather.Size = TEMPLATE_SIZE * FALLBACK_SCALE
		return feather
	end
	local template = AssetManifest.model("feather")
	local part: BasePart
	if template and template:IsA("BasePart") then
		part = template:Clone() :: BasePart
		part.Size = template.Size * FALLBACK_SCALE
	else
		local fallback = Instance.new("Part")
		fallback.Size = TEMPLATE_SIZE * FALLBACK_SCALE
		fallback.Material = Enum.Material.SmoothPlastic
		fallback:SetAttribute("SFE_Placeholder", "PHASE_6_VFX")
		part = fallback
	end
	part.Name = "Feather"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 0
	return part
end

local function releaseFeather(self: PileVisualController, feather: BasePart)
	feather.Parent = nil
	feather.Transparency = 0
	table.insert(self._pool, feather)
end

-- World centre of a column (XZ) and its current height.
function PileVisualController._columnGeometry(self: PileVisualController, column: Column): (Vector3, number)
	local field = self._field :: PileSurface.Field
	local centre = ChapterLayout.cellWorldPosition(self._layout, field.width, field.depth, field.cellSize, column.x, column.z, 0)
	return centre, PileSurface.columnHeight(field, column.x, column.z)
end

-- Visual surface height above the base at a world XZ: the shared field plus fluff where feathers remain.
function PileVisualController._visualHeight(self: PileVisualController, wx: number, wz: number): number
	local field = self._field :: PileSurface.Field
	local h = PileSurface.heightAt(field, wx, wz)
	if h <= 0 then
		return 0
	end
	return math.max(0, h + fluff(wx, wz) * math.min(1, h / 3))
end

-- Collider box per column: full column height, dropped below the floor once the column is cleared.
function PileVisualController._shapeCollider(self: PileVisualController, column: Column)
	local field = self._field :: PileSurface.Field
	local centre, height = self:_columnGeometry(column)
	local cell = field.cellSize
	local cleared = height <= 0.001
	if cleared then
		column.collider.Size = Vector3.new(cell, 0.1, cell)
		column.collider.CFrame = CFrame.new(centre + Vector3.new(0, field.baseY - 0.2, 0))
	else
		column.collider.Size = Vector3.new(cell, height, cell)
		column.collider.CFrame = CFrame.new(centre + Vector3.new(0, field.baseY + height / 2, 0))
	end
	column.collider.CanCollide = not cleared
end

-- ---------------------------------------------------------------------------------------------
-- Mound body
-- ---------------------------------------------------------------------------------------------

function PileVisualController._domeVertex(self: PileVisualController, dome: Dome, ix: number, iz: number): (Vector3, Vector3)
	local field = self._field :: PileSurface.Field
	local lx = -dome.half + (ix / dome.segments) * dome.half * 2
	local lz = -dome.half + (iz / dome.segments) * dome.half * 2
	local rim = field.radius * PileSurface.RIM_STRETCH
	local r = math.sqrt(lx * lx + lz * lz)
	if r > rim then
		lx, lz = lx * rim / r, lz * rim / r
	end
	local wx, wz = field.centreX + lx, field.centreZ + lz
	-- The body sits a little under the visual surface so the coat, not the body, defines the skin.
	local h = math.max(0, self:_visualHeight(wx, wz) - 0.25)
	return Vector3.new(lx, h, lz), PileSurface.normalAt(field, wx, wz)
end

local function partDefaults(part: BasePart, name: string, tier: string)
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = name == "Dome"
	part.CanTouch = false
	part.CastShadow = tier ~= "low"
	part.Material = Enum.Material.SmoothPlastic
	part:SetAttribute("SFE_Placeholder", "PHASE_6_ART")
end

function PileVisualController._buildDome(self: PileVisualController, folder: Folder, tier: string)
	local field = self._field :: PileSurface.Field
	local segments = MESH_SEGMENTS_BY_TIER[tier] or MESH_SEGMENTS_BY_TIER.medium
	local half = math.max(field.width, field.depth) * field.cellSize / 2 * PileSurface.RIM_STRETCH
	local dome: Dome = { part = nil :: any, mesh = nil, vertexIds = {}, normalIds = {}, segments = segments, half = half }
	local ok, err = pcall(function()
		local mesh = (AssetService :: any):CreateEditableMesh()
		local colorIds = {}
		for iz = 0, segments do
			for ix = 0, segments do
				local k = iz * (segments + 1) + ix + 1
				local position, normal = self:_domeVertex(dome, ix, iz)
				dome.vertexIds[k] = mesh:AddVertex(position)
				dome.normalIds[k] = mesh:AddNormal(normal)
				colorIds[k] = mesh:AddColor(DOME_COLOR:Lerp(DOME_COLOR_DEEP, hash(k, 41) * 0.8), 1)
			end
		end
		for iz = 0, segments - 1 do
			for ix = 0, segments - 1 do
				local a = iz * (segments + 1) + ix + 1
				local b = a + 1
				local c = a + segments + 1
				local d = c + 1
				local f1 = mesh:AddTriangle(dome.vertexIds[a], dome.vertexIds[c], dome.vertexIds[b])
				local f2 = mesh:AddTriangle(dome.vertexIds[b], dome.vertexIds[c], dome.vertexIds[d])
				mesh:SetFaceNormals(f1, { dome.normalIds[a], dome.normalIds[c], dome.normalIds[b] })
				mesh:SetFaceNormals(f2, { dome.normalIds[b], dome.normalIds[c], dome.normalIds[d] })
				mesh:SetFaceColors(f1, { colorIds[a], colorIds[c], colorIds[b] })
				mesh:SetFaceColors(f2, { colorIds[b], colorIds[c], colorIds[d] })
			end
		end
		dome.part = (AssetService :: any):CreateMeshPartAsync(Content.fromObject(mesh)) :: MeshPart
		dome.mesh = mesh
	end)
	if ok and dome.part then
		self.stats.domeKind = "mesh"
		dome.part.Color = Color3.new(1, 1, 1)
	else
		warn("[SFE][Pile] editable mesh unavailable, using ellipsoid mound: " .. tostring(err))
		local part = Instance.new("Part")
		local special = Instance.new("SpecialMesh")
		special.MeshType = Enum.MeshType.Sphere
		special.Parent = part
		dome.part = part
		dome.mesh = nil
		dome.part.Color = DOME_COLOR
		self.stats.domeKind = "ellipsoid"
	end
	partDefaults(dome.part, "Dome", tier)
	dome.part.Material = Enum.Material.Fabric
	self._dome = dome
	self:_placeDome()
	dome.part.Parent = folder
end

function PileVisualController._placeDome(self: PileVisualController)
	local dome = self._dome
	local field = self._field
	if not dome or not field then
		return
	end
	if dome.mesh then
		dome.part.CFrame = CFrame.new(field.centreX, field.baseY, field.centreZ)
	else
		local peak = math.max(0.2, PileSurface.heightAt(field, field.centreX, field.centreZ))
		local footprint = dome.half * 2
		dome.part.Size = Vector3.new(footprint, peak * 2, footprint)
		dome.part.CFrame = CFrame.new(field.centreX, field.baseY, field.centreZ)
	end
end

-- Moves the body vertices inside a world XZ box onto the current field (live dent).
function PileVisualController._refreshDome(self: PileVisualController, minX: number, maxX: number, minZ: number, maxZ: number)
	local dome = self._dome
	local field = self._field
	if not dome or not field then
		return
	end
	if not dome.mesh then
		self:_placeDome()
		return
	end
	for iz = 0, dome.segments do
		local wz = field.centreZ - dome.half + (iz / dome.segments) * dome.half * 2
		if wz < minZ or wz > maxZ then
			continue
		end
		for ix = 0, dome.segments do
			local wx = field.centreX - dome.half + (ix / dome.segments) * dome.half * 2
			if wx < minX or wx > maxX then
				continue
			end
			local k = iz * (dome.segments + 1) + ix + 1
			local position, normal = self:_domeVertex(dome, ix, iz)
			dome.mesh:SetPosition(dome.vertexIds[k], position)
			dome.mesh:SetNormal(dome.normalIds[k], normal)
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- Feather coat
-- ---------------------------------------------------------------------------------------------

-- Plans every feather of a cell: singles across the cell plus stacked clumps. Deterministic per cell.
local function planCell(cellIndex: number, count: number, cellSize: number, out: { Feather }, rimPush: Vector3?)
	local rank = 0
	local function add(seed: number, ox: number, oz: number, yaw: number, pitch: number, roll: number, depth: number)
		rank += 1
		local length = lerp(FEATHER_MIN_LENGTH, FEATHER_MAX_LENGTH, hash(seed, 61) ^ 1.3)
		if rimPush then
			-- Rim cells also dress the skirt below them: push a share of their seats outward.
			local push = hash(seed, 89) * cellSize * 1.6
			ox += rimPush.X * push
			oz += rimPush.Z * push
		end
		table.insert(out, {
			cell = cellIndex,
			rank = rank,
			ox = ox,
			oz = oz,
			yaw = yaw,
			pitch = pitch,
			roll = roll,
			depth = depth,
			length = length,
			width = length * lerp(0.26, 0.40, hash(seed, 67)),
			bend = lerp(0.05, 0.22, hash(seed, 71)),
			visible = true,
		})
	end
	local clumpBudget = math.floor(count * CLUMP_SHARE)
	local singles = count - clumpBudget
	local spread = cellSize * 0.8
	for f = 1, singles do
		local seed = cellIndex * 97 + f * 17
		local kind = hash(seed, 3)
		local pitch, depth
		if kind < 0.58 then
			-- flat on the coat, slightly sunk so the quill end disappears
			pitch = hash(seed, 5) * 0.35
			depth = lerp(-0.35, 0.1, hash(seed, 7))
		elseif kind < 0.82 then
			-- half-buried: only the tip shows, reads as depth
			pitch = hash(seed, 5) * 0.55
			depth = lerp(-1.3, -0.5, hash(seed, 7))
		else
			-- upright / crossed pieces that break the silhouette
			pitch = lerp(0.6, 1.35, hash(seed, 5))
			depth = lerp(-0.5, -0.15, hash(seed, 7))
		end
		add(
			seed,
			(hash(seed, 11) - 0.5) * spread,
			(hash(seed, 13) - 0.5) * spread,
			hash(seed, 23) * math.pi * 2,
			pitch,
			(hash(seed, 29) - 0.5) * 1.2,
			depth
		)
	end
	local placed = 0
	local clumpNo = 0
	while placed < clumpBudget do
		clumpNo += 1
		local seed = cellIndex * 131 + clumpNo * 523
		local size = math.min(clumpBudget - placed, math.floor(lerp(CLUMP_MIN, CLUMP_MAX + 0.99, hash(seed, 31))))
		local cx, cz = (hash(seed, 11) - 0.5) * spread, (hash(seed, 13) - 0.5) * spread
		local clumpYaw = hash(seed, 23) * math.pi * 2
		for k = 1, size do
			local s = seed + k * 7
			add(
				s,
				cx + (hash(s, 11) - 0.5) * 1.1,
				cz + (hash(s, 13) - 0.5) * 1.1,
				clumpYaw + (hash(s, 23) - 0.5) * 1.1,
				lerp(0.05, 0.5, hash(s, 5)),
				(hash(s, 29) - 0.5) * 1.4,
				-0.25 + (k - 1) * 0.24 + hash(s, 7) * 0.1 -- stacked: each sits on the one below
			)
		end
		placed += size
	end
end

-- Seat frame for a feather on the current visual surface (world space).
function PileVisualController._featherFrame(self: PileVisualController, feather: Feather): CFrame
	local field = self._field :: PileSurface.Field
	local column = self._columns[feather.cell]
	local centre = self:_columnGeometry(column)
	local wx, wz = centre.X + feather.ox, centre.Z + feather.oz
	local dx, dz = wx - field.centreX, wz - field.centreZ
	local r = math.sqrt(dx * dx + dz * dz)
	local rimInset = field.radius * PileSurface.RIM_STRETCH * 0.96
	if r > rimInset then
		wx, wz = field.centreX + dx * rimInset / r, field.centreZ + dz * rimInset / r
	end
	local y = field.baseY + self:_visualHeight(wx, wz)
	local normal = PileSurface.normalAt(field, wx, wz)
	local yawDirection = Vector3.new(math.cos(feather.yaw), 0, math.sin(feather.yaw))
	local tangent = yawDirection - normal * yawDirection:Dot(normal)
	if tangent.Magnitude < 0.01 then
		tangent = Vector3.new(1, 0, 0)
	end
	tangent = tangent.Unit
	local binormal = normal:Cross(tangent)
	-- X = width, Y = along the quill, Z = feather "up" (its own normal).
	local frame = CFrame.fromMatrix(Vector3.new(wx, y, wz) + normal * feather.depth, binormal, tangent, normal)
	return frame * CFrame.Angles(feather.pitch, feather.roll, 0)
end

-- Whether a planned feather is still present for the cell's remaining fraction.
function PileVisualController._featherVisible(self: PileVisualController, feather: Feather): boolean
	local column = self._columns[feather.cell]
	if not column or column.remaining <= 0 then
		return false
	end
	local keep = math.ceil(column.count * (column.remaining / math.max(1, column.base)))
	return feather.rank <= keep
end

-- Seats (or hides) coat clones. `onlyCells` limits the pass to the touched cells; `budgetPerFrame`
-- yields between batches so a full build never stalls a frame.
function PileVisualController._placeCoat(
	self: PileVisualController,
	folder: Folder,
	onlyCells: { [number]: boolean }?,
	budgetPerFrame: number?
)
	local coat = self._coat
	local instanced = coat.instanced
	local placedThisFrame = 0
	for i, feather in ipairs(coat.feathers) do
		if onlyCells and not onlyCells[feather.cell] then
			continue
		end
		local visible = self:_featherVisible(feather)
		feather.visible = visible
		local part = instanced[i]
		if visible then
			if not part then
				part = acquireFeather(self)
				local seed = feather.cell * 977 + feather.rank * 31
				part.Color = CREAM:Lerp(BEIGE, hash(seed, 83) ^ 1.1)
				part.Size = TEMPLATE_SIZE * (feather.length / TEMPLATE_SIZE.Y)
				instanced[i] = part
			end
			part.CFrame = self:_featherFrame(feather) * CFrame.new(0, feather.length * 0.5, 0)
			part.Parent = folder
			self.stats.reseats += 1
		elseif part then
			releaseFeather(self, part)
			instanced[i] = nil
		end
		if budgetPerFrame then
			placedThisFrame += 1
			if placedThisFrame >= budgetPerFrame then
				placedThisFrame = 0
				task.wait()
				if self._folder ~= folder then
					return
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- Build / delta
-- ---------------------------------------------------------------------------------------------

-- Builds the mound from a snapshot. Mesh creation yields, so the heavy work runs in its own thread
-- and deltas that arrive meanwhile are queued and applied once the coat exists.
function PileVisualController.build(self: PileVisualController, pile: { [string]: any }, chapter: string?)
	self:clear()
	self._generation += 1
	local generation = self._generation
	local folder = Instance.new("Folder")
	folder.Name = "SFE_PileVisual"
	folder.Parent = workspace
	self._folder = folder
	self._layout = ChapterLayout[chapter or "chapter1"]
	self._grid = {
		width = pile.width,
		depth = pile.depth,
		cellSize = pile.cellSize,
		remaining = table.clone(pile.remaining),
		base = table.clone(pile.base),
	}
	self._field = PileSurface.buildField(self._config, self._grid, self._layout)
	local field = self._field :: PileSurface.Field
	local budgets = self._quality:budgets()
	local tier = self._quality:tier()
	local cellCount = pile.width * pile.depth

	-- Columns (colliders) and the feather budget over the cells the mound actually covers, weighted
	-- by each cell's surface area (steep flanks get more) and boosted at the rim (the skirt below).
	local covered = 0
	local weights: { [number]: number } = {}
	local rimPush: { [number]: Vector3 } = {}
	local weightSum = 0
	for index = 1, cellCount do
		local x = (index - 1) % pile.width
		local z = math.floor((index - 1) / pile.width)
		local collider = Instance.new("Part")
		collider.Name = "Collider" .. index
		collider.Anchored = true
		collider.CanCollide = true
		collider.CanQuery = false
		collider.CanTouch = false
		collider.Transparency = 1
		collider.CastShadow = false
		local column: Column =
			{ collider = collider, base = pile.base[index], remaining = pile.remaining[index], x = x, z = z, count = 0, topCount = 0 }
		self._columns[index] = column
		local centre = self:_columnGeometry(column)
		local dx, dz = centre.X - field.centreX, centre.Z - field.centreZ
		local rNorm = math.sqrt(dx * dx + dz * dz) / field.radius
		if PileSurface.domeProfile(rNorm) > 0 then
			covered += 1
			local gx, gz = PileSurface.gradientAt(field, centre.X, centre.Z)
			local area = math.sqrt(1 + gx * gx + gz * gz) -- surface area per footprint area
			local weight = math.min(2.4, area) * lerp(0.8, 1.25, hash(index, 47))
			if rNorm > 0.78 then
				weight *= 1.35
				rimPush[index] = Vector3.new(dx, 0, dz).Unit
			end
			weights[index] = weight
			weightSum += weight
			column.count = -1 -- marked, sized below
		end
		self:_shapeCollider(column)
		collider.Parent = folder
	end
	for index = 1, cellCount do
		local column = self._columns[index]
		if column.count < 0 then
			column.count = math.max(1, math.floor(budgets.strands * weights[index] / math.max(1e-6, weightSum) + 0.5))
		end
	end

	-- Plan the coat (deterministic per cell) and place it over a few frames.
	self._coat = { feathers = {}, instanced = {} }
	local planned = 0
	for index = 1, cellCount do
		local column = self._columns[index]
		if column.count > 0 then
			planCell(index, column.count, pile.cellSize, self._coat.feathers, rimPush[index])
			planned += column.count
		end
	end
	self.stats.feathersPlaced = planned
	self.stats.reseats = 0

	self._building = true
	task.spawn(function()
		self:_buildDome(folder, tier)
		if self._generation ~= generation or self._folder ~= folder then
			return
		end
		self:_placeCoat(folder, nil, PLACE_PER_FRAME)
		if self._generation ~= generation or self._folder ~= folder then
			return
		end
		local template = AssetManifest.model("feather")
		self.stats.coatKind = if template and template:IsA("MeshPart") then "mesh" else "parts"
		self._building = false
		local pending = self._pendingDeltas
		self._pendingDeltas = {}
		for _, payload in ipairs(pending) do
			self:applyDelta(payload)
		end
	end)
end

-- Applies an authoritative delta: rebuild the field, dent the body around the touched cells, drop
-- their colliders, and re-seat / thin the coat feathers of those cells.
function PileVisualController.applyDelta(self: PileVisualController, payload: { [string]: any })
	if not self._folder or not self._grid then
		return
	end
	if self._building then
		table.insert(self._pendingDeltas, payload)
		return
	end
	local touched: { [number]: boolean } = {}
	local grid = self._grid :: { [string]: any }
	for _, change in ipairs(payload.cells) do
		local column = self._columns[change.i]
		if not column then
			continue
		end
		column.remaining = change.r
		grid.remaining[change.i] = change.r
		self.stats.dents += 1
		for dz = -1, 1 do
			for dx = -1, 1 do
				local nx, nz = column.x + dx, column.z + dz
				if nx >= 0 and nz >= 0 and nx < grid.width and nz < grid.depth then
					touched[nz * grid.width + nx + 1] = true
				end
			end
		end
	end
	if not next(touched) then
		return
	end
	self._field = PileSurface.buildField(self._config, grid, self._layout)
	local field = self._field :: PileSurface.Field
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for index in pairs(touched) do
		local column = self._columns[index]
		local centre = self:_columnGeometry(column)
		minX = math.min(minX, centre.X - field.cellSize * 2)
		maxX = math.max(maxX, centre.X + field.cellSize * 2)
		minZ = math.min(minZ, centre.Z - field.cellSize * 2)
		maxZ = math.max(maxZ, centre.Z + field.cellSize * 2)
		self:_shapeCollider(column)
	end
	self:_refreshDome(minX, maxX, minZ, maxZ)
	self:_placeCoat(self._folder :: Folder, touched, nil)
end

-- Feedback for an awarded hit: feathers tug up from the hit point, then stream toward `target`.
function PileVisualController.streamToBag(self: PileVisualController, hitPosition: Vector3, count: number, target: () -> Vector3)
	if not self._folder then
		return
	end
	local motion = self._accessibility:motionSettings()
	local budget = math.max(1, math.floor(self._quality:budgets().strands / 400))
	local n = math.min(count, budget, 6)
	local field = self._field
	local surfaceY = if field then field.baseY + self:_visualHeight(hitPosition.X, hitPosition.Z) else hitPosition.Y
	for i = 1, n do
		local feather = acquireFeather(self)
		feather.Color = TINTS[(i % #TINTS) + 1]
		feather.Parent = self._folder
		local offset = Vector3.new((i - n / 2) * 0.35, 0.4, ((i * 7) % 3 - 1) * 0.3)
		feather.CFrame = CFrame.new(Vector3.new(hitPosition.X, surfaceY, hitPosition.Z) + offset) * CFrame.Angles(math.rad(70), i * 1.1, 0)
		self._streaming += 1
		self.stats.streamed += 1
		-- Tug (anticipation), then release toward the bag (reward), then recycle (recovery).
		local tugInfo = TweenInfo.new(Motion.duration("quick", motion), Tokens.motion.easeOut)
		local tug = TweenService:Create(
			feather,
			tugInfo,
			{ CFrame = feather.CFrame * CFrame.new(0, 0.8 * self._accessibility:motionScale(), 0) * CFrame.Angles(0.6, 0.4, 0) }
		)
		tug:Play()
		tug.Completed:Once(function()
			local flyInfo = TweenInfo.new(Motion.duration("slow", motion), Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			local fly =
				TweenService:Create(feather, flyInfo, { CFrame = CFrame.new(target()) * CFrame.Angles(0, i, 0), Transparency = 0.6 })
			fly:Play()
			fly.Completed:Once(function()
				self._streaming -= 1
				releaseFeather(self, feather)
			end)
		end)
	end
	self._vfx:burst("featherPuff", Vector3.new(hitPosition.X, surfaceY, hitPosition.Z), 0.35)
end

-- Reveal spiral: feathers from the cover cells lift in a spiral around the Egg (reduced motion:
-- shorter, lower lift).
function PileVisualController.revealSpiral(self: PileVisualController, eggPosition: Vector3, coverCells: { number })
	if not self._folder then
		return
	end
	local motion = self._accessibility:motionSettings()
	local scale = self._accessibility:motionScale()
	local count = math.min(#coverCells * 2, 18)
	for i = 1, count do
		local feather = acquireFeather(self)
		feather.Parent = self._folder
		local angle = (i / count) * math.pi * 2
		feather.CFrame = CFrame.new(eggPosition + Vector3.new(math.cos(angle) * 2, 0.2, math.sin(angle) * 2))
			* CFrame.Angles(math.rad(80), angle, 0)
		local info = TweenInfo.new(Motion.duration("slow", motion) * 4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
		local goal = CFrame.new(
			eggPosition + Vector3.new(math.cos(angle + 2.5) * 5 * scale, 6 * scale + 1, math.sin(angle + 2.5) * 5 * scale)
		) * CFrame.Angles(angle, angle * 2, 0)
		local tween = TweenService:Create(feather, info, { CFrame = goal, Transparency = 1 })
		tween:Play()
		tween.Completed:Once(function()
			releaseFeather(self, feather)
		end)
	end
	self._vfx:burst("sparkle", eggPosition + Vector3.new(0, 1, 0), 1.2)
end

function PileVisualController.clear(self: PileVisualController)
	self._generation += 1
	self._building = false
	self._pendingDeltas = {}
	for _, part in pairs(self._coat.instanced) do
		releaseFeather(self, part)
	end
	self._coat = { feathers = {}, instanced = {} }
	table.clear(self._columns)
	self._grid = nil
	self._field = nil
	local dome = self._dome
	if dome then
		if dome.mesh then
			pcall(function()
				dome.mesh:Destroy()
			end)
		end
		self._dome = nil
	end
	if self._folder then
		self._folder:Destroy()
		self._folder = nil
	end
end

-- Latest known remaining count per cell index (from snapshot + deltas).
function PileVisualController.remainingByIndex(self: PileVisualController): { [number]: number }
	local out = {}
	for index, column in pairs(self._columns) do
		out[index] = column.remaining
	end
	return out
end

-- Surface height above the base at a world XZ (0 without a pile), for tests and the harness.
function PileVisualController.surfaceHeightAt(self: PileVisualController, worldX: number, worldZ: number): number
	local field = self._field
	return if field then PileSurface.heightAt(field, worldX, worldZ) else 0
end

function PileVisualController.domeKind(self: PileVisualController): string
	return self.stats.domeKind
end

function PileVisualController.coatKind(self: PileVisualController): string
	return self.stats.coatKind
end

function PileVisualController.cellCount(self: PileVisualController): number
	local n = 0
	for _ in pairs(self._columns) do
		n += 1
	end
	return n
end

-- Visible feathers in the coat.
function PileVisualController.featherCount(self: PileVisualController): number
	local n = 0
	for _, feather in ipairs(self._coat.feathers) do
		if feather.visible then
			n += 1
		end
	end
	return n
end

function PileVisualController.instanceCount(self: PileVisualController): number
	return if self._folder then #self._folder:GetDescendants() else 0
end

function PileVisualController.pooledCount(self: PileVisualController): number
	return #self._pool
end

function PileVisualController.destroy(self: PileVisualController)
	self:clear()
	for _, feather in ipairs(self._pool) do
		feather:Destroy()
	end
	table.clear(self._pool)
	self._trove:destroy()
end

return PileVisualController
