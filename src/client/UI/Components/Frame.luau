--!strict
-- Token-drawn frame primitives for the rebuilt UI: a warm cream panel inside a gold bevelled frame
-- with a soft shadow, feather-white rows and cards, a cream nameplate pill with gold lettering,
-- badges, dividers, meters with animated fill, and small feather / leaf accents. Every modal card,
-- station button, class card, reward row, and HUD chip composes these so the language stays one.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local AssetManifest = require(Shared.Design.AssetManifest)

local Frame = {}

local function skinLabel(parent: GuiObject, role: string, zIndex: number, inset: number?): ImageLabel?
	local id, rect, scale = AssetManifest.skin(role)
	if not id then
		return nil
	end
	local label = Instance.new("ImageLabel")
	label.Name = "ArtFrame"
	label.BackgroundTransparency = 1
	local pad = inset or 0
	label.Position = UDim2.fromOffset(-pad, -pad)
	label.Size = UDim2.new(1, pad * 2, 1, pad * 2)
	label.Image = id
	if rect then
		label.ScaleType = Enum.ScaleType.Slice
		label.SliceCenter = rect
		label.SliceScale = scale
	else
		label.ScaleType = Enum.ScaleType.Fit
	end
	label.ZIndex = zIndex
	label.Parent = parent
	return label
end
Frame.skinLabel = skinLabel

-- Soft drop shadow behind any rounded frame: two offset rounded frames with low alpha. Returns the
-- shadow frame (parented under `target`, drawn below it via ZIndex).
function Frame.shadow(target: GuiObject, options: { lifted: boolean?, radius: number? }?): Frame
	local opts = (options or {}) :: any
	local spec = if opts.lifted then Tokens.shadow.lifted else Tokens.shadow.soft
	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.new(0.5, 0, 0.5, spec.offset)
	shadow.Size = UDim2.new(1, spec.offset, 1, spec.offset)
	shadow.BackgroundColor3 = Tokens.color.shadow
	shadow.BackgroundTransparency = spec.transparency
	shadow.BorderSizePixel = 0
	shadow.ZIndex = math.max(1, target.ZIndex - 1)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, (opts.radius or Tokens.radius.xl) + 2)
	corner.Parent = shadow
	local halo = shadow:Clone()
	halo.Name = "Halo"
	halo.Position = UDim2.new(0.5, 0, 0.5, spec.offset * 2)
	halo.Size = UDim2.new(1, spec.offset * 3, 1, spec.offset * 3)
	halo.BackgroundTransparency = math.min(0.97, spec.transparency + 0.09)
	halo.ZIndex = shadow.ZIndex
	halo.Parent = target
	shadow.Parent = target
	return shadow
end

