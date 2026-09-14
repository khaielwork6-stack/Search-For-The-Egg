--!strict
-- Vector icon kit: every glyph is built from frames (UICorner / UIStroke / rotation), so icons scale
-- crisply on any device, tint from tokens, and never blur or stretch. Each builder returns a square
-- container frame (size `px`) whose children are the glyph; callers place it like an image.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)

local Icons = {}

export type Options = { color: Color3?, secondary: Color3?, zIndex: number?, outline: boolean? }

local function container(parent: Instance, name: string, px: number, z: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = UDim2.fromOffset(px, px)
	frame.BackgroundTransparency = 1
	frame.ZIndex = z
	frame.Parent = parent
	return frame
end

local function shape(
	parent: Frame,
	name: string,
	size: UDim2,
	position: UDim2,
	color: Color3,
	z: number,
	radius: number?,
	rotation: number?,
	outline: Color3?
): Frame
	local piece = Instance.new("Frame")
	piece.Name = name
	piece.AnchorPoint = Vector2.new(0.5, 0.5)
	piece.Size = size
	piece.Position = position
	piece.BackgroundColor3 = color
	piece.BorderSizePixel = 0
	piece.Rotation = rotation or 0
	piece.ZIndex = z
	local corner = Instance.new("UICorner")
	corner.CornerRadius = if radius then UDim.new(0, radius) else UDim.new(1, 0)
	corner.Parent = piece
	if outline then
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = Tokens.stroke.hairline + 0.5
		stroke.Color = outline
		stroke.Parent = piece
	end
	piece.Parent = parent
	return piece
end

-- Gem: a rotated rounded square with a light facet.
function Icons.gem(parent: Instance, px: number, options: Options?): Frame
	local opts = (options or {}) :: any
	local z = opts.zIndex or 1
	local frame = container(parent, "Icon_Gem", px, z)
	local outline = if opts.outline == false then nil else Tokens.color.outline
	shape(
		frame,
		"Body",
		UDim2.fromScale(0.62, 0.62),
		UDim2.fromScale(0.5, 0.52),
		opts.color or Tokens.color.tealAccent,
		z,
		math.max(2, px * 0.14),
		45,
		outline
	)
	shape(
		frame,
		"Facet",
		UDim2.fromScale(0.22, 0.22),
		UDim2.fromScale(0.42, 0.4),
		opts.secondary or Tokens.color.tealTint,
		z + 1,
		math.max(1, px * 0.06),
		45
	)
	return frame
end

-- Coin: a gold disc with a deeper rim and a highlight.
function Icons.coin(parent: Instance, px: number, options: Options?): Frame
	local opts = (options or {}) :: any
	local z = opts.zIndex or 1
	local frame = container(parent, "Icon_Coin", px, z)
	shape(
		frame,
		"Rim",
		UDim2.fromScale(0.86, 0.86),
		UDim2.fromScale(0.5, 0.5),
		opts.secondary or Tokens.color.goldDeep,
		z,
		nil,
		0,
		if opts.outline == false then nil else Tokens.color.outline
	)
	shape(frame, "Face", UDim2.fromScale(0.62, 0.62), UDim2.fromScale(0.5, 0.5), opts.color or Tokens.color.gold, z + 1)
	shape(frame, "Shine", UDim2.fromScale(0.18, 0.18), UDim2.fromScale(0.4, 0.38), Tokens.color.goldLight, z + 2)
	return frame
end

-- Feather: a tilted rounded vane with a quill line.
function Icons.feather(parent: Instance, px: number, options: Options?): Frame
	local opts = (options or {}) :: any
	local z = opts.zIndex or 1
	local frame = container(parent, "Icon_Feather", px, z)
	local vane = shape(
		frame,
		"Vane",
		UDim2.fromScale(0.42, 0.86),
		UDim2.fromScale(0.52, 0.5),
		opts.color or Tokens.color.featherWhite,
		z,
		nil,
		28,
		if opts.outline == false then nil else Tokens.color.outline
	)
	shape(vane, "Quill", UDim2.fromScale(0.12, 0.9), UDim2.fromScale(0.5, 0.5), opts.secondary or Tokens.color.strawDeep, z + 1, nil, 0)
	return frame
end

-- Egg: a tall ellipse with two spots.
function Icons.egg(parent: Instance, px: number, options: Options?): Frame
	local opts = (options or {}) :: any
	local z = opts.zIndex or 1
	local frame = container(parent, "Icon_Egg", px, z)
	local body = shape(
		frame,
		"Shell",
		UDim2.fromScale(0.62, 0.82),
		UDim2.fromScale(0.5, 0.52),
		opts.color or Tokens.color.cream,
		z,
		nil,
		0,
		if opts.outline == false then nil else Tokens.color.outline
	)
	shape(body, "Spot1", UDim2.fromScale(0.3, 0.22), UDim2.fromScale(0.38, 0.42), opts.secondary or Tokens.color.straw, z + 1)
	shape(body, "Spot2", UDim2.fromScale(0.22, 0.18), UDim2.fromScale(0.66, 0.66), opts.secondary or Tokens.color.straw, z + 1)
	return frame
end

-- Clock: a ring with two hands.
function Icons.clock(parent: Instance, px: number, options: Options?): Frame
	local opts = (options or {}) :: any
	local z = opts.zIndex or 1
	local frame = container(parent, "Icon_Clock", px, z)
	local ring = shape(frame, "Ring", UDim2.fromScale(0.8, 0.8), UDim2.fromScale(0.5, 0.5), Tokens.color.featherWhite, z)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = math.max(1.5, px * 0.09)
	stroke.Color = opts.color or Tokens.color.outline
	stroke.Parent = ring
	shape(ring, "Hour", UDim2.fromScale(0.12, 0.32), UDim2.fromScale(0.5, 0.36), opts.color or Tokens.color.outline, z + 1, nil, 0)
	shape(ring, "Minute", UDim2.fromScale(0.12, 0.3), UDim2.fromScale(0.62, 0.52), opts.color or Tokens.color.outline, z + 1, nil, -60)
	return frame
end

-- Check mark: two bars.
function Icons.check(parent: Instance, px: number, options: Options?): Frame
	local opts = (options or {}) :: any
	local z = opts.zIndex or 1
	local frame = container(parent, "Icon_Check", px, z)
	local color = opts.color or Tokens.color.success
	shape(frame, "Short", UDim2.fromScale(0.16, 0.4), UDim2.fromScale(0.36, 0.62), color, z, nil, -45)
	shape(frame, "Long", UDim2.fromScale(0.16, 0.72), UDim2.fromScale(0.6, 0.48), color, z, nil, 45)
	return frame
end

-- Close: two crossed bars.
function Icons.close(parent: Instance, px: number, options: Options?): Frame
	local opts = (options or {}) :: any
	local z = opts.zIndex or 1
	local frame = container(parent, "Icon_Close", px, z)
	local color = opts.color or Tokens.color.inkStrong
	shape(frame, "A", UDim2.fromScale(0.16, 0.72), UDim2.fromScale(0.5, 0.5), color, z, nil, 45)
	shape(frame, "B", UDim2.fromScale(0.16, 0.72), UDim2.fromScale(0.5, 0.5), color, z, nil, -45)
	return frame
end

-- Lock: a body with a shackle ring.
function Icons.lock(parent: Instance, px: number, options: Options?): Frame
	local opts = (options or {}) :: any
	local z = opts.zIndex or 1
	local frame = container(parent, "Icon_Lock", px, z)
	local color = opts.color or Tokens.color.inkMuted
	local shackle = shape(frame, "Shackle", UDim2.fromScale(0.44, 0.44), UDim2.fromScale(0.5, 0.36), Tokens.color.featherWhite, z)
	shackle.BackgroundTransparency = 1
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = math.max(1.5, px * 0.1)
	stroke.Color = color
	stroke.Parent = shackle
	shape(frame, "Body", UDim2.fromScale(0.58, 0.42), UDim2.fromScale(0.5, 0.66), color, z + 1, math.max(2, px * 0.12), 0)
	return frame
end

-- Star: two overlapping rotated squares read as a chunky star at small sizes.
function Icons.star(parent: Instance, px: number, options: Options?): Frame
	local opts = (options or {}) :: any
	local z = opts.zIndex or 1
	local frame = container(parent, "Icon_Star", px, z)
	local color = opts.color or Tokens.color.gold
	shape(frame, "A", UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0.5, 0.5), color, z, math.max(1, px * 0.1), 0)
	shape(frame, "B", UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0.5, 0.5), color, z, math.max(1, px * 0.1), 45)
	shape(frame, "C", UDim2.fromScale(0.22, 0.22), UDim2.fromScale(0.5, 0.5), Tokens.color.goldLight, z + 1)
	return frame
