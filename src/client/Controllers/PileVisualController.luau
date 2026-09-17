--!strict
-- Client visual layer for the logical pile (owner requirement; ASSUMED A-PILE-02/03). The server owns
-- the 16x16 cells, their individual feather records, the yields, the Egg, and the collision core (a
-- terrain mound it re-writes after every accepted pick). The client renders, per cell:
--   * the exposed feather records (the top `visibleSlotsPerCell` untaken slots) as individually
--     targetable parts placed by the shared FeatherLayout, seated on the live terrain surface so the
--     stack recedes as the cell is dug out and the next record is exposed where the last one was;
--   * a fluff bed of small non-targetable strands (the down between the feathers) that only leaves
--     when the cell's last record is gone, so picking one feather never disturbs its neighbours.
-- Targeting is a raycast from the camera through the reticle: the first feather part hit is the one
-- and only candidate, outlined with a Highlight. On an accepted pick exactly that part detaches and
-- flies to the carried stack. Nothing here is simulated physics; every part is anchored, non-colliding.
-- Quality tiers change only the fluff density and the cull distance.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Tokens = require(Shared.Design.Tokens)
local Signal = require(Shared.Util.Signal)
local Motion = require(Shared.Design.Motion)
local AssetManifest = require(Shared.Design.AssetManifest)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local PileSurface = require(Shared.Domain.PileSurface)
local FeatherLayout = require(Shared.Domain.FeatherLayout)

local PileVisualController = {}
PileVisualController.__index = PileVisualController

type Column = {
	index: number,
	x: number,
	z: number,
	base: number,
	remaining: number,
	mask: number,
	feathers: { [number]: BasePart }, -- slot -> part (exposed records only)
	fluff: { BasePart },
	fluffCount: number,
	step: number, -- studs the column recedes per record
	under: { { part: BasePart, depth: number } },
	slots: number,
	underlayerDone: boolean,
	built: boolean?,
}

export type Target = { featherId: number, part: BasePart, position: Vector3, cell: number, slot: number }

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
		_partPool: { BasePart },
		_layout: any,
		_grid: { [string]: any }?,
		_field: PileSurface.Field?,
		_seatField: PileSurface.Field?,
		targetChanged: any,
		_minCorner: Vector3?,
		_building: boolean,
		_pendingDeltas: { { [string]: any } },
		_generation: number,
		_highlight: Highlight?,
		_targetFade: number?,
		_flight: ((part: BasePart, from: Vector3, target: () -> Vector3, options: any) -> ())?,
		_ambient: BasePart?,
		_targetAccumulator: number,
		_cullAccumulator: number,
		_culled: boolean,
		_chevronGui: BillboardGui?,
		_streakPool: { BasePart },
		_rimBed: { BasePart },
		_bound: boolean,
		_lastPile: { [string]: any }?,
		_lastChapter: string?,
		_lifted: { [number]: { part: BasePart, seat: CFrame } },
		_recountPending: boolean?,
		_trove: Trove.Trove,
		target: Target?,
		stats: {
			dropped: number,
			dents: number,
			streamed: number,
			feathersPlaced: number,
			fluffPlaced: number,
			reseats: number,
			domeKind: string,
			coatKind: string,
		},
	},
	PileVisualController
))

local TEMPLATE_SIZE = Vector3.new(0.54, 1.44, 0.13) -- repo Feather mesh extents (quill along +Y)
local RENDER_NAME = "SFE_PileTargeting"
local FEATHER_ID_ATTRIBUTE = "SFE_FeatherId"
local RAINBOW_ATTRIBUTE = "SFE_Rainbow"
local CELL_ATTRIBUTE = "SFE_Cell"

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
		_partPool = {},
		_layout = ChapterLayout.chapter1,
		_grid = nil,
		_field = nil,
		_seatField = nil,
		targetChanged = Signal.new(),
		_minCorner = nil,
		_building = false,
		_pendingDeltas = {},
		_generation = 0,
		_highlight = nil,
		_targetFade = nil,
		_flight = nil,
		_ambient = nil,
		_targetAccumulator = 0,
		_cullAccumulator = 0,
		_culled = false,
		_chevronGui = nil,
		_streakPool = {},
		_rimBed = {},
		_bound = false,
		_lastPile = nil,
		_lastChapter = nil,
		_trove = Trove.new(),
		_rainbowParts = {},
		_rainbowSeed = 0,
		_rainbowLoop = nil,
		target = nil,
		stats = {
			dropped = 0,
			dents = 0,
			streamed = 0,
			feathersPlaced = 0,
			fluffPlaced = 0,
			reseats = 0,
			reveals = 0,
			lifts = 0,
			domeKind = "terrain",
			coatKind = "none",
		},
		_lifted = {},
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

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Colour for a record: `t` is its own hash tint, `depth` how many records sit above it. Most of
-- the colour comes from depth, so the coat reads light on top and dark in a dig.
local function depthTint(visual: { [string]: any }, t: number, depth: number): number
	local weight = visual.depthTintWeight or 0
	if weight <= 0 then
		return t
	end
	local span = math.max(1, visual.depthTintSlots or 14)
	local deep = math.clamp(depth / span, 0, 1)
	return math.clamp(t * (1 - weight) + deep * weight, 0, 0.999)
end

-- Cosmetic undulation of the coat. The logical dome is a perfect profile until it is dug, which
-- reads as a blob; rendered feathers ride this smooth deterministic wave so the mound has natural
-- rises and hollows. Aim, collision and every server number use the clean surface underneath.
local function seatLump(visual: { [string]: any }, wx: number, wz: number): number
	local amplitude = visual.seatLumpStuds or 0
	if amplitude <= 0 then
		return 0
	end
	local broad = math.sin(wx * 0.27 + wz * 0.17) * math.cos(wz * 0.31 - wx * 0.11)
	local fine = math.sin((wx + wz) * 0.52 + 1.3)
	return amplitude * (broad * 0.62 + fine * 0.38)
end

