--!strict
-- First-person viewmodels for the round tools: the owner's Pitchfork (Nest Rake), Dynamite (Confetti
-- Charge) and Vacuum (Feather Vac) models, staged script-free by the server, drawn under the camera
-- with procedural motion only (CFrames, springs, eased curves): idle sway and look-lag, the rake's
-- thrust to the reticle and its eased return, the dynamite's light-then-throw, the vac's recoil,
-- jitter, intake particles, wind streaks and motor loop. No
-- hands or arms are ever drawn. Every number lives in SYSTEM_CONFIG.toolFeel (ASSUMED until the
-- owner's clips are matched).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Tokens = require(Shared.Design.Tokens)

local ToolViewmodelController = {}
ToolViewmodelController.__index = ToolViewmodelController

local RENDER_NAME = "SFE_ToolViewmodel"
local MODELS_FOLDER = "SFE_ToolModels"

type Pose = {
	model: string,
	offset: CFrame,
	rotation: CFrame?,
	quill: Vector3?, -- camera-space direction the model's local +Y (its shaft) should point
	spin: number?, -- degrees about that shaft
	nozzle: string?,
	fuse: string?,
	tip: string?,
	procedural: boolean?, -- built from parts here rather than cloned from the staged models
}

-- Orientation from an explicit shaft direction. Euler triples are impossible to reason about for a
-- held tool; "the shaft points this way in camera space, rolled this far about itself" is not.
local function fromQuill(quill: Vector3, spin: number): CFrame
	local up = quill.Unit
	local reference = if math.abs(up.Z) < 0.95 then Vector3.new(0, 0, -1) else Vector3.new(1, 0, 0)
	local right = up:Cross(reference)
	if right.Magnitude < 0.01 then
		right = up:Cross(Vector3.new(1, 0, 0))
	end
	right = right.Unit
	return CFrame.fromMatrix(Vector3.zero, right, up, right:Cross(up)) * CFrame.Angles(0, math.rad(spin), 0)
end
-- Hold poses relative to the camera (x right, y up, z back): the grip sits low on the right and the
-- working end reaches toward the reticle. Model axes: the pitchfork and dynamite stand along +Y from
-- their Origin, the vacuum's nozzle points along -X.
local POSES: { [string]: Pose } = {
	-- Solved in camera space so the fork head lands in the lower right third and the shaft sweeps
	-- down to a grip just off the corner: at scale 0.34 the crossbar sits 2.24 studs up the shaft,
	-- the tips 2.82, so this anchor puts the head around 40 % down and 17 % right of centre.
	nestRake = {
		model = "Pitchfork",
		offset = CFrame.new(1.31, -1.69, -0.72),
		quill = Vector3.new(-0.34, 0.42, -0.84),
		spin = 8,
		tip = "ForkCrossbar",
	},
	confettiCharge = {
		model = "Dynamite",
		offset = CFrame.new(0.58, -0.62, -1.25),
		rotation = CFrame.Angles(math.rad(-12), math.rad(-30), math.rad(16)),
		fuse = "FuseTip",
	},
	featherVac = {
		model = "Vacuum",
		offset = CFrame.new(0.5, -0.55, -1.1),
		rotation = CFrame.Angles(math.rad(-8), math.rad(-80), 0),
		nozzle = "WideIntake",
	},
}

type Streak = { part: Part, start: Vector3, life: number, seconds: number, side: number }

export type ToolViewmodelController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_feel: { [string]: any },
		_model: Model?,
		_toolId: string,
		_active: boolean,
		_bound: boolean,
		_time: number,
		_lag: Vector2,
		_prevLook: Vector3?,
		_action: { kind: string, startedAt: number, from: CFrame?, seconds: number },
		_hidden: boolean,
		_vacRunning: boolean,
		_vacLoop: Sound?,
		_vacEmitter: ParticleEmitter?,
		_fuseSparks: ParticleEmitter?,
		_fuseSmoke: ParticleEmitter?,
		_fuseLight: PointLight?,
		_streakFolder: Folder?,
		_streaks: { Streak },
		_aimHit: Vector3?,
		_trove: Trove.Trove,
		stats: { builds: number, thrusts: number, lights: number, throws: number, vacFrames: number },
	},
	ToolViewmodelController
))

