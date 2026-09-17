--!strict
-- World visuals for server tool events (`ToolEvent`): thrown Confetti Charges (the owner's Dynamite
-- model arcing from the thrower to the targeted nest point, sticking in, fuse sparks and smoke,
-- then flash / fire / smoke / debris / shake and a persistent scorch crater), Feather Vac pulls
-- (every server-validated record curving into the puller's nozzle), Scout Chick units (the owner's
-- DodoBird model, procedurally hopping, turning, flapping and pecking), and overflow bundles.
-- Everything here is presentation: the server already decided every outcome.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Signal = require(Shared.Util.Signal)
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local FeatherLayout = require(Shared.Domain.FeatherLayout)
local ChapterLayout = require(Shared.Domain.ChapterLayout)

local ToolVisualController = {}
ToolVisualController.__index = ToolVisualController

type Charge = {
	part: BasePart?,
	model: Model?,
	light: PointLight?,
	sparks: ParticleEmitter?,
	explodeAt: number,
	mini: boolean,
	userId: number,
	landing: Vector3,
	flying: boolean,
}
type Bird = {
	head: Bone?,
	neck: Bone?,
	wingL: Bone?,
	wingR: Bone?,
	tail: Bone?,
	halfHeight: number,
	footOffset: number, -- pivot height above the model's lowest point, so the feet sit on the ground
	flapUntil: number,
	nextFlapAt: number,
	hop: number,
	peck: number,
	yaw: number,
	perchIndex: number,
	perchFrom: Vector3?,
	perchTo: Vector3?,
	perchStartedAt: number,
	perchSeconds: number,
	nextPerchAt: number,
}
type Unit =
	{ model: Model, bird: Bird?, target: Vector3?, speed: number, state: string, userId: number, position: Vector3, facing: Vector3 }
type Bundle = { part: Part, label: TextLabel, position: Vector3, count: number }

export type ToolVisualController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_folder: Folder,
		_charges: { [string]: Charge },
		_units: { [string]: Unit },
		_bundles: { [string]: Bundle },
		_craters: { BasePart },
		_bound: boolean,
		_nozzleProvider: ((userId: number) -> Vector3?)?,
		_throwOriginProvider: ((userId: number) -> Vector3?)?,
		_trove: Trove.Trove,
		chargeExploded: any, -- (payload) for the local player's haptics
		vacState: any, -- (payload) local player's vac state
		chickState: any, -- (payload)
		stats: {
			charges: number,
			explosions: number,
			units: number,
			bundles: number,
			deposits: number,
			pulls: number,
			pulledFeathers: number,
		},
	},
	ToolVisualController
))

local RENDER_NAME = "SFE_ToolVisuals"
local MODELS_FOLDER = "SFE_ToolModels"

