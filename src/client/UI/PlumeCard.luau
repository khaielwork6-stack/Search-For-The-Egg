--!strict
-- Professor Plume's card: one look, one decision. A floating slate title plate over a charcoal
-- card, the price in Rainbow Feathers against what the player carries in big stroked numerals with a
-- rainbow rule under it, a result well that holds the one clue once it is known, and one green
-- ANALYSE button that says why when it cannot be pressed. It draws and reports presses; the
-- PlumeController owns every decision.

local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Feedback = require(script.Parent.Feedback)
local Motion = require(Shared.Design.Motion)
local FrameKit = require(script.Parent.Components.Frame)
local Button = require(script.Parent.Components.Button)
local Depth = require(script.Parent.Components.Depth)
local Skin = require(script.Parent.Components.Skin)
local SafeArea = require(script.Parent.SafeArea)

local PlumeCard = {}

local CARD = Tokens.color.panel
local PLATE = Tokens.color.surface
local PLATE_DEEP = Tokens.color.panelDeep
local CARD_W, CARD_H = 600, 440

export type State = {
	carriedRainbow: number,
	cost: number,
	clue: { title: string, text: string }?, -- this round's clue, once analysed
	canAnalyse: boolean,
	reason: string?, -- phase | egg_found | used | insufficient | pending, when canAnalyse is false
}

export type Handle = {
	gui: ScreenGui,
	setState: (state: State) -> (),
	destroy: () -> (),
}

local function outlined(label: TextLabel, thickness: number, color: Color3?)
	FrameKit.outline(label, thickness, color)
end

-- The words on the button and the note under the count, per refusal.
local function wordsFor(state: State): (string, string)
	local reason = state.reason
	if reason == "used" then
		return "USED THIS ROUND", "One analysis per round. Plume has told you all he knows."
	elseif reason == "insufficient" then
		return string.format("NEED %d RAINBOW", state.cost), "Collect Rainbow Feathers from the nest, then come back."
	elseif reason == "egg_found" then
		return "EGG FOUND", "The Egg is already out."
	elseif reason == "phase" then
		return "NOT NOW", "Plume only analyses while the search is on."
	elseif reason == "pending" then
		return "ANALYSING...", "Plume is running the analyzer."
	end
	return "ANALYSE", "One vague clue: which half of the nest, or how deep. Once per round."
end

