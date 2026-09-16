--!strict
-- What is on screen while a player is at Molly's map: a wooden sign across the top with the one
-- instruction, a feather counter on the right, and the one orange button at the bottom with a small
-- BACK beside it. The map itself is the interface; this only names the decision. It draws and
-- reports presses; the MollyController owns every decision.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local FrameKit = require(script.Parent.Components.Frame)
local Button = require(script.Parent.Components.Button)
local Depth = require(script.Parent.Components.Depth)
local Skin = require(script.Parent.Components.Skin)
local SafeArea = require(script.Parent.SafeArea)

local SurveyPanel = {}

local PAPER = Color3.fromRGB(246, 236, 212)
local WOOD = Color3.fromRGB(150, 112, 66)
local WOOD_DEEP = Color3.fromRGB(104, 74, 42)

export type State = {
	title: string, -- the sign: "PICK ONE AREA", "SCANNING...", the result
	caption: string?, -- one short line under the sign, or nothing
	carried: number,
	cost: number,
	primary: string?, -- the button's words; nil hides it
	primaryEnabled: boolean,
	back: boolean, -- show BACK
	skip: boolean, -- show SKIP
	tone: ("plain" | "good" | "bad")?,
}

export type Handle = {
	gui: ScreenGui,
	setState: (state: State) -> (),
	primaryButton: TextButton,
	destroy: () -> (),
}

local function outlined(label: TextLabel, thickness: number, color: Color3?)
	FrameKit.outline(label, thickness, color)
end

