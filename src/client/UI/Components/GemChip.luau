--!strict
-- Gem balance pill (HUD top bar and modal headers): one dark slate pill with a thin keyline, the
-- painted gem at the left, the count in white stroked numerals scaled into its own slot, and a round
-- green "+" that opens the gem bundles, sitting flush inside the right end of the pill.
--
-- Everything inside is Scale against the pill's height H, so the same proportions hold on every
-- layout class (the stage UIScale sizes the whole pill; nothing inside is a pixel size):
--   gap g        = 0.12 H  (top / bottom / right margin of the "+", and the icon-to-count gap)
--   gem icon     = 0.70 H  square, left edge at 0.16 H (a little more than g: the pill end is round)
--   count slot   = from 0.94 H to (W - 0.96 H), 0.62 H tall, centred
--   "+" hit area = H x H square at the right end; its visible knob is (H - 2g) = 0.76 H, centred, so
--                  the knob keeps exactly g to the pill's top, bottom and right edge. Hover scale
--                  1.08 grows the knob to 0.82 H: still 0.09 H clear of the pill edge.
--   pill width W = 3.3 H with the "+" (count slot 1.4 H), 2.6 H without it (count slot 1.42 H).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Depth = require(script.Parent.Depth)
local Icons = require(script.Parent.Icons)
local Fit = require(script.Parent.Fit)

local GemChip = {}

export type Handle = {
	root: Frame,
	count: TextLabel,
	plus: TextButton,
	setCount: (count: number) -> (),
	setPlusVisible: (visible: boolean) -> (),
	destroy: () -> (),
}

local CHIP = Tokens.color.surface
local PLUS = Tokens.color.success
local PLUS_DEEP = Tokens.color.leafDeep

local GAP = 0.12
local ICON = 0.7
local ICON_LEFT = 0.16
local COUNT_LEFT = ICON_LEFT + ICON + 0.08
local KNOB = 1 - GAP * 2
local RATIO_PLUS = 3.3
local RATIO_BARE = 2.6