-- Gold bevel around a cream panel. Returns (outer, panel) where `panel` is the content parent.
function Frame.goldPanel(
	parent: Instance,
	name: string,
	options: { radius: number?, padding: number?, zIndex: number?, shadow: boolean?, inset: number? }?
): (Frame, Frame)
	local opts = (options or {}) :: any
	local radius = opts.radius or Tokens.radius.xl
	local z = opts.zIndex or 1
	local inset = opts.inset or Tokens.spacing.sm

	local outer = Instance.new("Frame")
	outer.Name = name
	outer.BackgroundColor3 = Tokens.color.gold
	outer.BorderSizePixel = 0
	outer.ZIndex = z
	local outerCorner = Instance.new("UICorner")
	outerCorner.CornerRadius = UDim.new(0, radius)
	outerCorner.Parent = outer
	local outline = Instance.new("UIStroke")
	outline.Thickness = Tokens.stroke.bold
	outline.Color = Tokens.color.outline
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	outline.Parent = outer
	local bevel = Instance.new("UIGradient")
	bevel.Name = "Bevel"
	bevel.Rotation = 90
	bevel.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Tokens.color.goldLight),
		ColorSequenceKeypoint.new(0.5, Tokens.color.gold),
		ColorSequenceKeypoint.new(1, Tokens.color.goldDeep),
	})
	bevel.Parent = outer
	local framePadding = Instance.new("UIPadding")
	framePadding.PaddingTop = UDim.new(0, inset)
	framePadding.PaddingBottom = UDim.new(0, inset)
	framePadding.PaddingLeft = UDim.new(0, inset)
	framePadding.PaddingRight = UDim.new(0, inset)
	framePadding.Parent = outer
	if opts.shadow ~= false then
		Frame.shadow(outer, { lifted = true, radius = radius })
	end

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = Tokens.color.panel
	panel.BorderSizePixel = 0
	panel.ZIndex = z + 1
	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, math.max(Tokens.radius.sm, radius - inset))
	panelCorner.Parent = panel
	local panelStroke = Instance.new("UIStroke")
	panelStroke.Thickness = Tokens.stroke.standard
	panelStroke.Color = Tokens.color.strawDeep
	panelStroke.Transparency = 0.35
	panelStroke.Parent = panel
	local sheen = Instance.new("UIGradient")
	sheen.Name = "Paper"
	sheen.Rotation = 90
	sheen.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Tokens.color.featherWhite),
		ColorSequenceKeypoint.new(0.4, Tokens.color.panel),
		ColorSequenceKeypoint.new(1, Tokens.color.panelDeep),
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

-- Cream nameplate pill with chunky gold lettering and a cocoa outline (titles, station names).
function Frame.pill(
	parent: Instance,
	name: string,
	text: string,
	options: {
		size: UDim2?,
		textSize: number?,
		zIndex: number?,
		fill: Color3?,
		textColor: Color3?,
		art: boolean?,
		fitText: boolean?,
	}?
): TextLabel
	local opts = (options or {}) :: any
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = opts.size or UDim2.new(1, 0, 0, Tokens.layout.minimumTapTargetPx)
	label.BackgroundColor3 = opts.fill or Tokens.color.creamPill
	label.BorderSizePixel = 0
	label.Font = Tokens.typography.label.font
	label.TextSize = opts.textSize or Tokens.typography.label.size
	label.TextColor3 = opts.textColor or Tokens.color.gold
	label.TextStrokeColor3 = Tokens.color.outline
	label.TextStrokeTransparency = 0.2
	label.Text = text
	label.TextScaled = false
	label.TextTruncate = Enum.TextTruncate.AtEnd
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
		ColorSequenceKeypoint.new(0, Tokens.color.featherWhite),
		ColorSequenceKeypoint.new(1, opts.fill or Tokens.color.creamPill),
	})
	gradient.Parent = label
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	padding.Parent = label
	if opts.art ~= false and skinLabel(label, "modal.title", label.ZIndex + 1, 2) then
		stroke.Enabled = false
		-- The art's rounded ends are wider than the drawn stroke: keep the text clear of them.
		padding.PaddingLeft = UDim.new(0, Tokens.spacing.xl + Tokens.spacing.xs)
		padding.PaddingRight = UDim.new(0, Tokens.spacing.xl + Tokens.spacing.xs)
	end
	if opts.fitText then
		-- Width follows the text plus padding (AutomaticSize would feed back on the art child).
		local height = label.Size.Y.Offset
		local function fit()
			label.Size =
				UDim2.fromOffset(math.ceil(label.TextBounds.X) + padding.PaddingLeft.Offset + padding.PaddingRight.Offset + 2, height)
		end
		label:GetPropertyChangedSignal("TextBounds"):Connect(fit)
		fit()
	end
	label.Parent = parent
	return label
end