local function placeholder(name: string, size: Vector3, color: Color3, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Shape = shape or Enum.PartType.Ball
	return part
end

local function stageModel(name: string): Model?
	local folder = ReplicatedStorage:FindFirstChild(MODELS_FOLDER)
	local source = folder and folder:FindFirstChild(name)
	return if source and source:IsA("Model") then source else nil
end

local function cloneStaged(name: string, scale: number): Model?
	local source = stageModel(name)
	if not source then
		return nil
	end
	local model = source:Clone()
	model:ScaleTo(scale)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Transparency = if descendant.Name == "Origin" then 1 else descendant.Transparency
		end
	end
	return model
end

function ToolVisualController.new(deps: {
	net: any,
	round: any,
	vfx: any,
	audio: any,
	accessibility: any,
	quality: any,
	config: { [string]: any },
	pile: any?,
	camera: any?,
	hud: any?,
}): ToolVisualController
	local folder = Instance.new("Folder")
	folder.Name = "SFE_ToolVisuals"
	folder.Parent = workspace
	local self = setmetatable({
		_deps = deps,
		_folder = folder,
		_charges = {},
		_units = {},
		_bundles = {},
		_craters = {},
		_bound = false,
		_nozzleProvider = nil,
		_throwOriginProvider = nil,
		_trove = Trove.new(),
		chargeExploded = Signal.new(),
		vacState = Signal.new(),
		chickState = Signal.new(),
		stats = { charges = 0, explosions = 0, units = 0, bundles = 0, deposits = 0, pulls = 0, pulledFeathers = 0 },
	}, ToolVisualController)
	self._trove:add(folder)
	self._trove:add(deps.net:on("ToolEvent", function(payload)
		self:_onEvent(payload)
	end))
	self._trove:add(deps.round.snapshot:Connect(function(payload)
		-- Rejoin / late snapshot: rebuild live bundles and charges from the authoritative projection.
		if payload.bundles then
			for _, bundle in ipairs(payload.bundles) do
				self:_upsertBundle(bundle.bundleId, Vector3.new(bundle.x, bundle.y, bundle.z), bundle.standard + bundle.rainbow)
			end
		end
		if payload.charges then
			for _, charge in ipairs(payload.charges) do
				if not self._charges[charge.chargeId] then
					self:_spawnCharge(
						charge.chargeId,
						Vector3.new(charge.x, charge.y, charge.z),
						charge.fuseMs,
						charge.mini,
						charge.userId,
						true
					)
				end
			end
		end
	end))
	self._trove:add(deps.round.phaseChanged:Connect(function(phase)
		if phase ~= "Searching" then
			self:clear()
		end
		self:_setBound(phase == "Searching")
	end))
	return self
end

-- Where feathers fly to (a player's vac nozzle) and where thrown sticks start (a player's hand).
function ToolVisualController.setProviders(
	self: ToolVisualController,
	providers: { nozzle: ((userId: number) -> Vector3?)?, throwOrigin: ((userId: number) -> Vector3?)? }
)
	self._nozzleProvider = providers.nozzle
	self._throwOriginProvider = providers.throwOrigin
end

function ToolVisualController._feel(self: ToolVisualController, toolId: string): { [string]: any }
	local feel = self._deps.config.toolFeel
	return (feel and feel[toolId]) or {}
end

local function characterPoint(userId: number, offset: Vector3): Vector3?
	local player = Players:GetPlayerByUserId(userId)
	local character = player and player.Character
	local head = character and (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart"))
	if head and head:IsA("BasePart") then
		return (head.CFrame * CFrame.new(offset)).Position
	end
	return nil
end

function ToolVisualController._setBound(self: ToolVisualController, bound: boolean)
	if bound == self._bound then
		return
	end
	self._bound = bound
	if bound then
		RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 3, function(dt)
			self:_step(dt)
		end)
	else
		RunService:UnbindFromRenderStep(RENDER_NAME)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Per-frame: fuse pulses, bird motion, bundle hover
-- ---------------------------------------------------------------------------------------------

function ToolVisualController._step(self: ToolVisualController, dt: number)
	local now = os.clock()
	local motionScale = self._deps.accessibility:motionScale()
	for _, charge in pairs(self._charges) do
		-- Fuse quickens toward detonation: sparks and light pulse faster in the last stretch.
		local remaining = math.max(0, charge.explodeAt - now)
		local rate = if remaining < 0.6 then 22 else 8
		local pulse = 0.5 + 0.5 * math.sin(now * rate)
		if charge.light then
			charge.light.Brightness = 0.8 + pulse * 1.6
		end
		if charge.sparks then
			charge.sparks.Rate = if remaining < 0.6 then 110 else 55
		end
		if charge.part and charge.mini then
			local base = 0.9 * (1 + 0.12 * motionScale * pulse)
			charge.part.Size = Vector3.new(base, base, base)
		end
	end
	local chickFeel = self:_feel("scoutChick")
	for _, unit in pairs(self._units) do
		self:_stepUnit(unit, dt, now, motionScale, chickFeel)
	end
	for _, bundle in pairs(self._bundles) do
		local hover = math.sin(now * 2 + bundle.position.X) * 0.15 * motionScale
		bundle.part.CFrame = CFrame.new(bundle.position + Vector3.new(0, 0.9 + hover, 0)) * CFrame.Angles(0, now * 0.8, 0)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Confetti Charge: the owner's Dynamite model
-- ---------------------------------------------------------------------------------------------

function ToolVisualController._spawnCharge(
	self: ToolVisualController,
	id: string,
	landing: Vector3,
	fuseMs: number,
	mini: boolean,
	userId: number,
	silent: boolean?
)
	local motion = self._deps.accessibility:motionSettings()
	local feel = self:_feel("confettiCharge")
	local charge: Charge = {
		part = nil,
		model = nil,
		light = nil,
		sparks = nil,
		explodeAt = os.clock() + fuseMs / 1000,
		mini = mini,
		userId = userId,
		landing = landing,
		flying = false,
	}
	local model = if mini then nil else cloneStaged("Dynamite", (feel.viewmodelScale or 0.42) * 0.9)
	if model then
		model.Name = "SFE_Charge"
		model.Parent = self._folder
		charge.model = model
		local tip = model:FindFirstChild("FuseTip", true)
		if tip and tip:IsA("BasePart") then
			local sparks = Instance.new("ParticleEmitter")
			sparks.Name = "FuseSparks"
			sparks.Color = ColorSequence.new(Tokens.color.honey, Tokens.color.ember)
			sparks.LightEmission = 1
			sparks.Size = NumberSequence.new(0.12, 0.02)
			sparks.Lifetime = NumberRange.new(0.15, 0.4)
			sparks.Rate = 55
			sparks.Speed = NumberRange.new(2, 4)
			sparks.SpreadAngle = Vector2.new(80, 80)
			sparks.Parent = tip
			local smoke = Instance.new("ParticleEmitter")
			smoke.Name = "FuseSmoke"
			smoke.Color = ColorSequence.new(Color3.fromRGB(200, 196, 190))
			smoke.Transparency = NumberSequence.new(0.5, 1)
			smoke.Size = NumberSequence.new(0.1, 0.5)
			smoke.Lifetime = NumberRange.new(0.6, 1.1)
			smoke.Rate = 12
			smoke.Speed = NumberRange.new(0.4, 1)
			smoke.Acceleration = Vector3.new(0, 1.5, 0)
			smoke.Parent = tip
			local light = Instance.new("PointLight")
			light.Color = Tokens.color.honey
			light.Range = 7
			light.Brightness = 1.2
			light.Parent = tip
			charge.sparks = sparks
			charge.light = light
			if not silent then
				self._deps.audio:play(Tokens.sound.fuseHiss, { at = tip })
			end
		end
		local rest = CFrame.new(landing + Vector3.new(0, 0.35, 0))
			* CFrame.Angles(math.rad(-28 + (math.random() * 2 - 1) * 8), math.random() * math.pi * 2, math.rad(12))
		local start = if self._throwOriginProvider then self._throwOriginProvider(userId) else nil
		start = start or characterPoint(userId, Vector3.new(0.6, 0, -1)) or (landing + Vector3.new(0, 9, 0))
		if silent or motion.reducedMotion then
			model:PivotTo(rest)
		else
			-- Readable arc: a parabola from the hand to the targeted point, spinning end over end.
			charge.flying = true
			local speed = feel.throwSpeedStudsPerSecond or 26
			local flat = (landing - start)
			local seconds = math.clamp(flat.Magnitude / speed, 0.28, 0.9)
			-- The arc rises in proportion to how far the throw actually went, measured against the tool's
			-- configured range rather than a fixed distance, so retuning the range retunes the arc.
			local reference = math.max(1, self._deps.config.tools.confettiCharge.throwDistanceStuds)
			local height = (feel.arcHeightStuds or 4.5) * math.clamp(flat.Magnitude / reference, 0.4, 1.2)
			task.spawn(function()
				local elapsed = 0
				local spin = 0
				while elapsed < seconds and charge.model == model and model.Parent do
					local step = RunService.Heartbeat:Wait()
					elapsed += step
					local u = math.clamp(elapsed / seconds, 0, 1)
					local point = start:Lerp(landing + Vector3.new(0, 0.35, 0), u) + Vector3.new(0, 4 * height * u * (1 - u), 0)
					spin += step * 9
					local ahead = flat.Magnitude > 0.01 and Vector3.new(flat.X, 0, flat.Z).Unit or Vector3.zAxis
					model:PivotTo(CFrame.lookAt(point, point + ahead) * CFrame.Angles(spin, 0, 0))
				end
				if charge.model == model and model.Parent then
					model:PivotTo(rest)
					charge.flying = false
					self._deps.vfx:burst("dust", landing + Vector3.new(0, 0.3, 0), 0.2)
				end
			end)
		end
	else
		local size = 0.9
		local part = placeholder("SFE_MiniCharge", Vector3.new(size, size, size), if mini then Tokens.color.danger else Tokens.color.ember)
		part.Material = Enum.Material.Neon
		part.Parent = self._folder
		charge.part = part
		local rest = landing + Vector3.new(0, size / 2, 0)
		if silent or motion.reducedMotion then
			part.CFrame = CFrame.new(rest)
		else
			part.CFrame = CFrame.new(rest + Vector3.new(0, 6, 0))
			TweenService:Create(part, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = CFrame.new(rest) })
				:Play()
		end
	end
	self._charges[id] = charge
	self.stats.charges += 1
