--!strict
-- Modal shell in the owner's language: dim overlay, gold-bevelled card with a deep teal panel, cream
-- pill title, close button, a scrolling content frame sized for phone and desktop, and an optional
-- footer row. Open/close use the supplied panel recipes (Back-out open + Quad fade, Quad-in close)
-- and the shell is a controller selection group so focus never escapes an open modal.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local FrameKit = require(script.Parent.Frame)

local ModalShell = {}

export type Shell = {
	root: Frame,
	card: Frame,
	panel: Frame,
	content: ScrollingFrame,
	footer: Frame,
	closeButton: TextButton,
	titleLabel: TextLabel,
	open: () -> (),
	close: (onClosed: (() -> ())?) -> (),
	setTitle: (text: string) -> (),
}

function ModalShell.create(
	gui: ScreenGui,
	options: {
		title: string,
		id: string?,
		blocking: boolean,
		motion: Motion.MotionSettings,
		minimumTapTarget: number?,
		wide: boolean?,
	}
): Shell
	local tap = options.minimumTapTarget or Tokens.layout.minimumTapTargetPx
	local root = Instance.new("Frame")
	root.Name = "Modal_" .. (options.id or options.title)
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = Tokens.color.overlay
	root.BackgroundTransparency = 1
	root.ZIndex = if options.blocking then Tokens.zIndex.blocking else Tokens.zIndex.modal
	root.Active = options.blocking

	local card, panel =
		FrameKit.goldPanel(root, "Card", { radius = Tokens.radius.xl, padding = Tokens.spacing.md, zIndex = root.ZIndex + 1 })
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(if options.wide then 0.96 else 0.92, Tokens.layout.cardMaxHeightFraction)
	card.SelectionGroup = true
	card.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
	card.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
	card.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
	card.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
	local maxSize = Instance.new("UISizeConstraint")
	maxSize.MaxSize = Vector2.new(if options.wide then 820 else Tokens.layout.cardMaxWidthPx, 900)
	maxSize.Parent = card
	local cardScale = Instance.new("UIScale")
	cardScale.Parent = card
	FrameKit.leaves(card, card.ZIndex)

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Tokens.spacing.md)
	layout.Parent = panel

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, tap)
	header.LayoutOrder = 1
	header.ZIndex = panel.ZIndex
	header.Parent = panel

	local title =
		FrameKit.pill(header, "Title", options.title, { size = UDim2.new(1, -(tap + Tokens.spacing.sm), 1, 0), zIndex = panel.ZIndex + 1 })
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextSize = Tokens.typography.title.size

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.fromScale(1, 0)
	closeButton.Size = UDim2.fromOffset(tap, tap)
	closeButton.BackgroundColor3 = Tokens.color.ember
	closeButton.Text = "X"
	closeButton.Font = Tokens.typography.label.font
	closeButton.TextSize = Tokens.typography.heading.size
	closeButton.TextColor3 = Tokens.color.cream
	closeButton.TextStrokeColor3 = Tokens.color.outline
	closeButton.TextStrokeTransparency = 0.3
	closeButton.AutoButtonColor = false
	closeButton.ZIndex = panel.ZIndex + 1
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	closeCorner.Parent = closeButton
	local closeStroke = Instance.new("UIStroke")
	closeStroke.Thickness = Tokens.stroke.bold
	closeStroke.Color = Tokens.color.outline
	closeStroke.Parent = closeButton
	closeButton.SelectionGained:Connect(function()
		closeStroke.Color = Tokens.color.goldLight
		closeStroke.Thickness = Tokens.stroke.frame
	end)
	closeButton.SelectionLost:Connect(function()
		closeStroke.Color = Tokens.color.outline
		closeStroke.Thickness = Tokens.stroke.bold
	end)
	closeButton.Parent = header

	local footer = Instance.new("Frame")
	footer.Name = "Footer"
	footer.BackgroundTransparency = 1
	footer.Size = UDim2.new(1, 0, 0, tap)
	footer.AutomaticSize = Enum.AutomaticSize.Y
	footer.LayoutOrder = 3
	footer.Visible = false
	footer.ZIndex = panel.ZIndex
	local footerLayout = Instance.new("UIListLayout")
	footerLayout.FillDirection = Enum.FillDirection.Horizontal
	footerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	footerLayout.SortOrder = Enum.SortOrder.LayoutOrder
	footerLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	footerLayout.Parent = footer
	footer.Parent = panel
	footer:GetPropertyChangedSignal("Visible"):Connect(function() end)

	-- Content scrolls inside the card so tall lists never push the footer off a phone screen.
	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.Size = UDim2.new(1, 0, 1, -(tap + Tokens.spacing.md))
	content.LayoutOrder = 2
	content.ZIndex = panel.ZIndex
	content.ScrollBarThickness = 6
	content.ScrollBarImageColor3 = Tokens.color.gold
	content.CanvasSize = UDim2.fromScale(0, 0)
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.ScrollingDirection = Enum.ScrollingDirection.Y
	content.ElasticBehavior = Enum.ElasticBehavior.Never
	content.SelectionGroup = false
	local contentLayout = Instance.new("UIListLayout")
	contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
	contentLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	contentLayout.Parent = content
	local contentPadding = Instance.new("UIPadding")
	contentPadding.PaddingRight = UDim.new(0, Tokens.spacing.sm)
	contentPadding.Parent = content
	content.Parent = panel

	-- Footer visibility shrinks the content area.
	local function relayout()
		local footerHeight = if footer.Visible then footer.AbsoluteSize.Y + Tokens.spacing.md else 0
		content.Size = UDim2.new(1, 0, 1, -(tap + Tokens.spacing.md + footerHeight))
	end
	footer:GetPropertyChangedSignal("Visible"):Connect(relayout)
	footer:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)

	root.Parent = gui

	local motion = options.motion
	local shell: Shell = {
		root = root,
		card = card,
		panel = panel,
		content = content,
		footer = footer,
		closeButton = closeButton,
		titleLabel = title,
		open = function()
			local openRecipe = Motion.recipe("panelOpen", motion)
			local fadeRecipe = Motion.recipe("panelFadeIn", motion)
			cardScale.Scale = openRecipe.fromScale or 0.82
			TweenService:Create(root, Motion.tweenInfo(fadeRecipe), { BackgroundTransparency = if options.blocking then 0.45 else 0.7 })
				:Play()
			TweenService:Create(cardScale, Motion.tweenInfo(openRecipe), { Scale = 1 }):Play()
			relayout()
		end,
		close = function(onClosed)
			local closeRecipe = Motion.recipe("panelClose", motion)
			local fadeRecipe = Motion.recipe("panelFadeOut", motion)
			local fade = TweenService:Create(root, Motion.tweenInfo(fadeRecipe), { BackgroundTransparency = 1 })
			fade:Play()
			TweenService:Create(cardScale, Motion.tweenInfo(closeRecipe), { Scale = closeRecipe.toScale or 0.86 }):Play()
			fade.Completed:Once(function()
				root:Destroy()
				if onClosed then
					onClosed()
				end
			end)
		end,
		setTitle = function(text)
			title.Text = text
		end,
	}
	return shell
end

return ModalShell
