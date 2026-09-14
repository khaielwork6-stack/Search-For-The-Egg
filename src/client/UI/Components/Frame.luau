--!strict
-- Hand-drawn frame kit for Search for the Egg. Everything is vector (frames, corners, strokes,
-- gradients) plus two low-alpha textures from the owner's pack, so the UI feels made for the game
-- rather than sliced from a kit: cream "cookie" panels with a bottom lip, gold header bands with a
-- rays backdrop and outlined lettering, feather-white rows, cream chips, gold meters, badges.
-- No drop shadows: a Roblox child can never draw beneath its parent, so depth comes from lips,
-- outlines and gradients instead.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local AssetManifest = require(Shared.Design.AssetManifest)

local Frame = {}

local LIP = 5

local function texture(parent: GuiObject, role: string, transparency: number, color: Color3, tile: number?, zIndex: number?): ImageLabel?
	local id = AssetManifest.image(role)
	if not id then
		return nil
	end
	local label = Instance.new("ImageLabel")
	label.Name = "Texture_" .. role
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Image = id
	label.ImageTransparency = transparency
	label.ImageColor3 = color
	if tile then
		label.ScaleType = Enum.ScaleType.Tile
		label.TileSize = UDim2.fromOffset(tile, tile)
	else
		label.ScaleType = Enum.ScaleType.Crop
	end
	label.ZIndex = zIndex or parent.ZIndex
	label.Parent = parent
	return label
end
Frame.texture = texture

-- Chunky lettering: a cocoa outline around the glyphs (the pack's titles use the same device).
function Frame.outline(label: TextLabel | TextButton, thickness: number?, color: Color3?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Name = "TextOutline"
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Thickness = thickness or 2
	stroke.Color = color or Tokens.color.outline
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label
	return stroke
end

-- Kept for callers: shadows are retired (they rendered as grey boxes inside their parents).
function Frame.shadow(target: GuiObject, _options: { lifted: boolean?, radius: number? }?): Frame
	local ghost = Instance.new("Frame")
	ghost.Name = "Shadow"
	ghost.Visible = false
	ghost.BackgroundTransparency = 1
	ghost.Size = UDim2.fromScale(0, 0)
	ghost.Parent = target
	return ghost
end

-- Cookie panel: cocoa outline, a darker lip along the bottom edge, cream body with a faint studs
-- weave and a top-light gradient. Returns (outer, panel) where `panel` is the content parent.
function Frame.goldPanel(
	parent: Instance,
	name: string,
	options: {
		radius: number?,
		padding: number?,
		zIndex: number?,
		shadow: boolean?,
		inset: number?,
		fill: Color3?,
		lipColor: Color3?,
		texture: boolean?,
	}?
): (Frame, Frame)
	local opts = (options or {}) :: any
	local radius = opts.radius or Tokens.radius.xl
	local z = opts.zIndex or 1
	local outer = Instance.new("Frame")
	outer.Name = name
	outer.BackgroundColor3 = opts.lipColor or Tokens.color.goldDeep
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

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.new(1, 0, 1, -LIP)
	panel.BackgroundColor3 = opts.fill or Tokens.color.panel
	panel.BorderSizePixel = 0
	panel.ZIndex = z + 1
	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, radius)
	panelCorner.Parent = panel
	local light = Instance.new("UIGradient")
	light.Name = "Paper"
	light.Rotation = 90
	light.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Tokens.color.featherWhite),
		ColorSequenceKeypoint.new(0.25, opts.fill or Tokens.color.panel),
		ColorSequenceKeypoint.new(1, Tokens.color.panelDeep),
	})
	light.Parent = panel
	if opts.texture ~= false then
		-- On the outer card (not inside the panel's list layout), drawn above the panel body and
		-- below its content.
		local weave = texture(outer, "texture.studs", 0.965, Tokens.color.cocoa, 28, z + 1)
		if weave then
			weave.Name = "Weave"
			weave.Size = UDim2.new(1, 0, 1, -LIP)
			local weaveCorner = Instance.new("UICorner")
			weaveCorner.CornerRadius = UDim.new(0, radius)
			weaveCorner.Parent = weave
		end
	end
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

-- Gold header band with a rays backdrop and an outlined title. Returns (band, titleLabel).
function Frame.headerBand(
	parent: Instance,
	name: string,
	text: string,
	options: { height: number?, zIndex: number?, radius: number?, color: Color3?, deep: Color3? }?
): (Frame, TextLabel)
	local opts = (options or {}) :: any
	local z = opts.zIndex or 1
	local height = opts.height or Tokens.layout.minimumTapTargetPx + Tokens.spacing.md
	local band = Instance.new("Frame")
	band.Name = name
	band.Size = UDim2.new(1, 0, 0, height)
	band.BackgroundColor3 = opts.color or Tokens.color.gold
	band.BorderSizePixel = 0
	band.ZIndex = z
	band.ClipsDescendants = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, opts.radius or Tokens.radius.lg)
	corner.Parent = band
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.bold
	stroke.Color = Tokens.color.outline
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = band
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Tokens.color.goldLight),
		ColorSequenceKeypoint.new(0.55, opts.color or Tokens.color.gold),
		ColorSequenceKeypoint.new(1, opts.deep or Tokens.color.goldDeep),
	})
	gradient.Parent = band
	texture(band, "texture.rays", 0.72, Tokens.color.featherWhite, nil, z + 1)
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 1)
	title.BackgroundTransparency = 1
	title.Font = Tokens.typography.display.font
	title.TextSize = Tokens.typography.title.size + 2
	title.TextColor3 = Tokens.color.featherWhite
	title.Text = text
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.ZIndex = z + 2
	title.Parent = band
	Frame.outline(title, 2.5)
	band.Parent = parent
	return band, title