function PlumeCard.create(
	parent: Instance,
	deps: { audio: any, accessibility: any, config: { [string]: any } },
	callbacks: { onAnalyse: () -> (), onClose: () -> () }
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
	dim.BackgroundTransparency = 1 -- invisible click-catcher: no scrim behind menus (owner)
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
	cap.MinSize = Vector2.new(340, 250)
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

	-- The price row: a feather, the carried count against the cost, and a rainbow rule under it.
	local priceRow = Instance.new("Frame")
	priceRow.Name = "Price"
	priceRow.BackgroundTransparency = 1
	priceRow.Position = UDim2.fromScale(0.06, 0.12)
	priceRow.Size = UDim2.fromScale(0.88, 0.2)
	priceRow.ZIndex = 3
	priceRow.Parent = card
	local feather = Skin.icon(priceRow, "icon.feather", 56, 4)
	if feather then
		feather.AnchorPoint = Vector2.new(0, 0.5)
		feather.Position = UDim2.fromScale(0, 0.5)
		feather.ImageColor3 = Tokens.color.featherWhite
	end
	local count =
		FrameKit.text(priceRow, "Count", "0 / 10", "display", { zIndex = 4, color = Tokens.color.gold, align = Enum.TextXAlignment.Right })
	count.AnchorPoint = Vector2.new(1, 0)
	count.Position = UDim2.fromScale(1, 0)
	count.Size = UDim2.fromScale(0.42, 0.72)
	count.TextScaled = true
	outlined(count, 4)
	local countScale = Instance.new("UIScale")
	countScale.Parent = count
	local label = FrameKit.text(
		priceRow,
		"Label",
		"RAINBOW FEATHERS",
		"heading",
		{ zIndex = 4, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Left }
	)
	label.Position = UDim2.fromOffset(64, 0)
	label.Size = UDim2.new(0.58, -64, 0.72, 0)
	label.TextScaled = true
	outlined(label, 2)
	local rule = Instance.new("Frame")
	rule.Name = "Rainbow"
	rule.AnchorPoint = Vector2.new(0, 1)
	rule.Position = UDim2.fromScale(0, 1)
	rule.Size = UDim2.new(1, 0, 0, 6)
	rule.BackgroundColor3 = Color3.new(1, 1, 1)
	rule.BorderSizePixel = 0
	rule.ZIndex = 4
	local ruleCorner = Instance.new("UICorner")
	ruleCorner.CornerRadius = UDim.new(1, 0)
	ruleCorner.Parent = rule
	local rainbow = Instance.new("UIGradient")
	rainbow.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(240, 64, 64)),
		ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 199, 44)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(96, 208, 40)),
		ColorSequenceKeypoint.new(0.75, Color3.fromRGB(56, 168, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 84, 240)),
	})
	rainbow.Parent = rule
	rule.Parent = priceRow

	-- The result well: the clue once known, otherwise what the analysis can tell.
	local well = Instance.new("Frame")
	well.Name = "Result"
	well.Position = UDim2.fromScale(0.06, 0.37)
	well.Size = UDim2.fromScale(0.88, 0.36)
	well.BackgroundColor3 = PLATE_DEEP
	well.ZIndex = 3
	local wellCorner = Instance.new("UICorner")
	wellCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
	wellCorner.Parent = well
	Depth.keyline(well, Tokens.depth.keylineThin)
	well.Parent = card
	local heading =
		FrameKit.text(well, "Heading", "", "display", { zIndex = 4, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center })
	heading.Position = UDim2.fromScale(0.04, 0.06)
	heading.Size = UDim2.fromScale(0.92, 0.4)
	heading.TextScaled = true
	outlined(heading, 3)
	local note = FrameKit.text(
		well,
		"Note",
		"",
		"body",
		{ zIndex = 4, color = Tokens.color.inkMuted, align = Enum.TextXAlignment.Center, wrap = true }
	)
	note.Position = UDim2.fromScale(0.05, 0.5)
	note.Size = UDim2.fromScale(0.9, 0.44)
	note.TextScaled = true
	outlined(note, 2)

	-- The one button: green, the "go" colour.
	local button = Button.build(card, {
		text = "ANALYSE",
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
	button.button.Name = "Analyse"
	button.button.AnchorPoint = Vector2.new(0.5, 1)
	button.button.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.lg)
	local current: State? = nil
	button.button.Activated:Connect(function()
		if current and current.canAnalyse then
			callbacks.onAnalyse()
		else
			Feedback.deny("plume:cannot_borrow")
		end
	end)

	TweenService:Create(entrance, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeBack), { Scale = 1 }):Play()
	GuiService.SelectedObject = button.button

	local lastCount: string? = nil
	local lastClue: string? = nil
	local function setState(state: State)
		current = state
		local countText = string.format("%d / %d", state.carriedRainbow, state.cost)
		if countText ~= lastCount and lastCount ~= nil and not motion.reducedMotion then
			countScale.Scale = 1.18
			TweenService:Create(countScale, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeBack), { Scale = 1 })
				:Play()
		end
		lastCount = countText
		count.Text = countText
		count.TextColor3 = if state.carriedRainbow < state.cost and not state.clue then Tokens.color.ember else Tokens.color.gold
		local buttonText, reasonNote = wordsFor(state)
		local clue = state.clue
		if clue then
			heading.Text = clue.title
			heading.TextColor3 = Tokens.color.gold
			note.Text = clue.text
			note.TextColor3 = Tokens.color.featherWhite
			if clue.title ~= lastClue and lastClue == nil and not motion.reducedMotion then
				local pop = Instance.new("UIScale")
				pop.Scale = 0.8
				pop.Parent = well
				local tween =
					TweenService:Create(pop, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeBack), { Scale = 1 })
				tween.Completed:Once(function()
					pop:Destroy()
				end)
				tween:Play()
			end
			lastClue = clue.title
		else
			heading.Text = "ONE CLUE PER ROUND"
			heading.TextColor3 = Tokens.color.featherWhite
			note.Text = reasonNote
			note.TextColor3 = Tokens.color.inkMuted
		end
		button.setText(buttonText)
		button.setEnabled(state.canAnalyse)
		button.pulse(state.canAnalyse)
	end

	return {
		gui = gui,
		setState = setState,
		destroy = function()
			button.destroy()
			scaleCleanup()
			gui:Destroy()
		end,
	}
end

return PlumeCard