end

-- Debris: a handful of feather-ish slivers tossed out of the blast on eased arcs.
function ToolVisualController._debris(self: ToolVisualController, position: Vector3, radius: number)
	local feel = self:_feel("confettiCharge")
	local count = feel.debrisCount or 10
	local seconds = feel.debrisSeconds or 0.9
	if self._deps.accessibility:motionSettings().reducedMotion then
		count = math.floor(count / 3)
	end
	for _ = 1, count do
		local part = placeholder(
			"Debris",
			Vector3.new(0.5 + math.random() * 0.6, 0.12, 0.9 + math.random() * 0.8),
			Tokens.worldColor.feather,
			Enum.PartType.Block
		)
		part.Material = Enum.Material.SmoothPlastic
		part.Parent = self._folder
		local angle = math.random() * math.pi * 2
		local distance = radius * (0.3 + math.random() * 0.9)
		local landing = position + Vector3.new(math.cos(angle) * distance, 0.2, math.sin(angle) * distance)
		local height = 3 + math.random() * 5
		local spinX, spinY = math.random() * 6, math.random() * 6
		task.spawn(function()
			local elapsed = 0
			while elapsed < seconds and part.Parent do
				elapsed += RunService.Heartbeat:Wait()
				local u = math.clamp(elapsed / seconds, 0, 1)
				local point = position:Lerp(landing, u) + Vector3.new(0, 4 * height * u * (1 - u), 0)
				part.CFrame = CFrame.new(point) * CFrame.Angles(spinX * u, angle, spinY * u)
				part.Transparency = if u > 0.7 then (u - 0.7) / 0.3 else 0
			end
			part:Destroy()
		end)
	end