end

-- Nameplate pill (station names, results lines): cream pill, gold outlined lettering.
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
		outline: boolean?,
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
	label.TextColor3 = opts.textColor or Tokens.color.goldDeep
	label.Text = text
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.ZIndex = opts.zIndex or 1
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	corner.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.standard
	stroke.Color = Tokens.color.outline
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
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
	if opts.outline ~= false then
		Frame.outline(label, 1.5, Tokens.color.outline)
	end
	if opts.fitText then
		label.TextTruncate = Enum.TextTruncate.None
		local height = label.Size.Y.Offset
		local function fit()
			label.Size = UDim2.fromOffset(math.ceil(label.TextBounds.X) + Tokens.spacing.lg * 2 + 4, height)
		end
		label:GetPropertyChangedSignal("TextBounds"):Connect(fit)
		fit()
	end
	label.Parent = parent
	return label
end

-- Body text (ink on cream).
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

-- Section heading: small gold pip + chunky heading.
function Frame.heading(parent: Instance, name: string, text: string, zIndex: number?): Frame
	local z = zIndex or 1
	local row = Instance.new("Frame")
	row.Name = name
	row.Size = UDim2.new(1, 0, 0, Tokens.typography.heading.size + Tokens.spacing.md)
	row.BackgroundTransparency = 1
	row.ZIndex = z
	local pip = Instance.new("Frame")
	pip.Name = "Pip"
	pip.AnchorPoint = Vector2.new(0, 0.5)
	pip.Position = UDim2.fromScale(0, 0.5)
	pip.Size = UDim2.fromOffset(10, 10)
	pip.BackgroundColor3 = Tokens.color.gold
	pip.BorderSizePixel = 0
	pip.ZIndex = z
	local pipCorner = Instance.new("UICorner")
	pipCorner.CornerRadius = UDim.new(1, 0)
	pipCorner.Parent = pip
	local pipStroke = Instance.new("UIStroke")
	pipStroke.Thickness = Tokens.stroke.standard
	pipStroke.Color = Tokens.color.outline
	pipStroke.Parent = pip
	pip.Parent = row
	local label = Frame.text(row, "Text", text, "heading", { zIndex = z, color = Tokens.color.inkStrong })
	label.Font = Tokens.typography.label.font
	label.TextSize = Tokens.typography.label.size + 1
	label.Position = UDim2.fromOffset(Tokens.spacing.lg + 2, 0)
	label.Size = UDim2.new(1, -(Tokens.spacing.lg + 2), 1, 0)
	row.Parent = parent
	return row
end

-- Leaf accents at the bottom corners (art when available, else drawn).
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

function Frame.feathers(_parent: Instance, _zIndex: number?) end

export type MeterHandle = { track: Frame, fill: Frame, set: (fraction: number, animate: boolean?) -> (), setColor: (color: Color3) -> () }

-- Progress meter: recessed cream track, gold fill with a light cap, animated.
function Frame.meter(
	parent: Instance,
	name: string,
	fraction: number,
	options: { height: number?, fill: Color3?, zIndex: number?, motion: (() -> Motion.MotionSettings)? }?
): (Frame, Frame, MeterHandle)
	local opts = (options or {}) :: any
	local height = opts.height or 12
	local track = Instance.new("Frame")
	track.Name = name
	track.Size = UDim2.new(1, 0, 0, height)
	track.BackgroundColor3 = Tokens.color.creamDeep
	track.BorderSizePixel = 0
	track.ZIndex = opts.zIndex or 1
	track.ClipsDescendants = true
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track
	local trackStroke = Instance.new("UIStroke")
	trackStroke.Thickness = Tokens.stroke.standard
	trackStroke.Color = Tokens.color.outline
	trackStroke.Transparency = 0.35
	trackStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
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
		ColorSequenceKeypoint.new(1, Color3.fromRGB(205, 205, 205)),
	})
	fillGradient.Parent = fill
	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = Vector2.new(0, height)
	sizeConstraint.Parent = fill
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

