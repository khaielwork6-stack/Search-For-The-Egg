--!strict
-- Client visual layer for the logical pile: one smooth, dense dome of feathers that players dig from
-- the outside (owner requirement, docs/HANDOFF_PHASE4.md; ASSUMED A-UX-07). The server keeps its
-- 16x16 logical cells; the client renders the shared PileSurface field as:
--   1. The mound: a single runtime EditableMesh heightfield (smooth per-vertex normals, subtle
--      cream vertex tints) sampled from PileSurface, so there is no visible grid. Deltas move the
--      touched vertices in place (live dents). When the mesh API is unavailable the mound falls
--      back to one ellipsoid (SpecialMesh sphere) that shrinks with the remaining fraction.
--   2. Invisible per-column colliders (cheap boxes) that keep players on the outside and drop with
--      the surface as cells clear; the mesh itself is query-only.
--   3. Feather shingles: the repo Feather mesh, instanced by density from the tier budget, lying
--      tangent to the surface (pitched along the local slope), random yaw, cream tints, pooled.
--   4. Streaming feathers that tug, release, and fly to the bag on each awarded hit, and the reveal
--      spiral, both from the same pool.

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

type Column = {
	collider: Part,
	base: number,
	remaining: number,
	x: number,
	z: number,
	feathers: { BasePart },
	seats: { { ox: number, oz: number, yaw: number, tint: number } },
}

type Dome = {
	part: BasePart,
	mesh: any?, -- EditableMesh when available
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
		_dome: Dome?,
		_pool: { BasePart },
		_streaming: number,
		_layout: any,
		_grid: { [string]: any }?,
		_field: PileSurface.Field?,
		_trove: Trove.Trove,
		stats: { dents: number, streamed: number, feathersPlaced: number, domeKind: string },
	},
	PileVisualController
))

local FEATHER_SCALE = 3.2 -- repo Feather mesh (0.54 x 1.44 studs) scaled to a readable shingle
local FEATHER_LIFT = 0.06 -- seat height above the surface (shingles half-sink so their ends stay flush)
local MESH_SEGMENTS_BY_TIER = { low = 32, medium = 48, high = 64 }
local MESH_SKIRT = PileSurface.RIM_STRETCH -- the heightfield grid spans the mound's full foot
local TINTS = { Tokens.color.cream, Tokens.color.creamDeep, Tokens.color.surface, Color3.fromRGB(246, 236, 214), Tokens.color.creamPill }
local DOME_COLOR = Color3.fromRGB(250, 243, 226)
local DOME_COLOR_DEEP = Color3.fromRGB(238, 226, 200)

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
		_dome = nil,
		_pool = {},
		_streaming = 0,
		_layout = ChapterLayout.chapter1,
		_grid = nil,
		_field = nil,
		_trove = Trove.new(),
		stats = { dents = 0, streamed = 0, feathersPlaced = 0, domeKind = "none" },
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

local function acquireFeather(self: PileVisualController): BasePart
	local feather = table.remove(self._pool)
	if feather then
		return feather
	end
	local template = AssetManifest.model("feather")
	local part: BasePart
	if template and template:IsA("BasePart") then
		part = template:Clone() :: BasePart
		part.Size = template.Size * FEATHER_SCALE
	else
		local fallback = Instance.new("Part")
		fallback.Size = Vector3.new(0.54, 1.44, 0.13) * FEATHER_SCALE
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