local function easeOutQuad(t: number): number
	return 1 - (1 - t) * (1 - t)
end

local function easeOutBack(t: number): number
	local c1 = 1.70158
	local c3 = c1 + 1
	return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
end

function ToolViewmodelController.new(deps: {
	tools: any,
	round: any,
	accessibility: any,
	audio: any,
	vfx: any,
	pile: any,
	config: { [string]: any },
}): ToolViewmodelController
	local self = setmetatable({
		_deps = deps,
		_feel = deps.config.toolFeel or {},
		_model = nil,
		_toolId = "hand",
		_active = false,
		_bound = false,
		_time = 0,
		_lag = Vector2.zero,
		_prevLook = nil,
		_action = { kind = "none", startedAt = 0, from = nil, seconds = 0 },
		_hidden = false,
		_vacRunning = false,
		_vacLoop = nil,
		_vacEmitter = nil,
		_fuseSparks = nil,
		_fuseSmoke = nil,
		_fuseLight = nil,
		_streakFolder = nil,
		_streaks = {},
		_aimHit = nil,
		_trove = Trove.new(),
		stats = { builds = 0, thrusts = 0, lights = 0, throws = 0, vacFrames = 0 },
	}, ToolViewmodelController)

	local tools = deps.tools
	self._trove:add(deps.round.phaseChanged:Connect(function(phase)
		self:setActive(phase == "Searching" or phase == "EggRevealed")
	end))
	self._trove:add(tools.equippedChanged:Connect(function(toolId)
		self:_equip(toolId)
	end))
	-- Rake: thrust on the swing, impact on the server's accepted hit, eased return either way.
	self._trove:add(tools.swung:Connect(function()
		self:_thrust()
	end))
	self._trove:add(tools.collected:Connect(function(data)
		if data.toolId == "nestRake" and self._toolId == "nestRake" then
			self:_impact(Vector3.new(data.hitX, data.hitY or 0, data.hitZ))
		end
	end))
	self._trove:add(tools.rejected:Connect(function()
		if self._action.kind == "thrust" or self._action.kind == "anticipate" then
			self:_beginReturn()
		end
	end))
	-- Dynamite: light, throw, or fizzle.
	self._trove:add(tools.chargeLit:Connect(function()
		self:_light()
	end))
	self._trove:add(tools.chargeThrown:Connect(function()
		self:_thrown()
	end))
	self._trove:add(tools.chargeExtinguished:Connect(function()
		self:_extinguish()
	end))
	-- Vac: the running flag drives recoil, particles, streaks and the motor loop.
	self._trove:add(tools.vacChanged:Connect(function(running)
		self:_setVacRunning(running)
	end))
	return self
end

-- ---------------------------------------------------------------------------------------------
-- Build / teardown
-- ---------------------------------------------------------------------------------------------

function ToolViewmodelController._models(_self: ToolViewmodelController): Instance?
	return ReplicatedStorage:FindFirstChild(MODELS_FOLDER)
end

function ToolViewmodelController._feelFor(self: ToolViewmodelController, toolId: string): { [string]: any }
	return self._feel[toolId] or {}
end

function ToolViewmodelController._destroyModel(self: ToolViewmodelController)
	self:_setVacRunning(false)
	self:_extinguish()
	if self._model then
		self._model:Destroy()
		self._model = nil
	end
	if self._streakFolder then
		self._streakFolder:Destroy()
		self._streakFolder = nil
	end
	table.clear(self._streaks)
	self._action = { kind = "none", startedAt = 0, from = nil, seconds = 0 }
