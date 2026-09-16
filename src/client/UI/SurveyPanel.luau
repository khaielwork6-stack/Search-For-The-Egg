--!strict
-- The strip across the bottom of the screen while a player is at Molly's map: her line, the
-- crate count against the cost, the region under the cursor, and the two buttons. It draws and it
-- reports presses; the MollyController owns every decision.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local FrameKit = require(script.Parent.Components.Frame)
local Button = require(script.Parent.Components.Button)
local Depth = require(script.Parent.Components.Depth)

local SurveyPanel = {}

local PAPER = Color3.fromRGB(246, 236, 212)
local RED = Color3.fromRGB(196, 52, 44)

export type State = {
	line: string,
	carried: number,
	cost: number,
	region: string?,
	regionText: string?,
	canSurvey: boolean,
	hint: string,
	mode: "select" | "sequence" | "result",
	skippable: boolean?,
}

export type Handle = {
	gui: ScreenGui,
	setState: (state: State) -> (),
	surveyButton: TextButton,
	destroy: () -> (),
}

function SurveyPanel.create(
	parent: Instance,
	deps: { audio: any, accessibility: any, config: { [string]: any } },
	callbacks: { onSurvey: () -> (), onCancel: () -> (), onSkip: () -> () }
): Handle
	local motion = deps.accessibility:motionSettings()
	local tap = Tokens.layout.minimumTapTargetPx
	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_Survey"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = Tokens.zIndex.modal - 1
	gui.Parent = parent

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -Tokens.layout.safeAreaPaddingPx * 2)
	panel.Size = UDim2.new(0.78, 0, 0, tap * 3.1)
	panel.ZIndex = 2
	Depth.panel(panel, PAPER, { radius = Tokens.radius.lg })
	local sizeCap = Instance.new("UISizeConstraint")
	sizeCap.MaxSize = Vector2.new(760, 400)
	sizeCap.MinSize = Vector2.new(320, tap * 3.1)
	sizeCap.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Tokens.spacing.sm)
	pad.PaddingBottom = UDim.new(0, Tokens.spacing.sm)
	pad.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
	pad.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	pad.Parent = panel
	panel.Parent = gui

	local who = FrameKit.text(panel, "Who", "MOLLY THE MOLE", "caption", { zIndex = 3, color = Tokens.color.inkMuted })
	who.Size = UDim2.new(0.6, 0, 0, Tokens.typography.caption.size + 2)
	local line = FrameKit.text(panel, "Line", "", "body", { zIndex = 3, color = Tokens.color.inkStrong, wrap = true })
	line.Position = UDim2.fromOffset(0, Tokens.typography.caption.size + 4)
	line.Size = UDim2.new(0.62, 0, 0, Tokens.typography.body.size * 2 + 6)
	line.TextYAlignment = Enum.TextYAlignment.Top

	local count = FrameKit.pill(panel, "Count", "", {
		size = UDim2.new(0.36, 0, 0, tap - 6),
		zIndex = 3,
		fill = Tokens.color.creamPill,
		textColor = Tokens.color.inkStrong,
		art = false,
	})
	count.AnchorPoint = Vector2.new(1, 0)
	count.Position = UDim2.fromScale(1, 0)

	local region = FrameKit.text(
		panel,
		"Region",
		"",
		"heading",
		{ zIndex = 3, color = Color3.fromRGB(40, 104, 172), align = Enum.TextXAlignment.Right }
	)
	region.AnchorPoint = Vector2.new(1, 0)
	region.Position = UDim2.new(1, 0, 0, tap - 2)
	region.Size = UDim2.new(0.36, 0, 0, Tokens.typography.heading.size + 4)
	local hint =
		FrameKit.text(panel, "Hint", "", "caption", { zIndex = 3, color = Tokens.color.inkMuted, align = Enum.TextXAlignment.Right })
	hint.AnchorPoint = Vector2.new(1, 0)
	hint.Position = UDim2.new(1, 0, 0, tap + Tokens.typography.heading.size + 4)
	hint.Size = UDim2.new(0.36, 0, 0, Tokens.typography.caption.size + 4)

	local actions = Instance.new("Frame")
	actions.Name = "Actions"
	actions.BackgroundTransparency = 1
	actions.AnchorPoint = Vector2.new(0, 1)
	actions.Position = UDim2.fromScale(0, 1)
	actions.Size = UDim2.new(1, 0, 0, tap + 4)
	actions.ZIndex = 3
	actions.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, Tokens.spacing.sm)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = actions

	local cancel = Button.build(actions, {
		text = "CANCEL",
		variant = "secondary",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(tap * 3, tap),
		zIndex = 4,
		sound = function()
			deps.audio:play(Tokens.sound.uiCancel)
		end,
		onActivated = callbacks.onCancel,
	})
	cancel.button.LayoutOrder = 1
	local skip = Button.build(actions, {
		text = "SKIP",
		variant = "ghost",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(tap * 2.6, tap),
		zIndex = 4,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		onActivated = callbacks.onSkip,
	})
	skip.button.LayoutOrder = 2
	skip.button.Visible = false
	local survey = Button.build(actions, {
		text = "SURVEY",
		variant = "gold",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(tap * 5.2, tap + 4),
		zIndex = 4,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onActivated = callbacks.onSurvey,
	})
	survey.button.LayoutOrder = 3

	local function setState(state: State)
		line.Text = state.line
		count.Text = string.format("NORMAL FEATHERS: %d / %d", state.carried, state.cost)
		count.TextColor3 = if state.carried >= state.cost then Tokens.color.inkStrong else RED
		region.Text = state.regionText or (if state.mode == "select" then "Pick a region" else "")
		hint.Text = state.hint
		local selecting = state.mode == "select"
		survey.button.Visible = selecting
		cancel.button.Visible = selecting
		skip.button.Visible = state.mode == "sequence" and state.skippable == true
		survey.setEnabled(state.canSurvey)
		survey.setText(if state.region then string.format("SURVEY %s", state.region) else "SURVEY")
	end

	return {
		gui = gui,
		surveyButton = survey.button,
		setState = setState,
		destroy = function()
			survey.destroy()
			cancel.destroy()
			skip.destroy()
			gui:Destroy()
		end,
	}
end

return SurveyPanel