end

-- Gear: a ring with four ticks.
function Icons.gear(parent: Instance, px: number, options: Options?): Frame
	local opts = (options or {}) :: any
	local z = opts.zIndex or 1
	local frame = container(parent, "Icon_Gear", px, z)
	local color = opts.color or Tokens.color.inkStrong
	for index, angle in ipairs({ 0, 45, 90, 135 }) do
		shape(frame, "Tick" .. index, UDim2.fromScale(0.22, 0.92), UDim2.fromScale(0.5, 0.5), color, z, math.max(1, px * 0.08), angle)
	end
	local ring = shape(frame, "Ring", UDim2.fromScale(0.6, 0.6), UDim2.fromScale(0.5, 0.5), color, z + 1)
	shape(ring, "Hole", UDim2.fromScale(0.42, 0.42), UDim2.fromScale(0.5, 0.5), opts.secondary or Tokens.color.cream, z + 2)
	return frame
end

-- Chevron (right): two bars meeting at a point.
function Icons.chevron(parent: Instance, px: number, options: Options?): Frame
	local opts = (options or {}) :: any
	local z = opts.zIndex or 1
	local frame = container(parent, "Icon_Chevron", px, z)
	local color = opts.color or Tokens.color.inkStrong
	shape(frame, "A", UDim2.fromScale(0.16, 0.46), UDim2.fromScale(0.52, 0.36), color, z, nil, -45)
	shape(frame, "B", UDim2.fromScale(0.16, 0.46), UDim2.fromScale(0.52, 0.64), color, z, nil, 45)
	return frame
