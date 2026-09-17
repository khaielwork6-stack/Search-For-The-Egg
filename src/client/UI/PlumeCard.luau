--!strict
-- Professor Plume's card: one look, one decision. A floating slate title plate over a charcoal
-- card, the Egg Sense rod with its glowing crystal on the left, the loan pips, the carried count
-- against the price in big gold stroked numerals and a one-line note on the right, and one green
-- button. Nothing on it is a paragraph; what Plume has to say, he says over his own head.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local FrameKit = require(script.Parent.Components.Frame)
local Button = require(script.Parent.Components.Button)
local Depth = require(script.Parent.Components.Depth)
local SafeArea = require(script.Parent.SafeArea)

local PlumeCard = {}

local CARD = Tokens.color.panel
local PLATE = Tokens.color.surface
local PLATE_DEEP = Tokens.color.panelDeep
local ROD = Tokens.color.cocoa -- the rod's shaft and prongs: mid slate, like a dark metal wand
local CARD_W, CARD_H = 600, 440

export type State = {
	carried: number, -- normal feathers in the bag
	cost: number?, -- nil once every loan is used
	usesLeft: number,
	maxUses: number,
	activeSeconds: number,
	active: boolean, -- this player already holds the rod
	canBorrow: boolean,
	reason: string?, -- phase | active | limit | insufficient, when canBorrow is false
}

export type Handle = {
	gui: ScreenGui,
	setState: (state: State) -> (),
	destroy: () -> (),
}

local function outlined(label: TextLabel, thickness: number, color: Color3?)
	FrameKit.outline(label, thickness, color)
end