end

function ToolViewmodelController._build(self: ToolViewmodelController, toolId: string): Model?
	local pose = POSES[toolId]
	local models = self:_models()
	local camera = workspace.CurrentCamera
	if not pose or not camera or not models then
		return nil
	end
	local source = models:FindFirstChild(pose.model)
	if not (source and source:IsA("Model")) then
		return nil
	end
	local model = source:Clone()
	model.Name = "SFE_Viewmodel_" .. toolId
	if not model.PrimaryPart then
		model.PrimaryPart = model:FindFirstChild("Origin") :: BasePart? or model:FindFirstChildWhichIsA("BasePart", true)
	end
	local scale = self:_feelFor(toolId).viewmodelScale or 0.4
	model:ScaleTo(scale)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
			descendant.Massless = true
			descendant.Transparency = if descendant.Name == "Origin" then 1 else descendant.Transparency
		end
	end
	model.Parent = camera
	self.stats.builds += 1
	return model
end

function ToolViewmodelController._equip(self: ToolViewmodelController, toolId: string)
	if toolId == self._toolId and (self._model ~= nil or POSES[toolId] == nil) then
		return
	end
	self:_destroyModel()
	self._toolId = toolId
	if not self._active then
		return
	end
	self._model = self:_build(toolId)
	if self._model then
		-- Draw in from below so a swap reads as the tool coming up into the hand.
		self._action = { kind = "raise", startedAt = os.clock(), from = nil, seconds = 0.3 }
		self._lag = Vector2.zero
		self._prevLook = nil
	end
end

function ToolViewmodelController.setActive(self: ToolViewmodelController, active: boolean)
	if active == self._active then
		return
	end
	self._active = active
	if active then
		if not self._bound then
			self._bound = true
			RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 4, function(dt)
				self:step(dt)
			end)
		end
		self._model = self:_build(self._toolId)
	else
		if self._bound then
			self._bound = false
			RunService:UnbindFromRenderStep(RENDER_NAME)
		end
		self:_destroyModel()
	end
end

-- ---------------------------------------------------------------------------------------------
-- Per-frame pose
-- ---------------------------------------------------------------------------------------------

-- World point under the reticle: the first feather or surface the centre ray meets (client-side;
-- the server resolves its own aim for every award).
function ToolViewmodelController.reticleHit(self: ToolViewmodelController): Vector3?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local origin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector
	local target = self._deps.pile and self._deps.pile:resolveTarget(origin, direction)
	if target then
		return target.position
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { camera }
	local character = Players.LocalPlayer.Character
	if character then
		table.insert(exclude, character)
	end
	for _, name in ipairs({ "SFE_VFX", "SFE_ToolVisuals" }) do
		local folder = workspace:FindFirstChild(name)
		if folder then
			table.insert(exclude, folder)
		end
	end
	params.FilterDescendantsInstances = exclude
	local range = self._deps.config.interaction.defaultRangeStuds + 10
	local result = workspace:Raycast(origin, direction * range, params)
	return result and result.Position or nil
end

