--!strict
-- Token-drawn frame primitives in the owner's visual language: a gold bevelled frame around a deep
-- teal panel, a cream pill label with chunky rounded lettering, and leaf accents. Every modal card,
-- station button, class card, and reward row composes these so the language stays consistent.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)

local Frame = {}

-- Gold bevel: outer outline, gold body with a highlight-to-shadow gradient, inner teal panel.
-- Returns (outer, panel) where `panel` is the content parent.
function Frame.goldPanel(parent: Instance, name: string, options: { radius: number?, padding: number?, zIndex: number? }?): (Frame, Frame)
	local opts = (options or {}) :: any
	local radius = opts.radius or Tokens.radius.xl
	local z = opts.zIndex or 1

	local outer = Instance.new("Frame")
	outer.Name = name
	outer.BackgroundColor3 = Tokens.color.gold
	outer.BorderSizePixel = 0
	outer.ZIndex = z
	local outerCorner = Instance.new("UICorner")
	outerCorner.CornerRadius = UDim.new(0, radius)
	outerCorner.Parent = outer
	local outline = Instance.new("UIStroke")
	outline.Thickness = Tokens.stroke.frame
	outline.Color = Tokens.color.outline
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	outline.Parent = outer
	local bevel = Instance.new("UIGradient")
	bevel.Rotation = 90
	bevel.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Tokens.color.goldLight),
		ColorSequenceKeypoint.new(0.55, Tokens.color.gold),
		ColorSequenceKeypoint.new(1, Tokens.color.goldDeep),
	})
	bevel.Parent = outer
	local framePadding = Instance.new("UIPadding")
	local inset = Tokens.spacing.sm
	framePadding.PaddingTop = UDim.new(0, inset)
	framePadding.PaddingBottom = UDim.new(0, inset)
	framePadding.PaddingLeft = UDim.new(0, inset)
	framePadding.PaddingRight = UDim.new(0, inset)
	framePadding.Parent = outer

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = Tokens.color.tealPanel
	panel.BorderSizePixel = 0
	panel.ZIndex = z + 1
	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, math.max(Tokens.radius.sm, radius - inset))
	panelCorner.Parent = panel
	local panelStroke = Instance.new("UIStroke")
	panelStroke.Thickness = Tokens.stroke.standard
	panelStroke.Color = Tokens.color.tealDeep
	panelStroke.Parent = panel
	local sheen = Instance.new("UIGradient")
	sheen.Rotation = 90
	sheen.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Tokens.color.tealLight),
		ColorSequenceKeypoint.new(0.35, Tokens.color.tealPanel),
		ColorSequenceKeypoint.new(1, Tokens.color.tealDeep),
	})
	sheen.Parent = panel
	local padding = Instance.new("UIPadding")
	local pad = opts.padding or Tokens.spacing.md
	padding.PaddingTop = UDim.new(0, pad)
	padding.PaddingBottom = UDim.new(0, pad)
	padding.PaddingLeft = UDim.new(0, pad)
	padding.PaddingRight = UDim.new(0, pad)
	padding.Parent = panel
	panel.Parent = outer
	outer.Parent = parent
	return outer, panel
end

-- Cream pill label with chunky rounded lettering and a dark outline (station names, titles).
function Frame.pill(
	parent: Instance,
	name: string,
	text: string,
	options: { size: UDim2?, textSize: number?, zIndex: number?, fill: Color3? }?
): TextLabel
	local opts = (options or {}) :: any
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = opts.size or UDim2.new(1, 0, 0, Tokens.layout.minimumTapTargetPx)
	label.BackgroundColor3 = opts.fill or Tokens.color.creamPill
	label.BorderSizePixel = 0
	label.Font = Tokens.typography.label.font
	label.TextSize = opts.textSize or Tokens.typography.label.size
	label.TextColor3 = Tokens.color.gold
	label.TextStrokeColor3 = Tokens.color.outline
	label.TextStrokeTransparency = 0.15
	label.Text = text
	label.TextScaled = false
	label.ZIndex = opts.zIndex or 1
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	corner.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.bold
	stroke.Color = Tokens.color.outline
	stroke.Parent = label
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Tokens.color.surface),
		ColorSequenceKeypoint.new(1, opts.fill or Tokens.color.creamPill),
	})
	gradient.Parent = label
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.md)
	padding.Parent = label
	label.Parent = parent
	return label
