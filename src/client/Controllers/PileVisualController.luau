--!strict
-- Client visual layer for the logical pile: one anchored mound part per cell whose height follows
-- the authoritative remaining count (coherent dents), a pooled strand layer scattered on the
-- surface (density-scaled per quality tier), and streaming strands that tug, release, and fly to
-- the bag on each awarded hit. All instances live under one folder and are destroyed on return.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local ChapterLayout = require(Shared.Domain.ChapterLayout)

local PileVisualController = {}
PileVisualController.__index = PileVisualController

type CellVisual = { part: Part, base: number, remaining: number, x: number, z: number, strands: { Part } }

export type PileVisualController = typeof(setmetatable(
	{} :: {
		_round: any,
		_quality: any,
		_accessibility: any,
		_vfx: any,
		_audio: any,
		_config: { [string]: any },
		_folder: Folder?,
		_cells: { CellVisual },
		_pool: { Part },
		_streaming: number,
		_layout: any,
		_trove: Trove.Trove,
		stats: { dents: number, streamed: number },
	},
	PileVisualController
))

local MIN_HEIGHT = 0.3

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
		_cells = {},
		_pool = {},
		_streaming = 0,
		_layout = ChapterLayout.chapter1,
		_trove = Trove.new(),
		stats = { dents = 0, streamed = 0 },
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

local function heightFor(config: { [string]: any }, remaining: number, base: number): number
	if remaining <= 0 then
		return MIN_HEIGHT
	end
	return MIN_HEIGHT + config.pile.maxVisualHeightStuds * (remaining / math.max(1, base))
end

local function acquireStrand(self: PileVisualController): Part
	local strand = table.remove(self._pool)
	if strand then
		return strand
	end
	local part = Instance.new("Part")
	part.Name = "Strand"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = Tokens.color.cream
	part.Size = Vector3.new(0.14, 0.45, 0.85)
	part:SetAttribute("SFE_Placeholder", "PHASE_6_VFX")
	return part
end

local function releaseStrand(self: PileVisualController, strand: Part)
	strand.Parent = nil
	table.insert(self._pool, strand)
end

-- Builds the visual grid from a snapshot. Rebuilding on a new snapshot reuses the folder.
function PileVisualController.build(self: PileVisualController, pile: { [string]: any }, chapter: string?)
	self:clear()
	local folder = Instance.new("Folder")
	folder.Name = "SFE_PileVisual"
	folder.Parent = workspace
	self._folder = folder
	self._layout = ChapterLayout[chapter or "chapter1"]
	local layout = self._layout
	local budgets = self._quality:budgets()
	local strandBudget = budgets.strands
	local cellCount = pile.width * pile.depth
	local strandsPerCell = math.max(1, math.floor(strandBudget / cellCount))
	local variance = self._config.pile.surfaceVariance

	for index = 1, cellCount do
		local x = (index - 1) % pile.width
		local z = math.floor((index - 1) / pile.width)
		local base = pile.base[index]
		local remaining = pile.remaining[index]
		local part = Instance.new("Part")
		part.Name = "Cell" .. index
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Fabric
		local tint = 0.94 + ((index * 37) % 7) * 0.01
		part.Color = Color3.new(Tokens.color.cream.R * tint, Tokens.color.cream.G * tint, Tokens.color.creamDeep.B * tint)
		local height = heightFor(self._config, remaining, base)
		part.Size = Vector3.new(pile.cellSize, height, pile.cellSize)
		part.Position = ChapterLayout.cellWorldPosition(layout, pile.width, pile.depth, pile.cellSize, x, z, height / 2)
		part:SetAttribute("SFE_Placeholder", "PHASE_6_ART")
		part.Parent = folder
		local visual: CellVisual = { part = part, base = base, remaining = remaining, x = x, z = z, strands = {} }
		self._cells[index] = visual
		-- Surface strands: proportional to density, scattered with a deterministic jitter.
		local count = math.floor(strandsPerCell * (remaining / math.max(1, base)) + 0.5)
		for s = 1, count do
			local strand = acquireStrand(self)
			local jitterX = (((index * 13 + s * 7) % 10) / 10 - 0.5) * pile.cellSize * 0.8
			local jitterZ = (((index * 29 + s * 11) % 10) / 10 - 0.5) * pile.cellSize * 0.8
			strand.CFrame = CFrame.new(part.Position + Vector3.new(jitterX, height / 2 + 0.2, jitterZ))
				* CFrame.Angles(math.rad(((index + s) * 41) % 60 - 30), math.rad((index * s * 17) % 360), 0)
			strand.Parent = folder
			table.insert(visual.strands, strand)
		end
	end
	local _ = variance
end