-- Body text on cream (ink brown by default).
function Frame.text(
	parent: Instance,
	name: string,
	text: string,
	style: string?,
	options: { size: UDim2?, align: Enum.TextXAlignment?, color: Color3?, zIndex: number?, wrap: boolean?, autoHeight: boolean? }?
): TextLabel
	local opts = (options or {}) :: any
	local typo = (Tokens.typography :: any)[style or "body"]
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = opts.size or UDim2.new(1, 0, 0, typo.size + Tokens.spacing.xs)
	label.BackgroundTransparency = 1
	label.Font = typo.font
	label.TextSize = typo.size
	label.TextColor3 = opts.color or Tokens.color.ink
	label.TextXAlignment = opts.align or Enum.TextXAlignment.Left
	label.TextWrapped = opts.wrap ~= false
	label.Text = text
	label.ZIndex = opts.zIndex or 1
	if opts.autoHeight then
		label.AutomaticSize = Enum.AutomaticSize.Y
	end
	label.Parent = parent
	return label
end

-- Section heading: small gold bar + heading text (consistent hierarchy inside panels).
function Frame.heading(parent: Instance, name: string, text: string, zIndex: number?): Frame
	local z = zIndex or 1
	local row = Instance.new("Frame")
	row.Name = name
	row.Size = UDim2.new(1, 0, 0, Tokens.typography.heading.size + Tokens.spacing.sm)
	row.BackgroundTransparency = 1
	row.ZIndex = z
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0, 0.5)
	bar.Position = UDim2.fromScale(0, 0.5)
	bar.Size = UDim2.fromOffset(5, Tokens.typography.heading.size)
	bar.BackgroundColor3 = Tokens.color.gold
	bar.BorderSizePixel = 0
	bar.ZIndex = z
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(1, 0)
	barCorner.Parent = bar
	bar.Parent = row
	local label = Frame.text(row, "Text", text, "heading", { zIndex = z, color = Tokens.color.inkStrong })
	label.Position = UDim2.fromOffset(Tokens.spacing.md, 0)
	label.Size = UDim2.new(1, -Tokens.spacing.md, 1, 0)
	row.Parent = parent
	return row
end

-- Leaf accent pair (small rounded leaves at the bottom corners of a card).
function Frame.leaves(parent: Instance, zIndex: number?)
	for index, corner in ipairs({ Vector2.new(0, 1), Vector2.new(1, 1) }) do
		local leaf = Instance.new("Frame")
		leaf.Name = "Leaf" .. index
		leaf.AnchorPoint = corner
		leaf.Position = UDim2.new(corner.X, if index == 1 then -4 else 4, corner.Y, 4)
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

-- Feather accent pair (two soft feather-white plumes peeking from the top corners of a card).
function Frame.feathers(parent: Instance, zIndex: number?)
	for index, corner in ipairs({ Vector2.new(0, 0), Vector2.new(1, 0) }) do
		local plume = Instance.new("Frame")
		plume.Name = "Plume" .. index
		plume.AnchorPoint = Vector2.new(0.5, 0.5)
		plume.Position = UDim2.new(corner.X, if index == 1 then 10 else -10, 0, 2)
		plume.Size = UDim2.fromOffset(16, 40)
		plume.BackgroundColor3 = Tokens.color.featherWhite
		plume.BorderSizePixel = 0
		plume.Rotation = if index == 1 then -34 else 34
		plume.ZIndex = (zIndex or 1) + 2
		local plumeCorner = Instance.new("UICorner")
		plumeCorner.CornerRadius = UDim.new(1, 0)
		plumeCorner.Parent = plume
		local edge = Instance.new("UIStroke")
		edge.Thickness = Tokens.stroke.standard
		edge.Color = Tokens.color.outline
		edge.Parent = plume
		local quill = Instance.new("Frame")
		quill.Name = "Quill"
		quill.AnchorPoint = Vector2.new(0.5, 0.5)
		quill.Position = UDim2.fromScale(0.5, 0.5)
		quill.Size = UDim2.new(0, 2, 0.8, 0)
		quill.BackgroundColor3 = Tokens.color.strawDeep
		quill.BorderSizePixel = 0
		quill.ZIndex = plume.ZIndex + 1
		quill.Parent = plume
		plume.Parent = parent
	end
end