end

function ToolVisualController._explodeCharge(self: ToolVisualController, payload: { [string]: any })
	local charge = self._charges[payload.chargeId]
	if charge then
		if charge.model then
			charge.model:Destroy()
		end
		if charge.part then
			charge.part:Destroy()
		end
		self._charges[payload.chargeId] = nil
	end
	local feel = self:_feel("confettiCharge")
	local position = Vector3.new(payload.x, payload.y + 0.8, payload.z)
	local radius = payload.radius or 8
	local mini = payload.mini == true
	self.stats.explosions += 1
	-- The validated records leave the crater one by one: up out of the blast, then to the owner.
	local pile = self._deps.pile
	if pile and payload.cells then
		local userId = payload.userId
		local function destination(): Vector3
			if userId == Players.LocalPlayer.UserId and self._nozzleProvider then
				local stack = self._deps.hud and self._deps.hud.carriedStackWorldPoint and self._deps.hud:carriedStackWorldPoint()
				if stack then
					return stack
				end
			end
			return characterPoint(userId, Vector3.new(0, 0.5, -1)) or (position + Vector3.new(0, 6, 0))
		end
		local index = 0
		for _, removal in ipairs(payload.cells) do
			for _, slot in ipairs(removal.slots or {}) do
				local featherId = FeatherLayout.featherId(removal.index, slot)
				task.delay(math.min(1.2, index * 0.012), function()
					pile:collectFeather(featherId, position, destination, { pullSeconds = 0.55, quiet = true })
				end)
				index += 1
			end
		end
	end
	-- Flash: a neon sphere that swells past the blast radius and fades in a beat.
	local flash = placeholder("Flash", Vector3.new(1, 1, 1), Tokens.color.honey)
	flash.Material = Enum.Material.Neon
	flash.CFrame = CFrame.new(position)
	flash.Parent = self._folder
	local flashLight = Instance.new("PointLight")
	flashLight.Color = Tokens.color.honey
	flashLight.Range = radius * 2
	flashLight.Brightness = 4
	flashLight.Parent = flash
	local flashSeconds = feel.flashSeconds or 0.14
	local grow = if mini then radius * 0.9 else radius * 1.15
	TweenService:Create(flash, TweenInfo.new(flashSeconds * 2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(grow, grow, grow),
		Transparency = 1,
	}):Play()
	TweenService:Create(flashLight, TweenInfo.new(flashSeconds * 3), { Brightness = 0 }):Play()
	task.delay(flashSeconds * 3, function()
		flash:Destroy()
	end)
	-- Fire, smoke, sparks, feather puff, then debris.
	self._deps.vfx:burst("blast", position, if mini then 0.15 else 0.28)
	self._deps.vfx:burst("spark", position, 0.2)
	self._deps.vfx:burst("smoke", position + Vector3.new(0, 1, 0), if mini then 0.5 else 1.2)
	self._deps.vfx:burst("featherPuff", position, 0.8)
	if payload.rainbow and payload.rainbow > 0 then
		self._deps.vfx:burst("sparkle", position + Vector3.new(0, 1.5, 0), 1.2)
	end
	if not mini then
		self:_debris(position, radius)
	end
	-- Scorch at the blast point: a mark the blast leaves, not a mark the blast makes permanent.
	--
	-- This used to stay until the round ended, so a handful of charges tiled the nest with black discs
	-- that never went away and had nothing to do with where the feathers actually were. It holds, then
	-- fades and goes. Still tracked in `_craters` so a round teardown mid-fade takes it with everything
	-- else, and taken back out of that list when it removes itself.
	local crater = placeholder("SFE_Crater", Vector3.new(0.1, radius * 1.4, radius * 1.4), Tokens.color.shadow, Enum.PartType.Cylinder)
	crater.Material = Enum.Material.Slate
	crater.Transparency = feel.craterTransparency or 0.35
	crater.CFrame = CFrame.new(payload.x, payload.y + 0.08, payload.z) * CFrame.Angles(0, 0, math.rad(90))
	crater.Parent = self._folder
	table.insert(self._craters, crater)
	local holdSeconds = feel.craterSeconds or 1.6
	local fadeSeconds = feel.craterFadeSeconds or 0.7
	task.delay(holdSeconds, function()
		if not crater.Parent then
			return
		end
		TweenService:Create(crater, TweenInfo.new(fadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Transparency = 1,
			Size = Vector3.new(0.1, radius * 1.7, radius * 1.7),
		}):Play()
		task.delay(fadeSeconds, function()
			local index = table.find(self._craters, crater)
			if index then
				table.remove(self._craters, index)
			end
			crater:Destroy()
		end)
	end)
	-- Sound and shake fall off with distance for everyone in the round.
	self._deps.audio:play(Tokens.sound.blast, { pitchVariance = 0.08 })
	-- A low floor under the owner's explosion.
	self._deps.audio:play(Tokens.sound.blastLow, { pitchVariance = 0.03 })
	local camera = workspace.CurrentCamera
	if camera and self._deps.camera then
		local distance = (camera.CFrame.Position - position).Magnitude
		local range = feel.blastShakeRangeStuds or 40
		local strength = (feel.blastShake or 0.5) * math.clamp(1 - distance / range, 0, 1) * (if mini then 0.4 else 1)
		if strength > 0.01 then
			self._deps.camera:impulse(strength)
		end
	end
	self.chargeExploded:Fire(payload)