end

-- Key cap: a rounded square with a letter, for input prompt glyphs (LMB, E, RT...).
function Icons.keycap(parent: Instance, text: string, px: number, options: Options?): Frame
	local opts = (options or {}) :: any
	local z = opts.zIndex or 1
	local frame = Instance.new("Frame")
	frame.Name = "Key_" .. text
	frame.Size = UDim2.fromOffset(math.max(px, px * (#text > 2 and 1.6 or 1)), px)
	frame.BackgroundColor3 = opts.color or Tokens.color.featherWhite
	frame.ZIndex = z
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, math.max(3, px * 0.22))
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.standard
	stroke.Color = opts.secondary or Tokens.color.outline
	stroke.Parent = frame
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color =
		ColorSequence.new({ ColorSequenceKeypoint.new(0, Tokens.color.featherWhite), ColorSequenceKeypoint.new(1, Tokens.color.creamDeep) })
	gradient.Parent = frame
	local label = Instance.new("TextLabel")
	label.Name = "Glyph"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Tokens.typography.heading.font
	label.TextSize = math.max(Tokens.typography.minimumBodySize, math.floor(px * 0.55))
	label.TextColor3 = Tokens.color.inkStrong
	label.Text = text
	label.ZIndex = z + 1
	label.Parent = frame
	frame.Parent = parent
	return frame
end

-- Builds a named icon by role ("gem", "coin", "feather", ...). Unknown roles draw a plain dot.
-- Flame: a rotated rounded square for the tongue over a round base, with a lighter core.
function Icons.flame(parent: Instance, px: number, options: Options?): Frame
	local opts = (options or {}) :: any
	local z = opts.zIndex or 1
	local color = opts.color or Tokens.color.ember
	local frame = container(parent, "Icon_flame", px, z)
	shape(
		frame,
		"Tongue",
		UDim2.fromScale(0.5, 0.5),
		UDim2.fromScale(0.5, 0.38),
		color,
		z,
		math.floor(px * 0.12),
		45,
		opts.outline and Tokens.color.outline or nil
	)
	shape(
		frame,
		"Base",
		UDim2.fromScale(0.66, 0.5),
		UDim2.fromScale(0.5, 0.68),
		color,
		z + 1,
		nil,
		0,
		opts.outline and Tokens.color.outline or nil
	)
	shape(frame, "Core", UDim2.fromScale(0.3, 0.3), UDim2.fromScale(0.5, 0.7), opts.secondary or Tokens.color.honey, z + 2)
	return frame
end

function Icons.build(role: string, parent: Instance, px: number, options: Options?): Frame
	local builder = (Icons :: any)[role]
	if type(builder) == "function" and role ~= "build" and role ~= "keycap" then
		return builder(parent, px, options)
	end
	local opts = (options or {}) :: any
	local frame = container(parent, "Icon_" .. role, px, opts.zIndex or 1)
	shape(frame, "Dot", UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0.5, 0.5), opts.color or Tokens.color.gold, opts.zIndex or 1)
	return frame
end

return Icons