function ToolViewmodelController._actionOffset(self: ToolViewmodelController, now: number): CFrame
	local action = self._action
	local feel = self:_feelFor(self._toolId)
	local motion = self._deps.accessibility:motionScale()
	if action.kind == "none" then
		return CFrame.identity
	end
	local t = math.clamp((now - action.startedAt) / math.max(0.01, action.seconds), 0, 1)
	if action.kind == "raise" then
		if t >= 1 then
			self._action = { kind = "none", startedAt = now, from = nil, seconds = 0 }
		end
		local e = easeOutBack(t)
		return CFrame.new(0, -0.9 * (1 - e) * motion, 0.2 * (1 - e)) * CFrame.Angles(math.rad(-30 * (1 - e)), 0, 0)
	elseif action.kind == "anticipate" then
		local e = easeOutQuad(t)
		if t >= 1 then
			self._action = { kind = "thrust", startedAt = now, from = nil, seconds = feel.thrustSeconds or 0.11 }
		end
		return CFrame.new(0, 0.12 * e, 0.22 * e) * CFrame.Angles(math.rad(14 * e), 0, math.rad(4 * e))
	elseif action.kind == "thrust" then
		-- Forward and down toward the reticle; holds at full reach until the server answers.
		local e = easeOutQuad(t)
		local reach = (feel.thrustStuds or 1.7) * (0.6 + 0.4 * motion)
		local drop = (feel.thrustDropStuds or 0.55)
		return CFrame.new(0, -drop * e, -reach * e) * CFrame.Angles(math.rad(-22 * e), 0, math.rad(-6 * e))
	elseif action.kind == "return" then
		if t >= 1 then
			self._action = { kind = "none", startedAt = now, from = nil, seconds = 0 }
			return CFrame.identity
		end
		local from = action.from or CFrame.identity
		return from:Lerp(CFrame.identity, easeOutBack(t))
	elseif action.kind == "lit" then
		-- Raised and cocked back, ready to throw; the fuse burns at the tip.
		local e = easeOutQuad(t)
		return CFrame.new(0.05 * e, 0.22 * e, 0.12 * e) * CFrame.Angles(math.rad(18 * e), math.rad(-10 * e), 0)
	elseif action.kind == "thrown" then
		-- Arm whips forward, then the next stick rises into the hand from below.
		if t < 0.25 then
			local e = t / 0.25
			return CFrame.new(0, 0.1 * (1 - e), -0.9 * e) * CFrame.Angles(math.rad(-50 * e), 0, 0)
		end
		local e = easeOutBack((t - 0.25) / 0.75)
		if t >= 1 then
			self._action = { kind = "none", startedAt = now, from = nil, seconds = 0 }
		end
		return CFrame.new(0, -1.0 * (1 - e), 0.15 * (1 - e)) * CFrame.Angles(math.rad(-28 * (1 - e)), 0, 0)
	end
	return CFrame.identity
end

function ToolViewmodelController.step(self: ToolViewmodelController, dt: number)
	local model = self._model
	local camera = workspace.CurrentCamera
	if not model or not camera then
		return
	end
	local pose = POSES[self._toolId]
	if not pose then
		return
	end
	local now = os.clock()
	self._time += dt
	local feel = self._feel.viewmodel or {}
	local motion = self._deps.accessibility:motionScale()
	-- Walk bob from the character's ground speed; a small breath while standing.
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local velocity = if root then root.AssemblyLinearVelocity else Vector3.zero
	local walk = math.clamp(Vector3.new(velocity.X, 0, velocity.Z).Magnitude / 16, 0, 1)
	local amp = (feel.swayAmplitudeStuds or 0.035) * motion
	local hz = feel.bobHz or 1.9
	local phase = self._time * hz * math.pi * 2
	local bobX = math.sin(phase) * amp * (0.3 + 1.4 * walk)
	local bobY = -math.abs(math.cos(phase)) * amp * (0.25 + 1.6 * walk) + math.sin(self._time * 1.3) * amp * 0.25
	-- Look lag: a damped spring on the camera's turn, expressed as a small counter-rotation.
	local look = camera.CFrame.LookVector
	local prev = self._prevLook or look
	self._prevLook = look
	local rel = camera.CFrame:VectorToObjectSpace(prev)
	local maxLag = math.rad(feel.lagDegrees or 4) * motion
	local target = Vector2.new(math.clamp(rel.X * 6, -maxLag, maxLag), math.clamp(rel.Y * 6, -maxLag, maxLag))
	local spring = math.min(1, dt * (feel.lagSpringHz or 6))
	self._lag = self._lag:Lerp(target, spring)
	local lagRot = CFrame.Angles(-self._lag.Y, self._lag.X, self._lag.X * 0.5)
	-- Tool-specific live offsets.
	local live = CFrame.identity
	if self._toolId == "featherVac" and self._vacRunning then
		local vacFeel = self:_feelFor("featherVac")
		local jitter = (vacFeel.jitterStuds or 0.02) * motion
		live = CFrame.new(
			(math.random() * 2 - 1) * jitter,
			(math.random() * 2 - 1) * jitter,
			(vacFeel.recoilStuds or 0.12) * (0.7 + 0.3 * math.sin(self._time * 23))
		)
		self.stats.vacFrames += 1
		self:_stepStreaks(dt)
	end
	local action = self:_actionOffset(now)
	local orientation = pose.rotation or fromQuill(pose.quill :: Vector3, pose.spin or 0)
	model:PivotTo(camera.CFrame * CFrame.new(bobX, bobY, 0) * lagRot * pose.offset * live * action * orientation)
	if self._toolId == "confettiCharge" and self._action.kind == "lit" and self._fuseLight then
		self._fuseLight.Brightness = 1.2 + math.sin(now * 30) * 0.6
	end