local function paletteColor(cfg: { [string]: any }, t: number): Color3
	local palette = cfg.pile.visual.palette
	local scaled = math.clamp(t, 0, 0.9999) * (#palette - 1)
	local index = math.floor(scaled) + 1
	local frac = scaled - (index - 1)
	local a, b = palette[index], palette[math.min(#palette, index + 1)]
	return Color3.fromRGB(a[1], a[2], a[3]):Lerp(Color3.fromRGB(b[1], b[2], b[3]), frac)
end

-- ---------------------------------------------------------------------------------------------
-- Part pool
-- ---------------------------------------------------------------------------------------------

local function acquirePart(self: PileVisualController): BasePart
	local part = table.remove(self._partPool)
	if part then
		return part
	end
	local template = AssetManifest.model("feather")
	if template and template:IsA("BasePart") then
		part = template:Clone() :: BasePart
	else
		local fallback = Instance.new("Part")
		fallback.Size = TEMPLATE_SIZE
		fallback.Material = Enum.Material.SmoothPlastic
		fallback:SetAttribute("SFE_Placeholder", "PHASE_6_VFX")
		part = fallback
	end
	part.Name = "Feather"
	-- SmoothPlastic keeps the coat bright and clean; the depth tint supplies the shading that a
	-- rough material would otherwise drain out of the whole mound.
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = true
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 0
	if part:IsA("MeshPart") then
		-- A single-sided vane vanishes when seen from behind; the coat is viewed from every angle.
		(part :: any).DoubleSided = true
	end
	return part :: BasePart
end

local function releasePart(self: PileVisualController, part: BasePart)
	part.Parent = nil
	part.Transparency = 0
	part.CanQuery = true
	part:SetAttribute(FEATHER_ID_ATTRIBUTE, nil)
	part:SetAttribute(CELL_ATTRIBUTE, nil)
	-- A Rainbow Feather is dressed in place (Neon plus a mote emitter). Without stripping that here
	-- the part carries the dressing back into the pool and returns as a glowing ordinary feather,
	-- so glowing strands accumulate across the coat over a round.
	if part:GetAttribute(RAINBOW_ATTRIBUTE) then
		part:SetAttribute(RAINBOW_ATTRIBUTE, nil)
		part.Material = Enum.Material.SmoothPlastic
		local motes = part:FindFirstChild("RainbowMotes")
		if motes then
			motes:Destroy()
		end
		self._rainbowParts[part] = nil
	end
	table.insert(self._partPool, part)
end

-- ---------------------------------------------------------------------------------------------
-- Surface sampling: the replicated terrain core first, the shared field as fallback.
-- ---------------------------------------------------------------------------------------------

-- Seat height: the mound as built. Seats never follow the live terrain or later deltas, so a pick
-- leaves every other feather exactly where it was; a cell's own stack recedes by `layerStepStuds`
-- per record taken (applied by the caller), never its neighbours.
function PileVisualController._surfaceAt(self: PileVisualController, wx: number, wz: number): (number, Vector3)
	local field = (self._seatField or self._field) :: PileSurface.Field
	return field.baseY + PileSurface.heightAt(field, wx, wz), PileSurface.normalAt(field, wx, wz)
end

-- Downslope direction (unit XZ) at a point: feathers lie along it so the coat reads as shingled layers.
function PileVisualController._downslope(self: PileVisualController, wx: number, wz: number): number
	local field = (self._seatField or self._field) :: PileSurface.Field
	local gx, gz = PileSurface.gradientAt(field, wx, wz)
	if gx * gx + gz * gz < 1e-6 then
		return 0
	end
	return math.atan2(-gz, -gx)
end

-- Places a feather-shaped part with its base at (wx, y, wz), lying along the surface (normal) with the
-- given yaw/tilt/roll, quill length `length` and vane width `width`.
local function placeFeather(
	part: BasePart,
	wx: number,
	y: number,
	wz: number,
	normal: Vector3,
	yaw: number,
	tilt: number,
	roll: number,
	length: number,
	width: number,
	thickness: number
)
	-- Thickness is the whole reason the inside of the mound can be seen. Records stack up a column at
	-- `step` (half a stud at the crown); a slab 0.09 thick left 0.4 studs of air above each one, so
	-- from the side a column was four parts air to one part feather and a dug cavity looked straight
	-- through its own walls. At or above the step, consecutive records touch and a column is a solid
	-- post from any angle - packed with records, never with filler.
	part.Size = Vector3.new(width, length, thickness)
	local yawDirection = Vector3.new(math.cos(yaw), 0, math.sin(yaw))
	local tangent = yawDirection - normal * yawDirection:Dot(normal)
	if tangent.Magnitude < 0.01 then
		tangent = Vector3.new(1, 0, 0)
	end
	tangent = tangent.Unit
	local binormal = normal:Cross(tangent)
	local frame = CFrame.fromMatrix(Vector3.new(wx, y, wz), tangent, normal, -binormal)
	-- Quill (+Y of the mesh) lies along the tangent, lifted by the tilt, rolled about itself; the
	-- mesh centre sits half a length along the quill so the base is at the pivot.
	part.CFrame = frame
		* CFrame.Angles(tilt, 0, 0)
		* CFrame.Angles(0, 0, roll)
		* CFrame.Angles(-math.pi / 2, 0, 0)
		* CFrame.new(0, length * 0.5, 0)
end

-- Records rendered (and targetable) per cell on this device. The server accepts any of the top
-- `visibleSlotsPerCell`; a low tier renders fewer, so it can only ever ask for what it shows.
function PileVisualController._visibleSlots(self: PileVisualController): number
	local visual = self._config.pile.visual
	return if self._quality:tier() == "low" then visual.visibleSlotsPerCellMobile else visual.visibleSlotsPerCell
end

-- Ceiling for the adaptive window on this device. A low tier's ceiling is below the desktop one, so
-- what it renders is always a subset of what the server accepts.
function PileVisualController._maxSlots(self: PileVisualController): number
	local visual = self._config.pile.visual
	return if self._quality:tier() == "low" then visual.maxVisibleSlotsPerCellMobile else visual.maxVisibleSlotsPerCell
end

-- Records rendered for one column: the device floor, deepened where the dome drops faster than the
-- coat is thick so the body never shows as a bare band between two rings. The server derives the
-- same number from the same config, so every rendered record is accepted.
function PileVisualController._slotsFor(self: PileVisualController, column: Column): number
	return if column.slots > 0 then column.slots else self:_visibleSlots()
end

function PileVisualController._fluffPerCell(self: PileVisualController, coatParts: number?): number
	local visual = self._config.pile.visual
	local tier = self._quality:tier()
	local perCell = if tier == "low"
		then visual.fluffPerCellMobile
		elseif tier == "medium" then math.floor((visual.fluffPerCellMobile + visual.fluffPerCellDesktop) / 2)
		else visual.fluffPerCellDesktop
	-- Respect the part budget: exposed feathers first, fluff with what is left.
	local budget = if tier == "low"
		then visual.partBudgetMobile
		elseif tier == "medium" then math.floor((visual.partBudgetMobile + visual.partBudgetDesktop) / 2)
		else visual.partBudgetDesktop
	local cells = 0
	for _ in pairs(self._columns) do
		cells += 1
	end
	local exposed = coatParts or (cells * self:_visibleSlots())
	local fluffBudget = math.max(0, budget - exposed)
	return math.min(perCell, math.floor(fluffBudget / math.max(1, cells)))
end

function PileVisualController._cullDistance(self: PileVisualController): number
	local visual = self._config.pile.visual
	return if self._quality:tier() == "low" then visual.cullDistanceMobileStuds else visual.cullDistanceDesktopStuds
end

-- Rim rule: nothing is placed past the mound's foot, and strands shrink toward the edge so there is
-- no floor overspill. Returns the length scale (0 = skip).
function PileVisualController._rimScale(self: PileVisualController, wx: number, wz: number): number
	local field = (self._seatField or self._field) :: PileSurface.Field
	local visual = self._config.pile.visual
	local dx, dz = wx - field.centreX, wz - field.centreZ
	local r = math.sqrt(dx * dx + dz * dz)
	local foot = field.radius * PileSurface.RIM_STRETCH - visual.rimInsetStuds
	if r >= foot then
		return 0
	end
	return math.clamp((foot - r) / visual.rimTaperStuds, visual.rimMinScale, 1)
end

-- (Re)materialises one column: exposed records as targetable feathers (the stack recedes by one
-- layer per record taken), fluff underneath (permanent, sinks with the cell). Touches nothing else.
function PileVisualController._applyColumn(self: PileVisualController, column: Column, folder: Folder)
	local visual = self._config.pile.visual
	local field = (self._seatField or self._field) :: PileSurface.Field
	local minCorner = self._minCorner :: Vector3
	local exposed = if self._culled then {} else FeatherLayout.exposedSlots(column.base, column.mask, self:_slotsFor(column))
	local wanted: { [number]: boolean } = {}
	for _, slot in ipairs(exposed) do
		wanted[slot] = true
	end
	for slot, part in pairs(column.feathers) do
		if not wanted[slot] then
			releasePart(self, part)
			column.feathers[slot] = nil
		end
	end
	-- Bed filler sits at a fixed depth under the original surface. Once the cell is dug past it the
	-- filler would hang in mid air inside the hole, so it goes with the records above it.
	local dug = (column.base - column.remaining) * column.step
	for index = #column.under, 1, -1 do
		local entry = column.under[index]
		if entry.depth <= dug then
			releasePart(self, entry.part)
			table.remove(column.under, index)
		end
	end
	for _, slot in ipairs(exposed) do
		local placement = FeatherLayout.placement(visual, column.index, slot, field.cellSize)
		local wx, wz = FeatherLayout.worldXZ(minCorner, field.cellSize, column.x, column.z, placement)
		local scale = self:_rimScale(wx, wz)
		if scale <= 0 then
			continue
		end
		local y, normal = self:_surfaceAt(wx, wz)
		-- Seat by slot, never by rank: a record's place is fixed for the round whatever gets taken
		-- above or beside it (the server resolves the same point for its aim check).
		-- The undulation fades out where the coat is thin: at the foot the surface is a fraction of a
		-- stud tall, so a dip of the full amplitude buried whole feathers under the sand and opened
		-- bare patches. Nothing may seat below the nest floor either.
		local height = y - field.baseY
		local lumpFade = math.clamp(height / math.max(0.01, visual.seatLumpFadeStuds or 3), 0, 1)
		local seatY = y + FeatherLayout.seatOffset(visual, column.base, slot, column.step) + seatLump(visual, wx, wz) * scale * lumpFade
		local floorY = math.max(field.baseY, (self._layout and self._layout.groundY) or field.baseY)
		seatY = math.max(seatY, floorY + 0.06)
		-- Rim factor: 0 well inside the coat, 1 at the outermost strands, used to curl the edge under
		-- instead of letting it radiate outward as blades.
		local rimMin = visual.rimMinScale
		local rimFactor = if rimMin < 1 then math.clamp((1 - scale) / (1 - rimMin), 0, 1) else 0
		-- Curl the rim down towards lying flat, never past it: a negative tilt drives the feather
		-- into the surface and leaves nothing but its base above the sand.
		local tilt = math.max(placement.tilt - rimFactor * math.rad(visual.rimCurlDegrees or 0), 0)
		local part = column.feathers[slot]
		if not part then
			part = acquirePart(self)
			part.Name = "Feather"
			part.CanQuery = true
			part.Color = paletteColor(self._config, depthTint(visual, placement.tint, column.base - slot))
			part:SetAttribute(FEATHER_ID_ATTRIBUTE, FeatherLayout.featherId(column.index, slot))
			column.feathers[slot] = part
			if FeatherLayout.isRainbow(self._config, self._rainbowSeed or 0, column.index, slot) then
				self:_dressRainbow(part, column.index, slot)
			end
			local yaw = self:_downslope(wx, wz) + (placement.yaw / (math.pi * 2) - 0.5) * math.rad(visual.downslopeYawJitterDegrees) * 2
			-- The bottom record rests on the sand. Records seat top-down at `step`, which left the
			-- lowest slab hovering 0.57 studs above the floor at the crown - a strip of air under every
			-- wall column, and the one sight line that ever left a cavity through its wall went out
			-- exactly there. The bottom slab's underside is pinned to the floor; a pure function of the
			-- slot, so it never moves, and nothing above it changes.
			local thickness = visual.featherThicknessStuds
			if slot == 1 then
				thickness = math.max(thickness, (seatY - floorY) * 2)
			end
			placeFeather(
				part,
				wx,
				seatY,
				wz,
				normal,
				yaw,
				tilt,
				placement.roll,
				placement.length * scale,
				placement.width * scale,
				thickness
			)
			if column.built and not self._culled then
				-- Newly exposed record: it was always there beneath; fade it in rather than pop.
				local seconds = Motion.clampSeconds(visual.revealFadeSeconds or 0.32, self._accessibility:motionSettings())
				part.Transparency = 1
				TweenService:Create(part, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = 0 })
					:Play()
				self.stats.reveals += 1
			end
			part.Parent = folder
			self.stats.reseats += 1
		end
	end
	column.built = true
	local fluffWanted = if self._culled
			or self:_rimScale(minCorner.X + (column.x + 0.5) * field.cellSize, minCorner.Z + (column.z + 0.5) * field.cellSize) <= 0
		then 0
		else column.fluffCount
	while #column.fluff > fluffWanted do
		releasePart(self, table.remove(column.fluff) :: BasePart)
	end
	local spread = field.cellSize * 0.98
	for k = 1, fluffWanted do
		local part = column.fluff[k]
		local h = function(salt: number)
			return FeatherLayout.hash(column.index, k, salt)
		end
		local wx = minCorner.X + (column.x + 0.5) * field.cellSize + (h(1) - 0.5) * spread
		local wz = minCorner.Z + (column.z + 0.5) * field.cellSize + (h(2) - 0.5) * spread
		local scale = self:_rimScale(wx, wz)
		if scale <= 0 then
			if part then
				releasePart(self, part)
				column.fluff[k] = nil
			end
			continue
		end
		-- Depth band: most strands lie on the surface, the rest tucked just under it (packed layers).
		local bandDepth = 0
		local pick = h(10)
		local acc = 0
		for band, share in ipairs(visual.fluffBandShares) do
			acc += share
			if pick <= acc then
				bandDepth = visual.fluffBandDepths[band]
				break
			end
		end
		if bandDepth >= column.base * column.step then
			-- Deeper than this (short, rim-side) column reaches: nothing to fill under it.
			if part then
				releasePart(self, part)
				column.fluff[k] = nil
			end
			continue
		end
		if not part then
			-- Placed once, anchored for the round: the bed never moves, whatever gets picked.
			part = acquirePart(self)
			part.Name = "Fluff"
			part.CanQuery = false -- cosmetic filler: the pick ray only ever meets records
			part:SetAttribute(CELL_ATTRIBUTE, column.index)
			part.Color = paletteColor(self._config, math.min(1, h(9) * 0.6 + visual.fluffTintShift))
			column.fluff[k] = part
			local y, normal = self:_surfaceAt(wx, wz)
			local yaw = self:_downslope(wx, wz) + (h(4) - 0.5) * math.rad(visual.downslopeYawJitterDegrees) * 2
			placeFeather(
				part,
				wx,
				y + lerp(0.1, 0.4, h(3)) - bandDepth,
				wz,
				normal,
				yaw,
				math.rad(lerp(visual.fluffTiltRangeDegrees[1], visual.fluffTiltRangeDegrees[2], h(5))),
				(h(6) - 0.5) * math.rad(visual.rollRangeDegrees),
				lerp(visual.fluffLengthRange[1], visual.fluffLengthRange[2], h(7)) * scale,
				lerp(visual.fluffWidthRange[1], visual.fluffWidthRange[2], h(8)) * scale,
				visual.featherThicknessStuds
			)
			part.Parent = folder
		end
	end
	self:_applyUnderlayer(column, folder)
end

-- Underlayer: two flat, gridded sheets of smaller feathers under the bed, each offset by half a
-- step from the sheet above, so any crack between top strands looks onto a feather face, never
-- ground or sky. Placed once with the bed; never moved.
function PileVisualController._applyUnderlayer(self: PileVisualController, column: Column, folder: Folder)
	if column.underlayerDone then
		return
	end
	column.underlayerDone = true
	local visual = self._config.pile.visual
	local field = self._seatField :: PileSurface.Field
	local minCorner = self._minCorner :: Vector3
	local grid = if self._quality:tier() == "low" then visual.underlayerGridMobile else visual.underlayerGridDesktop
	local cell = field.cellSize
	local originX = minCorner.X + column.x * cell
	local originZ = minCorner.Z + column.z * cell
	for sheet = 1, 2 do
		local n = grid[sheet]
		local span = column.base * column.step
		local depth = math.min(visual.underlayerDepths[sheet], span * 0.55)
		if n <= 0 or depth <= 0.02 then
			continue
		end
		local shift = if sheet == 2 then 0.5 else 0
		for i = 0, n - 1 do
			for j = 0, n - 1 do
				local k = sheet * 1000 + i * 100 + j
				local h = function(salt: number)
					return FeatherLayout.hash(column.index, k, salt)
				end
				local wx = originX + ((i + 0.5 + shift) / n) * cell + (h(1) - 0.5) * 0.25
				local wz = originZ + ((j + 0.5 + shift) / n) * cell + (h(2) - 0.5) * 0.25
				local scale = self:_rimScale(wx, wz)
				if scale <= 0 then
					continue
				end
				local part = acquirePart(self)
				part.Name = "Fluff"
				part.CanQuery = false -- cosmetic filler: the pick ray only ever meets records
				part:SetAttribute(CELL_ATTRIBUTE, column.index)
				part.Color = paletteColor(self._config, math.min(1, h(9) * 0.5 + visual.fluffTintShift))
				local y, normal = self:_surfaceAt(wx, wz)
				placeFeather(
					part,
					wx,
					y - depth + (h(3) - 0.5) * 0.15,
					wz,
					normal,
					self:_downslope(wx, wz) + (h(4) - 0.5) * math.rad(visual.downslopeYawJitterDegrees) * 2,
					math.rad(lerp(visual.underlayerTiltRangeDegrees[1], visual.underlayerTiltRangeDegrees[2], h(5))),
					(h(6) - 0.5) * math.rad(40),
					lerp(visual.underlayerLengthRange[1], visual.underlayerLengthRange[2], h(7)) * scale,
					lerp(visual.underlayerWidthRange[1], visual.underlayerWidthRange[2], h(8)) * scale,
					visual.featherThicknessStuds
				)
				part.Parent = folder
				table.insert(column.under, { part = part, depth = depth })
			end
		end
	end
end

-- The column's interior is packed layers too: as records leave and the top recedes, the layer at
-- the new depth is materialised (fixed, hashed positions; added once, never moved or removed), so

-- Current top of a column (studs above the base): the built surface minus its recession.
function PileVisualController._columnTop(self: PileVisualController, column: Column): number
	local field = self._seatField :: PileSurface.Field
	local minCorner = self._minCorner :: Vector3
	local cx = minCorner.X + (column.x + 0.5) * field.cellSize
	local cz = minCorner.Z + (column.z + 0.5) * field.cellSize
	return PileSurface.heightAt(field, cx, cz) - (column.base - column.remaining) * column.step
end

-- Wall strands a column no longer needs.
--
-- Strands line a column's exposed face and were added once and never taken back. When that column is
-- itself dug, every strand above its new top is left standing in open air - wrong to look at, and an
-- unbounded part leak as an excavation spreads: eight craters took the coat from 22k parts to 42k,
-- most of it faces that had since been dug away. Anything above the column's own surface goes back to

-- The interior is feathers too: when a dug column drops below a neighbour, that neighbour's newly
-- exposed side gets strands down to the new depth (added once, never moved or removed), so a pit's

-- ---------------------------------------------------------------------------------------------
-- Build / delta
-- ---------------------------------------------------------------------------------------------

function PileVisualController.build(self: PileVisualController, pile: { [string]: any }, chapter: string?)
	self:clear()
	self._lastPile = {
		width = pile.width,
		depth = pile.depth,
		cellSize = pile.cellSize,
		remaining = table.clone(pile.remaining),
		base = table.clone(pile.base),
		masks = table.clone(pile.masks or {}),
	}
	self._lastChapter = chapter
	self._rainbowSeed = pile.rainbowSeed or 0
	self._generation += 1
	local generation = self._generation
	local folder = Instance.new("Folder")
	folder.Name = "SFE_PileVisual"
	-- Built detached. The coat is placed over a few dozen frames, and a player looking at the mound
	-- while that happens sees it grow row by row. Under a parent of nil nothing renders until the
	-- last column is in, and the folder joins the workspace in one frame (the intro holds its fade
	-- until `isBuilt`, so even that single pop lands behind black).
	folder.Parent = nil
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
	self:_buildAmbient(folder)
	-- Seat positions come from the mound as first built (the round's snapshot), so later deltas
	-- never move untouched feathers.
	self._seatField = if pile.seatField
		then pile.seatField
		else PileSurface.buildField(self._config, {
			width = pile.width,
			depth = pile.depth,
			cellSize = pile.cellSize,
			remaining = table.clone(pile.base),
			base = table.clone(pile.base),
		}, self._layout)
	self._minCorner = ChapterLayout.gridMinCorner(self._layout, pile.width, pile.depth, pile.cellSize)
	local masks = pile.masks or {}
	for index = 1, pile.width * pile.depth do
		self._columns[index] = {
			index = index,
			x = (index - 1) % pile.width,
			z = math.floor((index - 1) / pile.width),
			base = pile.base[index],
			remaining = pile.remaining[index],
			mask = masks[index] or 0,
			feathers = {},
			fluff = {},
			fluffCount = 0,
			step = 0,
			under = {},
			slots = 0,
			underlayerDone = false,
			built = false,
		}
	end
	self:_buildRimBed(folder)
	-- Seat spacing and the render window first: the fluff budget is what the records leave over, and
	-- steep columns render more records than flat ones.
	local minSlots, maxSlots = self:_visibleSlots(), self:_maxSlots()
	local coatParts = 0
	for _, column in pairs(self._columns) do
		local full = PileSurface.columnFullHeight(self._config, pile.width, pile.depth, pile.cellSize, column.x, column.z)
		column.step = math.max(full / math.max(1, column.base), self._config.pile.visual.minSeatStepStuds or 0)
		column.slots = self:_coatWindow(column, minSlots, maxSlots)
		coatParts += column.slots
	end
	local fluffPerCell = self:_fluffPerCell(coatParts)
	for _, column in pairs(self._columns) do
		-- Vary the bed a little per cell so no row reads as a grid.
		column.fluffCount = math.max(0, math.floor(fluffPerCell * lerp(0.75, 1.25, FeatherLayout.hash(column.index, 0, 17)) + 0.5))
	end
	self.stats.reseats = 0
	self.stats.coatKind = "feathers"
	self.stats.domeKind = "terrain"

	-- Place over a few frames so a build never stalls one frame.
	self._building = true
	task.spawn(function()
		local placedThisFrame = 0
		for _, column in pairs(self._columns) do
			if self._generation ~= generation or self._folder ~= folder then
				return
			end
			self:_applyColumn(column, folder)
			placedThisFrame += column.fluffCount + 2
			if placedThisFrame >= 160 then
				placedThisFrame = 0
				task.wait()
			end
		end
		if self._generation ~= generation or self._folder ~= folder then
			return
		end
		local template = AssetManifest.model("feather")
		self.stats.coatKind = if template and template:IsA("MeshPart") then "feathers" else "feathers-parts"
		self:_recount()
		-- The whole coat appears in this one frame.
		folder.Parent = workspace
		self._building = false
		self:_bindTargeting()
		local pending = self._pendingDeltas
		self._pendingDeltas = {}
		for _, payload in ipairs(pending) do
			self:applyDelta(payload)
		end
	end)
end

-- The terrain mound's foot reaches past the logical square (rim stretch); those four skirt caps get
-- their own permanent bed so no core shows at the base from any side.
function PileVisualController._buildRimBed(self: PileVisualController, folder: Folder)
	local visual = self._config.pile.visual
	local field = self._seatField :: PileSurface.Field
	local low = self._quality:tier() == "low"
	local count = if low then visual.rimStrandsMobile else visual.rimStrandsDesktop
	-- Front skirt (owner request): fixed, overlapping strands over the front rim on the spawn side
	-- (+Z), two layers deep, so the mound's foot never shows a gap from the approach. They are not
	-- records and are never picked (CanQuery false); the records above them are untouched.
	local skirtCount = if low then (visual.frontSkirtStrandsMobile or 0) else (visual.frontSkirtStrandsDesktop or 0)
	local skirtArc = math.rad(visual.frontSkirtArcDegrees or 140)
	local skirtDepth = visual.frontSkirtDepthStuds or 4.5
	local half = field.width * field.cellSize / 2
	local foot = field.radius * PileSurface.RIM_STRETCH - visual.rimInsetStuds
	local placed = 0
	local attempt = 0
	local total = count + skirtCount
	while placed < total and attempt < total * 8 do
		attempt += 1
		local h = function(salt: number)
			return FeatherLayout.hash(attempt, 3, salt)
		end
		local skirt = placed >= count
		local angle, r
		if skirt then
			-- Front arc centred on +Z, packed inward from the mound's real foot. Past the grid there
			-- is no surface to sit on, so anything seeded out there lands on bare sand as litter.
			angle = math.pi / 2 + (h(1) - 0.5) * skirtArc
			r = math.min(foot, field.radius * 1.08) - h(2) * skirtDepth
		else
			angle = h(1) * math.pi * 2
			r = foot - h(2) * h(2) * 3.2
		end
		local dx, dz = math.cos(angle) * r, math.sin(angle) * r
		if not skirt and math.abs(dx) <= half - 0.3 and math.abs(dz) <= half - 0.3 then
			continue -- inside the grid: the cells' own bed covers it
		end
		local wx, wz = field.centreX + dx, field.centreZ + dz
		local scale = self:_rimScale(wx, wz)
		if scale <= 0 then
			continue
		end
		local part = acquirePart(self)
		part.Name = "Fluff"
		part.CanQuery = false
		part.Color = paletteColor(self._config, math.min(1, h(9) * 0.6 + visual.fluffTintShift))
		local y, normal = self:_surfaceAt(wx, wz)
		placeFeather(
			part,
			wx,
			y + (if skirt then lerp(0.05, 0.55, h(3)) else lerp(0.1, 0.3, h(3))),
			wz,
			normal,
			self:_downslope(wx, wz) + (h(4) - 0.5) * math.rad(visual.downslopeYawJitterDegrees) * 2,
			math.rad(lerp(visual.fluffTiltRangeDegrees[1], visual.fluffTiltRangeDegrees[2], h(5))),
			(h(6) - 0.5) * math.rad(visual.rollRangeDegrees),
			lerp(visual.fluffLengthRange[1], visual.fluffLengthRange[2], h(7)) * math.max(scale, 0.6),
			lerp(visual.fluffWidthRange[1], visual.fluffWidthRange[2], h(8)) * math.max(scale, 0.6),
			visual.featherThicknessStuds
		)
		part.Parent = folder
		table.insert(self._rimBed, part)
		placed += 1
	end
end

-- Counts are refreshed once per frame at most: a 27-record sweep marks the pass dirty 27 times.
function PileVisualController._requestRecount(self: PileVisualController)
	if self._recountPending then
		return
	end
	self._recountPending = true
	task.defer(function()
		self._recountPending = false
		self:_recount()
	end)
end

function PileVisualController._recount(self: PileVisualController)
	local feathers, fluff = 0, 0
	for _, column in pairs(self._columns) do
		for _ in pairs(column.feathers) do
			feathers += 1
		end
		fluff += #column.fluff
	end
	self.stats.feathersPlaced = feathers
	self.stats.fluffPlaced = fluff + #self._rimBed
end

-- How many records a column draws: the deeper of the dome window and the dug window.
--
-- The dug window is why a neighbour has to be re-evaluated when a column is dug. A column that loses
-- records leaves the one beside it standing over a hole, and that one now has to draw far enough down
-- to cover the wall it just became - otherwise the packed body shows through the side of the pit as a
-- flat pale block, which is exactly what a vacuum used to carve out.
function PileVisualController._coatWindow(self: PileVisualController, column: any, minSlots: number, maxSlots: number): number
	local pile = self._grid :: { [string]: any }
	local heights = if self._field then PileSurface.fieldHeights(self._field) else nil
	local dome =
		PileSurface.coatSlots(self._config, pile.width, pile.depth, pile.cellSize, column.x, column.z, column.base, minSlots, maxSlots)
	if not heights then
		return dome
	end
	return math.max(
		dome,
		PileSurface.coatSlotsAt(
			self._config,
			pile.width,
			pile.depth,
			pile.cellSize,
			heights,
			column.x,
			column.z,
			column.base,
			minSlots,
			maxSlots
		)
	)
end

-- Applies an authoritative delta ({ i, r, m } per cell): only the touched cells change (a taken
-- record leaves, the next one appears, that cell's fluff settles one layer). Neighbours never move.
function PileVisualController.applyDelta(self: PileVisualController, payload: { [string]: any })
	if not self._folder or not self._grid then
		return
	end
	if self._building then
		table.insert(self._pendingDeltas, payload)
		return
	end
	local grid = self._grid :: { [string]: any }
	local touched: { [number]: boolean } = {}
	for _, change in ipairs(payload.cells) do
		local column = self._columns[change.i]
		if not column then
			continue
		end
		if change.r ~= column.remaining or (change.m ~= nil and change.m ~= column.mask) then
			self.stats.dents += 1
			column.remaining = change.r
			if change.m ~= nil then
				column.mask = change.m
			end
			grid.remaining[change.i] = change.r
			touched[change.i] = true
		end
	end
	if next(touched) == nil then
		return
	end
	-- The field carries the heights the coat window is measured against, so it has to be current
	-- before any column is re-seated.
	self._field = PileSurface.buildField(self._config, grid, self._layout)
	-- A dug column changes how deep its four neighbours have to draw, so they are re-seated with it.
	local pile = self._grid :: { [string]: any }
	local minSlots, maxSlots = self:_visibleSlots(), self:_maxSlots()
	local dirty: { [number]: boolean } = {}
	for index in pairs(touched) do
		dirty[index] = true
		local column = self._columns[index]
		if column then
			-- Everything the window can now depend on: the 5x5 around a dug column, matching coatSlotsAt.
			for dz = -2, 2 do
				for dx = -2, 2 do
					local nx, nz = column.x + dx, column.z + dz
					if nx >= 0 and nz >= 0 and nx < pile.width and nz < pile.depth then
						dirty[nz * pile.width + nx + 1] = true
					end
				end
			end
		end
	end
	local folder = self._folder :: Folder
	for index in pairs(dirty) do
		local column = self._columns[index]
		if column then
			local slots = self:_coatWindow(column, minSlots, maxSlots)
			-- A neighbour that has not changed depth needs no work; only the dug cells always re-seat.
			if slots ~= column.slots or touched[index] then
				column.slots = slots
				self:_applyColumn(column, folder)
			end
		end
	end
	self:_recount()
end

-- ---------------------------------------------------------------------------------------------
-- Targeting, culling, and dirty re-seats (one throttled render binding)
-- ---------------------------------------------------------------------------------------------

function PileVisualController._bindTargeting(self: PileVisualController)
	if self._bound then
		return
	end
	self._bound = true
	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 3, function(dt)
		self:_step(dt)
	end)
end

function PileVisualController._unbindTargeting(self: PileVisualController)
	if self._bound then
		self._bound = false
		RunService:UnbindFromRenderStep(RENDER_NAME)
	end
	if self._highlight then
		self._highlight.Adornee = nil
		self._highlight.Enabled = false
	end
	self.target = nil
end

function PileVisualController._step(self: PileVisualController, dt: number)
	local folder = self._folder
	local field = self._field
	if not folder or not field then
		return
	end
	local visual = self._config.pile.visual
	self._cullAccumulator += dt
	if self._cullAccumulator > 0.5 then
		self._cullAccumulator = 0
		local camera = workspace.CurrentCamera
		if camera then
			local distance = (camera.CFrame.Position - Vector3.new(field.centreX, field.baseY, field.centreZ)).Magnitude
			local culled = distance > self:_cullDistance()
			if culled ~= self._culled then
				self._culled = culled
				for _, column in pairs(self._columns) do
					self:_applyColumn(column, folder)
				end
				self:_recount()
			end
		end
	end
	self:_stepTarget()
	self._targetAccumulator += dt
	if self._targetAccumulator < 1 / visual.targetRateHz then
		return
	end
	self._targetAccumulator = 0
	self:resolveUnderCursor()
end

-- The pick ray: from the camera through the crosshair. In first person the mouse is locked to the
-- screen centre, where the crosshair is drawn, so the centre IS the cursor; only a free mouse
-- (camera not locked) aims through its own position. Touch and gamepad have no cursor over the
-- world and aim through the centre too.
function PileVisualController.aimRay(_self: PileVisualController): (Vector3?, Vector3?)
	local camera = workspace.CurrentCamera
	if not camera then
		return nil, nil
	end
	local point = camera.ViewportSize * 0.5
	local player = Players.LocalPlayer
	local firstPerson = (player ~= nil and player.CameraMode == Enum.CameraMode.LockFirstPerson)
		or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
	local lastInput = UserInputService:GetLastInputType()
	local mouse = lastInput == Enum.UserInputType.MouseButton1
		or lastInput == Enum.UserInputType.MouseMovement
		or lastInput == Enum.UserInputType.MouseButton2
		or lastInput == Enum.UserInputType.MouseWheel
	if mouse and not firstPerson then
		local okLocation, location = pcall(UserInputService.GetMouseLocation, UserInputService)
		if okLocation and typeof(location) == "Vector2" then
			point = location
		end
	end
	local ray = camera:ViewportPointToRay(point.X, point.Y)
	return ray.Origin, ray.Direction
end

-- Re-targets under the cursor right now (the click path calls this so the pick is what the player
-- sees at that instant, not the last periodic sample) and returns the target.
function PileVisualController.resolveUnderCursor(self: PileVisualController): Target?
	local origin, direction = self:aimRay()
	local target = if origin and direction then self:resolveTarget(origin, direction) else nil
	self:_setTarget(target)
	return target
end

-- The one feather under a ray: the FIRST part the ray meets must itself be a feather record (it
-- carries SFE_FeatherId); that exact record is the target. A bed strand, underlayer sheet, or the
-- ground met first means nothing is targeted - the pick is never redirected to a record behind or
-- beside what the player is actually looking at.
function PileVisualController.resolveTarget(self: PileVisualController, origin: Vector3, direction: Vector3): Target?
	local folder = self._folder
	if not folder or direction.Magnitude < 1e-6 then
		return nil
	end
	local range = self._config.interaction.defaultRangeStuds + 10
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder, workspace.Terrain }
	local result = workspace:Raycast(origin, direction.Unit * range, params)
	if not result or not result.Instance:IsA("BasePart") then
		return nil
	end
	local hitPart = result.Instance
	local featherId = hitPart:GetAttribute(FEATHER_ID_ATTRIBUTE)
	if type(featherId) ~= "number" then
		return nil
	end
	local cell, slot = FeatherLayout.decode(featherId)
	if not cell or not slot then
		return nil
	end
	return { featherId = featherId, part = hitPart, position = hitPart.Position, cell = cell, slot = slot }
end

function PileVisualController._setTarget(self: PileVisualController, target: Target?)
	local folder = self._folder
	if not folder then
		return
	end
	local visual = self._config.pile.visual
	local pickup = visual.pickup
	if not self._highlight then
		-- One Highlight for the whole coat. A thin warm rim over the real feather colour: the record
		-- keeps its material and tint, the rim says "this one", and there is no solid fill to turn the
		-- target into a marker sitting on the mound.
		local highlight = Instance.new("Highlight")
		highlight.Name = "SFE_PileTarget"
		local rgb = pickup.rimColor
		highlight.FillColor = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		highlight.FillTransparency = pickup.fillTransparency
		highlight.OutlineColor = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		highlight.OutlineTransparency = pickup.rimTransparency
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Enabled = false
		highlight.Parent = folder
		self._highlight = highlight
	end
	local highlight = self._highlight :: Highlight
	local had = self.target ~= nil
	if (target ~= nil) ~= had then
		self.targetChanged:Fire(target ~= nil)
	end
	if target then
		if highlight.Adornee ~= target.part then
			highlight.Adornee = target.part
		end
		self._targetFade = nil
		highlight.Enabled = true
	elseif had then
		-- Lost the target: the rim fades over targetFadeSeconds rather than blinking off.
		self._targetFade = os.clock()
	end
	self.target = target
end

-- Ambient life: one emitter over the mound letting a few down motes drift across it. One instance,
-- client-side, no record touched, and not on the low tier.
function PileVisualController._buildAmbient(self: PileVisualController, folder: Folder)
	local field = self._field
	if not field or (self._quality and self._quality:tier() == "low") then
		return
	end
	local anchor = Instance.new("Part")
	anchor.Name = "SFE_PileAmbient"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(field.cellSize * (self._grid :: any).width * 0.7, 4, field.cellSize * (self._grid :: any).depth * 0.7)
	anchor.Position = Vector3.new(field.centreX, field.baseY + 9, field.centreZ)
	local motes = Instance.new("ParticleEmitter")
	motes.Name = "Down"
	motes.Rate = 2.5
	motes.Lifetime = NumberRange.new(4, 7)
	motes.Speed = NumberRange.new(0.15, 0.4)
	motes.Acceleration = Vector3.new(0.3, -0.35, 0.2)
	motes.Drag = 0.6
	motes.Rotation = NumberRange.new(0, 360)
	motes.RotSpeed = NumberRange.new(-40, 40)
	motes.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.12), NumberSequenceKeypoint.new(1, 0.18) })
	motes.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, 0.35),
		NumberSequenceKeypoint.new(0.85, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	motes.Color = ColorSequence.new(Color3.fromRGB(255, 250, 238))
	motes.LightEmission = 0.15
	motes.Shape = Enum.ParticleEmitterShape.Box
	motes.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
	motes.Parent = anchor
	anchor.Parent = folder
	self._ambient = anchor
end

-- Per frame while targeting is bound: the rim breathes on the live target and fades off a lost one.
function PileVisualController._stepTarget(self: PileVisualController)
	local highlight = self._highlight
	if not highlight or not highlight.Enabled then
		return
	end
	local pickup = self._config.pile.visual.pickup
	local now = os.clock()
	if self.target then
		local breath = 0.5 + 0.5 * math.sin(now * pickup.targetBreathHz * math.pi * 2)
		highlight.OutlineTransparency = pickup.rimTransparency + pickup.targetBreathTransparency * breath
		highlight.FillTransparency = pickup.fillTransparency + (1 - pickup.fillTransparency) * 0.35 * breath
		return
	end
	local started = self._targetFade
	if not started then
		highlight.Enabled = false
		highlight.Adornee = nil
		return
	end
	local t = (now - started) / math.max(0.016, pickup.targetFadeSeconds)
	if t >= 1 then
		self._targetFade = nil
		highlight.Enabled = false
		highlight.Adornee = nil
		highlight.OutlineTransparency = pickup.rimTransparency
		highlight.FillTransparency = pickup.fillTransparency
	else
		highlight.OutlineTransparency = pickup.rimTransparency + (1 - pickup.rimTransparency) * t
		highlight.FillTransparency = pickup.fillTransparency + (1 - pickup.fillTransparency) * t
	end
end

-- ---------------------------------------------------------------------------------------------
-- Pick feedback: the exact feather detaches, flies to the carried stack, chevrons, layered audio
-- ---------------------------------------------------------------------------------------------

function PileVisualController._chevrons(self: PileVisualController, position: Vector3)
	local visual = self._config.pile.visual
	local motion = self._accessibility:motionSettings()
	local folder = self._folder
	if not folder then
		return
	end
	local gui = self._chevronGui
	if not gui then
		gui = Instance.new("BillboardGui")
		gui.Name = "SFE_Chevrons"
		gui.AlwaysOnTop = true
		gui.Size = UDim2.fromOffset(60, 90)
		gui.LightInfluence = 0
		gui.MaxDistance = 60
		for i = 1, visual.chevronCount do
			local label = Instance.new("TextLabel")
			label.Name = "Chevron" .. i
			label.BackgroundTransparency = 1
			label.Size = UDim2.fromOffset(60, 26)
			label.Font = Enum.Font.GothamBlack
			label.Text = "︿"
			label.TextScaled = true
			label.TextColor3 = Color3.new(1, 1, 1)
			label.TextStrokeTransparency = 0.5
			label.TextTransparency = 1
			label.Parent = gui
		end
		self._chevronGui = gui
	end
	local anchor = folder:FindFirstChild("SFE_ChevronAnchor") :: BasePart?
	if not anchor then
		anchor = Instance.new("Part")
		anchor.Name = "SFE_ChevronAnchor"
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(0.2, 0.2, 0.2)
		anchor.Parent = folder
	end
	anchor.Position = position + Vector3.new(0, 0.8, 0)
	gui.Parent = anchor
	local seconds = Motion.clampSeconds(visual.chevronSeconds, motion)
	for i = 1, visual.chevronCount do
		local label = gui:FindFirstChild("Chevron" .. i) :: TextLabel?
		if label then
			label.Position = UDim2.fromOffset(0, 70 - i * 8)
			label.TextTransparency = 0.1
			task.delay((i - 1) * 0.06, function()
				TweenService:Create(label, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Position = UDim2.fromOffset(0, 20 - i * 12),
					TextTransparency = 1,
				}):Play()
			end)
		end
	end
