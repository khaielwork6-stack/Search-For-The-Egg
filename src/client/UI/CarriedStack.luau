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
		_count: number,
		_tier: string,
		_visible: boolean,
		_hiddenByUi: boolean,
		_scale: UIScale,
		_bottomOffset: () -> number,
		_connections: { RBXScriptConnection },
		_bobPhase: number,
		_bob: number,
		_sway: number,
		_lastYaw: number?,
		_bound: boolean,
	},
	CarriedStack
))

local TEMPLATE_SIZE = Vector3.new(0.54, 1.44, 0.13)
-- Camera framing (FOV 38, aspect 0.66): about 2.4 studs of half-height and 3.6 of half-width at the
-- bundle's depth, so a twelve-feather fan (quills ~2.4 studs) from the base below-right stays
-- inside the frame with margin for bob, sway and the pick squash.
local REST_CAMERA = CFrame.lookAt(Vector3.new(0, 0.2, 7.0), Vector3.new(0, 0, 0))
local RENDER_NAME = "SFE_CarriedStackSway"

local function makeFeather(index: number, palette: { { number } }): BasePart
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
	return part
end

-- Rest pose of the k-th feather (of `count`): every stem meets at the bundle's base (lower right of
-- the viewport); heads fan up and to the left across a fixed arc, each a touch further back so they
-- read as neatly overlapping layers. The arc is the same for any count, so twelve feathers overlap
-- more tightly rather than spreading wider, and no head ever reaches the frame edge.
local function restPose(index: number, count: number): CFrame
	local h = function(salt: number)
		return FeatherLayout.hash(index, 11, salt)
	end
	local base = Vector3.new(0.4, -1.5, 0.2)
	local spread = math.rad(64)
	local t = if count <= 1 then 0.5 else (index - 1) / (count - 1)
	local fan = -spread / 2 + spread * t + (h(1) - 0.5) * math.rad(3)
	local lean = math.rad(-38) -- fan centre leans up-left, away from the crosshair
	local roll = (h(2) - 0.5) * math.rad(12)
	local depth = (0.5 - t) * 0.4 + (h(3) - 0.5) * 0.06
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
	viewport.Ambient = Color3.fromRGB(200, 196, 188)
	viewport.LightColor = Color3.fromRGB(255, 250, 240)
	viewport.LightDirection = Vector3.new(-0.3, -1, -0.6)
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
		_count = 0,
		_tier = "empty",
		_visible = false,
		_hiddenByUi = false,
		_scale = scale,
		_bottomOffset = bottomOffset,
		_connections = {},
		_bobPhase = 0,
		_bob = 0,
		_sway = 0,
		_lastYaw = nil,
		_bound = false,
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

-- Mirrors the authoritative bag: the displayed count follows carried / capacity (logarithmic when
-- infinite), capped at `maxVisibleFeathers`; the HUD counter shows the true amount.
function CarriedStack.setBag(self: CarriedStack, carried: number, capacity: number, infinite: boolean, animate: boolean?)
	local count = CarriedDisplay.count(self._config, carried, capacity, infinite)
	self._tier = CarriedDisplay.tier(count, self._config.hud.carriedStack.maxVisibleFeathers)
	self:_setCount(count, animate == true)
end

function CarriedStack._setCount(self: CarriedStack, count: number, animate: boolean)
	local palette = self._config.pile.visual.palette
	local carried = self._config.hud.carriedStack
	local motion = self._motion()
	local previous = #self._feathers
	while #self._feathers > count do
		local part = table.remove(self._feathers) :: BasePart
		part:Destroy()
	end
	for index = #self._feathers + 1, count do
		local part = makeFeather(index, palette)
		part.Parent = self._world
		table.insert(self._feathers, part)
	end
	-- Re-fan the whole bundle so stems stay gathered as it grows; new feathers settle in from above.
	local seconds = Motion.clampSeconds(carried.bounceSeconds, motion)
	for index, part in ipairs(self._feathers) do
		local rest = restPose(index, count)
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

function CarriedStack.clear(self: CarriedStack)
	self._tier = "empty"
	self:_setCount(0, false)
end

-- Walking bob and camera sway, eased back to rest. Bound only while visible.
function CarriedStack._bind(self: CarriedStack)
	if self._bound then
		return
	end
	self._bound = true
	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 5, function(dt)
		local carried = self._config.hud.carriedStack
		local settings = self._motion()
		local amplitude = if settings.reducedMotion then 0 else carried.bobAmplitudeStuds
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local moving = humanoid and humanoid.MoveDirection.Magnitude > 0.1
		local ease = math.clamp(dt / math.max(0.016, carried.easeSeconds), 0, 1)
		self._bobPhase += dt * carried.bobHz * math.pi * 2
		local bobTarget = if moving then amplitude else 0
		self._bob += (bobTarget - self._bob) * ease
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
		self._sway += (swayTarget - self._sway) * ease
		local bobY = math.sin(self._bobPhase) * self._bob
		local bobX = math.cos(self._bobPhase * 0.5) * self._bob * 0.6
		self._camera.CFrame = REST_CAMERA * CFrame.new(-bobX, -bobY, 0) * CFrame.Angles(0, self._sway, self._sway * 0.35)
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
