--!strict
-- Gem balance chip for a modal header: a dark slate chip, a darker well, the painted gem, the count
-- in white stroked numerals, and a round green "+" that opens the gem bundles. Sized in Scale from
-- its parent's height.

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
	setCount: (count: number) -> (),
	destroy: () -> (),
}

local CHIP = Tokens.color.surface
local WELL = Tokens.color.panelDeep
local PLUS = Tokens.color.success
local PLUS_DEEP = Tokens.color.leafDeep

local function withCommas(n: number): string
	local text = tostring(math.floor(n))
	return (text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

function GemChip.build(
	parent: Instance,
	options: { count: number, zIndex: number?, minimumTapTarget: number?, onPlus: (() -> ())?, sound: (() -> ())? }
): Handle
	local z = options.zIndex or 1
	local root = Instance.new("Frame")
	root.Name = "GemChip"
	root.Size = UDim2.fromScale(0, 1)
	root.BorderSizePixel = 0
	root.ZIndex = z
	Fit.aspect(root, 3.3, Enum.DominantAxis.Height)
	Depth.panel(root, CHIP, { radius = Tokens.radius.md })
	Fit.corner(root, 0.3)
	root.Parent = parent

	local window = Instance.new("Frame")
	window.Name = "Window"
	window.Position = UDim2.fromScale(0.05, 0.14)
	window.Size = UDim2.fromScale(0.66, 0.72)
	window.BackgroundColor3 = WELL
	window.BorderSizePixel = 0
	window.ZIndex = 2
	Fit.corner(window, 0.35)
	local line = Depth.keyline(window)
	line.Thickness = Tokens.depth.keylineThin
	window.Parent = root

	local gem = Fit.image(window, "hud.gem", {
		size = UDim2.fromScale(0, 0.86),
		position = UDim2.fromScale(0.17, 0.5),
		zIndex = 3,
		name = "Gem",
	})
	if gem then
		Fit.aspect(gem, 1, Enum.DominantAxis.Height)
	else
		local glyph = Icons.gem(window, 10, { zIndex = 3 })
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromScale(0.17, 0.5)
		glyph.Size = UDim2.fromScale(0, 0.8)
		Fit.aspect(glyph, 1, Enum.DominantAxis.Height)
	end
	local count = Fit.text(window, "Count", withCommas(options.count), {
		font = Tokens.typography.numeral.font,
		color = Tokens.color.featherWhite,
		max = 30,
		zIndex = 3,
		outline = 2,
		outlineColor = Tokens.color.outline,
		size = UDim2.fromScale(0.62, 0.8),
		position = UDim2.fromScale(0.34, 0.1),
		align = Enum.TextXAlignment.Center,
	})

	local plus = Instance.new("TextButton")
	plus.Name = "Plus"
	plus.Text = ""
	plus.AutoButtonColor = false
	plus.AnchorPoint = Vector2.new(0.5, 0.5)
	plus.Position = UDim2.fromScale(0.855, 0.5)
	plus.Size = UDim2.fromScale(0, 0.86)
	plus.BackgroundColor3 = PLUS_DEEP
	plus.BorderSizePixel = 0
	plus.ZIndex = 3
	plus.Selectable = true
	Fit.aspect(plus, 1, Enum.DominantAxis.Height)
	Fit.corner(plus, 0.5)
	Depth.keyline(plus)
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.fromScale(1, 0.9)
	face.BackgroundColor3 = PLUS
	face.BorderSizePixel = 0
	face.ZIndex = 4
	Fit.corner(face, 0.5)
	Depth.applySheen(face, PLUS)
	Depth.rim(face, PLUS)
	face.Parent = plus
	Fit.text(face, "Glyph", "+", {
		font = Tokens.typography.display.font,
		color = Tokens.color.featherWhite,
		max = 34,
		zIndex = 5,
		outline = 2,
		outlineColor = Tokens.color.outline,
		size = UDim2.fromScale(0.9, 0.9),
		position = UDim2.fromScale(0.5, 0.48),
		anchor = Vector2.new(0.5, 0.5),
	})
	local plusScale = Instance.new("UIScale")
	plusScale.Parent = plus
	plus.MouseEnter:Connect(function()
		TweenService:Create(plusScale, TweenInfo.new(0.12), { Scale = 1.1 }):Play()
	end)
	plus.MouseLeave:Connect(function()
		TweenService:Create(plusScale, TweenInfo.new(0.12), { Scale = 1 }):Play()
	end)
	local connection = plus.Activated:Connect(function()
		if options.sound then
			options.sound()
		end
		if options.onPlus then
			options.onPlus()
		end
	end)
	plus.Parent = root

	local shown = options.count
	return {
		root = root,
		setCount = function(value: number)
			if value ~= shown then
				shown = value
				count.Text = withCommas(value)
				local pop = count:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
				pop.Parent = count
				pop.Scale = 1.25
				TweenService:Create(pop, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
			end
		end,
		destroy = function()
			connection:Disconnect()
			root:Destroy()
		end,
	}
end

return GemChip