end

-- ---------------------------------------------------------------------------------------------
-- Rake
-- ---------------------------------------------------------------------------------------------

function ToolViewmodelController._thrust(self: ToolViewmodelController)
	if self._toolId ~= "nestRake" or not self._model then
		return
	end
	local feel = self:_feelFor("nestRake")
	-- Anticipation first: a short draw back and up, then the forward thrust into the strike.
	self._action = { kind = "anticipate", startedAt = os.clock(), from = nil, seconds = feel.anticipateSeconds or 0.07 }
	self.stats.thrusts += 1
	self._deps.audio:play(Tokens.sound.rakeSwing, { pitchVariance = 0.08 })
end

function ToolViewmodelController._beginReturn(self: ToolViewmodelController)
	local now = os.clock()
	local feel = self:_feelFor("nestRake")
	local from = self:_actionOffset(now)
	self._action = { kind = "return", startedAt = now, from = from, seconds = feel.returnSeconds or 0.36 }
end

-- Impact at the server's strike point: rustle, puff, dust, a short-lived dent shadow, then the return.
function ToolViewmodelController._impact(self: ToolViewmodelController, hit: Vector3)
	local feel = self:_feelFor("nestRake")
	local surface = if self._deps.pile and self._deps.pile.surfaceHeightAt then self._deps.pile:surfaceHeightAt(hit.X, hit.Z) else hit.Y
	local point = Vector3.new(hit.X, math.max(hit.Y, surface or hit.Y), hit.Z)
	self._deps.vfx:burst("dust", point, 0.25)
	self._deps.vfx:burst("featherPuff", point + Vector3.new(0, 0.4, 0), 0.3)
	self._deps.audio:play(Tokens.sound.rakeImpact, { pitchVariance = 0.12 })
	-- Dent: a soft dark disc pressed into the coat that fades as the records settle.
	local dent = Instance.new("Part")
	dent.Name = "SFE_RakeDent"
	dent.Shape = Enum.PartType.Cylinder
	dent.Anchored = true
	dent.CanCollide = false
	dent.CanQuery = false
	dent.CanTouch = false
	dent.CastShadow = false
	dent.Material = Enum.Material.SmoothPlastic
	dent.Color = Tokens.color.shadow
	dent.Transparency = 0.55
	local radius = feel.dentRadiusStuds or 1.4
	dent.Size = Vector3.new(0.08, radius * 2, radius * 2)
	dent.CFrame = CFrame.new(point + Vector3.new(0, 0.06, 0)) * CFrame.Angles(0, 0, math.rad(90))
	local camera = workspace.CurrentCamera
	dent.Parent = camera
	local seconds = feel.dentSeconds or 0.22
	task.spawn(function()
		local elapsed = 0
		while elapsed < seconds * 3 and dent.Parent do
			elapsed += RunService.Heartbeat:Wait()
			local t = math.clamp(elapsed / (seconds * 3), 0, 1)
			dent.Transparency = 0.55 + 0.45 * t
			dent.Size = Vector3.new(0.08, radius * 2 * (1 + 0.3 * t), radius * 2 * (1 + 0.3 * t))
		end
		dent:Destroy()
	end)
	-- The return starts when the thrust reaches full extension, never before.
	local action = self._action
	local remaining = 0
	if action.kind == "anticipate" then
		remaining = math.max(0, action.startedAt + action.seconds - os.clock()) + (feel.thrustSeconds or 0.11)
	elseif action.kind == "thrust" then
		remaining = math.max(0, action.startedAt + action.seconds - os.clock())
	end
	if remaining > 0 then
		task.delay(remaining, function()
			if self._action.kind == "thrust" or self._action.kind == "anticipate" then
				self:_beginReturn()
			end
		end)
	else
		self:_beginReturn()
	end