-- Applies an authoritative delta: tween each changed cell to its new height (dent) and thin strands.
function PileVisualController.applyDelta(self: PileVisualController, payload: { [string]: any })
	if not self._folder then
		return
	end
	local motion = self._accessibility:motionSettings()
	local info = TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeOut)
	for _, change in ipairs(payload.cells) do
		local visual = self._cells[change.i]
		if not visual then
			continue
		end
		visual.remaining = change.r
		local height = heightFor(self._config, change.r, visual.base)
		local position = ChapterLayout.cellWorldPosition(
			self._layout,
			self._round.pile.width,
			self._round.pile.depth,
			self._round.pile.cellSize,
			visual.x,
			visual.z,
			height / 2
		)
		TweenService:Create(visual.part, info, { Size = Vector3.new(visual.part.Size.X, height, visual.part.Size.Z), Position = position })
			:Play()
		-- Keep strand count proportional to remaining density.
		local target = math.floor(#visual.strands * (change.r / math.max(1, visual.base)) + 0.5)
		if change.r == 0 then
			target = 0
		end
		while #visual.strands > target do
			local strand = table.remove(visual.strands) :: Part
			releaseStrand(self, strand)
		end
		if change.r == 0 then
			visual.part.Color = Tokens.color.strawDeep
			visual.part.Material = Enum.Material.Grass
		end
		self.stats.dents += 1
	end
end

-- Feedback for an awarded hit: strands tug up from the hit point, then stream toward `target`.
function PileVisualController.streamToBag(self: PileVisualController, hitPosition: Vector3, count: number, target: () -> Vector3)
	if not self._folder then
		return
	end
	local motion = self._accessibility:motionSettings()
	local budget = math.max(1, math.floor(self._quality:budgets().strands / 60))
	local n = math.min(count, budget, 6)
	for i = 1, n do
		local strand = acquireStrand(self)
		strand.Parent = self._folder
		local offset = Vector3.new((i - n / 2) * 0.35, 0.4, ((i * 7) % 3 - 1) * 0.3)
		strand.CFrame = CFrame.new(hitPosition + offset)
		self._streaming += 1
		self.stats.streamed += 1
		-- Tug (anticipation), then release toward the bag (reward), then recycle (recovery).
		local tugInfo = TweenInfo.new(Motion.duration("quick", motion), Tokens.motion.easeOut)
		local tug = TweenService:Create(
			strand,
			tugInfo,
			{ CFrame = strand.CFrame * CFrame.new(0, 0.8 * self._accessibility:motionScale(), 0) * CFrame.Angles(0.6, 0.4, 0) }
		)
		tug:Play()
		tug.Completed:Once(function()
			local flyInfo = TweenInfo.new(Motion.duration("slow", motion), Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			local fly = TweenService:Create(
				strand,
				flyInfo,
				{ CFrame = CFrame.new(target()) * CFrame.Angles(0, i, 0), Size = Vector3.new(0.05, 0.15, 0.3) }
			)
			fly:Play()
			fly.Completed:Once(function()
				strand.Size = Vector3.new(0.14, 0.45, 0.85)
				self._streaming -= 1
				releaseStrand(self, strand)
			end)
		end)
	end
	self._vfx:burst("featherPuff", hitPosition, 0.35)
end

-- Reveal spiral: strands from the cover cells lift in a spiral around the Egg (reduced motion:
-- shorter, lower lift).
function PileVisualController.revealSpiral(self: PileVisualController, eggPosition: Vector3, coverCells: { number })
	if not self._folder then
		return
	end
	local motion = self._accessibility:motionSettings()
	local scale = self._accessibility:motionScale()
	local count = math.min(#coverCells * 2, 18)
	for i = 1, count do
		local strand = acquireStrand(self)
		strand.Parent = self._folder
		local angle = (i / count) * math.pi * 2
		strand.CFrame = CFrame.new(eggPosition + Vector3.new(math.cos(angle) * 2, 0.2, math.sin(angle) * 2))
		local info = TweenInfo.new(Motion.duration("slow", motion) * 4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
		local goal = CFrame.new(
			eggPosition + Vector3.new(math.cos(angle + 2.5) * 5 * scale, 6 * scale + 1, math.sin(angle + 2.5) * 5 * scale)
		) * CFrame.Angles(angle, angle * 2, 0)
		local tween = TweenService:Create(strand, info, { CFrame = goal, Transparency = 1 })
		tween:Play()
		tween.Completed:Once(function()
			strand.Transparency = 0
			releaseStrand(self, strand)
		end)
	end
	self._vfx:burst("sparkle", eggPosition + Vector3.new(0, 1, 0), 1.2)
end

function PileVisualController.clear(self: PileVisualController)
	for _, visual in pairs(self._cells) do
		for _, strand in ipairs(visual.strands) do
			releaseStrand(self, strand)
		end
	end
	table.clear(self._cells)
	if self._folder then
		self._folder:Destroy()
		self._folder = nil
	end
end

-- Latest known remaining count per cell index (from snapshot + deltas).
function PileVisualController.remainingByIndex(self: PileVisualController): { [number]: number }
	local out = {}
	for index, visual in pairs(self._cells) do
		out[index] = visual.remaining
	end
	return out
end

function PileVisualController.cellCount(self: PileVisualController): number
	local n = 0
	for _ in pairs(self._cells) do
		n += 1
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
	for _, strand in ipairs(self._pool) do
		strand:Destroy()
	end
	table.clear(self._pool)
	self._trove:destroy()
end

return PileVisualController
