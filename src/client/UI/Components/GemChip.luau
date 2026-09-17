--!strict
-- Gem balance chip for a modal header, to the reference clip (17 Sep 2026): a dark slate pill with
-- a thick black keyline, the painted gem, the count in white with a black stroke, and a round green
-- "+" that opens the gem bundles. Sized in Scale from its parent's height.

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
	Depth.panel(root, Tokens.color.surface, { radius = Tokens.radius.pill })
	Fit.corner(root, 0.5)
	root.Parent = parent

	local gem = Fit.image(root, "hud.gem", {
		size = UDim2.fromScale(0, 0.74),
		position = UDim2.fromScale(0.16, 0.5),
		zIndex = z + 2,
		name = "Gem",
	})
	if gem then
		Fit.aspect(gem, 1, Enum.DominantAxis.Height)
	else
		local glyph = Icons.gem(root, 10, { zIndex = z + 2 })
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromScale(0.16, 0.5)
		glyph.Size = UDim2.fromScale(0, 0.7)
		Fit.aspect(glyph, 1, Enum.DominantAxis.Height)
	end
	local count = Fit.text(root, "Count", withCommas(options.count), {
		font = Tokens.typography.numeral.font,
		color = Tokens.color.featherWhite,
		max = 30,
		zIndex = z + 2,
		outline = 2.6,
		outlineColor = Tokens.color.outline,
		size = UDim2.fromScale(0.42, 0.72),
		position = UDim2.fromScale(0.29, 0.14),
		align = Enum.TextXAlignment.Center,
	})

	local plus = Instance.new("TextButton")
	plus.Name = "Plus"
	plus.Text = ""
	plus.AutoButtonColor = false
	plus.AnchorPoint = Vector2.new(0.5, 0.5)
	plus.Position = UDim2.fromScale(0.85, 0.5)
	plus.Size = UDim2.fromScale(0, 0.84)
	plus.BackgroundColor3 = Tokens.color.leafDeep
	plus.BorderSizePixel = 0
	plus.ZIndex = z + 2
	plus.Selectable = true
	Fit.aspect(plus, 1, Enum.DominantAxis.Height)
	Fit.corner(plus, 0.5)
	Depth.keyline(plus, Tokens.depth.keylineThin)
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.fromScale(1, 0.9)
	face.BackgroundColor3 = Tokens.color.success
	face.BorderSizePixel = 0
	face.ZIndex = z + 3
	Fit.corner(face, 0.5)
	Depth.applySheen(face, Tokens.color.success, Tokens.color.leafBright)
	Depth.rim(face, Tokens.color.success)
	face.Parent = plus
	Fit.text(face, "Glyph", "+", {
		font = Tokens.typography.display.font,
		color = Tokens.color.featherWhite,
		max = 34,
		zIndex = z + 4,
		outline = 2.6,
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
