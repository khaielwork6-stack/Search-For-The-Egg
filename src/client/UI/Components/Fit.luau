--!strict
-- Scale-first helpers for screens that must never crop or scroll: every element is sized in
-- Scale relative to its parent, text scales down to fit its box (with a ceiling so it never
-- blows up on large screens), images keep their aspect, and buttons get scaled lettering.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local AssetManifest = require(Shared.Design.AssetManifest)
local FrameKit = require(script.Parent.Frame)

local Fit = {}

export type TextOptions = {
	font: Enum.Font?,
	color: Color3?,
	max: number?,
	min: number?,
	align: Enum.TextXAlignment?,
	valign: Enum.TextYAlignment?,
	zIndex: number?,
	outline: number?,
	outlineColor: Color3?,
	wrap: boolean?,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	upper: boolean?,
}

-- A TextLabel that scales its lettering to its box, capped at `max` px (default 32).
function Fit.text(parent: Instance, name: string, text: string, options: TextOptions?): TextLabel
	local opts = (options or {}) :: any
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Size = opts.size or UDim2.fromScale(1, 1)
	label.Position = opts.position or UDim2.fromScale(0, 0)
	label.AnchorPoint = opts.anchor or Vector2.new(0, 0)
	label.Font = opts.font or Tokens.typography.title.font
	label.TextColor3 = opts.color or Tokens.color.inkStrong
	label.Text = if opts.upper then string.upper(text) else text
	label.TextScaled = true
	-- Always wrapped: in practice TextWrapped = false left TextScaled labels at their minimum size (the
	-- HUD gem count, 17 Sep 2026), so `wrap` is ignored and single-word labels simply never break.
	label.TextWrapped = true
	label.TextXAlignment = opts.align or Enum.TextXAlignment.Center
	label.TextYAlignment = opts.valign or Enum.TextYAlignment.Center
	label.ZIndex = opts.zIndex or 1
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = opts.max or 32
	constraint.MinTextSize = opts.min or 8
	constraint.Parent = label
	if opts.outline then
		FrameKit.outline(label, opts.outline, opts.outlineColor)
	end
	label.Parent = parent
	return label
end

-- Locks an object's aspect (width / height). `dominant` picks which axis the parent's Scale drives.
function Fit.aspect(object: GuiObject, ratio: number, dominant: Enum.DominantAxis?): UIAspectRatioConstraint
	local constraint = Instance.new("UIAspectRatioConstraint")
	constraint.AspectRatio = ratio
	constraint.AspectType = if dominant then Enum.AspectType.ScaleWithParentSize else Enum.AspectType.FitWithinMaxSize
	constraint.DominantAxis = dominant or Enum.DominantAxis.Width
	constraint.Parent = object
	return constraint
end

-- A painted image (by manifest role) or nil, sized in Scale and kept square. `Fit` scale type.
function Fit.image(
	parent: Instance,
	role: string,
	options: {
		size: UDim2?,
		position: UDim2?,
		anchor: Vector2?,
		zIndex: number?,
		name: string?,
		color: Color3?,
		transparency: number?,
	}?
): ImageLabel?
	local opts = (options or {}) :: any
	local id = AssetManifest.image(role)
	if not id then
		return nil
	end
	local image = Instance.new("ImageLabel")
	image.Name = opts.name or ("Art_" .. role)
	image.BackgroundTransparency = 1
	image.Image = id
	image.ScaleType = Enum.ScaleType.Fit
	image.Size = opts.size or UDim2.fromScale(1, 1)
	image.Position = opts.position or UDim2.fromScale(0.5, 0.5)
	image.AnchorPoint = opts.anchor or Vector2.new(0.5, 0.5)
	image.ZIndex = opts.zIndex or 1
	if opts.color then
		image.ImageColor3 = opts.color
	end
	image.ImageTransparency = opts.transparency or 0
	image.Parent = parent
	return image
end

-- A plain frame sized and placed in Scale.
function Fit.frame(parent: Instance, name: string, position: UDim2, size: UDim2, zIndex: number?, anchor: Vector2?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Position = position
	frame.Size = size
	frame.AnchorPoint = anchor or Vector2.new(0, 0)
	frame.ZIndex = zIndex or 1
	frame.Parent = parent
	return frame
end

-- Scales a Button handle's lettering to its face (capped at `max` px) so Scale-sized buttons never
-- truncate. Returns the label.
function Fit.buttonText(handle: any, max: number?, padding: number?): TextLabel?
	local face = handle.button:FindFirstChild("Face")
	local label = face and face:FindFirstChild("Label")
	if not label or not label:IsA("TextLabel") then
		return nil
	end
	label.TextScaled = true
	label.TextWrapped = true
	label.TextTruncate = Enum.TextTruncate.None
	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint") or Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = max or 30
	constraint.MinTextSize = 8
	constraint.Parent = label
	local pad = label:FindFirstChildOfClass("UIPadding")
	if pad then
		local px = padding or Tokens.spacing.sm
		pad.PaddingLeft = UDim.new(0, px)
		pad.PaddingRight = UDim.new(0, px)
		pad.PaddingTop = UDim.new(0.12, 0)
		pad.PaddingBottom = UDim.new(0.12, 0)
	end
	return label
end

-- Horizontal list layout with Scale padding.
function Fit.row(
	parent: Instance,
	options: { gap: number?, halign: Enum.HorizontalAlignment?, valign: Enum.VerticalAlignment?, vertical: boolean? }?
): UIListLayout
	local opts = (options or {}) :: any
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = if opts.vertical then Enum.FillDirection.Vertical else Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = opts.halign or Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = opts.valign or Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(opts.gap or 0.02, 0)
	layout.Parent = parent
	return layout
end

-- Scale padding on all sides.
function Fit.pad(parent: Instance, x: number, y: number?): UIPadding
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(x, 0)
	padding.PaddingRight = UDim.new(x, 0)
	padding.PaddingTop = UDim.new(y or x, 0)
	padding.PaddingBottom = UDim.new(y or x, 0)
	padding.Parent = parent
	return padding
end

-- Rounded corners as a fraction of the shorter edge (UICorner scale).
function Fit.corner(object: GuiObject, scale: number): UICorner
	local corner = object:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
	corner.CornerRadius = UDim.new(scale, 0)
	corner.Parent = object
	return corner
end

return Fit
