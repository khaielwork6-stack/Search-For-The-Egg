--!strict
-- Safe-area, UIScale and layout-class policy. Every ScreenGui gets a Stage frame that fills the
-- safe area; controllers parent their UI into the stage. The stage carries the responsive UIScale
-- and reports the layout class. A Studio-only viewport override shrinks every stage to a phone or
-- tablet size (centred, with a frame) so layouts can be checked on a desktop viewport.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Signal = require(Shared.Util.Signal)

local SafeArea = {}

export type LayoutClass = "phone" | "tablet" | "desktop"

local override: Vector2? = nil
local stages: { Frame } = {}
SafeArea.overrideChanged = Signal.new()

-- Classifies by the shorter viewport edge (a landscape phone is wide but short) and aspect ratio:
-- phone when the short edge is under the phone breakpoint; tablet for squarer mid-size viewports.
function SafeArea.layoutClass(viewportWidth: number, viewportHeight: number?): LayoutClass
	local height = viewportHeight or viewportWidth
	local shortEdge = math.min(viewportWidth, height)
	local aspect = math.max(viewportWidth, height) / math.max(1, shortEdge)
	if shortEdge < Tokens.layout.phoneShortEdgePx then
		return "phone"
	elseif shortEdge < Tokens.layout.tabletShortEdgePx and aspect < Tokens.layout.tabletMaxAspect then
		return "tablet"
	end
	return "desktop"
end

function SafeArea.scaleFor(class: LayoutClass): number
	if class == "phone" then
		return Tokens.layout.phoneUiScale
	elseif class == "tablet" then
		return Tokens.layout.tabletUiScale
	end
	return Tokens.layout.desktopUiScale
end

-- The viewport the layout should assume: the override when set, else the camera viewport.
function SafeArea.viewport(): Vector2
	if override then
		return override :: Vector2
	end
	local camera = workspace.CurrentCamera
	return if camera then camera.ViewportSize else Vector2.new(1280, 720)
end

function SafeArea.viewportOverride(): Vector2?
	return override
end

-- Studio-only device emulation: every stage takes the given size (nil restores the real viewport).
function SafeArea.setViewportOverride(size: Vector2?)
	override = size
	for _, stage in ipairs(stages) do
		SafeArea._applyStageSize(stage)
	end
	SafeArea.overrideChanged:Fire(size)
end

function SafeArea._applyStageSize(stage: Frame)
	local frame = stage:FindFirstChild("EmulationFrame") :: Frame?
	if override then
		stage.AnchorPoint = Vector2.new(0.5, 0.5)
		stage.Position = UDim2.fromScale(0.5, 0.5)
		stage.Size = UDim2.fromOffset(override.X, override.Y)
		stage.ClipsDescendants = true
		if not frame then
			frame = Instance.new("Frame")
			frame.Name = "EmulationFrame"
			frame.Size = UDim2.fromScale(1, 1)
			frame.BackgroundTransparency = 1
			frame.ZIndex = 1
			local stroke = Instance.new("UIStroke")
			stroke.Thickness = 3
			stroke.Color = Tokens.color.tealAccent
			stroke.Parent = frame
			frame.Parent = stage
		end
	else
		stage.AnchorPoint = Vector2.new(0, 0)
		stage.Position = UDim2.fromScale(0, 0)
		stage.Size = UDim2.fromScale(1, 1)
		stage.ClipsDescendants = false
		if frame then
			frame:Destroy()
		end
	end
end

-- Creates the Stage frame under a ScreenGui with a responsive UIScale that tracks the viewport.
-- Returns the stage, the UIScale and a cleanup function.
function SafeArea.applyScale(gui: ScreenGui, config: { [string]: any }): (UIScale, () -> (), Frame)
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.Size = UDim2.fromScale(1, 1)
	stage.BackgroundTransparency = 1
	stage.ZIndex = 1
	local scale = Instance.new("UIScale")
	scale.Name = "ResponsiveScale"
	scale.Parent = stage
	stage.Parent = gui
	table.insert(stages, stage)
	SafeArea._applyStageSize(stage)
	local connections: { RBXScriptConnection } = {}
	local function refresh()
		local size = SafeArea.viewport()
		local class = SafeArea.layoutClass(size.X, size.Y)
		scale.Scale = SafeArea.scaleFor(class)
		gui:SetAttribute("SFE_LayoutClass", class :: string)
		gui:SetAttribute("SFE_MinimumTapTargetPx", config.polishBudgets.minimumTapTargetPixels)
		stage:SetAttribute("SFE_LayoutClass", class :: string)
	end
	refresh()
	local camera = workspace.CurrentCamera
	if camera then
		table.insert(connections, camera:GetPropertyChangedSignal("ViewportSize"):Connect(refresh))
	end
	table.insert(connections, SafeArea.overrideChanged:Connect(refresh))
	return scale,
		function()
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			local index = table.find(stages, stage)
			if index then
				table.remove(stages, index)
			end
		end,
		stage
end

-- The stage (or ScreenGui) that hosts a gui object, and its responsive UIScale.
function SafeArea.stageOf(object: Instance): Frame?
	local current: Instance? = object
	while current do
		if current:IsA("Frame") and current.Name == "Stage" and current.Parent and current.Parent:IsA("ScreenGui") then
			return current
		end
		current = current.Parent
	end
	return nil
end

function SafeArea.scaleOf(object: Instance): number
	local stage = SafeArea.stageOf(object)
	local scale = stage and stage:FindFirstChildOfClass("UIScale")
	if scale then
		return scale.Scale
	end
	local gui = object:FindFirstAncestorWhichIsA("ScreenGui") or (if object:IsA("ScreenGui") then object else nil)
	local guiScale = gui and gui:FindFirstChildOfClass("UIScale")
	return if guiScale then guiScale.Scale else 1
end

-- Layout class for whatever hosts `object` (from the stage attribute, else from the viewport).
function SafeArea.classOf(object: Instance): LayoutClass
	local stage = SafeArea.stageOf(object)
	local class = stage and stage:GetAttribute("SFE_LayoutClass")
	if type(class) == "string" then
		return class :: LayoutClass
	end
	local size = SafeArea.viewport()
	return SafeArea.layoutClass(size.X, size.Y)
end

-- Minimum tap target in pixels *before* UIScale so scaled buttons stay >= the configured size.
function SafeArea.minimumTapTarget(gui: Instance, config: { [string]: any }): number
	local factor = SafeArea.scaleOf(gui)
	return math.ceil(config.polishBudgets.minimumTapTargetPixels / factor)
end

return SafeArea