export type MeterHandle = { track: Frame, fill: Frame, set: (fraction: number, animate: boolean?) -> (), setColor: (color: Color3) -> () }

-- Progress meter (cream track, gold fill with a highlight) that animates to a fraction.
function Frame.meter(
	parent: Instance,
	name: string,
	fraction: number,
	options: { height: number?, fill: Color3?, zIndex: number?, motion: (() -> Motion.MotionSettings)? }?
): (Frame, Frame, MeterHandle)
	local opts = (options or {}) :: any
	local height = opts.height or 10
	local track = Instance.new("Frame")
	track.Name = name
	track.Size = UDim2.new(1, 0, 0, height)
	track.BackgroundColor3 = Tokens.color.creamDeep
	track.BorderSizePixel = 0
	track.ZIndex = opts.zIndex or 1
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track
	local trackStroke = Instance.new("UIStroke")
	trackStroke.Thickness = Tokens.stroke.hairline
	trackStroke.Color = Tokens.color.strawDeep
	trackStroke.Transparency = 0.4
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
	local fillGradient = Instance.new("UIGradient")
	fillGradient.Rotation = 90
	fillGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(215, 215, 215)),
	})
	fillGradient.Parent = fill
	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = Vector2.new(0, height)
	sizeConstraint.Parent = fill
	if skinLabel(track, "meter.track", track.ZIndex, 0) then
		trackStroke.Enabled = false
		track.BackgroundTransparency = 1
		local fillArt = skinLabel(
			fill,
			if opts.fill == Tokens.color.leafBright or opts.fill == Tokens.color.success then "meter.fill.green" else "meter.fill.gold",
			fill.ZIndex,
			0
		)
		if fillArt then
			fill.BackgroundTransparency = 1
			fillGradient.Enabled = false
		end
	end
	fill.Parent = track
	track.Parent = parent
	local handle: MeterHandle = {
		track = track,
		fill = fill,
		set = function(value: number, animate: boolean?)
			local target = UDim2.fromScale(math.clamp(value, 0, 1), 1)
			if animate and opts.motion then
				TweenService
					:Create(fill, TweenInfo.new(Motion.duration("standard", opts.motion()), Tokens.motion.easeOut), { Size = target })
					:Play()
			else
				fill.Size = target
			end
		end,
		setColor = function(color: Color3)
			fill.BackgroundColor3 = color
		end,
	}
	return track, fill, handle
end

-- Row / card container on a cream panel: feather-white with a soft edge and a hairline shadow.
function Frame.row(
	parent: Instance,
	name: string,
	height: number,
	zIndex: number?,
	options: { tint: Color3?, padding: number?, art: boolean?, muted: boolean? }?
): Frame
	local opts = (options or {}) :: any
	local row = Instance.new("Frame")
	row.Name = name
	row.Size = UDim2.new(1, 0, 0, height)
	row.BackgroundColor3 = opts.tint or Tokens.color.featherWhite
	row.BorderSizePixel = 0
	row.ZIndex = zIndex or 1
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.md)
	corner.Parent = row
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.hairline + 0.5
	stroke.Color = Tokens.color.strawDeep
	stroke.Transparency = 0.45
	stroke.Parent = row
	local padding = Instance.new("UIPadding")
	local pad = opts.padding or Tokens.spacing.md
	padding.PaddingLeft = UDim.new(0, pad)
	padding.PaddingRight = UDim.new(0, pad)
	padding.Parent = row
	-- The supplied row art carries a filled teal centre; cream rows stay token-drawn.
	if opts.muted then
		row.BackgroundColor3 = Tokens.color.surfaceAlt
		stroke.Transparency = 0.7
	end
	row.Parent = parent
	return row
end

