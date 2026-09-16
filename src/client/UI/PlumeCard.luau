--!strict
-- Professor Plume's card: one look, one decision. A wooden title plate over a parchment card, the
-- Rainbow Feather with its glow on the left, the count against the cost in big gold numerals on the
-- right with the two clue slips under it, and one orange button. Nothing on it is a paragraph; what
-- Plume has to say, he says over his own head.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local NestClues = require(Shared.Domain.NestClues)
local FrameKit = require(script.Parent.Components.Frame)
local Button = require(script.Parent.Components.Button)
local Depth = require(script.Parent.Components.Depth)
local Skin = require(script.Parent.Components.Skin)
local SafeArea = require(script.Parent.SafeArea)

local PlumeCard = {}

local PARCHMENT = Color3.fromRGB(248, 236, 208)
local SLIP = Color3.fromRGB(238, 222, 180)
local WOOD = Color3.fromRGB(160, 116, 66)
local WOOD_DEEP = Color3.fromRGB(110, 76, 42)
local STAMP = Color3.fromRGB(196, 52, 44)
local BLUE = Color3.fromRGB(40, 104, 172)
local CARD_W, CARD_H = 600, 440

export type State = {
	carried: number,
	cost: number?, -- nil once every clue is bought
	unlocked: { [string]: any },
	selected: string?,
	canGet: boolean,
}

export type Handle = {
	gui: ScreenGui,
	setState: (state: State) -> (),
	destroy: () -> (),
}

local function outlined(label: TextLabel, thickness: number, color: Color3?)
	FrameKit.outline(label, thickness, color)
end