end

-- ---------------------------------------------------------------------------------------------
-- Dynamite
-- ---------------------------------------------------------------------------------------------

function ToolViewmodelController._fusePart(self: ToolViewmodelController): BasePart?
	local model = self._model
	local pose = POSES[self._toolId]
	if not model or not pose or not pose.fuse then
		return nil
	end
	local part = model:FindFirstChild(pose.fuse, true)
	return if part and part:IsA("BasePart") then part else nil
end

function ToolViewmodelController._light(self: ToolViewmodelController)
	if self._toolId ~= "confettiCharge" or not self._model then
		return
	end
	local feel = self:_feelFor("confettiCharge")
	self._action = { kind = "lit", startedAt = os.clock(), from = nil, seconds = feel.lightSeconds or 0.28 }
	self.stats.lights += 1
	local tip = self:_fusePart()
	if tip and not self._fuseSparks then
		local sparks = Instance.new("ParticleEmitter")
		sparks.Name = "FuseSparks"
		sparks.Color = ColorSequence.new(Tokens.color.honey, Tokens.color.ember)
		sparks.LightEmission = 1
		sparks.Size = NumberSequence.new(0.09, 0.02)
		sparks.Lifetime = NumberRange.new(0.15, 0.35)
		sparks.Rate = 60
		sparks.Speed = NumberRange.new(1.5, 3.5)
		sparks.SpreadAngle = Vector2.new(70, 70)
		sparks.Parent = tip
		local smoke = Instance.new("ParticleEmitter")
		smoke.Name = "FuseSmoke"
		smoke.Color = ColorSequence.new(Color3.fromRGB(200, 196, 190))
		smoke.Transparency = NumberSequence.new(0.5, 1)
		smoke.Size = NumberSequence.new(0.08, 0.35)
		smoke.Lifetime = NumberRange.new(0.5, 0.9)
		smoke.Rate = 14
		smoke.Speed = NumberRange.new(0.4, 0.9)
		smoke.Acceleration = Vector3.new(0, 1.2, 0)
		smoke.Parent = tip
		local light = Instance.new("PointLight")
		light.Name = "FuseLight"
		light.Color = Tokens.color.honey
		light.Range = 5
		light.Brightness = 1.4
		light.Parent = tip
		self._fuseSparks = sparks
		self._fuseSmoke = smoke
		self._fuseLight = light
	end
	self._deps.audio:play(Tokens.sound.fuseLight, { pitchVariance = 0.05 })
	self._deps.audio:play(Tokens.sound.fuseHiss)
end

function ToolViewmodelController._extinguish(self: ToolViewmodelController)
	local this = self :: any
	for _, key in ipairs({ "_fuseSparks", "_fuseSmoke", "_fuseLight" }) do
		local instance = this[key]
		if instance then
			instance:Destroy()
			this[key] = nil
		end
	end
	if self._action.kind == "lit" then
		self._action = { kind = "return", startedAt = os.clock(), from = self:_actionOffset(os.clock()), seconds = 0.25 }
	end