function SurveyPanel.create(
	parent: Instance,
	deps: { audio: any, accessibility: any, config: { [string]: any } },
	callbacks: { onPrimary: () -> (), onBack: () -> (), onSkip: () -> () }
): Handle
	local motion = deps.accessibility:motionSettings()
	local tap = Tokens.layout.minimumTapTargetPx
	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_Survey"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = Tokens.zIndex.modal - 1
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = parent
	local _, scaleCleanup, stage = SafeArea.applyScale(gui, deps.config)

	-- The sign: a plank with a parchment inset, hung from the top.
	local sign = Instance.new("Frame")
	sign.Name = "Sign"
	sign.AnchorPoint = Vector2.new(0.5, 0)
	sign.Position = UDim2.new(0.5, 0, 0, Tokens.spacing.lg)
	sign.Size = UDim2.new(0.5, 0, 0, 104)
	sign.ZIndex = 2
	Depth.panel(sign, WOOD, { radius = Tokens.radius.md, rim = Color3.fromRGB(214, 170, 110) })
	local signCap = Instance.new("UISizeConstraint")
	signCap.MaxSize = Vector2.new(620, 104)
	signCap.MinSize = Vector2.new(300, 104)
	signCap.Parent = sign
	sign.Parent = stage
	for _, x in ipairs({ 0.12, 0.88 }) do
		local nail = Instance.new("Frame")
		nail.Name = "Nail"
		nail.AnchorPoint = Vector2.new(0.5, 0.5)
		nail.Position = UDim2.new(x, 0, 0, 10)
		nail.Size = UDim2.fromOffset(10, 10)
		nail.BackgroundColor3 = Tokens.color.goldDeep
		nail.ZIndex = 5
		local nailCorner = Instance.new("UICorner")
		nailCorner.CornerRadius = UDim.new(1, 0)
		nailCorner.Parent = nail
		nail.Parent = sign
	end
	local inset = Instance.new("Frame")
	inset.Name = "Inset"
	inset.AnchorPoint = Vector2.new(0.5, 0.5)
	inset.Position = UDim2.fromScale(0.5, 0.5)
	inset.Size = UDim2.new(1, -Tokens.spacing.lg * 2, 1, -Tokens.spacing.lg)
	inset.BackgroundColor3 = PAPER
	inset.ZIndex = 3
	local insetCorner = Instance.new("UICorner")
	insetCorner.CornerRadius = UDim.new(0, Tokens.radius.sm)
	insetCorner.Parent = inset
	Depth.keyline(inset, Tokens.stroke.standard, WOOD_DEEP)
	inset.Parent = sign
	local title = FrameKit.text(
		inset,
		"Title",
		"PICK ONE AREA",
		"display",
		{ zIndex = 4, color = Tokens.color.inkStrong, align = Enum.TextXAlignment.Center }
	)
	title.Position = UDim2.fromScale(0, 0.04)
	title.Size = UDim2.fromScale(1, 0.62)
	title.TextScaled = true
	local caption =
		FrameKit.text(inset, "Caption", "", "caption", { zIndex = 4, color = Tokens.color.inkMuted, align = Enum.TextXAlignment.Center })
	caption.Position = UDim2.fromScale(0, 0.66)
	caption.Size = UDim2.fromScale(1, 0.3)
	caption.TextScaled = true
	local signScale = Instance.new("UIScale")
	signScale.Parent = sign

	-- The feather counter, top right.
	local counter = Instance.new("Frame")
	counter.Name = "Counter"
	counter.AnchorPoint = Vector2.new(1, 0)
	counter.Position = UDim2.new(1, -Tokens.spacing.lg, 0, Tokens.spacing.lg + 20)
	counter.Size = UDim2.fromOffset(250, 64)
	counter.ZIndex = 2
	Depth.panel(counter, WOOD, { radius = Tokens.radius.md, rim = Color3.fromRGB(214, 170, 110) })
	counter.Parent = stage
	local counterInset = Instance.new("Frame")
	counterInset.Name = "Inset"
	counterInset.AnchorPoint = Vector2.new(0.5, 0.5)
	counterInset.Position = UDim2.fromScale(0.5, 0.5)
	counterInset.Size = UDim2.new(1, -Tokens.spacing.md, 1, -Tokens.spacing.md)
	counterInset.BackgroundColor3 = WOOD_DEEP
	counterInset.ZIndex = 3
	local counterCorner = Instance.new("UICorner")
	counterCorner.CornerRadius = UDim.new(0, Tokens.radius.sm)
	counterCorner.Parent = counterInset
	counterInset.Parent = counter
	local featherIcon = Skin.icon(counterInset, "icon.feather", 36, 4)
	if featherIcon then
		featherIcon.AnchorPoint = Vector2.new(0, 0.5)
		featherIcon.Position = UDim2.new(0, Tokens.spacing.sm, 0.5, 0)
		featherIcon.ImageColor3 = Tokens.color.featherWhite
	end
	local count = FrameKit.text(
		counterInset,
		"Count",
		"0 / 100",
		"display",
		{ zIndex = 4, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Right }
	)
	count.AnchorPoint = Vector2.new(1, 0.5)
	count.Position = UDim2.new(1, -Tokens.spacing.md, 0.5, 0)
	count.Size = UDim2.new(1, -60, 0.8, 0)
	count.TextScaled = true
	outlined(count, 2, WOOD_DEEP)

	-- The bottom row: BACK, the primary, SKIP.
	local row = Instance.new("Frame")
	row.Name = "Actions"
	row.AnchorPoint = Vector2.new(0.5, 1)
	row.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.lg)
	row.Size = UDim2.new(0.8, 0, 0, 96)
	row.BackgroundTransparency = 1
	row.ZIndex = 2
	row.Parent = stage
	local back = Button.build(row, {
		text = "X  BACK",
		variant = "secondary",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(150, 72),
		zIndex = 3,
		textSize = 22,
		sound = function()
			deps.audio:play(Tokens.sound.uiCancel)
		end,
		onActivated = callbacks.onBack,
	})
	back.button.AnchorPoint = Vector2.new(1, 0.5)
	back.button.Position = UDim2.new(0.5, -300, 0.5, 0)
	local primary = Button.build(row, {
		text = "SCAN",
		variant = "ember",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(560, 96),
		zIndex = 3,
		textSize = 46,
		sound = function()
			deps.audio:play(Tokens.sound.uiConfirm)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onActivated = callbacks.onPrimary,
	})
	primary.button.AnchorPoint = Vector2.new(0.5, 0.5)
	primary.button.Position = UDim2.fromScale(0.5, 0.5)
	local primaryCap = Instance.new("UISizeConstraint")
	primaryCap.MaxSize = Vector2.new(560, 96)
	primaryCap.Parent = primary.button
	local skip = Button.build(row, {
		text = "SKIP",
		variant = "ghost",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(140, 64),
		zIndex = 3,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		onActivated = callbacks.onSkip,
	})
	skip.button.AnchorPoint = Vector2.new(1, 0.5)
	skip.button.Position = UDim2.fromScale(1, 0.5)

	local lastTitle: string? = nil
	local function setState(state: State)
		if state.title ~= lastTitle and lastTitle ~= nil and not motion.reducedMotion then
			signScale.Scale = 1.06
			TweenService:Create(signScale, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeBack), { Scale = 1 }):Play()
		end
		lastTitle = state.title
		title.Text = state.title
		title.TextColor3 = if state.tone == "good"
			then Tokens.color.goldDeep
			elseif state.tone == "bad" then Color3.fromRGB(90, 110, 140)
			else Tokens.color.inkStrong
		caption.Text = state.caption or ""
		caption.Visible = (state.caption or "") ~= ""
		count.Text = string.format("%d / %d", state.carried, state.cost)
		count.TextColor3 = if state.carried >= state.cost then Tokens.color.featherWhite else Color3.fromRGB(255, 190, 170)
		primary.button.Visible = state.primary ~= nil
		if state.primary then
			primary.setText(state.primary)
		end
		primary.setEnabled(state.primaryEnabled)
		primary.pulse(state.primaryEnabled)
		back.button.Visible = state.back
		skip.button.Visible = state.skip
	end

	return {
		gui = gui,
		primaryButton = primary.button,
		setState = setState,
		destroy = function()
			primary.destroy()
			back.destroy()
			skip.destroy()
			scaleCleanup()
			gui:Destroy()
		end,
	}
end

return SurveyPanel
