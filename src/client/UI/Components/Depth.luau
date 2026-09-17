--!strict
-- The one place that knows how a surface in this game is lit.
--
-- Every control used to light itself: a button had a lip and a two-stop gradient, a card had a
-- different stroke, a modal header had neither, and the result read as several kits stacked in one
-- game. These are the four moves, and a button, a card, a modal header, a hotbar slot and a quest row
-- all call the same ones, which is what makes them look like one thing.
--
--   keyline  - a dark warm outline around the whole control. Not black: black on cream reads as a
--              placeholder, cocoa reads as drawn.
--   rim      - a bright stroke just inside the face. This is the move that matters most; an edge with
--              a light rim reads as lit, an edge without one reads as printed.
--   sheen    - a fill that returns to its own colour at both ends and lifts only through the middle,
--              so the surface reads as curved. A top-to-bottom ramp reads as a flat card with a
--              shadow on it, which is exactly what the owner called bland.
--   lip      - the face sits inset from the bottom of a darker base, so the control has a thickness.
--              Pressing collapses the lip, which is the whole of why a press feels like one.
--
-- Nothing here animates or holds state; callers own that.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tokens = require(ReplicatedStorage.Shared.Design.Tokens)

local Depth = {}

local function mix(a: Color3, b: Color3, t: number): Color3
	return Color3.new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end

Depth.mix = mix

-- A colour moved towards white (positive) or towards the outline (negative).
function Depth.shade(base: Color3, amount: number): Color3
	if amount >= 0 then
		return mix(base, Color3.new(1, 1, 1), amount)
	end
	return mix(base, Tokens.color.outline, -amount)
end

-- The glossy ramp (17 Sep 2026, to the reference clip): a lit cap at the top that falls to the
-- face colour by the upper third, then sinks to a darker foot. `light` is optional: without one the
-- cap is derived from the face, which keeps every caller honest about only needing one colour.
function Depth.sheen(face: Color3, light: Color3?): ColorSequence
	local d = Tokens.depth
	local peak = light or Depth.shade(face, d.sheenLift)
	local foot = Depth.shade(face, -d.sheenDrop)
	local stops = d.sheenStops
	return ColorSequence.new({
		ColorSequenceKeypoint.new(stops[1], peak),
		ColorSequenceKeypoint.new(stops[2], peak),
		ColorSequenceKeypoint.new(stops[3], face),
		ColorSequenceKeypoint.new(stops[4], face),
		ColorSequenceKeypoint.new(stops[5], foot),
	})
end

-- Applies (or updates) the sheen on a GuiObject. Reuses the gradient so a variant swap or a hover
-- re-tint never leaves a second one behind.
function Depth.applySheen(object: GuiObject, face: Color3, light: Color3?): UIGradient
	local existing = object:FindFirstChild("SFE_Sheen")
	local gradient: UIGradient
	if existing and existing:IsA("UIGradient") then
		gradient = existing
	else
		gradient = Instance.new("UIGradient")
		gradient.Name = "SFE_Sheen"
		gradient.Rotation = 90
		gradient.Parent = object
	end
	gradient.Color = Depth.sheen(face, light)
	return gradient
end

-- The dark outline around a whole control.
function Depth.keyline(object: GuiObject, thickness: number?, color: Color3?): UIStroke
	local existing = object:FindFirstChild("SFE_Keyline")
	local stroke: UIStroke
	if existing and existing:IsA("UIStroke") then
		stroke = existing
	else
		stroke = Instance.new("UIStroke")
		stroke.Name = "SFE_Keyline"
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = object
	end
	stroke.Thickness = thickness or Tokens.depth.keyline
	stroke.Color = color or Tokens.color.outline
	return stroke
end

-- The keyline on a control, if it has one. Callers that re-tint a border (a selected tile, an
-- affordable bundle, the active tab) look it up through here rather than by name, so the name stays
-- an implementation detail of this module.
function Depth.keylineOf(object: GuiObject): UIStroke?
	local found = object:FindFirstChild("SFE_Keyline")
	if found and found:IsA("UIStroke") then
		return found
	end
	return nil
end

-- The bright rim just inside a face. Derived from the face unless the caller has a better colour.
function Depth.rim(object: GuiObject, face: Color3, color: Color3?): UIStroke
	local existing = object:FindFirstChild("SFE_Rim")
	local stroke: UIStroke
	if existing and existing:IsA("UIStroke") then
		stroke = existing
	else
		stroke = Instance.new("UIStroke")
		stroke.Name = "SFE_Rim"
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = object
	end
	stroke.Thickness = Tokens.depth.rim
	stroke.Color = color or Color3.new(1, 1, 1)
	stroke.Transparency = Tokens.depth.rimTransparency
	return stroke
end

-- A soft dark band under a header or along the top of a well, so content below it sits in something
-- rather than floating on a flat field.
function Depth.innerShadow(parent: GuiObject, height: number, zIndex: number): Frame
	local band = Instance.new("Frame")
	band.Name = "SFE_InnerShadow"
	band.Size = UDim2.new(1, 0, 0, height)
	band.BackgroundColor3 = Tokens.color.shadow
	band.BackgroundTransparency = 1
	band.BorderSizePixel = 0
	band.ZIndex = zIndex
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, Tokens.depth.innerShadow),
		NumberSequenceKeypoint.new(1, 1),
	})
	fade.Parent = band
	band.Parent = parent
	return band
end

-- Dresses a panel: keyline, rim, sheen and a foot that grounds it. Returns the face so the caller can
-- fill it. `base` is the darker frame the face is inset into; pass nil for a flat card.
function Depth.panel(object: GuiObject, face: Color3, options: { radius: number?, rim: Color3?, light: Color3? }?): ()
	local opts = options or {}
	local corner = object:FindFirstChildOfClass("UICorner")
	if not corner then
		corner = Instance.new("UICorner")
		corner.Parent = object
	end
	corner.CornerRadius = UDim.new(0, opts.radius or Tokens.radius.lg)
	object.BackgroundColor3 = face
	Depth.keyline(object)
	Depth.rim(object, face, opts.rim)
	Depth.applySheen(object, face, opts.light)
end

return Depth