end

-- Server-confirmed pick of one record: that exact part lifts out (slightly enlarged), then arcs to
-- the held bundle and vanishes - about a quarter of a second so rapid picks stay crisp. The column
-- re-applies at once so the next record shows where this one was; nothing else moves.
-- Client-first response: the targeted record loosens (lifts a hair along its normal, swells) the
-- instant the pick is sent; the server's answer either finishes the pick or eases it back.
function PileVisualController.beginLift(self: PileVisualController, featherId: number)
	local cellIndex, slot = FeatherLayout.decode(featherId)
	local column = cellIndex and self._columns[cellIndex] or nil
	local part = column and slot and column.feathers[slot] or nil
	if not part or self._lifted[featherId] then
		return
	end
	local visual = self._config.pile.visual
	local seat = part.CFrame
	self._lifted[featherId] = { part = part, seat = seat }
	self.stats.lifts += 1
	local lift = Motion.amplitude(visual.liftPreviewStuds or 0.22, self._accessibility:motionSettings())
	TweenService:Create(part, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = seat * CFrame.new(0, 0, -lift) * CFrame.Angles(0, 0, 0.12),
	}):Play()
end

-- The server refused a claim because the record is no longer collectible - another player has it,
-- or it is buried. Whatever this client is drawing for that id is stale and leaves now: released to
-- the pool, the slot marked taken so nothing re-seats it, the column re-applied so the record under
-- it shows. Putting it back in its seat, which is what a cancelled lift does, is what left a ghost to
-- be aimed at again and again.
function PileVisualController.dropFeather(self: PileVisualController, featherId: number)
	local cellIndex, slot = FeatherLayout.decode(featherId)
	local column = cellIndex and self._columns[cellIndex] or nil
	if not column or not slot then
		return
	end
	self._lifted[featherId] = nil
	local part = column.feathers[slot]
	if part then
		column.feathers[slot] = nil
		releasePart(self, part)
	end
	column.mask = bit32.bor(column.mask, bit32.lshift(1, slot - 1))
	column.remaining = math.max(0, column.remaining - 1)
	if self._grid then
		(self._grid :: any).remaining[column.index] = column.remaining
	end
	if self._folder then
		self:_applyColumn(column, self._folder)
	end
	if self.target and self.target.featherId == featherId then
		self:_setTarget(nil)
	end
	self.stats.dropped += 1