end

-- ---------------------------------------------------------------------------------------------
-- Feather Vac: validated records curve into the puller's nozzle
-- ---------------------------------------------------------------------------------------------

function ToolVisualController._vacPull(self: ToolVisualController, payload: { [string]: any })
	local pile = self._deps.pile
	if not pile then
		return
	end
	local userId = payload.userId
	local feel = self:_feel("featherVac")
	local stagger = feel.pullStaggerSeconds or 0.035
	local pullSeconds = feel.pullSeconds or 0.24
	local hit = Vector3.new(payload.x or 0, payload.y or 0, payload.z or 0)
	local function nozzle(): Vector3
		local point = if self._nozzleProvider then self._nozzleProvider(userId) else nil
		return point or characterPoint(userId, Vector3.new(0.5, -0.4, -1.4)) or hit
	end
	local index = 0
	self.stats.pulls += 1
	for _, removal in ipairs(payload.cells or {}) do
		for _, slot in ipairs(removal.slots or {}) do
			local featherId = FeatherLayout.featherId(removal.index, slot)
			self.stats.pulledFeathers += 1
			task.delay(index * stagger, function()
				pile:collectFeather(featherId, hit, nozzle, { pullSeconds = pullSeconds, quiet = true })
			end)
			index += 1
		end
	end
	if index > 0 then
		self._deps.vfx:burst("wind", hit + Vector3.new(0, 0.4, 0), 0.15)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Scout Chick: the owner's DodoBird, hopping and pecking
-- ---------------------------------------------------------------------------------------------

local function findBone(model: Model, name: string): Bone?
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Bone") and descendant.Name == name then
			return descendant
		end
	end
	return nil
end

function ToolVisualController._buildUnit(self: ToolVisualController, position: Vector3): (Model, Bird?)
	local feel = self:_feel("scoutChick")
	local model = cloneStaged("DodoBird", feel.modelScale or 0.34)
	if model then
		model.Name = "SFE_ScoutChick"
		local box, size = model:GetBoundingBox()
		-- The pivot is not the box centre: measure how far the feet sit under it so nothing clips.
		local footOffset = model:GetPivot().Position.Y - (box.Position.Y - size.Y * 0.5) + 0.12
		local bird: Bird = {
			head = findBone(model, "head"),
			neck = findBone(model, "neck"),
			wingL = findBone(model, "wing.L"),
			wingR = findBone(model, "wing.R"),
			tail = findBone(model, "tail"),
			halfHeight = size.Y * 0.5,
			footOffset = footOffset,
			flapUntil = 0,
			nextFlapAt = os.clock() + 1 + math.random() * 3,
			hop = 0,
			peck = 0,
			yaw = 0,
			perchIndex = 0,
			perchFrom = nil,
			perchTo = nil,
			perchStartedAt = 0,
			perchSeconds = 1,
			nextPerchAt = 0,
		}
		model:PivotTo(CFrame.new(position + Vector3.new(0, footOffset, 0)))
		model.Parent = self._folder
		return model, bird
	end
	-- Fallback when the owner's model is not staged: a small chick block.
	local fallback = Instance.new("Model")
	fallback.Name = "SFE_ScoutChick"
	local body = placeholder("Body", Vector3.new(1.2, 1.1, 1.4), Tokens.color.straw, Enum.PartType.Block)
	body.Material = Enum.Material.Fabric
	body.Parent = fallback
	fallback.PrimaryPart = body
	fallback:PivotTo(CFrame.new(position + Vector3.new(0, 0.6, 0)))
	fallback.Parent = self._folder
	return fallback, nil