local function withCommas(n: number): string
	local text = tostring(math.floor(n))
	return (text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

function GemChip.withCommas(n: number): string
	return withCommas(n)
end

function GemChip.build(
	parent: Instance,
	options: {
		count: number,
		zIndex: number?,
		minimumTapTarget: number?,
		onPlus: (() -> ())?,
		sound: (() -> ())?,
		-- Pixel height for a pill in an offset layout (the HUD row, under the stage UIScale). Omitted,
		-- the pill fills its parent's height and keeps its aspect (modal headers).
		height: number?,
		showPlus: boolean?,
	}
): Handle
	local z = options.zIndex or 1
	local plusShown = options.showPlus ~= false
	local root = Instance.new("Frame")
	root.Name = "GemChip"
	root.BorderSizePixel = 0
	root.ZIndex = z
	root.BackgroundColor3 = CHIP
	Fit.corner(root, 0.5)
	Depth.keyline(root, Tokens.depth.keylineThin)
	Depth.rim(root, CHIP)
	Depth.applySheen(root, CHIP)
	local aspect: UIAspectRatioConstraint? = nil
	if not options.height then
		root.Size = UDim2.fromScale(0, 1)
		aspect = Fit.aspect(root, RATIO_PLUS, Enum.DominantAxis.Height)
	end
	-- The chip's own scale, for count-up punches and reward landings.
	local punch = Instance.new("UIScale")
	punch.Parent = root
	root.Parent = parent

	local gem = Fit.image(root, "hud.gem", {
		size = UDim2.fromScale(0, ICON),
		zIndex = z + 2,
		name = "Gem",
	})
	local icon: GuiObject
	if gem then
		icon = gem
	else
		local glyph = Icons.gem(root, 10, { zIndex = z + 2 })
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Size = UDim2.fromScale(0, ICON)
		icon = glyph
	end
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	Fit.aspect(icon, 1, Enum.DominantAxis.Height)

	local count = Fit.text(root, "Count", withCommas(options.count), {
		font = Tokens.typography.numeral.font,
		color = Tokens.color.featherWhite,
		max = 48,
		min = 8,
		zIndex = z + 2,
		outline = 2,
		outlineColor = Tokens.color.outline,
		wrap = false,
		anchor = Vector2.new(0, 0.5),
		align = Enum.TextXAlignment.Center,
	})

	-- The "+": a square hit area the pill's height, with the visible knob inset by the gap.
	local plus = Instance.new("TextButton")
	plus.Name = "Plus"
	plus.Text = ""
	plus.AutoButtonColor = false
	plus.BackgroundTransparency = 1
	plus.AnchorPoint = Vector2.new(1, 0.5)
	plus.ZIndex = z + 2
	plus.Selectable = true
	plus.Parent = root
	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(0.5, 0.5)
	knob.Size = UDim2.fromScale(KNOB, KNOB)
	knob.BackgroundColor3 = PLUS_DEEP
	knob.BorderSizePixel = 0
	knob.ZIndex = z + 3
	Fit.corner(knob, 0.5)
	Depth.keyline(knob, Tokens.stroke.hairline)
	knob.Parent = plus
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.fromScale(1, 0.9)
	face.BackgroundColor3 = PLUS
	face.BorderSizePixel = 0
	face.ZIndex = z + 4
	Fit.corner(face, 0.5)
	Depth.applySheen(face, PLUS)
	face.Parent = knob
	Fit.text(face, "Glyph", "+", {
		font = Tokens.typography.display.font,
		color = Tokens.color.featherWhite,
		max = 34,
		zIndex = z + 5,
		outline = 1.5,
		outlineColor = Tokens.color.outline,
		size = UDim2.fromScale(0.8, 0.8),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	local knobScale = Instance.new("UIScale")
	knobScale.Parent = knob
	plus.MouseEnter:Connect(function()
		TweenService:Create(knobScale, TweenInfo.new(0.12), { Scale = 1.08 }):Play()
	end)
	plus.MouseLeave:Connect(function()
		TweenService:Create(knobScale, TweenInfo.new(0.12), { Scale = 1 }):Play()
	end)
	local connection = plus.Activated:Connect(function()
		if options.sound then
			options.sound()
		end
		if options.onPlus then
			options.onPlus()
		end
	end)

	-- Every child is placed in fractions of the pill width, derived from the H-unit geometry above.
	local function layout()
		local ratio = if plusShown then RATIO_PLUS else RATIO_BARE
		if aspect then
			aspect.AspectRatio = ratio
		elseif options.height then
			root.Size = UDim2.fromOffset(math.floor(options.height * ratio + 0.5), options.height)
		end
		icon.Position = UDim2.fromScale((ICON_LEFT + ICON / 2) / ratio, 0.5)
		-- With the "+": the count ends 0.08 H short of the knob's left edge (W - g - 0.76 H - 0.08 H =
		-- W - 0.96 H). Without it: 0.24 H short of the pill's round right end.
		local countRight = if plusShown then ratio - (GAP + KNOB + 0.08) else ratio - GAP * 2
		count.Position = UDim2.fromScale(COUNT_LEFT / ratio, 0.5)
		count.Size = UDim2.fromScale((countRight - COUNT_LEFT) / ratio, 0.62)
		plus.Visible = plusShown
		plus.Position = UDim2.fromScale(1, 0.5)
		plus.Size = UDim2.fromScale(1 / ratio, 1)
	end
	layout()

	local shown = options.count
	return {
		root = root,
		count = count,
		plus = plus,
		setCount = function(value: number)
			if value ~= shown then
				shown = value
				count.Text = withCommas(value)
				local pop = count:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
				pop.Parent = count
				pop.Scale = 1.15
				TweenService:Create(pop, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
			end
		end,
		setPlusVisible = function(visible: boolean)
			if visible ~= plusShown then
				plusShown = visible
				layout()
			end
		end,
		destroy = function()
			connection:Disconnect()
			root:Destroy()
		end,
	}
end

return GemChip