end

function PileVisualController.cancelLift(self: PileVisualController, featherId: number)
	local entry = self._lifted[featherId]
	if not entry then
		return
	end
	self._lifted[featherId] = nil
	local cellIndex, slot = FeatherLayout.decode(featherId)
	local column = cellIndex and self._columns[cellIndex] or nil
	if column and slot and column.feathers[slot] == entry.part then
		TweenService:Create(entry.part, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = entry.seat })
			:Play()
	end
end

-- Server-confirmed pick of one record: that exact part leaves the coat now (no longer targetable,
-- its slot marked taken, the column re-applied so the record beneath shows where it was - nothing
-- else moves) and is handed back, free, to whoever animates the flight. `from` is where it was.
function PileVisualController.detachFeather(self: PileVisualController, featherId: number, hitPosition: Vector3): (BasePart?, Vector3)
	local folder = self._folder
	if not folder then
		return nil, hitPosition
	end
	local visual = self._config.pile.visual
	local cellIndex, slot = FeatherLayout.decode(featherId)
	local column = cellIndex and self._columns[cellIndex] or nil
	local part = column and slot and column.feathers[slot] or nil
	local from = hitPosition
	self._lifted[featherId] = nil
	if part then
		from = part.Position
		column.feathers[slot] = nil -- detached: no longer part of the coat, never re-targetable
		part:SetAttribute(FEATHER_ID_ATTRIBUTE, nil)
		part.CanQuery = false
		if self._rainbowParts[part] then
			-- A Rainbow Feather leaves with a shimmer burst and keeps its colour flow in flight.
			self._vfx:burst("sparkle", part.Position + Vector3.new(0, 0.6, 0), 1.0)
		end
	else
		part = acquirePart(self)
		part.CanQuery = false
		local placement = FeatherLayout.placement(visual, cellIndex or 1, slot or 1, (self._field :: PileSurface.Field).cellSize)
		part.Size = Vector3.new(placement.width, placement.length, visual.featherThicknessStuds)
		local column2 = cellIndex and self._columns[cellIndex]
		part.Color = paletteColor(self._config, depthTint(visual, placement.tint, if column2 and slot then column2.base - slot else 0))
		part.CFrame = CFrame.new(hitPosition)
		part.Parent = folder
	end
	-- Local prediction: mark the record taken and re-apply just this column (the delta is idempotent).
	if column and slot then
		column.mask = bit32.bor(column.mask, bit32.lshift(1, slot - 1))
		column.remaining = math.max(0, column.remaining - 1)
		if self._grid then
			(self._grid :: any).remaining[column.index] = column.remaining
		end
		self:_applyColumn(column, folder)
		self:_requestRecount()
	end
	if self.target and self.target.featherId == featherId then
		self:_setTarget(nil)
	end
	self.stats.streamed += 1
	return part, from