local function circle(parent: GuiObject, name: string, color: Color3, zIndex: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = color
	frame.BorderSizePixel = 0
	frame.ZIndex = zIndex
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = frame
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.Parent = frame
	frame.Parent = parent
	return frame
end

function PlumeCard.create(
	parent: Instance,
	deps: { audio: any, accessibility: any, config: { [string]: any } },
	callbacks: { onBorrow: () -> (), onClose: () -> () }
): Handle
	local motion = deps.accessibility:motionSettings()
	local tap = Tokens.layout.minimumTapTargetPx
	local rodCfg = deps.config.plume.rod
	local cold = Color3.fromRGB(rodCfg.coldColor[1], rodCfg.coldColor[2], rodCfg.coldColor[3])
	local warm = Color3.fromRGB(rodCfg.warmColor[1], rodCfg.warmColor[2], rodCfg.warmColor[3])
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
	Depth.panel(card, CARD, { radius = Tokens.radius.xl })
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

	-- Title plate, floating over the top edge: a slate pill on a darker lip, like the modal shell's.
	local plate = Instance.new("Frame")
	plate.Name = "Title"
	plate.AnchorPoint = Vector2.new(0.5, 0.5)
	plate.Position = UDim2.new(0.5, 0, 0, 4)
	plate.Size = UDim2.new(0.74, 0, 0, 66)
	plate.ZIndex = 4
	Depth.panel(plate, PLATE, { radius = Tokens.radius.lg })
	local plateLip = Instance.new("Frame")
	plateLip.Name = "Lip"
	plateLip.AnchorPoint = Vector2.new(0.5, 1)
	plateLip.Position = UDim2.new(0.5, 0, 1, 6)
	plateLip.Size = UDim2.new(1, 0, 0, 12)
	plateLip.BackgroundColor3 = PLATE_DEEP
	plateLip.BorderSizePixel = 0
	plateLip.ZIndex = 3
	local lipCorner = Instance.new("UICorner")
	lipCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	lipCorner.Parent = plateLip
	Depth.keyline(plateLip)
	plateLip.Parent = plate
	local title = FrameKit.text(plate, "Text", "PROFESSOR PLUME", "display", {
		zIndex = 5,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Center,
		size = UDim2.fromScale(1, 1),
	})
	title.TextSize = 34
	outlined(title, 3)
	plate.Parent = card

	-- Close: the red corner X.
	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, 14, 0, -14)
	close.Size = UDim2.fromOffset(tap + 8, tap + 8)
	close.BackgroundColor3 = Tokens.color.ember
	close.Text = "X"
	close.Font = Tokens.typography.display.font
	close.TextSize = 30
	close.TextColor3 = Tokens.color.featherWhite
	close.ZIndex = 6
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(1, 0)
	closeCorner.Parent = close
	Depth.keyline(close)
	Depth.rim(close, Tokens.color.ember)
	Depth.applySheen(close, Tokens.color.ember)
	outlined(close :: any, 2.5)
	close.Parent = card
	close.Activated:Connect(function()
		deps.audio:play(Tokens.sound.uiClose)
		callbacks.onClose()
	end)

	-- Left: the rod, drawn from frames: a leaning shaft, two prongs, the crystal and its glow.
	local art = Instance.new("Frame")
	art.Name = "Art"
	art.BackgroundTransparency = 1
	art.Position = UDim2.fromScale(0.03, 0.15)
	art.Size = UDim2.fromScale(0.42, 0.6)
	art.ZIndex = 3
	art.Parent = card
	local artRatio = Instance.new("UIAspectRatioConstraint")
	artRatio.AspectRatio = 1
	artRatio.Parent = art
	local glows = {}
	for i, spec in ipairs({ { 0.62, 0.55 }, { 0.42, 0.3 } }) do
		local glow = circle(art, "Glow" .. i, cold, 3)
		glow.AnchorPoint = Vector2.new(0.5, 0.5)
		glow.Position = UDim2.fromScale(0.5, 0.28)
		glow.Size = UDim2.fromScale(spec[1], spec[1])
		glow.BackgroundTransparency = spec[2]
		table.insert(glows, glow)
	end
	local shaft = Instance.new("Frame")
	shaft.Name = "Shaft"
	shaft.AnchorPoint = Vector2.new(0.5, 0)
	shaft.Position = UDim2.fromScale(0.5, 0.36)
	shaft.Size = UDim2.fromScale(0.07, 0.6)
	shaft.Rotation = -8
	shaft.BackgroundColor3 = ROD
	shaft.BorderSizePixel = 0
	shaft.ZIndex = 4
	local shaftCorner = Instance.new("UICorner")
	shaftCorner.CornerRadius = UDim.new(1, 0)
	shaftCorner.Parent = shaft
	Depth.keyline(shaft, Tokens.stroke.standard)
	shaft.Parent = art
	for _, side in ipairs({ -1, 1 }) do
		local prong = Instance.new("Frame")
		prong.Name = if side < 0 then "ProngLeft" else "ProngRight"
		prong.AnchorPoint = Vector2.new(0.5, 1)
		prong.Position = UDim2.fromScale(0.5 + side * 0.06, 0.4)
		prong.Size = UDim2.fromScale(0.05, 0.24)
		prong.Rotation = side * 28 - 8
		prong.BackgroundColor3 = ROD
		prong.BorderSizePixel = 0
		prong.ZIndex = 4
		local prongCorner = Instance.new("UICorner")
		prongCorner.CornerRadius = UDim.new(1, 0)
		prongCorner.Parent = prong
		Depth.keyline(prong, Tokens.stroke.standard)
		prong.Parent = art
	end
	local crystal = circle(art, "Crystal", cold, 5)
	crystal.AnchorPoint = Vector2.new(0.5, 0.5)
	crystal.Position = UDim2.fromScale(0.5, 0.28)
	crystal.Size = UDim2.fromScale(0.2, 0.2)
	Depth.keyline(crystal, Tokens.stroke.bold)
	local sparkles = {}
	for i, spot in ipairs({ { 0.2, 0.12 }, { 0.82, 0.1 }, { 0.86, 0.5 }, { 0.14, 0.52 } }) do
		local spark =
			FrameKit.text(art, "Spark" .. i, "*", "display", { zIndex = 6, color = Tokens.color.gold, align = Enum.TextXAlignment.Center })
		spark.AnchorPoint = Vector2.new(0.5, 0.5)
		spark.Position = UDim2.fromScale(spot[1], spot[2])
		spark.Size = UDim2.fromOffset(28, 28)
		spark.TextSize = 30 + (i % 2) * 8
		outlined(spark, 2)
		table.insert(sparkles, spark)
	end

	-- Right: the name, the loan pips, the count against the cost, the note.
	local right = Instance.new("Frame")
	right.Name = "Right"
	right.BackgroundTransparency = 1
	right.Position = UDim2.fromScale(0.47, 0.13)
	right.Size = UDim2.fromScale(0.5, 0.62)
	right.ZIndex = 3
	right.Parent = card
	local heading = FrameKit.text(
		right,
		"Heading",
		"EGG SENSE ROD",
		"heading",
		{ zIndex = 4, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center }
	)
	heading.Size = UDim2.fromScale(1, 0.14)
	heading.TextScaled = true
	outlined(heading, 2)
	local pips = Instance.new("Frame")
	pips.Name = "Pips"
	pips.BackgroundTransparency = 1
	pips.Position = UDim2.fromScale(0, 0.15)
	pips.Size = UDim2.fromScale(1, 0.12)
	pips.ZIndex = 4
	pips.Parent = right
	local pipLayout = Instance.new("UIListLayout")
	pipLayout.FillDirection = Enum.FillDirection.Horizontal
	pipLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	pipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	pipLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	pipLayout.Parent = pips
	local pipViews: { Frame } = {}
	local count =
		FrameKit.text(right, "Count", "0 / 100", "display", { zIndex = 4, color = Tokens.color.gold, align = Enum.TextXAlignment.Center })
	count.Position = UDim2.fromScale(0, 0.28)
	count.Size = UDim2.fromScale(1, 0.36)
	count.TextScaled = true
	outlined(count, 4)
	local countScale = Instance.new("UIScale")
	countScale.Parent = count
	local caption = FrameKit.text(
		right,
		"Caption",
		"FEATHERS FOR ONE LOAN",
		"heading",
		{ zIndex = 4, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center }
	)
	caption.Position = UDim2.fromScale(0, 0.64)
	caption.Size = UDim2.fromScale(1, 0.12)
	caption.TextScaled = true
	outlined(caption, 2)
	local note = FrameKit.text(
		right,
		"Note",
		"",
		"caption",
		{ zIndex = 4, color = Tokens.color.inkMuted, align = Enum.TextXAlignment.Center, wrap = true }
	)
	note.Position = UDim2.fromScale(0, 0.78)
	note.Size = UDim2.fromScale(1, 0.22)
	note.TextScaled = true
	outlined(note, 2)

	-- The one button: green, the "go" colour.
	local button = Button.build(card, {
		text = "BORROW THE ROD",
		variant = "success",
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
		if current and current.canBorrow then
			callbacks.onBorrow()
		else
			deps.audio:play(Tokens.sound.uiError)
		end
	end)

	-- Twinkle, a breathing glow that warms and cools, and a settle-in.
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
			local heat = 0.5 + 0.5 * math.sin(t * 0.9)
			local tint = cold:Lerp(warm, heat)
			crystal.BackgroundColor3 = tint
			for i, glow in ipairs(glows) do
				glow.BackgroundColor3 = tint
				glow.BackgroundTransparency = (if i == 1 then 0.55 else 0.3) + 0.15 * (1 - heat)
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
		count.TextColor3 = if cost and state.carried < cost then Tokens.color.ember else Tokens.color.gold
		-- One pip per loan the party may still take; spent ones sit hollow.
		while #pipViews < state.maxUses do
			local pip = circle(pips, "Pip" .. (#pipViews + 1), Tokens.color.gold, 5)
			pip.Size = UDim2.fromScale(0.75, 0.75)
			pip.LayoutOrder = #pipViews + 1
			Depth.keyline(pip, Tokens.stroke.bold)
			table.insert(pipViews, pip)
		end
		for index, pip in ipairs(pipViews) do
			local left = index <= state.usesLeft
			pip.Visible = index <= state.maxUses
			pip.BackgroundColor3 = if left then Tokens.color.gold else PLATE_DEEP
			pip.BackgroundTransparency = 0
		end
		caption.Text = if state.reason == "active"
			then "ROD IN YOUR HAND"
			elseif not cost then "NO LOANS LEFT"
			elseif state.carried < cost then string.format("NEED %d FEATHERS", cost)
			else "FEATHERS FOR ONE LOAN"
		note.Text =
			string.format("Ticks faster near the Egg. Lasts %d s. %d of %d loans left.", state.activeSeconds, state.usesLeft, state.maxUses)
		button.setText(
			if state.reason == "active"
				then "ROD IN USE"
				elseif state.reason == "limit" then "NO LOANS LEFT"
				elseif state.reason == "insufficient" then "NEED MORE FEATHERS"
				elseif state.reason == "phase" then "NOT NOW"
				else "BORROW THE ROD"
		)
		button.setEnabled(state.canBorrow)
		button.pulse(state.canBorrow)
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
