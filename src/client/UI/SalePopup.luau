--!strict
-- Sale result popup: a dark slate card that springs up above the round strip when a trade lands,
-- "Sold N feathers" with the cash counting up in white stroked numerals, a gold coin, a confetti
-- burst and layered ticks. One at a time; a new sale replaces the card. Cosmetic - the server owns
-- the cash.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local EconomyMath = require(Shared.EconomyMath)
local FrameKit = require(script.Parent.Components.Frame)
local Depth = require(script.Parent.Components.Depth)
local Icons = require(script.Parent.Components.Icons)
local Skin = require(script.Parent.Components.Skin)
local Tween = require(script.Parent.Components.Tween)
local Confetti = require(script.Parent.Components.Confetti)

local SalePopup = {}

export type Options = {
	feathers: number,
	cents: number,
	motion: Motion.MotionSettings,
	tier: string?,
	onTick: (() -> ())?,
	zIndex: number?,
}

local current: Frame? = nil

function SalePopup.show(parent: GuiObject, options: Options)
	if current then
		current:Destroy()
		current = nil
	end
	local z = options.zIndex or Tokens.zIndex.toast
	local card = Instance.new("Frame")
	card.Name = "SalePopup"
	card.AnchorPoint = Vector2.new(0.5, 1)
	card.Position = UDim2.new(0.5, 0, 1, -(Tokens.layout.safeAreaPaddingPx + Tokens.layout.minimumTapTargetPx * 2 + Tokens.spacing.xl * 2))
	card.Size = UDim2.fromOffset(280, Tokens.layout.minimumTapTargetPx + Tokens.spacing.xl)
	card.ZIndex = z
	Depth.panel(card, Tokens.color.surface, { radius = Tokens.radius.lg })
	local scale = Instance.new("UIScale")
	scale.Scale = 0.6
	scale.Parent = card
	local coinArt = Skin.icon(card, "hud.token", Tokens.icon.lg + Tokens.spacing.sm, z + 1)
	if coinArt then
		coinArt.ImageColor3 = Tokens.color.gold
	end
	local coin = coinArt or Icons.coin(card, Tokens.icon.lg + Tokens.spacing.sm, { zIndex = z + 1 })
	coin.AnchorPoint = Vector2.new(0, 0.5)
	coin.Position = UDim2.new(0, Tokens.spacing.md, 0.5, 0)
	local title = FrameKit.text(
		card,
		"Title",
		string.format("Sold %d feather%s", options.feathers, if options.feathers == 1 then "" else "s"),
		"heading",
		{ zIndex = z + 1, color = Tokens.color.featherWhite }
	)
	title.Position = UDim2.fromOffset(Tokens.spacing.md + Tokens.icon.lg + Tokens.spacing.md, Tokens.spacing.sm)
	title.Size = UDim2.new(1, -(Tokens.spacing.md * 3 + Tokens.icon.lg), 0, Tokens.typography.heading.size + 2)
	FrameKit.outline(title, 2)
	local amount = FrameKit.text(card, "Amount", "+$0.00", "display", { zIndex = z + 1, color = Tokens.color.featherWhite })
	amount.Font = Tokens.typography.label.font
	amount.TextSize = Tokens.typography.title.size
	FrameKit.outline(amount, 3)
	amount.Position = UDim2.fromOffset(
		Tokens.spacing.md + Tokens.icon.lg + Tokens.spacing.md,
		Tokens.spacing.sm + Tokens.typography.heading.size + Tokens.spacing.xs
	)
	amount.Size = UDim2.new(1, -(Tokens.spacing.md * 3 + Tokens.icon.lg), 0, Tokens.typography.title.size + 2)
	card.Parent = parent
	current = card

	local motion = options.motion
	local pop = Motion.recipe("notifyGrow", motion)
	TweenService:Create(scale, Motion.tweenInfo(pop), { Scale = 1 }):Play()
	Confetti.burst(
		card,
		{ origin = UDim2.fromScale(0.5, 0.2), count = 26, spread = 150, motion = motion, tier = options.tier, zIndex = z + 2 }
	)
	local duration = Motion.duration("slow", motion) * 2.5
	local started = os.clock()
	local ticks = 0
	task.spawn(function()
		while card.Parent do
			local t = math.clamp((os.clock() - started) / duration, 0, 1)
			local eased = 1 - (1 - t) ^ 3
			amount.Text = "+" .. EconomyMath.formatCents(math.floor(options.cents * eased + 0.5))
			if options.onTick and ticks % 3 == 0 and ticks < 18 then
				options.onTick()
			end
			ticks += 1
			if t >= 1 then
				break
			end
			task.wait()
		end
	end)
	task.delay(2.6, function()
		if card.Parent then
			local shrink = Motion.recipe("notifyShrink", motion)
			local tween = TweenService:Create(scale, Motion.tweenInfo(shrink), { Scale = shrink.toScale or 0.7 })
			Tween.fade(card, motion, 1, "standard")
			tween:Play()
			tween.Completed:Once(function()
				if current == card then
					current = nil
				end
				card:Destroy()
			end)
		end
	end)
end

return SalePopup
