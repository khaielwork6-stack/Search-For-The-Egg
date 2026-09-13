--!strict
-- Carried feather stack (owner requirement; ASSUMED A-HUD-04): a small, unsupported pile of feathers
-- near the bottom of the screen that grows with bag fullness so the player reads "I am piling these
-- up" - with no hands, arms, gloves, or tools anywhere. Cosmetic only: the server owns the real bag
-- count; this just mirrors it in tiers (empty/low/medium/high/full) so a full bag never means one
-- rendered feather per inventory unit. Rendered in a ViewportFrame (no world instances), positioned
-- below the reticle and above the hotbar, sized per layout class so it never covers the mobile controls.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Motion = require(Shared.Design.Motion)
local AssetManifest = require(Shared.Design.AssetManifest)
local FeatherLayout = require(Shared.Domain.FeatherLayout)
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
	},
	CarriedStack
))

local TEMPLATE_SIZE = Vector3.new(0.54, 1.44, 0.13)

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
	local scale = 0.9 + h(1) * 0.25
	part.Size = Vector3.new(TEMPLATE_SIZE.X * 2.2 * scale, TEMPLATE_SIZE.Y * 1.9 * scale, TEMPLATE_SIZE.Z)
	local t = h(2)
	local scaled = math.clamp(t, 0, 0.9999) * (#palette - 1)
	local i = math.floor(scaled) + 1
	local a, b = palette[i], palette[math.min(#palette, i + 1)]
	part.Color = Color3.fromRGB(a[1], a[2], a[3]):Lerp(Color3.fromRGB(b[1], b[2], b[3]), scaled - (i - 1))
	return part
end

-- Rest pose of the k-th carried feather: layered, fanned, slightly offset (controlled variation).
local function restPose(index: number): CFrame
	local h = function(salt: number)
		return FeatherLayout.hash(index, 11, salt)
	end
	local x = (h(1) - 0.5) * 1.1
	local y = -0.55 + index * 0.16
	local z = (h(2) - 0.5) * 0.35
	local yaw = math.rad(-28 + h(3) * 56)
	local roll = math.rad(-18 + h(4) * 36)
	local pitch = math.rad(62 + h(5) * 16) -- lying nearly flat, tips toward the camera
	return CFrame.new(x, y, z) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, roll)
end

function CarriedStack.new(
	gui: ScreenGui,
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
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 0.9, 4.2), Vector3.new(0, -0.1, 0))
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
	}, CarriedStack)
	self:_layout()
	table.insert(
		self._connections,
		gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			self:_layout()
		end)
	)
	self:_applyVisibility()
	return self
end

function CarriedStack._layout(self: CarriedStack)
	local carried = self._config.hud.carriedStack
	local gui = self.frame.Parent :: ScreenGui
	local class = SafeArea.layoutClass(gui.AbsoluteSize.X, gui.AbsoluteSize.Y)
	local mobile = class ~= "desktop"
	local width = if mobile then carried.widthPxMobile else carried.widthPxDesktop
	local height = if mobile then carried.heightPxMobile else carried.heightPxDesktop
	self.frame.Size = UDim2.fromOffset(width, height)
	self.frame.Position = UDim2.new(carried.anchorX, 0, 1, -(self._bottomOffset() + carried.anchorBottomOffsetPx))
end

-- Tier for a fullness ratio (0..1): the highest tier whose threshold is met.
function CarriedStack.tierFor(config: { [string]: any }, fullness: number): (string, number)
	local tiers = config.hud.carriedStack.tiers
	local name, feathers = tiers[1].name, tiers[1].feathers
	for _, tier in ipairs(tiers) do
		if fullness >= tier.minFullness then
			name, feathers = tier.name, tier.feathers
		end
	end
	return name, feathers
end

-- Mirrors the authoritative bag: carried / capacity (or carried / reference when infinite).
function CarriedStack.setBag(self: CarriedStack, carried: number, capacity: number, infinite: boolean, animate: boolean?)
	local reference = if infinite then self._config.hud.carriedStack.infiniteReferenceCount else math.max(1, capacity)
	local fullness = if carried <= 0 then 0 else math.clamp(carried / reference, 0.0001, 1)
	local tier, count = CarriedStack.tierFor(self._config, fullness)
	self._tier = tier
	self:_setCount(count, animate == true)
end

function CarriedStack._setCount(self: CarriedStack, count: number, animate: boolean)
	local palette = self._config.pile.visual.palette
	local carried = self._config.hud.carriedStack
	local motion = self._motion()
	while #self._feathers > count do
		local part = table.remove(self._feathers) :: BasePart
		part:Destroy()
	end
	for index = #self._feathers + 1, count do
		local part = makeFeather(index, palette)
		local rest = restPose(index)
		part.Parent = self._world
		table.insert(self._feathers, part)
		if animate then
			-- Settle: drop in from above with a small overshoot, then rest.
			part.CFrame = rest * CFrame.new(0, carried.bounceStuds * 3, 0)
			local seconds = Motion.clampSeconds(carried.bounceSeconds, motion)
			TweenService:Create(part, TweenInfo.new(seconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = rest }):Play()
		else
			part.CFrame = rest
		end
	end
	if animate and count > self._count then
		-- Whole-stack squash so even a same-tier pick reads on the stack.
		local seconds = Motion.clampSeconds(carried.bounceSeconds * 0.6, motion)
		self._scale.Scale = 1.08
		TweenService:Create(self._scale, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
	self._count = count
end

function CarriedStack.clear(self: CarriedStack)
	self._tier = "empty"
	self:_setCount(0, false)
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
	self.frame.Visible = self._visible and not self._hiddenByUi
end

function CarriedStack.count(self: CarriedStack): number
	return self._count
end

function CarriedStack.tier(self: CarriedStack): string
	return self._tier
end

-- Screen-space centre of the stack (for the flying-feather destination).
function CarriedStack.screenCentre(self: CarriedStack): Vector2
	return self.frame.AbsolutePosition + self.frame.AbsoluteSize / 2
end

function CarriedStack.destroy(self: CarriedStack)
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self.frame:Destroy()
end

return CarriedStack