end

-- Body text on the teal panel (cream, readable).
function Frame.text(
	parent: Instance,
	name: string,
	text: string,
	style: string?,
	options: { size: UDim2?, align: Enum.TextXAlignment?, color: Color3?, zIndex: number?, wrap: boolean? }?
): TextLabel
	local opts = (options or {}) :: any
	local typo = (Tokens.typography :: any)[style or "body"]
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = opts.size or UDim2.new(1, 0, 0, typo.size + Tokens.spacing.xs)
	label.BackgroundTransparency = 1
	label.Font = typo.font
	label.TextSize = typo.size
	label.TextColor3 = opts.color or Tokens.color.cream
	label.TextXAlignment = opts.align or Enum.TextXAlignment.Left
	label.TextWrapped = opts.wrap ~= false
	label.Text = text
	label.ZIndex = opts.zIndex or 1
	label.Parent = parent
	return label
end

-- Leaf accent pair (small rounded leaves at the corners of a panel).
function Frame.leaves(parent: Instance, zIndex: number?)
	for index, corner in ipairs({ Vector2.new(0, 1), Vector2.new(1, 1) }) do
		local leaf = Instance.new("Frame")
		leaf.Name = "Leaf" .. index
		leaf.AnchorPoint = corner
		leaf.Position = UDim2.fromScale(corner.X, corner.Y)
		leaf.Size = UDim2.fromOffset(26, 14)
		leaf.BackgroundColor3 = Tokens.color.leafBright
		leaf.BorderSizePixel = 0
		leaf.Rotation = if index == 1 then -28 else 28
		leaf.ZIndex = (zIndex or 1) + 2
		local leafCorner = Instance.new("UICorner")
		leafCorner.CornerRadius = UDim.new(1, 0)
		leafCorner.Parent = leaf
		local vein = Instance.new("UIStroke")
		vein.Thickness = Tokens.stroke.standard
		vein.Color = Tokens.color.leafDeep
		vein.Parent = leaf
		leaf.Parent = parent
	end
end

-- Progress meter (cream track, gold fill) for perks, daily streaks, and bag-style bars.
function Frame.meter(
	parent: Instance,
	name: string,
	fraction: number,
	options: { height: number?, fill: Color3?, zIndex: number? }?
): (Frame, Frame)
	local opts = (options or {}) :: any
	local track = Instance.new("Frame")
	track.Name = name
	track.Size = UDim2.new(1, 0, 0, opts.height or 10)
	track.BackgroundColor3 = Tokens.color.tealDeep
	track.BorderSizePixel = 0
	track.ZIndex = opts.zIndex or 1
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track
	local trackStroke = Instance.new("UIStroke")
	trackStroke.Thickness = Tokens.stroke.hairline
	trackStroke.Color = Tokens.color.outline
	trackStroke.Parent = track
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
	fill.BackgroundColor3 = opts.fill or Tokens.color.gold
	fill.BorderSizePixel = 0
	fill.ZIndex = track.ZIndex + 1
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill
	fill.Parent = track
	track.Parent = parent
	return track, fill
end

-- Row container on the panel (slightly lighter teal card) used for lists.
function Frame.row(parent: Instance, name: string, height: number, zIndex: number?): Frame
	local row = Instance.new("Frame")
	row.Name = name
	row.Size = UDim2.new(1, 0, 0, height)
	row.BackgroundColor3 = Tokens.color.tealLight
	row.BackgroundTransparency = 0.35
	row.BorderSizePixel = 0
	row.ZIndex = zIndex or 1
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.md)
	corner.Parent = row
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.hairline
	stroke.Color = Tokens.color.tealDeep
	stroke.Parent = row
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.md)
	padding.Parent = row
	row.Parent = parent
	return row
end

return Frame