function PlumeCard.create(
	parent: Instance,
	deps: { audio: any, accessibility: any, config: { [string]: any } },
	callbacks: { onGetClue: (category: string) -> (), onSelect: (category: string) -> (), onClose: () -> () }
): Handle
	local motion = deps.accessibility:motionSettings()
	local tap = Tokens.layout.minimumTapTargetPx
	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_PlumeCard"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = Tokens.zIndex.modal
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = parent
	local _, scaleCleanup, stage = SafeArea.applyScale(gui, deps.config)

	local dim = Instance.new("TextButton")
	dim.Name = "Dim"
	dim.Text = ""
	dim.BackgroundColor3 = Tokens.color.overlay
	dim.BackgroundTransparency = 0.5
	dim.Size = UDim2.fromScale(1, 1)
	dim.ZIndex = 1
	dim.Parent = stage
	dim.Activated:Connect(callbacks.onClose)

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.52)
	card.Size = UDim2.fromScale(0.62, 0.66)
	card.ZIndex = 2
	Depth.panel(card, PARCHMENT, { radius = Tokens.radius.xl })
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(CARD_W, CARD_H)
	cap.MinSize = Vector2.new(340, 300)
	cap.Parent = card
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = CARD_W / CARD_H
	ratio.Parent = card
	local entrance = Instance.new("UIScale")
	entrance.Scale = 0.72
	entrance.Parent = card
	card.Parent = stage
	FrameKit.leaves(card, 2)

	-- Title plate, overhanging the top edge.
	local plate = Instance.new("Frame")
	plate.Name = "Title"
	plate.AnchorPoint = Vector2.new(0.5, 0.5)
	plate.Position = UDim2.new(0.5, 0, 0, 4)
	plate.Size = UDim2.new(0.74, 0, 0, 66)
	plate.ZIndex = 4
	Depth.panel(plate, WOOD, { radius = Tokens.radius.lg, rim = Color3.fromRGB(214, 170, 110) })
	local plateLip = Instance.new("Frame")
	plateLip.Name = "Lip"
	plateLip.AnchorPoint = Vector2.new(0.5, 1)
	plateLip.Position = UDim2.new(0.5, 0, 1, 6)
	plateLip.Size = UDim2.new(1, 0, 0, 12)
	plateLip.BackgroundColor3 = WOOD_DEEP
	plateLip.BorderSizePixel = 0
	plateLip.ZIndex = 3
	local lipCorner = Instance.new("UICorner")
	lipCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	lipCorner.Parent = plateLip
	plateLip.Parent = plate
	local title = FrameKit.text(plate, "Text", "PROFESSOR PLUME", "display", {
		zIndex = 5,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Center,
		size = UDim2.fromScale(1, 1),
	})
	title.TextSize = 34
	outlined(title, 3, WOOD_DEEP)
	plate.Parent = card
	FrameKit.leaves(plate, 4)

	-- Close.
	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, 14, 0, -14)
	close.Size = UDim2.fromOffset(tap + 8, tap + 8)
	close.BackgroundColor3 = STAMP
	close.Text = "X"
	close.Font = Tokens.typography.display.font
	close.TextSize = 30
	close.TextColor3 = Tokens.color.featherWhite
	close.ZIndex = 6
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(1, 0)
	closeCorner.Parent = close
	Depth.keyline(close, Tokens.stroke.bold, WOOD_DEEP)
	Depth.rim(close, STAMP)
	outlined(close :: any, 2, WOOD_DEEP)
	close.Parent = card
	close.Activated:Connect(function()
		deps.audio:play(Tokens.sound.uiClose)
		callbacks.onClose()
	end)

	-- Left: the feather and its glow.
	local art = Instance.new("Frame")
	art.Name = "Art"
	art.BackgroundTransparency = 1
	art.Position = UDim2.fromScale(0.03, 0.15)
	art.Size = UDim2.fromScale(0.42, 0.6)
	art.ZIndex = 3
	art.Parent = card
	for i, spec in ipairs({ { 1.0, 0.55 }, { 0.72, 0.35 } }) do
		local glow = Instance.new("Frame")
		glow.Name = "Glow" .. i
		glow.AnchorPoint = Vector2.new(0.5, 0.5)
		glow.Position = UDim2.fromScale(0.5, 0.5)
		glow.Size = UDim2.fromScale(spec[1], spec[1])
		glow.BackgroundColor3 = Color3.fromRGB(255, 236, 170)
		glow.BackgroundTransparency = spec[2]
		glow.BorderSizePixel = 0
		glow.ZIndex = 3
		local glowCorner = Instance.new("UICorner")
		glowCorner.CornerRadius = UDim.new(1, 0)
		glowCorner.Parent = glow
		local glowRatio = Instance.new("UIAspectRatioConstraint")
		glowRatio.Parent = glow
		glow.Parent = art
	end
	local feather = Skin.icon(art, "icon.feather", 200, 5)
	local featherRatio = Instance.new("UIAspectRatioConstraint")
	if feather then
		feather.AnchorPoint = Vector2.new(0.5, 0.5)
		feather.Position = UDim2.fromScale(0.5, 0.5)
		feather.Size = UDim2.fromScale(0.86, 0.86)
		feather.Rotation = -18
		featherRatio.Parent = feather
		local rainbow = Instance.new("UIGradient")
		rainbow.Rotation = 60
		rainbow.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 96, 96)),
			ColorSequenceKeypoint.new(0.22, Color3.fromRGB(255, 176, 64)),
			ColorSequenceKeypoint.new(0.42, Color3.fromRGB(255, 236, 90)),
			ColorSequenceKeypoint.new(0.62, Color3.fromRGB(110, 226, 120)),
			ColorSequenceKeypoint.new(0.82, Color3.fromRGB(96, 170, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 110, 255)),
		})
		rainbow.Parent = feather
	end
	local sparkles = {}
	for i, spot in ipairs({ { 0.12, 0.2 }, { 0.86, 0.14 }, { 0.9, 0.78 }, { 0.1, 0.8 } }) do
		local spark =
			FrameKit.text(art, "Spark" .. i, "*", "display", { zIndex = 6, color = Tokens.color.gold, align = Enum.TextXAlignment.Center })
		spark.AnchorPoint = Vector2.new(0.5, 0.5)
		spark.Position = UDim2.fromScale(spot[1], spot[2])
		spark.Size = UDim2.fromOffset(28, 28)
		spark.TextSize = 30 + (i % 2) * 8
		outlined(spark, 1.5, Tokens.color.goldDeep)
		table.insert(sparkles, spark)
	end

	-- Right: the count, the caption, the two slips.
	local right = Instance.new("Frame")
	right.Name = "Right"
	right.BackgroundTransparency = 1
	right.Position = UDim2.fromScale(0.47, 0.13)
	right.Size = UDim2.fromScale(0.5, 0.62)
	right.ZIndex = 3
	right.Parent = card
	local count =
		FrameKit.text(right, "Count", "0 / 3", "display", { zIndex = 4, color = Tokens.color.gold, align = Enum.TextXAlignment.Center })
	count.Size = UDim2.fromScale(1, 0.42)
	count.TextScaled = true
	outlined(count, 5, WOOD_DEEP)
	local countScale = Instance.new("UIScale")
	countScale.Parent = count
	local caption = FrameKit.text(
		right,
		"Caption",
		"TRADE FOR A CLUE",
		"heading",
		{ zIndex = 4, color = Tokens.color.inkStrong, align = Enum.TextXAlignment.Center }
	)
	caption.Position = UDim2.fromScale(0, 0.42)
	caption.Size = UDim2.fromScale(1, 0.13)
	caption.TextScaled = true
	local slips = Instance.new("Frame")
	slips.Name = "Slips"
	slips.BackgroundTransparency = 1
	slips.Position = UDim2.fromScale(0, 0.58)
	slips.Size = UDim2.fromScale(1, 0.42)
	slips.ZIndex = 4
	slips.Parent = right
	local slipViews: { [string]: any } = {}
	for index, category in ipairs(NestClues.CATEGORIES) do
		local slip = Instance.new("TextButton")
		slip.Name = "Slip_" .. category
		slip.Text = ""
		slip.AutoButtonColor = false
		slip.AnchorPoint = Vector2.new(if index == 1 then 0 else 1, 0)
		slip.Position = UDim2.fromScale(if index == 1 then 0 else 1, 0)
		slip.Size = UDim2.fromScale(0.47, 1)
		slip.BackgroundColor3 = SLIP
		slip.ZIndex = 4
		local slipCorner = Instance.new("UICorner")
		slipCorner.CornerRadius = UDim.new(0, Tokens.radius.sm)
		slipCorner.Parent = slip
		Depth.keyline(slip, Tokens.stroke.standard, Tokens.color.strawDeep)
		-- The folded corner.
		local fold = Instance.new("Frame")
		fold.Name = "Fold"
		fold.Position = UDim2.fromOffset(-4, -4)
		fold.Size = UDim2.fromOffset(18, 18)
		fold.Rotation = 45
		fold.BackgroundColor3 = Tokens.color.strawDeep
		fold.BorderSizePixel = 0
		fold.ZIndex = 5
		fold.Parent = slip
		local label = FrameKit.text(
			slip,
			"Label",
			NestClues.LABELS[category],
			"caption",
			{ zIndex = 6, color = Tokens.color.inkStrong, align = Enum.TextXAlignment.Center }
		)
		label.Position = UDim2.fromScale(0, 0.08)
		label.Size = UDim2.fromScale(1, 0.22)
		label.TextScaled = true
		local value = FrameKit.text(
			slip,
			"Value",
			"?",
			"display",
			{ zIndex = 6, color = Tokens.color.inkStrong, align = Enum.TextXAlignment.Center, wrap = true }
		)
		value.Position = UDim2.fromScale(0.05, 0.32)
		value.Size = UDim2.fromScale(0.9, 0.6)
		value.TextScaled = true
		local stamp = FrameKit.badge(slip, "Stamp", "ANALYZED", STAMP, 7)
		stamp.AnchorPoint = Vector2.new(0.5, 1)
		stamp.Position = UDim2.new(0.5, 0, 1, 4)
		stamp.Rotation = -8
		stamp.TextSize = Tokens.typography.caption.size - 2
		stamp.Visible = false
		slip.Parent = slips
		slip.Activated:Connect(function()
			callbacks.onSelect(category)
		end)
		slipViews[category] = { slip = slip, value = value, stamp = stamp }
	end

	-- The one button.
	local button = Button.build(card, {
		text = "GET CLUE",
		variant = "ember",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromScale(0.86, 0.18),
		zIndex = 4,
		textSize = 40,
		sound = function()
			deps.audio:play(Tokens.sound.uiConfirm)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onActivated = function() end,
	})
	button.button.AnchorPoint = Vector2.new(0.5, 1)
	button.button.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.lg)
	local current: State? = nil
	button.button.Activated:Connect(function()
		if current and current.canGet and current.selected then
			callbacks.onGetClue(current.selected)
		else
			deps.audio:play(Tokens.sound.uiError)
		end
	end)

	-- Twinkle and a settle-in.
	TweenService:Create(entrance, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeBack), { Scale = 1 }):Play()
	local heartbeat = nil
	if not motion.reducedMotion then
		local started = os.clock()
		heartbeat = RunService.Heartbeat:Connect(function()
			local t = os.clock() - started
			for i, spark in ipairs(sparkles) do
				spark.TextTransparency = 0.5 + 0.5 * math.sin(t * 2.6 + i * 1.7)
				spark.Rotation = math.sin(t * 1.3 + i) * 20
			end
			if feather then
				feather.Rotation = -18 + math.sin(t * 1.1) * 3
				feather.Position = UDim2.fromScale(0.5, 0.5 + math.sin(t * 1.4) * 0.015)
			end
		end)
	end
	GuiService.SelectedObject = button.button

	local lastCount: string? = nil
	local function setState(state: State)
		current = state
		local cost = state.cost
		local countText = if cost then string.format("%d / %d", state.carried, cost) else "DONE"
		if countText ~= lastCount and lastCount ~= nil and not motion.reducedMotion then
			countScale.Scale = 1.18
			TweenService:Create(countScale, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeBack), { Scale = 1 })
				:Play()
		end
		lastCount = countText
		count.Text = countText
		count.TextColor3 = if cost and state.carried < cost then Tokens.color.strawDeep else Tokens.color.gold
		caption.Text = if not cost
			then "ALL CLUES FOUND"
			elseif state.carried < cost then string.format("NEED %d RAINBOW FEATHERS", cost)
			else "TRADE FOR A CLUE"
		for category, view in pairs(slipViews) do
			local entry = state.unlocked[category]
			local isSelected = state.selected == category and not entry
			view.value.Text = if entry then tostring(entry.title) else "?"
			view.value.TextColor3 = if entry then BLUE else Tokens.color.inkStrong
			view.stamp.Visible = entry ~= nil
			view.slip.BackgroundColor3 = if isSelected then Tokens.color.creamPill else SLIP
			local keyline = Depth.keylineOf(view.slip)
			if keyline then
				keyline.Color = if isSelected then Tokens.color.gold else Tokens.color.strawDeep
				keyline.Thickness = if isSelected then Tokens.stroke.frame else Tokens.stroke.standard
			end
		end
		button.setText(if cost then "GET CLUE" else "ALL CLUES FOUND")
		button.setEnabled(state.canGet)
		button.pulse(state.canGet)
	end

	return {
		gui = gui,
		setState = setState,
		destroy = function()
			if heartbeat then
				heartbeat:Disconnect()
			end
			button.destroy()
			scaleCleanup()
			gui:Destroy()
		end,
	}
end

return PlumeCard
