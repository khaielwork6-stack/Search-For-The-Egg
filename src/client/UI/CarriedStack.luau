--!strict
-- Held-feather viewmodel (owner requirement; ASSUMED A-HUD-04): a handless first-person bundle in the
-- lower-right corner of the screen - stems gathered to one point, heads fanned upward and inward so
-- nothing crosses the crosshair. It grows one feather at a time with bag fullness up to
-- `maxVisibleFeathers` (logarithmically for an infinite bag; the bag counter shows the true count),
-- settles when a feather is added, bobs gently while walking, and sways a few degrees with camera
-- turns, always easing back to rest. Cosmetic only: the server owns the real bag count. Rendered in a
-- ViewportFrame (no world instances, no hands), hidden behind blocking menus, sized per layout class
-- and kept clear of the mobile jump button.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Motion = require(Shared.Design.Motion)
local AssetManifest = require(Shared.Design.AssetManifest)
local FeatherLayout = require(Shared.Domain.FeatherLayout)
local CarriedDisplay = require(Shared.Domain.CarriedDisplay)
local SafeArea = require(script.Parent.SafeArea)

local CarriedStack = {}
CarriedStack.__index = CarriedStack

export type CarriedStack = typeof(setmetatable(
	{} :: {
		frame: Frame,
		viewport: ViewportFrame,
		_camera: Camera,
		_world: Model,
		_config: { [string]: any },
		_motion: () -> Motion.MotionSettings,
		_feathers: { BasePart },
		_rainbowParts: { [BasePart]: number },
		_count: number,
		_rainbowCount: number,
		_tier: string,
		_visible: boolean,
		_hiddenByUi: boolean,
		_scale: UIScale,
		_bottomOffset: () -> number,
		_connections: { RBXScriptConnection },
		_bobPhase: number,
		_bob: number,
		_sway: number,
		_swayVelocity: number,
		_lastYaw: number?,
		_bound: boolean,
		_kick: number,
		_kickVelocity: number,
		_lurch: Vector3,
		_lurchVelocity: Vector3,
		_lastRootVelocity: Vector3?,
		_topTilt: number,
		_topTiltVelocity: number,
		_landings: number,
	},
	CarriedStack
))

local TEMPLATE_SIZE = Vector3.new(0.54, 1.44, 0.13)
-- Camera framing (FOV 38, aspect 0.66): about 2.4 studs of half-height and 3.6 of half-width at the
-- bundle's depth, so a twelve-feather fan (quills ~2.4 studs) from the base below-right stays
-- inside the frame with margin for bob, sway and the pick squash.
local REST_CAMERA = CFrame.lookAt(Vector3.new(0, 0.2, 7.0), Vector3.new(0, 0, 0))
local RENDER_NAME = "SFE_CarriedStackSway"

-- Rainbow dressing, the same recipe the pile uses: an emissive surface and a few motes, and no light
-- source at all. Nothing here can tint a neighbouring feather, and inside a ViewportFrame it could
-- not reach the world even if it tried.
local function dressRainbow(part: BasePart, index: number)
	part.Material = Enum.Material.Neon
	local motes = Instance.new("ParticleEmitter")
	motes.Name = "RainbowMotes"
	motes.Rate = 4
	motes.Lifetime = NumberRange.new(0.6, 1.1)
	motes.Speed = NumberRange.new(0.2, 0.6)
	motes.Size = NumberSequence.new(0.1, 0)
	motes.Transparency = NumberSequence.new(0.25, 1)
	motes.LightEmission = 0.8
	motes.Color = ColorSequence.new(Color3.fromRGB(255, 240, 255))
	motes.Parent = part
	local _ = index
end