end

-- A flown part comes back to the pool once its flight is over.
function PileVisualController.returnFlown(self: PileVisualController, part: BasePart)
	if self._folder then
		releasePart(self, part)
	else
		part:Destroy()
	end
end

-- One flight animation for every source of a pick (the hand, the rake stream, another player's
-- vac): installed by the pickup feedback controller so there is exactly one way a feather flies.
function PileVisualController.setFlightDriver(
	self: PileVisualController,
	driver: ((part: BasePart, from: Vector3, target: () -> Vector3, options: any) -> ())?
)
	self._flight = driver
end

-- Detach + fly, for callers that only have a target point (tool streams). The pickup controller
-- drives the local hand path itself for its landing hooks.
function PileVisualController.collectFeather(
	self: PileVisualController,
	featherId: number,
	hitPosition: Vector3,
	target: () -> Vector3,
	options: { pullSeconds: number?, quiet: boolean? }?
)
	local opts = (options or {}) :: any
	local part, from = self:detachFeather(featherId, hitPosition)
	if not part then
		return
	end
	local driver = self._flight
	if driver then
		driver(part, from, target, { seconds = opts.pullSeconds, quiet = true })
	else
		self:_fallbackFlight(part, from, target, opts.pullSeconds)
	end
	if opts.quiet then
		return
	end
	self._audio:play(Tokens.sound.collectTug, { pitchVariance = 0.18 })
	self._vfx:burst("featherPuff", from, 0.15)