-- Row / card: feather-white body on a cocoa-tinted lip, soft outline.
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
	row.BackgroundColor3 = if opts.muted then Tokens.color.surfaceAlt else (opts.tint or Tokens.color.featherWhite)
	row.BorderSizePixel = 0
	row.ZIndex = zIndex or 1
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.md)
	corner.Parent = row
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.standard
	stroke.Color = Tokens.color.outline
	stroke.Transparency = if opts.muted then 0.75 else 0.55
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = row
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(240, 236, 228)),
	})
	gradient.Parent = row
	local padding = Instance.new("UIPadding")
	local pad = opts.padding or Tokens.spacing.md
	padding.PaddingLeft = UDim.new(0, pad)
	padding.PaddingRight = UDim.new(0, pad)
	padding.Parent = row
	row.Parent = parent
	return row
end

-- Rounded badge ("MAX", "NEW") in a tone colour with outlined text.
function Frame.badge(parent: Instance, name: string, text: string, tone: Color3?, zIndex: number?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, Tokens.typography.caption.size + Tokens.spacing.sm + 2)
	label.BackgroundColor3 = tone or Tokens.color.tealAccent
	label.BorderSizePixel = 0
	label.Font = Tokens.typography.label.font
	label.TextSize = Tokens.typography.caption.size
	label.TextColor3 = Tokens.color.featherWhite
	label.Text = text
	label.ZIndex = zIndex or 1
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = label
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.sm + 2)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.sm + 2)
	padding.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.standard
	stroke.Color = Tokens.color.outline
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = label
	Frame.outline(label, 1.2)
	label.Parent = parent
	return label
end

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

-- HUD chip: cream pill on a cocoa lip, optional leading icon slot, outlined numerals.
-- Returns (chip, textLabel, iconSlot). Width follows the text unless `width` is given.
function Frame.chip(
	parent: Instance,
	name: string,
	options: { zIndex: number?, width: number?, height: number?, fill: Color3?, art: string?, lip: Color3? }?
): (Frame, TextLabel, Frame)
	local opts = (options or {}) :: any
	local z = opts.zIndex or Tokens.zIndex.hud
	local height = opts.height or Tokens.layout.minimumTapTargetPx
	local chip = Instance.new("Frame")
	chip.Name = name
	chip.Size = UDim2.fromOffset(opts.width or height * 2, height)
	chip.BackgroundColor3 = opts.lip or Tokens.color.goldDeep
	chip.BorderSizePixel = 0
	chip.ZIndex = z
	local chipCorner = Instance.new("UICorner")
	chipCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	chipCorner.Parent = chip
	local outline = Instance.new("UIStroke")
	outline.Thickness = Tokens.stroke.bold
	outline.Color = Tokens.color.outline
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	outline.Parent = chip
	local scale = Instance.new("UIScale")
	scale.Parent = chip
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.new(1, 0, 1, -4)
	face.BackgroundColor3 = opts.fill or Tokens.color.creamPill
	face.BorderSizePixel = 0
	face.ZIndex = z + 1
	local faceCorner = Instance.new("UICorner")
	faceCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	faceCorner.Parent = face
	local faceGradient = Instance.new("UIGradient")
	faceGradient.Rotation = 90
	faceGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Tokens.color.featherWhite),
		ColorSequenceKeypoint.new(1, opts.fill or Tokens.color.creamPill),
	})
	faceGradient.Parent = face
	face.Parent = chip
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, 0, 1, -4)
	content.BackgroundTransparency = 1
	content.ZIndex = z + 3
	content.Parent = chip
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.HorizontalAlignment = if opts.width then Enum.HorizontalAlignment.Center else Enum.HorizontalAlignment.Left
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Tokens.spacing.sm)
	layout.Parent = content
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	padding.Parent = content
	local iconSlot = Instance.new("Frame")
	iconSlot.Name = "IconSlot"
	iconSlot.LayoutOrder = 1
	iconSlot.Size = UDim2.fromOffset(Tokens.icon.md + 2, Tokens.icon.md + 2)
	iconSlot.BackgroundTransparency = 1
	iconSlot.ZIndex = z + 4
	iconSlot.Visible = false
	iconSlot.Parent = content
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.LayoutOrder = 2
	label.Size = UDim2.fromOffset(0, height - 4)
	label.BackgroundTransparency = 1
	label.Font = Tokens.typography.label.font
	label.TextSize = Tokens.typography.label.size + 1
	label.TextColor3 = Tokens.color.inkStrong
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = ""
	label.ZIndex = z + 4
	label.Parent = content
	if not opts.width then
		local function fit()
			local iconWidth = if iconSlot.Visible then Tokens.icon.md + 2 + Tokens.spacing.sm else 0
			local width = math.ceil(label.TextBounds.X) + iconWidth + Tokens.spacing.md + Tokens.spacing.lg
			label.Size = UDim2.fromOffset(math.ceil(label.TextBounds.X) + 2, height - 4)
			chip.Size = UDim2.fromOffset(math.max(height, width), height)
		end
		label:GetPropertyChangedSignal("TextBounds"):Connect(fit)
		iconSlot:GetPropertyChangedSignal("Visible"):Connect(fit)
		fit()
	end
	chip.Parent = parent
	return chip, label, iconSlot
end

return Frame