end

function ToolViewmodelController._thrown(self: ToolViewmodelController)
	self:_extinguish()
	if self._toolId ~= "confettiCharge" then
		return
	end
	local feel = self:_feelFor("confettiCharge")
	local cooldown = self._deps.config.tools.confettiCharge.cooldownSeconds or 1.2
	self._action = { kind = "thrown", startedAt = os.clock(), from = nil, seconds = math.max(0.5, math.min(cooldown, 1.2)) }
	self.stats.throws += 1
	self._deps.audio:play(Tokens.sound.throw, { pitchVariance = 0.1 })
	-- The stick in hand is gone for the first part of the throw: hide, then the next one rises.
	local model = self._model
	if model then
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part.Name ~= "Origin" then
				part.LocalTransparencyModifier = 1
			end
		end
		task.delay((feel.lightSeconds or 0.28) * 0.6 + 0.2, function()
			if self._model == model then
				for _, part in ipairs(model:GetDescendants()) do
					if part:IsA("BasePart") then
						part.LocalTransparencyModifier = 0
					end
				end
			end
		end)
	end
end

-- Where a thrown stick leaves the hand (the fuse tip of the viewmodel), for the world projectile.
function ToolViewmodelController.muzzlePosition(self: ToolViewmodelController): Vector3?
	local model = self._model
	if not model then
		return nil
	end
	return model:GetPivot().Position
end

-- ---------------------------------------------------------------------------------------------
-- Vacuum
-- ---------------------------------------------------------------------------------------------

function ToolViewmodelController.nozzlePosition(self: ToolViewmodelController): Vector3?
	local model = self._model
	local pose = POSES[self._toolId]
	if not model or not pose or not pose.nozzle then
		return nil
	end
	local nozzle = model:FindFirstChild(pose.nozzle, true)
	if nozzle and nozzle:IsA("BasePart") then
		-- The intake mouth: the model's -X axis is the nozzle direction.
		local forward = -model:GetPivot().RightVector
		return nozzle.Position + forward * (nozzle.Size.Magnitude * 0.3)
	end
	return model:GetPivot().Position
end

function ToolViewmodelController._setVacRunning(self: ToolViewmodelController, running: boolean)
	if running == self._vacRunning then
		return
	end
	self._vacRunning = running
	local model = self._model
	if running and model and self._toolId == "featherVac" then
		local pose = POSES.featherVac
		local nozzle = model:FindFirstChild(pose.nozzle :: string, true)
		if nozzle and nozzle:IsA("BasePart") then
			local emitter = Instance.new("ParticleEmitter")
			emitter.Name = "Intake"
			emitter.Color = ColorSequence.new(Tokens.color.featherWhite, Tokens.color.sky)
			emitter.Transparency = NumberSequence.new(0.2, 1)
			emitter.Size = NumberSequence.new(0.3, 0.05)
			emitter.Lifetime = NumberRange.new(0.18, 0.3)
			emitter.Rate = 40
			emitter.Speed = NumberRange.new(4, 7)
			emitter.SpreadAngle = Vector2.new(25, 25)
			emitter.EmissionDirection = Enum.NormalId.Left
			emitter.Drag = 4
			emitter.Parent = nozzle
			self._vacEmitter = emitter
			-- One managed loop for as long as the vac is sucking: `loop` refuses a second copy on the
			-- same nozzle, fades in, and `stopLoop` fades out. Volume and speed come from config.
			self._vacLoop = self._deps.audio:loop(Tokens.sound.vacMotor, nozzle)
			self._deps.audio:play(Tokens.sound.vacSuck, { pitchVariance = 0.04 })
		end
		if not self._streakFolder then
			local folder = Instance.new("Folder")
			folder.Name = "SFE_VacStreaks"
			folder.Parent = workspace.CurrentCamera
			self._streakFolder = folder
		end
	else
		if self._vacEmitter then
			self._vacEmitter:Destroy()
			self._vacEmitter = nil
		end
		if self._vacLoop then
			self._deps.audio:stopLoop(self._vacLoop)
			self._vacLoop = nil
		end
		for _, streak in ipairs(self._streaks) do
			streak.part:Destroy()
		end
		table.clear(self._streaks)
	end