-- Small rounded badge ("NEW", "MAX", "x2") in a tone colour.
function Frame.badge(parent: Instance, name: string, text: string, tone: Color3?, zIndex: number?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, Tokens.typography.caption.size + Tokens.spacing.sm)
	label.BackgroundColor3 = tone or Tokens.color.tealAccent
	label.BorderSizePixel = 0
	label.Font = Tokens.typography.heading.font
	label.TextSize = Tokens.typography.caption.size - 1
	label.TextColor3 = Tokens.color.featherWhite
	label.Text = text
	label.ZIndex = zIndex or 1
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = label
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.sm)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.sm)
	padding.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.hairline + 0.5
	stroke.Color = Tokens.color.outline
	stroke.Transparency = 0.3
	stroke.Parent = label
	label.Parent = parent
	return label
end

-- Hairline divider.
function Frame.divider(parent: Instance, name: string, zIndex: number?): Frame
	local line = Instance.new("Frame")
	line.Name = name
	line.Size = UDim2.new(1, 0, 0, 2)
	line.BackgroundColor3 = Tokens.color.strawDeep
	line.BackgroundTransparency = 0.6
	line.BorderSizePixel = 0
	line.ZIndex = zIndex or 1
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = line
	line.Parent = parent
	return line
end

-- HUD chip: cream pill with cocoa outline, optional leading icon slot, and a UIScale for pops.
function Frame.chip(
	parent: Instance,
	name: string,
	options: { zIndex: number?, width: number?, height: number?, fill: Color3? }?
): (Frame, TextLabel, Frame)
	local opts = (options or {}) :: any
	local z = opts.zIndex or Tokens.zIndex.hud
	local height = opts.height or Tokens.layout.minimumTapTargetPx
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = UDim2.fromOffset(opts.width or height * 2, height)
	frame.BackgroundColor3 = opts.fill or Tokens.color.creamPill
	frame.BorderSizePixel = 0
	frame.ZIndex = z
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.bold
	stroke.Color = Tokens.color.outline
	stroke.Parent = frame
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Tokens.color.featherWhite),
		ColorSequenceKeypoint.new(1, opts.fill or Tokens.color.creamPill),
	})
	gradient.Parent = frame
	local scale = Instance.new("UIScale")
	scale.Parent = frame
	Frame.shadow(frame, { radius = Tokens.radius.pill })
	if skinLabel(frame, opts.art or "hud.chip", z + 1, 2) then
		stroke.Enabled = false
		frame.BackgroundTransparency = 0.1
	end
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Tokens.spacing.sm)
	layout.Parent = frame
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	padding.Parent = frame
	local iconSlot = Instance.new("Frame")
	iconSlot.Name = "IconSlot"
	iconSlot.LayoutOrder = 1
	iconSlot.Size = UDim2.fromOffset(Tokens.icon.md, Tokens.icon.md)
	iconSlot.BackgroundTransparency = 1
	iconSlot.ZIndex = z + 1
	iconSlot.Visible = false
	iconSlot.Parent = frame
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.LayoutOrder = 2
	label.Size = UDim2.fromOffset(0, height)
	label.BackgroundTransparency = 1
	label.Font = Tokens.typography.label.font
	label.TextSize = Tokens.typography.label.size
	label.TextColor3 = Tokens.color.inkStrong
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = ""
	label.ZIndex = z + 1
	label.Parent = frame
	-- Width follows the text (never AutomaticSize: scale-sized shadow and art children would feed
	-- back into it). Fixed-width chips keep their width and centre the text.
	if not opts.width then
		local function fit()
			local iconWidth = if iconSlot.Visible then Tokens.icon.md + Tokens.spacing.sm else 0
			local width = math.ceil(label.TextBounds.X) + iconWidth + Tokens.spacing.md + Tokens.spacing.lg
			label.Size = UDim2.fromOffset(math.ceil(label.TextBounds.X) + 2, height)
			frame.Size = UDim2.fromOffset(math.max(height, width), height)
		end
		label:GetPropertyChangedSignal("TextBounds"):Connect(fit)
		iconSlot:GetPropertyChangedSignal("Visible"):Connect(fit)
		fit()
	end
	frame.Parent = parent
	return frame, label, iconSlot
end

return Frame