function PileVisualController._seatFeather(
	self: PileVisualController,
	column: Column,
	feather: BasePart,
	seat: { ox: number, oz: number, yaw: number, tint: number }
)
	local field = self._field :: PileSurface.Field
	local centre = self:_columnGeometry(column)
	local wx, wz = centre.X + seat.ox, centre.Z + seat.oz
	-- Seats that scatter past the mound's foot are pulled back onto the flank so no shingle lies
	-- flat on the floor beyond the nest base.
	local dx, dz = wx - field.centreX, wz - field.centreZ
	local r = math.sqrt(dx * dx + dz * dz)
	local rimInset = field.radius * PileSurface.RIM_STRETCH * 0.96
	if r > rimInset then
		wx, wz = field.centreX + dx * rimInset / r, field.centreZ + dz * rimInset / r
	end
	local y = field.baseY + PileSurface.heightAt(field, wx, wz) + FEATHER_LIFT
	-- Surface normal from the slope; the feather's long axis (Y) lies along the surface.
	local normal = PileSurface.normalAt(field, wx, wz)
	local yawDirection = Vector3.new(math.cos(seat.yaw), 0, math.sin(seat.yaw))
	local tangent = (yawDirection - normal * yawDirection:Dot(normal))
	if tangent.Magnitude < 0.01 then
		tangent = Vector3.new(1, 0, 0)
	end
	tangent = tangent.Unit
	local binormal = normal:Cross(tangent)
	feather.CFrame = CFrame.fromMatrix(Vector3.new(wx, y, wz), binormal, tangent, normal)
	feather.Color = TINTS[(math.floor(seat.tint * #TINTS) % #TINTS) + 1]
end

function PileVisualController._targetFeatherCount(self: PileVisualController, column: Column, perCell: number): number
	local field = self._field :: PileSurface.Field
	-- Footprint corners outside the round mound carry no shingles (they would float past the base).
	local centre = self:_columnGeometry(column)
	local dx, dz = centre.X - field.centreX, centre.Z - field.centreZ
	if PileSurface.domeProfile(math.sqrt(dx * dx + dz * dz) / field.radius) <= 0 then
		return 0
	end
	local fraction = column.remaining / math.max(1, column.base)
	local jitter = hash(column.x + column.z * field.width, 5) * 0.8
	return math.floor(perCell * fraction + jitter + 0.35)
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

-- Mesh-local position and normal of heightfield vertex (ix, iz).
function PileVisualController._domeVertex(self: PileVisualController, dome: Dome, ix: number, iz: number): (Vector3, Vector3)
	local field = self._field :: PileSurface.Field
	local lx = -dome.half + (ix / dome.segments) * dome.half * 2
	local lz = -dome.half + (iz / dome.segments) * dome.half * 2
	-- Vertices past the rim collapse onto the rim circle, so the mesh edge is the mound's foot (no
	-- flat skirt over the nest base or the floor beyond it).
	local rim = field.radius * PileSurface.RIM_STRETCH
	local r = math.sqrt(lx * lx + lz * lz)
	if r > rim then
		lx, lz = lx * rim / r, lz * rim / r
	end
	local wx, wz = field.centreX + lx, field.centreZ + lz
	return Vector3.new(lx, PileSurface.heightAt(field, wx, wz), lz), PileSurface.normalAt(field, wx, wz)
end

local function domePartDefaults(part: BasePart, tier: string)
	part.Name = "Dome"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = true
	part.CanTouch = false
	part.CastShadow = tier ~= "low"
	part.Material = Enum.Material.SmoothPlastic
	part.Color = DOME_COLOR
	part:SetAttribute("SFE_Placeholder", "PHASE_6_ART")
end

-- Builds the mound: an EditableMesh heightfield when the API is available, else one ellipsoid.
function PileVisualController._buildDome(self: PileVisualController, folder: Folder, tier: string)
	local field = self._field :: PileSurface.Field
	local segments = MESH_SEGMENTS_BY_TIER[tier] or MESH_SEGMENTS_BY_TIER.medium
	local half = math.max(field.width, field.depth) * field.cellSize / 2 * MESH_SKIRT
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
				colorIds[k] = mesh:AddColor(DOME_COLOR:Lerp(DOME_COLOR_DEEP, hash(k, 41) * 0.7), 1)
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
		local part = (AssetService :: any):CreateMeshPartAsync(Content.fromObject(mesh)) :: MeshPart
		dome.part = part
		dome.mesh = mesh
	end)
	if ok and dome.part then
		self.stats.domeKind = "mesh"
	else
		warn("[SFE][Pile] editable mesh unavailable, using ellipsoid mound: " .. tostring(err))
		local part = Instance.new("Part")
		local special = Instance.new("SpecialMesh")
		special.MeshType = Enum.MeshType.Sphere
		special.Parent = part
		dome.part = part
		dome.mesh = nil
		self.stats.domeKind = "ellipsoid"
	end
	domePartDefaults(dome.part, tier)
	self._dome = dome
	self:_placeDome()
	dome.part.Parent = folder
end

-- Positions the mound (mesh origin = nest centre at base height) or resizes the fallback ellipsoid.
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
		local footprint = dome.half / MESH_SKIRT * 2 * PileSurface.RIM_STRETCH
		dome.part.Size = Vector3.new(footprint, peak * 2, footprint)
		dome.part.CFrame = CFrame.new(field.centreX, field.baseY, field.centreZ)
	end
end

-- Moves the heightfield vertices inside a world XZ box onto the current field (live dent).
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
	local mesh = dome.mesh
	for iz = 0, dome.segments do
		local lz = -dome.half + (iz / dome.segments) * dome.half * 2
		local wz = field.centreZ + lz
		if wz < minZ or wz > maxZ then
			continue
		end
		for ix = 0, dome.segments do
			local lx = -dome.half + (ix / dome.segments) * dome.half * 2
			local wx = field.centreX + lx
			if wx < minX or wx > maxX then
				continue
			end
			local k = iz * (dome.segments + 1) + ix + 1
			local position, normal = self:_domeVertex(dome, ix, iz)
			mesh:SetPosition(dome.vertexIds[k], position)
			mesh:SetNormal(dome.normalIds[k], normal)
		end
	end
end

-- Builds the dome from a snapshot. Rebuilding on a new snapshot reuses the feather pool.
function PileVisualController.build(self: PileVisualController, pile: { [string]: any }, chapter: string?)
	self:clear()
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
	local budgets = self._quality:budgets()
	local tier = self._quality:tier()
	local cellCount = pile.width * pile.depth
	local perCell = budgets.strands / cellCount
	local cell = pile.cellSize

	self:_buildDome(folder, tier)

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
		local column: Column = {
			collider = collider,
			base = pile.base[index],
			remaining = pile.remaining[index],
			x = x,
			z = z,
			feathers = {},
			seats = {},
		}
		self._columns[index] = column
		-- Shingle seats: stable per-index scatter across the cell (and a little beyond it).
		local count = self:_targetFeatherCount(column, perCell)
		for f = 1, count do
			local seed = x * 7 + z * 131 + f * 17
			table.insert(column.seats, {
				ox = (hash(seed, 11) - 0.5) * cell * 1.3,
				oz = (hash(seed, 13) - 0.5) * cell * 1.3,
				yaw = hash(seed, 23) * math.pi * 2,
				tint = hash(seed, 31),
			})
		end
	end
	for index = 1, cellCount do
		local column = self._columns[index]
		self:_shapeCollider(column)
		column.collider.Parent = folder
		for f, seat in ipairs(column.seats) do
			local feather = acquireFeather(self)
			self:_seatFeather(column, feather, seat)
			feather.Parent = folder
			column.feathers[f] = feather
			self.stats.feathersPlaced += 1
		end
	end
end

-- Applies an authoritative delta: rebuild the field, dent the mound around the touched cells, drop
-- their colliders, thin shingles proportionally, and re-seat survivors on the lowered surface.
function PileVisualController.applyDelta(self: PileVisualController, payload: { [string]: any })
	if not self._folder or not self._grid then
		return
	end
	local motion = self._accessibility:motionSettings()
	local info = TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeOut)
	local budgets = self._quality:budgets()
	local perCell = budgets.strands / math.max(1, #self._columns)
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
	self._field = PileSurface.buildField(self._config, grid, self._layout)
	local field = self._field :: PileSurface.Field
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for index in pairs(touched) do
		local column = self._columns[index]
		local centre = self:_columnGeometry(column)
		minX = math.min(minX, centre.X - field.cellSize)
		maxX = math.max(maxX, centre.X + field.cellSize)
		minZ = math.min(minZ, centre.Z - field.cellSize)
		maxZ = math.max(maxZ, centre.Z + field.cellSize)
		self:_shapeCollider(column)
		local target = self:_targetFeatherCount(column, perCell)
		if column.remaining == 0 then
			target = 0
		end
		while #column.feathers > target do
			local feather = table.remove(column.feathers) :: BasePart
			releaseFeather(self, feather)
		end
		for f, feather in ipairs(column.feathers) do
			local seat = column.seats[f]
			if seat then
				local before = feather.CFrame
				self:_seatFeather(column, feather, seat)
				local goal = feather.CFrame
				feather.CFrame = before
				TweenService:Create(feather, info, { CFrame = goal }):Play()
			end
		end
	end
	if next(touched) then
		-- Interpolated heights reach one cell past the touched neighbourhood.
		self:_refreshDome(minX - field.cellSize, maxX + field.cellSize, minZ - field.cellSize, maxZ + field.cellSize)
	end
end

-- Feedback for an awarded hit: feathers tug up from the hit point, then stream toward `target`.
function PileVisualController.streamToBag(self: PileVisualController, hitPosition: Vector3, count: number, target: () -> Vector3)
	if not self._folder then
		return
	end
	local motion = self._accessibility:motionSettings()
	local budget = math.max(1, math.floor(self._quality:budgets().strands / 60))
	local n = math.min(count, budget, 6)
	local field = self._field
	local surfaceY = if field then field.baseY + PileSurface.heightAt(field, hitPosition.X, hitPosition.Z) else hitPosition.Y
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
	for _, column in pairs(self._columns) do
		for _, feather in ipairs(column.feathers) do
			releaseFeather(self, feather)
		end
	end
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
		dome.part:Destroy()
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

function PileVisualController.cellCount(self: PileVisualController): number
	local n = 0
	for _ in pairs(self._columns) do
		n += 1
	end
	return n
end

function PileVisualController.featherCount(self: PileVisualController): number
	local n = 0
	for _, column in pairs(self._columns) do
		n += #column.feathers
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
