--!strict
-- Original skippable story overlay for the Sunlit Henhouse (18 s from config). Three text beats
-- fade over a warm vignette; a Skip button (>= tap target) sends a skip vote. Copy is original.
-- PLACEHOLDER: static beats stand in for the Phase 6 animated storyboard (owner: Phase 6).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Button = require(script.Parent.Components.Button)
local Skin = require(script.Parent.Components.Skin)

local CutsceneOverlay = {}

local BEATS = {
	"Every spring the henhouse keeps one golden Egg safe beneath the great nest.",
	"This year the flock scattered in the night, and the nest grew wild and deep.",
	"Clear the feathers, fill your bag, and be the first to lift the Egg into the light.",
}

export type Overlay = { gui: ScreenGui, destroy: () -> () }

function CutsceneOverlay.create(parent: Instance, options: { seconds: number, motion: Motion.MotionSettings, onSkip: () -> () }): Overlay
	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_Cutscene"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = Tokens.zIndex.blocking
	gui.Parent = parent

	local vignette = Instance.new("Frame")
	vignette.Name = "Vignette"
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.BackgroundColor3 = Tokens.color.overlay
	vignette.BackgroundTransparency = 1
	vignette.Parent = gui
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(Tokens.color.overlay, Tokens.color.inkStrong)
	gradient.Rotation = 90
	gradient.Parent = vignette
	local vignetteArt = Skin.label(vignette, "cutscene.vignette", { zIndex = vignette.ZIndex + 1, name = "Art" })
	if vignetteArt then
		vignetteArt.ScaleType = Enum.ScaleType.Stretch
		vignetteArt.ImageTransparency = 1
	end

	local caption = Instance.new("TextLabel")
	caption.Name = "Caption"
	caption.AnchorPoint = Vector2.new(0.5, 1)
	caption.Position = UDim2.fromScale(0.5, 0.86)
	caption.Size = UDim2.new(0.7, 0, 0, 90)
	caption.BackgroundTransparency = 1
	caption.Font = Tokens.typography.title.font
	caption.TextSize = Tokens.typography.title.size
	caption.TextColor3 = Tokens.color.inkStrong
	caption.TextStrokeTransparency = 1
	caption.TextWrapped = true
	caption.TextTransparency = 1
	caption.Text = BEATS[1]
	caption.ZIndex = 3
	local captionMax = Instance.new("UISizeConstraint")
	captionMax.MaxSize = Vector2.new(720, 90)
	captionMax.Parent = caption
	local captionArt = Skin.label(caption, "cutscene.caption", { zIndex = 2, inset = 8, name = "Plate" })
	if captionArt then
		captionArt.ImageTransparency = 1
	else
		caption.TextColor3 = Tokens.color.cream
		caption.TextStrokeTransparency = 0.5
	end
	caption.Parent = gui

	local skip, skipCleanup = Button.create(gui, {
		text = "Skip story",
		variant = "secondary",
		minimumTapTarget = Tokens.layout.minimumTapTargetPx,
		motion = options.motion,
		onActivated = options.onSkip,
	})
	skip.AnchorPoint = Vector2.new(1, 1)
	skip.Position = UDim2.new(1, -Tokens.spacing.xl, 1, -Tokens.spacing.xl)

	local alive = true
	local function tween(object: Instance, token: string, goal: { [string]: any })
		TweenService:Create(object, TweenInfo.new(Motion.duration(token, options.motion), Tokens.motion.easeInOut), goal):Play()
	end
	tween(vignette, "slow", { BackgroundTransparency = if vignetteArt then 0.75 else 0.35 })
	if vignetteArt then
		tween(vignetteArt, "slow", { ImageTransparency = 0.15 })
	end
	if captionArt then
		tween(captionArt, "slow", { ImageTransparency = 0 })
	end
	tween(caption, "slow", { TextTransparency = 0 })

	task.spawn(function()
		local perBeat = options.seconds / #BEATS
		for index = 2, #BEATS do
			task.wait(perBeat)
			if not alive then
				return
			end
			tween(caption, "quick", { TextTransparency = 1 })
			task.wait(Motion.duration("quick", options.motion))
			if not alive then
				return
			end
			caption.Text = BEATS[index]
			tween(caption, "standard", { TextTransparency = 0 })
		end
	end)

	return {
		gui = gui,
		destroy = function()
			if not alive then
				return
			end
			alive = false
			skipCleanup()
			local fade =
				TweenService:Create(vignette, TweenInfo.new(Motion.duration("quick", options.motion)), { BackgroundTransparency = 1 })
			tween(caption, "quick", { TextTransparency = 1 })
			if captionArt then
				tween(captionArt, "quick", { ImageTransparency = 1 })
			end
			if vignetteArt then
				tween(vignetteArt, "quick", { ImageTransparency = 1 })
			end
			fade:Play()
			fade.Completed:Once(function()
				gui:Destroy()
			end)
		end,
	}
end

return CutsceneOverlay