end

-- The pre-controller arc, kept for the brief moment before the driver is installed.
function PileVisualController._fallbackFlight(
	self: PileVisualController,
	part: BasePart,
	from: Vector3,
	target: () -> Vector3,
	seconds: number?
)
	local visual = self._config.pile.visual
	local motion = self._accessibility:motionSettings()
	local pullSeconds = Motion.clampSeconds(seconds or visual.pullSeconds, motion)
	local baseSize = part.Size
	local _ = from
	task.spawn(function()
		local origin = part.Position
		local elapsed = 0
		while elapsed < pullSeconds do
			local dt = RunService.Heartbeat:Wait()
			elapsed += dt
			local t = math.clamp(elapsed / pullSeconds, 0, 1)
			local e = t * t
			local destination = target()
			local control = origin:Lerp(destination, 0.5) + Vector3.new(0, 1.2, 0)
			local point = origin:Lerp(control, e):Lerp(control:Lerp(destination, e), e)
			part.CFrame = CFrame.lookAt(point, destination) * CFrame.Angles(math.rad(90), 0, t * 2)
			part.Size = baseSize * (1 - 0.6 * t)
			part.Transparency = if t > 0.8 then (t - 0.8) / 0.2 else 0
		end
		part.Size = baseSize
		self:returnFlown(part)
	end)