local function makeFeather(index: number, palette: { { number } }, rainbow: boolean?): BasePart
	local template = AssetManifest.model("feather")
	local part: BasePart
	if template and template:IsA("BasePart") then
		part = template:Clone() :: BasePart
	else
		local fallback = Instance.new("Part")
		fallback.Material = Enum.Material.SmoothPlastic
		part = fallback
	end
	part.Name = "Carried" .. index
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false
	local h = function(salt: number)
		return FeatherLayout.hash(index, 7, salt)
	end
	local scale = 0.94 + h(1) * 0.12
	part.Size = Vector3.new(TEMPLATE_SIZE.X * 1.75 * scale, TEMPLATE_SIZE.Y * 1.65 * scale, TEMPLATE_SIZE.Z)
	local t = h(2)
	local scaled = math.clamp(t, 0, 0.9999) * (#palette - 1)
	local i = math.floor(scaled) + 1
	local a, b = palette[i], palette[math.min(#palette, i + 1)]
	part.Color = Color3.fromRGB(a[1], a[2], a[3]):Lerp(Color3.fromRGB(b[1], b[2], b[3]), scaled - (i - 1))
	if rainbow then
		dressRainbow(part, index)
	end
	return part
end

-- Rest pose of the k-th feather (of `count`). A single flat fan reads as a handful of loose quills
-- once there are more than about eight of them, so the bundle is built as three overlapping depth
-- layers instead: stems still gather to one point at the lower right, but each layer sits a little
-- further back, a little higher and fans a little wider, so the front layer reads as the near face
-- of a thick bunch rather than a row of separate feathers. The arc never widens with count - more
-- feathers overlap more tightly - so a full bundle cannot reach the frame edge.
local LAYERS = 3

local function restPose(index: number, count: number, geometry: { [string]: any }): CFrame
	local h = function(salt: number)
		return FeatherLayout.hash(index, 11, salt)
	end
	local perLayer = math.max(1, math.ceil(count / LAYERS))
	local layer = math.min(LAYERS, math.floor((index - 1) / perLayer) + 1)
	local within = (index - 1) % perLayer
	local inLayer = math.min(perLayer, count - (layer - 1) * perLayer)
	local t = if inLayer <= 1 then 0.5 else within / (inLayer - 1)
	-- Back layers fan wider and ride higher, so they fill the gaps the front layer leaves.
	local layerT = (layer - 1) / math.max(1, LAYERS - 1)
	local spread = math.rad(geometry.spreadDegrees) * (1 + layerT * geometry.layerSpreadGain)
	local base = Vector3.new(geometry.baseX, geometry.baseY + layerT * geometry.layerRiseStuds, geometry.baseZ)
	local fan = -spread / 2 + spread * t + (h(1) - 0.5) * math.rad(3)
	local lean = math.rad(geometry.leanDegrees) -- fan centre leans up-left, away from the crosshair
	local roll = (h(2) - 0.5) * math.rad(12)
	local depth = -layerT * geometry.layerDepthStuds + (0.5 - t) * 0.22 + (h(3) - 0.5) * 0.05
	-- Quill (+Y) points from the base up-left; rotate about the view axis to fan.
	local frame = CFrame.new(base + Vector3.new(0, 0, depth)) * CFrame.Angles(0, 0, lean + fan) * CFrame.Angles(math.rad(10), 0, roll)
	return frame * CFrame.new(0, TEMPLATE_SIZE.Y * 1.65 * 0.5, 0) -- centre the mesh half a length up the quill
end

function CarriedStack.new(
	gui: Instance,
	config: { [string]: any },
	motion: () -> Motion.MotionSettings,
	bottomOffset: () -> number
): CarriedStack
	local carried = config.hud.carriedStack
	local frame = Instance.new("Frame")
	frame.Name = "CarriedStack"
	frame.BackgroundTransparency = 1
	frame.AnchorPoint = Vector2.new(carried.anchorX, 1)
	frame.ZIndex = 2
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Viewport"
	viewport.BackgroundTransparency = 1
	viewport.Size = UDim2.fromScale(1, 1)
	-- Lit from the upper left with a darker, warmer ambient than the world, so the bundle's feathers
	-- carry shaded sides and read as an object in the hand against the white mound behind them.
	viewport.Ambient = Color3.fromRGB(176, 160, 138)
	viewport.LightColor = Color3.fromRGB(255, 244, 222)
	viewport.LightDirection = Vector3.new(-0.55, -0.75, 0.4)
	viewport.ZIndex = 3
	-- A soft warm-dark shade under the bundle: the one thing that separates it from the pile when
	-- both are ivory. Ellipse, faded at its ends, no image.
	local shade = Instance.new("Frame")
	shade.Name = "Shade"
	shade.AnchorPoint = Vector2.new(0.5, 0.5)
	shade.Position = UDim2.fromScale(0.62, 0.66)
	shade.Size = UDim2.fromScale(0.8, 0.5)
	shade.BackgroundColor3 = Color3.fromRGB(64, 42, 24)
	shade.BackgroundTransparency = 0.8
	shade.BorderSizePixel = 0
	shade.ZIndex = 2
	local shadeCorner = Instance.new("UICorner")
	shadeCorner.CornerRadius = UDim.new(1, 0)
	shadeCorner.Parent = shade
	local shadeFade = Instance.new("UIGradient")
	shadeFade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, 0.2),
		NumberSequenceKeypoint.new(0.7, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	shadeFade.Parent = shade
	shade.Parent = frame
	viewport.Parent = frame
	local camera = Instance.new("Camera")
	camera.FieldOfView = 38
	camera.CFrame = REST_CAMERA
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	local world = Instance.new("Model")
	world.Name = "Feathers"
	world.Parent = viewport
	local scale = Instance.new("UIScale")
	scale.Parent = frame
	frame.Parent = gui

	local self = setmetatable({
		frame = frame,
		viewport = viewport,
		_camera = camera,
		_world = world,
		_config = config,
		_motion = motion,
		_feathers = {},
		_rainbowParts = {},
		_count = 0,
		_rainbowCount = 0,
		_tier = "empty",
		_visible = false,
		_hiddenByUi = false,
		_scale = scale,
		_bottomOffset = bottomOffset,
		_connections = {},
		_bobPhase = 0,
		_bob = 0,
		_sway = 0,
		_swayVelocity = 0,
		_lastYaw = nil,
		_bound = false,
		_kick = 0,
		_kickVelocity = 0,
		_lurch = Vector3.zero,
		_lurchVelocity = Vector3.zero,
		_lastRootVelocity = nil,
		_topTilt = 0,
		_topTiltVelocity = 0,
		_landings = 0,
	}, CarriedStack)
	self:_layout()
	table.insert(
		self._connections,
		(gui :: GuiBase2d):GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			self:_layout()
		end)
	)
	self:_applyVisibility()
	return self
end

function CarriedStack._layout(self: CarriedStack)
	local carried = self._config.hud.carriedStack
	local gui = self.frame.Parent :: GuiBase2d
	local class = SafeArea.layoutClass(gui.AbsoluteSize.X, gui.AbsoluteSize.Y)
	local mobile = class ~= "desktop"
	-- Size follows the viewport (a fraction of its width, clamped) so the whole bundle stays inside
	-- the bottom-right safe area on every screen; the frame never extends past the gui bounds.
	local factor = SafeArea.scaleOf(self.frame)
	local width = math.clamp(gui.AbsoluteSize.X * carried.widthFraction / factor, carried.minWidthPx, carried.maxWidthPx)
	local bottom = if mobile then carried.bottomOffsetPxMobile else carried.bottomOffsetPxDesktop
	-- The gui already excludes the core UI safe insets; never let the frame outgrow what is left of
	-- the screen beside and above its offsets on a tiny viewport.
	width = math.max(
		1,
		math.min(width, (gui.AbsoluteSize.X / factor) - carried.rightOffsetPx, ((gui.AbsoluteSize.Y / factor) - bottom) / carried.aspect)
	)
	local height = math.floor(width * carried.aspect)
	self.frame.Size = UDim2.fromOffset(math.floor(width), height)
	self.frame.Position = UDim2.new(carried.anchorX, -carried.rightOffsetPx, 1, -bottom)
end

-- Visible feather count for a bag (pure model in Shared.Domain.CarriedDisplay).
function CarriedStack.countFor(config: { [string]: any }, carried: number, capacity: number, infinite: boolean): number
	return CarriedDisplay.count(config, carried, capacity, infinite)
end

-- Mirrors the authoritative bag, in size and in composition: the displayed count follows carried /
-- capacity (logarithmic when infinite) capped at `maxVisibleFeathers`, and the Rainbow Feathers the
-- player is actually carrying are shown as rainbow feathers in the bundle. The HUD counter shows the
-- true amount.
function CarriedStack.setBag(self: CarriedStack, standard: number, rainbow: number, capacity: number, infinite: boolean, animate: boolean?)
	local count, rainbowCount = CarriedDisplay.split(self._config, standard, rainbow, capacity, infinite)
	self._tier = CarriedDisplay.tier(count, self._config.hud.carriedStack.maxVisibleFeathers)
	self:_setCount(count, animate == true, rainbowCount)
end

function CarriedStack._setCount(self: CarriedStack, count: number, animate: boolean, rainbowCount: number?)
	local palette = self._config.pile.visual.palette
	local carried = self._config.hud.carriedStack
	local motion = self._motion()
	local previous = #self._feathers
	local rainbowWanted = math.clamp(rainbowCount or 0, 0, count)
	-- Rainbow feathers sit at the front of the bundle (lowest indices are the near layer) so they are
	-- never buried behind ordinary ones. A change in composition rebuilds only the parts whose kind
	-- changed, not the whole bundle.
	local needRebuild = rainbowWanted ~= self._rainbowCount
	if needRebuild then
		for _, part in ipairs(self._feathers) do
			part:Destroy()
		end
		table.clear(self._feathers)
		table.clear(self._rainbowParts)
		previous = 0
	end
	while #self._feathers > count do
		local part = table.remove(self._feathers) :: BasePart
		self._rainbowParts[part] = nil
		part:Destroy()
	end
	for index = #self._feathers + 1, count do
		local isRainbow = index <= rainbowWanted
		local part = makeFeather(index, palette, isRainbow)
		part.Parent = self._world
		table.insert(self._feathers, part)
		if isRainbow then
			self._rainbowParts[part] = FeatherLayout.hash(index, 23, 5)
		end
	end
	self._rainbowCount = rainbowWanted
	-- Re-fan the whole bundle so stems stay gathered as it grows; new feathers settle in from above.
	local seconds = Motion.clampSeconds(carried.bounceSeconds, motion)
	for index, part in ipairs(self._feathers) do
		local rest = restPose(index, count, carried.bundle)
		if animate and index > previous then
			part.CFrame = rest * CFrame.new(0, carried.bounceStuds * 3, 0)
			TweenService:Create(part, TweenInfo.new(seconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = rest }):Play()
		elseif animate then
			TweenService:Create(part, TweenInfo.new(seconds * 0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = rest })
				:Play()
		else
			part.CFrame = rest
		end
	end
	if animate and count > self._count then
		local squash = Motion.clampSeconds(carried.bounceSeconds * 0.6, motion)
		self._scale.Scale = 1.06
		TweenService:Create(self._scale, TweenInfo.new(squash, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
	self._count = count
end

-- A pick landed: a small settle even when the tier did not change.
function CarriedStack.pulse(self: CarriedStack)
	local carried = self._config.hud.carriedStack
	local squash = Motion.clampSeconds(carried.bounceSeconds * 0.5, self._motion())
	self._scale.Scale = 1.05
	TweenService:Create(self._scale, TweenInfo.new(squash, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- A feather has just arrived: the bundle takes the weight (compresses, springs back) and the top
-- feather tips by a small deterministic amount before settling. Spring state, not a tween, so ten
-- fast landings add up to a rhythm and never restart or drift: every spring is clamped.
function CarriedStack.land(self: CarriedStack, squashScale: number, tiltDegrees: number)
	local settings = self._motion()
	local scale = if settings.reducedMotion then settings.reducedMotionScale else 1
	self._landings += 1
	self._kickVelocity = math.clamp(self._kickVelocity - (squashScale - 1) * 26 * scale, -0.9, 0.9)
	local sign = if FeatherLayout.hash(self._landings, 7, 3) > 0.5 then 1 else -1
	self._topTiltVelocity = math.clamp(self._topTiltVelocity + sign * math.rad(tiltDegrees) * 18 * scale, -2.5, 2.5)
end

-- Emptying the bundle. A sale or a deposit should look like the feathers leaving, so `animate` hands
-- the current parts to a short fly-out (up and away towards the crate, shrinking) and detaches them
-- from the bundle immediately, so a pick landing during the animation builds a fresh bundle rather
-- than fighting the one on its way out.
function CarriedStack.clear(self: CarriedStack, animate: boolean?)
	self._tier = "empty"
	if not animate or #self._feathers == 0 then
		self:_setCount(0, false, 0)
		return
	end
	local carried = self._config.hud.carriedStack
	local leaving = self._feathers
	self._feathers = {}
	self._rainbowParts = {}
	self._count = 0
	self._rainbowCount = 0
	local seconds = Motion.clampSeconds(carried.depositSeconds, self._motion())
	for index, part in ipairs(leaving) do
		local away = part.CFrame * CFrame.new(carried.depositDriftStuds, carried.depositRiseStuds, 0)
		local delay = (index - 1) * carried.depositStaggerSeconds
		task.delay(delay, function()
			if not part.Parent then
				return
			end
			local info = TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			TweenService:Create(part, info, { CFrame = away, Size = part.Size * 0.2, Transparency = 1 }):Play()
			task.delay(seconds, function()
				part:Destroy()
			end)
		end)
	end
end

-- Walking bob and camera sway, eased back to rest. Bound only while visible.
function CarriedStack._bind(self: CarriedStack)
	if self._bound then
		return
	end
	self._bound = true
	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 5, function(dt)
		dt = math.min(dt, 1 / 20)
		local carried = self._config.hud.carriedStack
		local settings = self._motion()
		local amplitude = if settings.reducedMotion then 0 else carried.bobAmplitudeStuds
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local moving = humanoid and humanoid.MoveDirection.Magnitude > 0.1
		local ease = math.clamp(dt / math.max(0.016, carried.easeSeconds), 0, 1)
		-- One critically damped spring for everything that reacts: x'' = -k x - c x'.
		local function spring(value: number, velocity: number, target: number, stiffness: number): (number, number)
			local damping = 2 * math.sqrt(stiffness)
			velocity += (-stiffness * (value - target) - damping * velocity) * dt
			return value + velocity * dt, velocity
		end
		-- Walking bob: speed-scaled phase, amplitude eased in and out.
		local speed = if root then Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude else 0
		self._bobPhase += dt * carried.bobHz * math.pi * 2 * math.clamp(speed / 16, 0.6, 1.3)
		local bobTarget = if moving then amplitude else 0
		self._bob += (bobTarget - self._bob) * ease
		-- Camera-turn sway, sprung rather than eased, clamped to swayDegrees.
		local camera = workspace.CurrentCamera
		local yaw = if camera then math.atan2(-camera.CFrame.LookVector.X, -camera.CFrame.LookVector.Z) else 0
		local delta = 0
		if self._lastYaw then
			delta = yaw - self._lastYaw
			if delta > math.pi then
				delta -= math.pi * 2
			elseif delta < -math.pi then
				delta += math.pi * 2
			end
		end
		self._lastYaw = yaw
		local swayLimit = if settings.reducedMotion then 0 else math.rad(carried.swayDegrees)
		local swayTarget = math.clamp(-delta / math.max(0.001, dt) * 0.02, -swayLimit, swayLimit)
		self._sway, self._swayVelocity = spring(self._sway, self._swayVelocity, swayTarget, 140)
		self._sway = math.clamp(self._sway, -swayLimit, swayLimit)
		-- Acceleration: a change in the character's velocity lags the bundle the other way, then it
		-- springs back. Clamped to a few hundredths of a stud so sprinting never throws it about.
		local rootVelocity = if root then root.AssemblyLinearVelocity else Vector3.zero
		if self._lastRootVelocity and not settings.reducedMotion then
			local accel = (rootVelocity - self._lastRootVelocity) / math.max(0.008, dt)
			local lurchKick = Vector3.new(-accel.X, -accel.Y * 0.5, -accel.Z) * 0.00035
			self._lurchVelocity += lurchKick
		end
		self._lastRootVelocity = rootVelocity
		local lurchDamping = 2 * math.sqrt(110)
		self._lurchVelocity += (-110 * self._lurch - lurchDamping * self._lurchVelocity) * dt
		self._lurch += self._lurchVelocity * dt
		if self._lurch.Magnitude > 0.07 then
			self._lurch = self._lurch.Unit * 0.07
		end
		-- Landing compression and the top feather's tip.
		self._kick, self._kickVelocity = spring(self._kick, self._kickVelocity, 0, 260)
		self._kick = math.clamp(self._kick, -0.12, 0.12)
		self._topTilt, self._topTiltVelocity = spring(self._topTilt, self._topTiltVelocity, 0, 120)
		self._topTilt = math.clamp(self._topTilt, -math.rad(14), math.rad(14))
		local top = self._feathers[#self._feathers]
		if top then
			local rest = restPose(#self._feathers, #self._feathers, carried.bundle)
			top.CFrame = rest * CFrame.Angles(0, 0, self._topTilt)
		end
		-- Rainbow hue flows on the bundle's own parts only. Desaturated like the pile's records rather
		-- than raw neon, and no light anywhere: the ordinary feathers beside them keep their colour.
		if next(self._rainbowParts) ~= nil then
			local clock = os.clock() * carried.rainbowHueRate
			for part, phase in pairs(self._rainbowParts) do
				if part.Parent then
					part.Color = Color3.fromHSV((clock + phase) % 1, carried.rainbowSaturation, 1)
				else
					self._rainbowParts[part] = nil
				end
			end
		end
		-- Idle breathing: a barely-there rise and fall so the bundle is never a still picture.
		local breath = if settings.reducedMotion then 0 else math.sin(os.clock() * 1.1) * 0.012
		local bobY = math.sin(self._bobPhase) * self._bob + breath
		local bobX = math.cos(self._bobPhase * 0.5) * self._bob * 0.6
		local kickZ = self._kick * 1.6 -- compression reads as the bundle pushing back from the eye
		self._camera.CFrame = REST_CAMERA
			* CFrame.new(-bobX - self._lurch.X, -bobY - self._lurch.Y - self._kick * 0.4, -kickZ)
			* CFrame.Angles(0, self._sway, self._sway * 0.35 + self._kick * 0.6)
	end)
end

function CarriedStack._unbind(self: CarriedStack)
	if self._bound then
		self._bound = false
		RunService:UnbindFromRenderStep(RENDER_NAME)
	end
end

-- Gameplay visibility (in a searching round) and UI suppression (menus, results) are separate gates.
function CarriedStack.setVisible(self: CarriedStack, visible: boolean)
	self._visible = visible
	self:_applyVisibility()
end

function CarriedStack.setHiddenByUi(self: CarriedStack, hidden: boolean)
	self._hiddenByUi = hidden
	self:_applyVisibility()
end

function CarriedStack._applyVisibility(self: CarriedStack)
	local shown = self._visible and not self._hiddenByUi
	self.frame.Visible = shown
	if shown then
		self:_bind()
	else
		self:_unbind()
	end
end

function CarriedStack.count(self: CarriedStack): number
	return self._count
end

function CarriedStack.tier(self: CarriedStack): string
	return self._tier
end

-- Screen-space point of the bundle's base (for the flying-feather destination).
function CarriedStack.screenCentre(self: CarriedStack): Vector2
	return self.frame.AbsolutePosition + Vector2.new(self.frame.AbsoluteSize.X * 0.72, self.frame.AbsoluteSize.Y * 0.8)
end

function CarriedStack.destroy(self: CarriedStack)
	self:_unbind()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self.frame:Destroy()
end

return CarriedStack
