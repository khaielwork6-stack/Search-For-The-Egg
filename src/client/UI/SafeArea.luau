--!strict
-- Safe-area and UIScale policy. Applies a responsive UIScale to a ScreenGui based on viewport
-- width breakpoints from design tokens and reports the current layout class so components can
-- adapt without hard-coded desktop offsets.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)

local SafeArea = {}

export type LayoutClass = "phone" | "tablet" | "desktop"

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

-- Attaches a UIScale that tracks the camera viewport. Returns the UIScale and a cleanup function.
function SafeArea.applyScale(gui: ScreenGui, config: { [string]: any }): (UIScale, () -> ())
	local scale = Instance.new("UIScale")
	scale.Name = "ResponsiveScale"
	scale.Parent = gui
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	local connection: RBXScriptConnection? = nil
	local function refresh()
		local camera = workspace.CurrentCamera
		local width = camera and camera.ViewportSize.X or 1280
		local height = camera and camera.ViewportSize.Y or 720
		local class = SafeArea.layoutClass(width, height)
		scale.Scale = SafeArea.scaleFor(class)
		gui:SetAttribute("SFE_LayoutClass", class :: string)
		gui:SetAttribute("SFE_MinimumTapTargetPx", config.polishBudgets.minimumTapTargetPixels)
	end
	refresh()
	local camera = workspace.CurrentCamera
	if camera then
		connection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(refresh)
	end
	return scale, function()
		if connection then
			connection:Disconnect()
		end
	end
end

-- Minimum tap target in pixels *before* UIScale so scaled buttons stay >= the configured size.
function SafeArea.minimumTapTarget(gui: ScreenGui, config: { [string]: any }): number
	local scale = gui:FindFirstChildOfClass("UIScale")
	local factor = scale and scale.Scale or 1
	return math.ceil(config.polishBudgets.minimumTapTargetPixels / factor)
end

return SafeArea