end

-- Reveal spiral: loose feathers lift in a spiral around the Egg.
function PileVisualController.revealSpiral(self: PileVisualController, eggPosition: Vector3, coverCells: { number })
	if not self._folder then
		return
	end
	local motion = self._accessibility:motionSettings()
	local scale = self._accessibility:motionScale()
	-- The Egg blows the loose feathers outward: a ring of them bursts away and up, tumbling.
	local count = math.min(#coverCells * 3 + 12, 36)
	for i = 1, count do
		local feather = acquirePart(self)
		feather.CanQuery = false
		feather.Size = Vector3.new(1.2, 3, 0.12)
		feather.Color = paletteColor(self._config, FeatherLayout.hash(i, 0, 91))
		feather.Parent = self._folder
		local angle = (i / count) * math.pi * 2
		local ring = if i % 2 == 0 then 1.4 else 2.2
		feather.CFrame = CFrame.new(eggPosition + Vector3.new(math.cos(angle) * ring, 0.2, math.sin(angle) * ring))
			* CFrame.Angles(math.rad(80), angle, 0)
		local info = TweenInfo.new(Motion.duration("slow", motion) * 3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
		local reach = (7 + (i % 3) * 1.5) * scale
		local goal = CFrame.new(
			eggPosition + Vector3.new(math.cos(angle + 0.6) * reach, (4 + (i % 4)) * scale + 1, math.sin(angle + 0.6) * reach)
		) * CFrame.Angles(angle * 3, angle * 2, angle)
		local tween = TweenService:Create(feather, info, { CFrame = goal, Transparency = 1 })
		tween:Play()
		tween.Completed:Once(function()
			releasePart(self, feather)
		end)
	end
	self._vfx:burst("sparkle", eggPosition + Vector3.new(0, 1, 0), 1.2)
end

-- Dresses a record as a Rainbow Feather: registered for the colour flow, a soft glow and a few
-- drifting motes. Cheap per part; the count is bounded by pile.rainbowChance.
function PileVisualController._dressRainbow(self: PileVisualController, part: BasePart, cellIndex: number, slot: number)
	part:SetAttribute(RAINBOW_ATTRIBUTE, true)
	-- Local emissive colour only: no light source and no halo sprite, so neighbouring feathers keep
	-- their own colour and brightness. The glow is the Neon surface plus a few motes.
	part.Material = Enum.Material.Neon
	local motes = Instance.new("ParticleEmitter")
	motes.Name = "RainbowMotes"
	motes.Rate = 3
	motes.Lifetime = NumberRange.new(0.8, 1.4)
	motes.Speed = NumberRange.new(0.3, 0.8)
	motes.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.12), NumberSequenceKeypoint.new(1, 0) })
	motes.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	motes.LightEmission = 0.8
	motes.Color = ColorSequence.new(Color3.fromRGB(255, 240, 255))
	motes.Parent = part
	self._rainbowParts[part] = FeatherLayout.hash(cellIndex, slot, 7) -- phase offset for the hue flow
	self:_ensureRainbowLoop()
