--!strict
-- World billboards in the UI language, built so they behave like objects in the world:
--   * sized in studs (BillboardGui Size in Scale), so they shrink naturally with distance;
--   * AlwaysOnTop off, so world geometry (the feather pile, stalls, walls, other players) hides them;
--   * LightInfluence 0, so they stay readable in shade and at night;
--   * culled past a MaxDistance (Tokens.world).
-- Every child is Scale-sized with TextScaled lettering, so the whole plate scales as one piece.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Fit = require(script.Parent.Fit)
local Depth = require(script.Parent.Depth)

local WorldBillboard = {}

-- Lettering may grow as the camera closes in; the cap only stops absurd sizes nose-to-plate.
local TEXT_CAP = 120

function WorldBillboard.create(
	adornee: BasePart,
	name: string,
	studs: Vector2,
	offset: Vector3,
	maxDistance: number,
	parent: Instance?
): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = name
	gui.Adornee = adornee
	gui.Size = UDim2.fromScale(studs.X, studs.Y)
	gui.StudsOffsetWorldSpace = offset
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = maxDistance
	gui.ResetOnSpawn = false
	gui.ClipsDescendants = false
	gui.Parent = parent or adornee
	return gui
end

-- Stroked lettering scaled to its Scale box.
function WorldBillboard.text(
	parent: Instance,
	name: string,
	text: string,
	options: {
		size: UDim2,
		position: UDim2?,
		anchor: Vector2?,
		color: Color3?,
		font: Enum.Font?,
		outline: number?,
		zIndex: number?,
		align: Enum.TextXAlignment?,
		wrap: boolean?,
	}
): TextLabel
	local label = Fit.text(parent, name, text, {
		font = options.font or Tokens.typography.label.font,
		color = options.color or Tokens.color.featherWhite,
		max = TEXT_CAP,
		min = 1,
		outline = options.outline or 2,
		outlineColor = Tokens.color.outline,
		zIndex = options.zIndex or 2,
		size = options.size,
		position = options.position or UDim2.fromScale(0.5, 0),
		anchor = options.anchor or Vector2.new(0.5, 0),
		align = options.align or Enum.TextXAlignment.Center,
		wrap = options.wrap == true,
	})
	return label
end

-- A slate pill whose width follows its text: the box is the most it may take, an aspect constraint
-- (estimated from the character count) shrinks it to the lettering.
function WorldBillboard.pill(
	parent: Instance,
	name: string,
	text: string,
	options: { size: UDim2, position: UDim2, anchor: Vector2, fill: Color3?, textColor: Color3?, zIndex: number? }
): (Frame, TextLabel)
	local z = options.zIndex or 2
	local pill = Instance.new("Frame")
	pill.Name = name
	pill.Size = options.size
	pill.Position = options.position
	pill.AnchorPoint = options.anchor
	pill.BackgroundColor3 = options.fill or Tokens.color.surface
	pill.BorderSizePixel = 0
	pill.ZIndex = z
	Fit.corner(pill, 0.5)
	Depth.keyline(pill, Tokens.stroke.hairline)
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectType = Enum.AspectType.FitWithinMaxSize
	aspect.DominantAxis = Enum.DominantAxis.Height
	aspect.Parent = pill
	pill.Parent = parent
	local label = WorldBillboard.text(pill, "Text", text, {
		size = UDim2.fromScale(0.84, 0.72),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		color = options.textColor,
		outline = 1.5,
		zIndex = z + 1,
	})
	local function fit()
		aspect.AspectRatio = math.clamp(utf8.len(label.Text) or #label.Text, 1, 40) * 0.56 + 1.1
	end
	label:GetPropertyChangedSignal("Text"):Connect(fit)
	fit()
	return pill, label
end

return WorldBillboard
