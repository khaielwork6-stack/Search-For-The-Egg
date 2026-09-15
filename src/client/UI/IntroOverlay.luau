--!strict
-- The flat layer of the round intro: the fade, the cinematic bars, the subtitle, the Skip control,
-- the "waiting for party" line and the objective card that lands as the intro hands over.
--
-- Deliberately dumb. It owns no timing and no state beyond what it is told to show, so the director
-- can drive it from one clock and a skip can tear it down at any moment without leaving half a
-- sequence running. Everything it creates lives under one ScreenGui, so `destroy` is complete.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Button = require(script.Parent.Components.Button)
local SafeArea = require(script.Parent.SafeArea)

local IntroOverlay = {}

export type Overlay = {
	gui: ScreenGui,
	setFade: (alpha: number, seconds: number?) -> (),
	setLetterbox: (shown: boolean, seconds: number?) -> (),
	setSubtitle: (text: string?) -> (),
	setWaiting: (waiting: boolean) -> (),
	setSkipEnabled: (enabled: boolean) -> (),
	showObjective: (text: string, seconds: number) -> (),
	destroy: () -> (),
}

export type Options = {
	config: { [string]: any },
	motion: Motion.MotionSettings,
	allowSkip: boolean,
	onSkip: () -> (),
}

function IntroOverlay.create(parent: Instance, options: Options): Overlay
	local intro = options.config.round.intro
	local motion = options.motion
	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_RoundIntro"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = Tokens.zIndex.blocking + 5
	gui.Parent = parent

	-- Bars and fade sit outside the safe area on purpose: they are the frame of the picture.
	local function bar(name: string, anchorY: number): Frame
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.AnchorPoint = Vector2.new(0.5, anchorY)
		frame.Position = UDim2.fromScale(0.5, anchorY)
		frame.Size = UDim2.fromScale(1, 0)
		frame.BackgroundColor3 = Color3.new(0, 0, 0)
		frame.BorderSizePixel = 0
		frame.ZIndex = 4
		frame.Parent = gui
		return frame
	end
	local topBar, bottomBar = bar("TopBar", 0), bar("BottomBar", 1)

	local fade = Instance.new("Frame")
	fade.Name = "Fade"
	fade.Size = UDim2.fromScale(1, 1)
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.BackgroundTransparency = 0
	fade.BorderSizePixel = 0
	fade.ZIndex = 8
	fade.Parent = gui

	local _, releaseScale, stage = SafeArea.applyScale(gui, options.config)
	stage.ZIndex = 5

	-- Subtitle: light text on a soft dark plate, low enough to sit inside the bottom bar's breathing
	-- room but never under it.
	local plate = Instance.new("Frame")
	plate.Name = "SubtitlePlate"
	plate.AnchorPoint = Vector2.new(0.5, 1)
	plate.Position = UDim2.fromScale(0.5, 0.84)
	plate.Size = UDim2.fromOffset(0, 0)
	plate.AutomaticSize = Enum.AutomaticSize.XY
	plate.BackgroundColor3 = Color3.fromRGB(18, 13, 9)
	plate.BackgroundTransparency = 0.25
	plate.BorderSizePixel = 0
	plate.Visible = false
	plate.ZIndex = 6
	plate.Parent = stage
	local plateCorner = Instance.new("UICorner")
	plateCorner.CornerRadius = UDim.new(0, Tokens.radius.sm)
	plateCorner.Parent = plate
	local platePad = Instance.new("UIPadding")
	platePad.PaddingTop = UDim.new(0, Tokens.spacing.xs)
	platePad.PaddingBottom = UDim.new(0, Tokens.spacing.xs)
	platePad.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	platePad.PaddingRight = UDim.new(0, Tokens.spacing.md)
	platePad.Parent = plate
	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.AutomaticSize = Enum.AutomaticSize.XY
	subtitle.Size = UDim2.fromOffset(0, 0)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Tokens.typography.title.font
	subtitle.TextSize = Tokens.typography.title.size
	subtitle.TextColor3 = Tokens.color.featherWhite
	subtitle.TextStrokeColor3 = Color3.new(0, 0, 0)
	subtitle.TextStrokeTransparency = 0.4
	subtitle.Text = ""
	subtitle.ZIndex = 7
	subtitle.Parent = plate
	local subtitleCap = Instance.new("UISizeConstraint")
	subtitleCap.MaxSize = Vector2.new(820, math.huge)
	subtitleCap.Parent = subtitle

	local waiting = Instance.new("TextLabel")
	waiting.Name = "Waiting"
	waiting.AnchorPoint = Vector2.new(0.5, 1)
	waiting.Position = UDim2.fromScale(0.5, 0.92)
	waiting.Size = UDim2.new(0.6, 0, 0, Tokens.typography.body.size + 6)
	waiting.BackgroundTransparency = 1
	waiting.Font = Tokens.typography.body.font
	waiting.TextSize = Tokens.typography.body.size
	waiting.TextColor3 = Tokens.color.creamDeep
	waiting.TextStrokeColor3 = Color3.new(0, 0, 0)
	waiting.TextStrokeTransparency = 0.5
	waiting.Text = intro.waitingLabel
	waiting.Visible = false
	waiting.ZIndex = 9
	waiting.Parent = stage

	-- The objective card: the one thing that survives the fade, so the round opens on its goal.
	local objective = Instance.new("TextLabel")
	objective.Name = "Objective"
	objective.AnchorPoint = Vector2.new(0.5, 0.5)
	objective.Position = UDim2.fromScale(0.5, 0.42)
	objective.Size = UDim2.new(0.8, 0, 0, Tokens.typography.display.size + 12)
	objective.BackgroundTransparency = 1
	objective.Font = Tokens.typography.display.font
	objective.TextSize = Tokens.typography.display.size
	objective.TextColor3 = Tokens.color.featherWhite
	objective.TextStrokeColor3 = Color3.new(0, 0, 0)
	objective.TextStrokeTransparency = 0.35
	objective.TextTransparency = 1
	objective.Text = ""
	objective.ZIndex = 10
	objective.Parent = stage

	local skip: Button.Handle? = nil
	if options.allowSkip then
		local tap = SafeArea.minimumTapTarget(gui, options.config)
		skip = Button.build(stage, {
			text = "SKIP",
			variant = "secondary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromOffset(math.max(112, tap * 2.4), tap),
			zIndex = 9,
			onActivated = options.onSkip,
		})
		local handle = skip :: Button.Handle
		handle.button.Name = "IntroSkipButton"
		handle.button.AnchorPoint = Vector2.new(1, 1)
		handle.button.Position = UDim2.new(1, -Tokens.layout.safeAreaPaddingPx, 1, -Tokens.layout.safeAreaPaddingPx)
	end

	local alive = true
	-- `Motion.clampSeconds` caps every tween at the UI budget (0.45 s) to keep buttons and modals
	-- snappy. A cinematic fade is not a button: that cap was cutting a 0.9 s fade in half, which is
	-- what made the open and close read as hard cuts. These durations still honour reduced motion,
	-- which is an accessibility setting, but are not held to the snappiness budget.
	local function cinematicSeconds(seconds: number): number
		if motion.reducedMotion then
			return seconds * motion.reducedMotionScale
		end
		return seconds
	end
	local function tween(object: Instance, seconds: number, goal: { [string]: any }, style: Enum.EasingStyle?)
		local clamped = cinematicSeconds(seconds)
		if clamped <= 0.01 then
			for key, value in pairs(goal) do
				(object :: any)[key] = value
			end
			return
		end
		local easing = style or Enum.EasingStyle.Sine
		TweenService:Create(object, TweenInfo.new(clamped, easing, Enum.EasingDirection.Out), goal):Play()
	end

	local overlay: Overlay
	overlay = {
		gui = gui,
		setFade = function(alpha: number, seconds: number?)
			if not alive then
				return
			end
			tween(fade, seconds or 0, { BackgroundTransparency = 1 - math.clamp(alpha, 0, 1) })
		end,
		-- Bars close in on an eased curve as the picture arrives, and are taken away instantly behind
		-- the black at the end. Retracting them over the top of a lifting fade is what read as a cut.
		setLetterbox = function(shown: boolean, seconds: number?)
			if not alive then
				return
			end
			local height = if shown then intro.letterboxFraction else 0
			local span = seconds or intro.letterboxSeconds
			tween(topBar, span, { Size = UDim2.fromScale(1, height) }, Enum.EasingStyle.Quint)
			tween(bottomBar, span, { Size = UDim2.fromScale(1, height) }, Enum.EasingStyle.Quint)
		end,
		setSubtitle = function(text: string?)
			if not alive then
				return
			end
			plate.Visible = text ~= nil and text ~= ""
			subtitle.Text = text or ""
		end,
		setWaiting = function(isWaiting: boolean)
			if not alive then
				return
			end
			waiting.Visible = isWaiting
		end,
		setSkipEnabled = function(enabled: boolean)
			if skip then
				(skip :: Button.Handle).button.Visible = enabled
			end
		end,
		showObjective = function(text: string, seconds: number)
			if not alive then
				return
			end
			objective.Text = text
			objective.TextTransparency = 1
			tween(objective, 0.35, { TextTransparency = 0 })
			task.delay(math.max(0.1, seconds), function()
				if alive then
					tween(objective, 0.5, { TextTransparency = 1 })
				end
			end)
		end,
		destroy = function()
			if not alive then
				return
			end
			alive = false
			if skip then
				(skip :: Button.Handle).destroy()
			end
			releaseScale()
			gui:Destroy()
		end,
	}
	return overlay
end

return IntroOverlay