end

-- One shared heartbeat drives the hue of every rainbow record (and any in flight): a smooth,
-- desaturated rainbow rather than raw neon.
function PileVisualController._ensureRainbowLoop(self: PileVisualController)
	if self._rainbowLoop then
		return
	end
	self._rainbowLoop = RunService.Heartbeat:Connect(function()
		local t = os.clock() * 0.35
		for part, phase in pairs(self._rainbowParts) do
			if part.Parent == nil then
				self._rainbowParts[part] = nil
			else
				local hue = (t + phase) % 1
				part.Color = Color3.fromHSV(hue, 0.55, 1)
				-- The record's own surface is the only thing that changes colour.
			end
		end
	end)
	self._trove:add(self._rainbowLoop)
end

function PileVisualController.rainbowCount(self: PileVisualController): number
	local count = 0
	for _ in pairs(self._rainbowParts) do
		count += 1
	end
	return count
end

-- True once a round's coat is fully placed and in the workspace (false while building or empty).
function PileVisualController.isBuilt(self: PileVisualController): boolean
	return self._folder ~= nil and self._folder.Parent == workspace and not self._building
end

function PileVisualController.clear(self: PileVisualController)
	self._generation += 1
	self._building = false
	self._pendingDeltas = {}
	self:_unbindTargeting()
	for _, column in pairs(self._columns) do
		for slot, part in pairs(column.feathers) do
			releasePart(self, part)
			column.feathers[slot] = nil
		end
		for _, part in ipairs(column.fluff) do
			releasePart(self, part)
		end
		table.clear(column.fluff)
		for _, entry in ipairs(column.under) do
			releasePart(self, entry.part)
		end
		table.clear(column.under)
	end
	table.clear(self._columns)
	for _, part in ipairs(self._rimBed) do
		releasePart(self, part)
	end
	table.clear(self._rimBed)
	self._grid = nil
	self._field = nil
	self._seatField = nil
	self._minCorner = nil
	self._culled = false
	self.stats.feathersPlaced = 0
	self.stats.fluffPlaced = 0
	if self._chevronGui then
		self._chevronGui.Parent = nil
	end
	if self._highlight then
		self._highlight:Destroy()
		self._highlight = nil
	end
	if self._folder then
		self._folder:Destroy()
		self._folder = nil
	end
end

-- Rebuilds the coat from the latest known cells (after a quality-tier change).
function PileVisualController.rebuild(self: PileVisualController)
	local pile = self._lastPile
	if not pile then
		return
	end
	for index, column in pairs(self._columns) do
		pile.remaining[index] = column.remaining
		pile.masks[index] = column.mask
	end
	self:build(pile, self._lastChapter)
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
	if not field then
		return 0
	end
	local y = self:_surfaceAt(worldX, worldZ)
	return y - field.baseY
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

-- Visible targetable feather parts in the coat.
function PileVisualController.featherCount(self: PileVisualController): number
	self:_recount()
	return self.stats.feathersPlaced
end

function PileVisualController.fluffCount(self: PileVisualController): number
	self:_recount()
	return self.stats.fluffPlaced
end

function PileVisualController.instanceCount(self: PileVisualController): number
	return if self._folder then #self._folder:GetDescendants() else 0
end

function PileVisualController.pooledCount(self: PileVisualController): number
	return #self._partPool
end

function PileVisualController.destroy(self: PileVisualController)
	self:clear()
	for _, part in ipairs(self._partPool) do
		part:Destroy()
	end
	table.clear(self._partPool)
	if self._chevronGui then
		self._chevronGui:Destroy()
	end
	self._trove:destroy()
end

return PileVisualController