end

function ToolVisualController._stepUnit(
	self: ToolVisualController,
	unit: Unit,
	dt: number,
	now: number,
	motionScale: number,
	feel: { [string]: any }
)
	local bird = unit.bird
	local moving = false
	if unit.target then
		local delta = unit.target - unit.position
		local flatDelta = Vector3.new(delta.X, 0, delta.Z)
		local distance = flatDelta.Magnitude
		local step = unit.speed * dt
		if distance <= step or distance < 0.05 then
			unit.position = unit.target
			unit.target = nil
		else
			unit.position = unit.position + flatDelta.Unit * step
			unit.facing = flatDelta.Unit
			moving = true
		end
	end
	local hopHeight = (feel.hopHeightStuds or 0.32) * motionScale
	local hopHz = feel.hopHz or 2.6
	local bounce = 0
	local flying = false
	if bird and unit.state == "Waiting" then
		-- Crate away: fly between the intentional perches (crate lid, fence post, rail) with a
		-- pause on each, wings working for the whole flight.
		local perches = ChapterLayout.chapter1.chickPerches
		if perches and #perches > 0 then
			if bird.perchTo == nil and now >= bird.nextPerchAt then
				bird.perchIndex = (bird.perchIndex % #perches) + 1
				bird.perchFrom = unit.position
				bird.perchTo = perches[bird.perchIndex]
				bird.perchStartedAt = now
				bird.perchSeconds = math.clamp((bird.perchTo - unit.position).Magnitude / 9, 0.6, 1.6)
				bird.flapUntil = now + bird.perchSeconds + 0.2
			end
			if bird.perchTo and bird.perchFrom then
				flying = true
				local t = math.clamp((now - bird.perchStartedAt) / bird.perchSeconds, 0, 1)
				local e = t * t * (3 - 2 * t)
				local point = bird.perchFrom:Lerp(bird.perchTo, e) + Vector3.new(0, math.sin(t * math.pi) * 2.2 * motionScale, 0)
				local flat = Vector3.new(bird.perchTo.X - bird.perchFrom.X, 0, bird.perchTo.Z - bird.perchFrom.Z)
				if flat.Magnitude > 0.05 then
					unit.facing = flat.Unit
				end
				unit.position = point
				if t >= 1 then
					unit.position = bird.perchTo
					bird.perchTo = nil
					bird.perchFrom = nil
					bird.nextPerchAt = now + 2.5 + math.random() * 2.5
					self._deps.vfx:burst("featherPuff", unit.position + Vector3.new(0, 0.5, 0), 0.15)
				end
			end
		end
	end
	if bird then
		-- Hop while moving; a settle-down bob when arriving.
		if moving or bird.hop % 1 > 0.02 then
			bird.hop += dt * hopHz
		end
		bounce = if flying then 0 else math.abs(math.sin(bird.hop * math.pi)) * hopHeight * (if moving then 1 else 0.4)
		-- Face the travel direction, easing the yaw.
		local wantedYaw = math.atan2(-unit.facing.X, -unit.facing.Z)
		local diff = (wantedYaw - bird.yaw + math.pi) % (math.pi * 2) - math.pi
		bird.yaw += diff * math.min(1, dt * 8)
		local lean = if flying then math.rad(-12) elseif moving then math.rad(8) * math.sin(bird.hop * math.pi * 2) else 0
		unit.model:PivotTo(
			CFrame.new(unit.position + Vector3.new(0, bird.footOffset + bounce, 0))
				* CFrame.Angles(0, bird.yaw, 0)
				* CFrame.Angles(lean, 0, 0)
		)
		-- Head: slow looks around while idle or walking, a sharp peck while collecting.
		local headTurn = math.rad(feel.headTurnDegrees or 35) * motionScale
		local headYaw = math.sin(now * 0.9 + unit.position.X) * headTurn * (if moving then 0.3 else 1)
		local headPitch = 0
		if unit.state == "Collecting" then
			bird.peck += dt * (1 / math.max(0.15, self._deps.config.tools.scoutChick.collectIntervalSeconds or 0.5)) * math.pi
			headPitch = -math.abs(math.sin(bird.peck)) * math.rad(feel.peckDegrees or 40) * motionScale
			headYaw *= 0.2
		elseif unit.state == "Depositing" then
			headPitch = math.sin(now * 6) * math.rad(10)
		end
		if bird.head then
			bird.head.Transform = CFrame.Angles(headPitch, headYaw, 0)
		end
		if bird.neck then
			bird.neck.Transform = CFrame.Angles(headPitch * 0.5, headYaw * 0.4, 0)
		end
		-- Wings: a flap burst now and then, on every hop apex, and while depositing.
		local flapSeconds = feel.flapSeconds or 0.55
		if now >= bird.nextFlapAt or unit.state == "Depositing" or (moving and bounce > hopHeight * 0.85 and now > bird.flapUntil) then
			local interval = feel.flapIntervalSeconds or { 3, 7 }
			bird.flapUntil = now + flapSeconds
			bird.nextFlapAt = now + interval[1] + math.random() * (interval[2] - interval[1])
		end
		local flap = if flying
			then math.abs(math.sin(now * 14))
			elseif now < bird.flapUntil then math.abs(math.sin((bird.flapUntil - now) / flapSeconds * math.pi * 3))
			else 0
		local wingAngle = flap * math.rad(45) * motionScale + (if moving then math.rad(6) else math.rad(2))
		if bird.wingL then
			bird.wingL.Transform = CFrame.Angles(0, 0, wingAngle)
		end
		if bird.wingR then
			bird.wingR.Transform = CFrame.Angles(0, 0, -wingAngle)
		end
		if bird.tail then
			bird.tail.Transform = CFrame.Angles(math.sin(now * 3) * math.rad(6) * motionScale, 0, 0)
		end
	else
		local cf = CFrame.new(unit.position + Vector3.new(0, 0.6, 0))
		if unit.facing.Magnitude > 0.01 then
			cf = CFrame.lookAt(unit.position + Vector3.new(0, 0.6, 0), unit.position + Vector3.new(0, 0.6, 0) + unit.facing)
		end
		unit.model:PivotTo(cf)
	end
end

function ToolVisualController._upsertUnit(self: ToolVisualController, payload: { [string]: any })
	local unit = self._units[payload.unitId]
	if payload.removed then
		if unit then
			-- A recalled or docked chick puffs out; a deposit-and-dock one flaps first.
			self._deps.vfx:burst("featherPuff", unit.position + Vector3.new(0, 0.8, 0), 0.25)
			unit.model:Destroy()
			self._units[payload.unitId] = nil
		end
		self.chickState:Fire(payload)
		return
	end
	local serverPosition = Vector3.new(payload.x, payload.y, payload.z)
	if not unit then
		local model, bird = self:_buildUnit(serverPosition)
		unit = {
			model = model,
			bird = bird,
			target = nil,
			speed = payload.speed or 10,
			state = payload.state,
			userId = payload.userId,
			position = serverPosition,
			facing = Vector3.new(0, 0, -1),
		}
		self._units[payload.unitId] = unit
		self.stats.units += 1
		self._deps.vfx:burst("featherPuff", serverPosition + Vector3.new(0, 0.6, 0), 0.25)
		self._deps.audio:play(Tokens.sound.chickChirp, { pitchVariance = 0.15 })
	end
	local previousState = unit.state
	unit.state = payload.state
	if payload.speed then
		unit.speed = payload.speed
	end
	-- Snap correction if the client drifted more than a couple of studs, else keep smoothing
	-- (perching while the crate is away is client-side motion around the server's crate point).
	if payload.state ~= "Waiting" and (unit.position - serverPosition).Magnitude > 3 then
		unit.position = serverPosition
	end
	if payload.state ~= "Waiting" and unit.bird then
		unit.bird.perchTo = nil
		unit.bird.perchFrom = nil
	end
	if payload.targetX then
		unit.target = Vector3.new(payload.targetX, payload.targetY, payload.targetZ)
	elseif payload.state == "Collecting" or payload.state == "Depositing" then
		unit.target = nil
	end
	if unit.bird and payload.state ~= previousState then
		-- Reaction on every state change: a quick flap and a chirp when it starts pecking or trading.
		unit.bird.flapUntil = os.clock() + (self:_feel("scoutChick").flapSeconds or 0.55) * 0.7
		if payload.state == "Collecting" or payload.state == "Depositing" then
			self._deps.audio:play(Tokens.sound.chickChirp, { pitchVariance = 0.2 })
		end
	end
	if payload.cents then
		self.stats.deposits += 1
		self._deps.vfx:burst("sparkle", serverPosition + Vector3.new(0, 1, 0), 0.5)
		self._deps.audio:play(Tokens.sound.sellTick, { pitchVariance = 0.1 })
		if unit.bird then
			unit.bird.flapUntil = os.clock() + (self:_feel("scoutChick").flapSeconds or 0.55)
		end
	end
	self.chickState:Fire(payload)
end

-- ---------------------------------------------------------------------------------------------
-- Overflow bundles
-- ---------------------------------------------------------------------------------------------

function ToolVisualController._upsertBundle(self: ToolVisualController, id: string, position: Vector3, count: number)
	local bundle = self._bundles[id]
	if not bundle then
		local part = placeholder("SFE_Bundle", Vector3.new(1.3, 1.3, 1.3), Tokens.worldColor.feather)
		part.Material = Enum.Material.Fabric
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(80, 24)
		gui.StudsOffset = Vector3.new(0, 1.4, 0)
		gui.AlwaysOnTop = true
		gui.MaxDistance = 60
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Tokens.typography.numeral.font
		label.TextSize = Tokens.typography.numeral.size
		label.TextColor3 = Tokens.color.featherWhite
		label.TextStrokeTransparency = 0.3
		label.Parent = gui
		gui.Parent = part
		part.Parent = self._folder
		bundle = { part = part, label = label, position = position, count = count }
		self._bundles[id] = bundle
		self.stats.bundles += 1
		self._deps.vfx:burst("featherPuff", position + Vector3.new(0, 1, 0), 0.4)
	end
	bundle.count = count
	bundle.label.Text = string.format("+%d", count)
end

function ToolVisualController._removeBundle(self: ToolVisualController, id: string, gathered: boolean)
	local bundle = self._bundles[id]
	if not bundle then
		return
	end
	if gathered then
		self._deps.vfx:burst("sparkle", bundle.position + Vector3.new(0, 1, 0), 0.4)
	end
	bundle.part:Destroy()
	self._bundles[id] = nil
end

-- ---------------------------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------------------------

function ToolVisualController._onEvent(self: ToolVisualController, payload: { [string]: any })
	local kind = payload.kind
	if kind == "charge_thrown" then
		self:_spawnCharge(
			payload.chargeId,
			Vector3.new(payload.x, payload.y, payload.z),
			payload.fuseMs,
			payload.mini == true,
			payload.userId
		)
	elseif kind == "charge_exploded" then
		self:_explodeCharge(payload)
	elseif kind == "vac_state" then
		self.vacState:Fire(payload)
	elseif kind == "vac_pull" then
		self:_vacPull(payload)
	elseif kind == "chick_state" then
		self:_upsertUnit(payload)
	elseif kind == "bundle_dropped" then
		self:_upsertBundle(payload.bundleId, Vector3.new(payload.x, payload.y, payload.z), payload.standard + payload.rainbow)
	elseif kind == "bundle_changed" then
		local bundle = self._bundles[payload.bundleId]
		if bundle then
			self:_upsertBundle(payload.bundleId, bundle.position, payload.standard + payload.rainbow)
		end
	elseif kind == "bundle_removed" then
		self:_removeBundle(payload.bundleId, payload.byUserId ~= nil)
	end
end

-- Nearest live bundle within `radius` of `position` (for the auto-gather walk-over).
function ToolVisualController.nearestBundle(self: ToolVisualController, position: Vector3, radius: number): (string?, number?)
	local bestId, bestDistance = nil, radius
	for id, bundle in pairs(self._bundles) do
		local flat = Vector3.new(bundle.position.X - position.X, 0, bundle.position.Z - position.Z).Magnitude
		if flat <= bestDistance then
			bestId, bestDistance = id, flat
		end
	end
	return bestId, bestDistance
end

function ToolVisualController.clear(self: ToolVisualController)
	for id, charge in pairs(self._charges) do
		if charge.model then
			charge.model:Destroy()
		end
		if charge.part then
			charge.part:Destroy()
		end
		self._charges[id] = nil
	end
	for id, unit in pairs(self._units) do
		unit.model:Destroy()
		self._units[id] = nil
	end
	for id, bundle in pairs(self._bundles) do
		bundle.part:Destroy()
		self._bundles[id] = nil
	end
	for _, crater in ipairs(self._craters) do
		crater:Destroy()
	end
	table.clear(self._craters)
end

function ToolVisualController.counts(self: ToolVisualController): { charges: number, units: number, bundles: number, craters: number }
	local charges, units, bundles = 0, 0, 0
	for _ in pairs(self._charges) do
		charges += 1
	end
	for _ in pairs(self._units) do
		units += 1
	end
	for _ in pairs(self._bundles) do
		bundles += 1
	end
	return { charges = charges, units = units, bundles = bundles, craters = #self._craters }
end

function ToolVisualController.instanceCount(self: ToolVisualController): number
	return #self._folder:GetDescendants()
end

function ToolVisualController.destroy(self: ToolVisualController)
	self:_setBound(false)
	self:clear()
	self._trove:destroy()
	self.chargeExploded:Destroy()
	self.vacState:Destroy()
	self.chickState:Destroy()
end

ToolVisualController.Motion = Motion
ToolVisualController.LocalPlayer = Players.LocalPlayer

return ToolVisualController