end

-- Wind streaks: thin white ribbons that spawn around the reticle's aim point and curve into the
-- nozzle, respawning as they arrive, so the pull path is always visible while the vac runs.
function ToolViewmodelController._stepStreaks(self: ToolViewmodelController, dt: number)
	local folder = self._streakFolder
	local nozzle = self:nozzlePosition()
	if not folder or not nozzle then
		return
	end
	local feel = self:_feelFor("featherVac")
	local count = feel.streakCount or 6
	local seconds = feel.streakSeconds or 0.22
	local hit = self:reticleHit()
	self._aimHit = hit or self._aimHit
	local aim = self._aimHit
	if not aim then
		return
	end
	while #self._streaks < count do
		local part = Instance.new("Part")
		part.Name = "Streak"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = Tokens.color.featherWhite
		part.Transparency = 0.55
		part.Size = Vector3.new(0.06, 0.06, 0.6)
		part.Parent = folder
		local angle = math.random() * math.pi * 2
		local radius = 0.4 + math.random() * 1.6
		table.insert(self._streaks, {
			part = part,
			start = aim + Vector3.new(math.cos(angle) * radius, 0.2 + math.random() * 0.6, math.sin(angle) * radius),
			life = math.random() * seconds,
			seconds = seconds * (0.8 + math.random() * 0.5),
			side = if math.random() < 0.5 then -1 else 1,
		})
	end
	for _, streak in ipairs(self._streaks) do
		streak.life += dt
		local t = streak.life / streak.seconds
		if t >= 1 then
			local angle = math.random() * math.pi * 2
			local radius = 0.4 + math.random() * 1.6
			streak.start = aim + Vector3.new(math.cos(angle) * radius, 0.2 + math.random() * 0.6, math.sin(angle) * radius)
			streak.life = 0
			streak.seconds = seconds * (0.8 + math.random() * 0.5)
			t = 0
		end
		local e = t * t
		local control = streak.start:Lerp(nozzle, 0.5)
			+ Vector3.new(0, 0.8, 0)
			+ (nozzle - streak.start):Cross(Vector3.yAxis).Unit * streak.side * 0.5
		local point = streak.start:Lerp(control, e):Lerp(control:Lerp(nozzle, e), e)
		local ahead =
			streak.start:Lerp(control, math.min(1, e + 0.05)):Lerp(control:Lerp(nozzle, math.min(1, e + 0.05)), math.min(1, e + 0.05))
		local length = 0.3 + 0.9 * (1 - t)
		if (ahead - point).Magnitude > 1e-4 then
			streak.part.CFrame = CFrame.lookAt(point, ahead)
		end
		streak.part.Size = Vector3.new(0.05, 0.05, length)
		streak.part.Transparency = 0.35 + 0.6 * t
	end
end

function ToolViewmodelController.status(self: ToolViewmodelController): { [string]: any }
	return {
		toolId = self._toolId,
		active = self._active,
		hasModel = self._model ~= nil,
		modelName = self._model and self._model.Name or nil,
		action = self._action.kind,
		vacRunning = self._vacRunning,
		streaks = #self._streaks,
		stats = table.clone(self.stats),
	}
end

function ToolViewmodelController.destroy(self: ToolViewmodelController)
	self:setActive(false)
	self._trove:destroy()
end

ToolViewmodelController.POSES = POSES

return ToolViewmodelController
