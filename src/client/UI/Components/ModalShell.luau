--!strict
-- Modal shell: dim overlay, a cookie panel (cocoa outline, bottom lip, cream body with a faint
-- weave), a gold header band with a rays backdrop and chunky outlined title, the station glyph on
-- the band, a round ember close button, a scrolling content area sized to its content, an
-- optional footer, and leaf accents. Opens with a lift and Back-out scale, closes with an ease.
-- The card is a controller selection group so focus never escapes an open modal.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local FrameKit = require(script.Parent.Frame)
local Depth = require(script.Parent.Depth)
local Icons = require(script.Parent.Icons)
local Tween = require(script.Parent.Tween)
local Skin = require(script.Parent.Skin)
local SafeArea = require(script.Parent.Parent.SafeArea)

-- The barn's woodwork and paper.
local WOOD = Color3.fromRGB(150, 112, 66)
local WOOD_DEEP = Color3.fromRGB(104, 74, 42)
local WOOD_LIGHT = Color3.fromRGB(196, 150, 96)
local PAPER = Color3.fromRGB(248, 238, 214)
local FRAME_SCALE = 0.4 -- the crate painting's slice scale
local FRAME = math.floor(130 * FRAME_SCALE) + 4 -- the wooden edge around the panel at that scale
local TOP_ROOM = 44 -- room above the frame for the plaque to hang over

local ModalShell = {}

export type Shell = {
	root: Frame,
	headerRight: Frame,
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
	gui: Instance,
	options: {
		title: string,
		id: string?,
		blocking: boolean,
		motion: Motion.MotionSettings,
		minimumTapTarget: number?,
		wide: boolean?,
		compact: boolean?,
		ambient: boolean?,
		icon: string?,
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

	-- The frame: the barn's crate painting, sliced, so the panel is real wood with a gold inner rim
	-- and parchment inside (the feather rides the bottom-right corner). The title hangs over the top
	-- edge on the station sign; the close is a red knob on the corner; the top-right of the frame
	-- keeps a slot for a currency chip.
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.new(0.5, 0, 0.5, TOP_ROOM / 2)
	card.Size = UDim2.fromScale(if options.compact then 0.8 elseif options.wide then 0.92 else 0.88, Tokens.layout.cardMaxHeightFraction)
	card.BackgroundTransparency = 1
	card.ZIndex = root.ZIndex + 1
	card.SelectionGroup = true
	card.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
	card.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
	card.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
	card.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
	local maxSize = Instance.new("UISizeConstraint")
	maxSize.MaxSize = Vector2.new(if options.compact then 440 elseif options.wide then 1040 else Tokens.layout.cardMaxWidthPx + 40, 900)
	maxSize.Parent = card
	local cardScale = Instance.new("UIScale")
	cardScale.Parent = card
	card.Parent = root
	local crate = Skin.overlay(card, "world.tradeTop", { zIndex = card.ZIndex, sliceScale = FRAME_SCALE, name = "Crate" })
	if not crate then
		-- No painting: a vector wood frame stands in.
		card.BackgroundTransparency = 0
		Depth.panel(card, WOOD, { radius = Tokens.radius.xl, rim = WOOD_LIGHT })
	end

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.new(1, -FRAME * 2, 1, -FRAME * 2)
	panel.BackgroundColor3 = PAPER
	panel.BackgroundTransparency = if crate then 1 else 0
	panel.BorderSizePixel = 0
	panel.ZIndex = card.ZIndex + 1
	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	panelCorner.Parent = panel
	if not crate then
		Depth.keyline(panel, Tokens.stroke.standard, WOOD_DEEP)
	end
	local panelPadding = Instance.new("UIPadding")
	panelPadding.PaddingLeft = UDim.new(0, Tokens.spacing.sm)
	panelPadding.PaddingRight = UDim.new(0, Tokens.spacing.sm)
	panelPadding.PaddingTop = UDim.new(0, Tokens.spacing.sm)
	panelPadding.PaddingBottom = UDim.new(0, Tokens.spacing.sm)
	panelPadding.Parent = panel
	panel.Parent = card

	-- The plaque: the station sign, hung over the top edge, the title in gold on its parchment.
	local plaqueHeight = tap + 28
	local plaque = Instance.new("Frame")
	plaque.Name = "Header"
	plaque.AnchorPoint = Vector2.new(0.5, 0.5)
	plaque.Position = UDim2.new(0.5, 0, 0, 6)
	-- Narrow enough that a chip and the knob fit to its right on a wide frame.
	plaque.Size = UDim2.new(if options.compact then 0.8 else 0.44, 0, 0, plaqueHeight)
	plaque.BackgroundTransparency = 1
	plaque.ZIndex = card.ZIndex + 6
	local plaqueCap = Instance.new("UISizeConstraint")
	plaqueCap.MaxSize = Vector2.new(480, plaqueHeight)
	plaqueCap.MinSize = Vector2.new(240, plaqueHeight)
	plaqueCap.Parent = plaque
	local sign = Skin.overlay(plaque, "world.stationSign", { zIndex = plaque.ZIndex, sliceScale = 0.42, name = "Sign" })
	if not sign then
		Depth.panel(plaque, WOOD_DEEP, { radius = Tokens.radius.lg, rim = WOOD_LIGHT })
	end
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.new(0.5, 0, 0.5, -1)
	title.Size = UDim2.new(1, -Tokens.spacing.xxl * 2, 0.74, 0)
	title.Font = Tokens.typography.display.font
	title.TextScaled = true
	title.Text = string.upper(options.title)
	title.TextColor3 = Tokens.color.gold
	title.ZIndex = plaque.ZIndex + 3
	local titleGradient = Instance.new("UIGradient")
	titleGradient.Rotation = 90
	titleGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 232, 150)),
		ColorSequenceKeypoint.new(0.5, Tokens.color.gold),
		ColorSequenceKeypoint.new(1, Tokens.color.goldDeep),
	})
	titleGradient.Parent = title
	FrameKit.outline(title, 3.5, WOOD_DEEP)
	local titleCap = Instance.new("UITextSizeConstraint")
	titleCap.MaxTextSize = 44
	titleCap.MinTextSize = 16
	titleCap.Parent = title
	title.Parent = plaque
	-- Leaves at both ends of the sign.
	for index, role in ipairs({ "modal.leaf.left", "modal.leaf.right" }) do
		local leaf = Skin.icon(plaque, role, 40, plaque.ZIndex + 4)
		if leaf then
			leaf.Size = UDim2.fromOffset(58, 34)
			leaf.AnchorPoint = Vector2.new(if index == 1 then 1 else 0, 0.5)
			leaf.Position = UDim2.new(if index == 1 then 0 else 1, if index == 1 then 12 else -12, 1, -8)
		end
	end
	if options.icon then
		local glyph = Skin.icon(plaque, options.icon, plaqueHeight - Tokens.spacing.md, plaque.ZIndex + 4)
		if glyph then
			glyph.AnchorPoint = Vector2.new(1, 0.5)
			glyph.Position = UDim2.new(0, -Tokens.spacing.xs, 0.5, 0)
		end
	end
	plaque.Parent = card

	-- The slot for a currency chip, on the frame's top edge left of the close knob.
	local headerRight = Instance.new("Frame")
	headerRight.Name = "HeaderRight"
	headerRight.AnchorPoint = Vector2.new(1, 0.5)
	headerRight.Position = UDim2.new(1, -(tap + 30), 0, 8)
	headerRight.Size = UDim2.fromOffset(210, tap + 8)
	headerRight.BackgroundTransparency = 1
	headerRight.ZIndex = card.ZIndex + 6
	headerRight.Parent = card

	-- Close: the red knob on the corner.
	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, 14, 0, -14)
	closeButton.Size = UDim2.fromOffset(tap + 8, tap + 8)
	closeButton.BackgroundColor3 = Color3.fromRGB(176, 40, 32)
	closeButton.Text = ""
	closeButton.AutoButtonColor = false
	closeButton.ZIndex = card.ZIndex + 7
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(1, 0)
	closeCorner.Parent = closeButton
	local closeStroke = Instance.new("UIStroke")
	closeStroke.Thickness = Tokens.stroke.bold
	closeStroke.Color = WOOD_DEEP
	closeStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	closeStroke.Parent = closeButton
	local closeFace = Instance.new("Frame")
	closeFace.Name = "Face"
	closeFace.Size = UDim2.new(1, 0, 1, -5)
	closeFace.BackgroundColor3 = Color3.fromRGB(226, 66, 54)
	closeFace.BorderSizePixel = 0
	closeFace.ZIndex = closeButton.ZIndex + 1
	local closeFaceCorner = Instance.new("UICorner")
	closeFaceCorner.CornerRadius = UDim.new(1, 0)
	closeFaceCorner.Parent = closeFace
	local closeGradient = Instance.new("UIGradient")
	closeGradient.Rotation = 90
	closeGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 130, 110)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(214, 56, 44)),
	})
	closeGradient.Parent = closeFace
	closeFace.Parent = closeButton
	local closeIcon = Icons.close(closeFace, Tokens.icon.md + 2, { zIndex = closeFace.ZIndex + 1, color = Tokens.color.featherWhite })
	closeIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	closeIcon.Position = UDim2.fromScale(0.5, 0.5)
	local closeScale = Instance.new("UIScale")
	closeScale.Parent = closeButton
	closeButton.MouseEnter:Connect(function()
		Tween.scale(closeScale, "hover", options.motion)
	end)
	closeButton.MouseLeave:Connect(function()
		Tween.scale(closeScale, "release", options.motion, 1)
		closeFace.Position = UDim2.fromOffset(0, 0)
	end)
	closeButton.MouseButton1Down:Connect(function()
		closeFace.Position = UDim2.fromOffset(0, 5)
	end)
	closeButton.MouseButton1Up:Connect(function()
		closeFace.Position = UDim2.fromOffset(0, 0)
	end)
	closeButton.SelectionGained:Connect(function()
		closeStroke.Color = Tokens.color.goldLight
		closeStroke.Thickness = Tokens.stroke.frame
		Tween.scale(closeScale, "hover", options.motion)
	end)
	closeButton.SelectionLost:Connect(function()
		closeStroke.Color = WOOD_DEEP
		closeStroke.Thickness = Tokens.stroke.bold
		Tween.scale(closeScale, "release", options.motion, 1)
	end)
	closeButton.Parent = card

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Tokens.spacing.md)
	layout.Parent = panel
	-- Spacer keeps the list layout below the plaque's lower half.
	local spacer = Instance.new("Frame")
	spacer.Name = "HeaderSpace"
	spacer.BackgroundTransparency = 1
	spacer.Size = UDim2.new(1, 0, 0, math.max(0, plaqueHeight / 2 + 6 - FRAME) + Tokens.spacing.sm)
	spacer.LayoutOrder = 1
	spacer.Parent = panel

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

	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.Size = UDim2.new(1, 0, 1, -(spacer.Size.Y.Offset + Tokens.spacing.md))
	content.LayoutOrder = 2
	content.ZIndex = panel.ZIndex + 1
	content.ScrollBarThickness = 6
	content.ScrollBarImageColor3 = Tokens.color.goldDeep
	content.CanvasSize = UDim2.fromScale(0, 0)
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.ScrollingDirection = Enum.ScrollingDirection.Y
	content.ElasticBehavior = Enum.ElasticBehavior.Never
	content.SelectionGroup = false
	if options.compact then
		content.ScrollingEnabled = false
	end
	local contentLayout = Instance.new("UIListLayout")
	contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
	contentLayout.Padding = UDim.new(0, Tokens.spacing.sm + 2)
	contentLayout.Parent = content
	local contentPadding = Instance.new("UIPadding")
	contentPadding.PaddingRight = UDim.new(0, Tokens.spacing.sm)
	contentPadding.PaddingTop = UDim.new(0, Tokens.spacing.xs)
	contentPadding.PaddingBottom = UDim.new(0, Tokens.spacing.sm)
	contentPadding.Parent = content
	content.Parent = panel

	local function relayout()
		local footerHeight = if footer.Visible then footer.AbsoluteSize.Y + Tokens.spacing.md else 0
		content.Size = UDim2.new(1, 0, 1, -(spacer.Size.Y.Offset + Tokens.spacing.md + footerHeight))
		local host = gui :: GuiBase2d
		local stageHeight = host.AbsoluteSize.Y / SafeArea.scaleOf(gui)
		local maxHeight = math.min(stageHeight * Tokens.layout.cardMaxHeightFraction, stageHeight - TOP_ROOM - Tokens.spacing.lg)
		local chrome = spacer.Size.Y.Offset + Tokens.spacing.md + footerHeight + FRAME * 2 + Tokens.spacing.sm * 2 + 5
		local inner = contentLayout.AbsoluteContentSize.Y / SafeArea.scaleOf(gui) + Tokens.spacing.sm * 2
		local wanted = math.clamp(inner + chrome, 220, maxHeight)
		card.Size = UDim2.new(card.Size.X.Scale, 0, 0, math.floor(wanted))
	end
	footer:GetPropertyChangedSignal("Visible"):Connect(relayout)
	footer:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
	contentLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(relayout)
	local host = gui :: GuiBase2d
	host:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)

	root.Parent = gui

	local motion = options.motion
	local shell: Shell =
		{
			root = root,
			card = card,
			panel = panel,
			content = content,
			footer = footer,
			headerRight = headerRight,
			closeButton = closeButton,
			titleLabel = title,
			open = function()
				local openRecipe = Motion.recipe("panelOpen", motion)
				local fadeRecipe = Motion.recipe("panelFadeIn", motion)
				cardScale.Scale = openRecipe.fromScale or 0.82
				card.Position = UDim2.new(0.5, 0, 0.5, TOP_ROOM / 2 + Motion.amplitude(18, motion))
				TweenService:Create(root, Motion.tweenInfo(fadeRecipe), { BackgroundTransparency = if options.blocking then 0.5 else 0.72 })
					:Play()
				TweenService:Create(cardScale, Motion.tweenInfo(openRecipe), { Scale = 1 }):Play()
				TweenService:Create(card, Motion.tweenInfo(openRecipe), { Position = UDim2.new(0.5, 0, 0.5, TOP_ROOM / 2) }):Play()
				relayout()
			end,
			close = function(onClosed)
				local closeRecipe = Motion.recipe("panelClose", motion)
				local fadeRecipe = Motion.recipe("panelFadeOut", motion)
				local fade = TweenService:Create(root, Motion.tweenInfo(fadeRecipe), { BackgroundTransparency = 1 })
				fade:Play()
				TweenService:Create(cardScale, Motion.tweenInfo(closeRecipe), { Scale = closeRecipe.toScale or 0.86 }):Play()
				TweenService:Create(
					card,
					Motion.tweenInfo(closeRecipe),
					{ Position = UDim2.new(0.5, 0, 0.5, TOP_ROOM / 2 + Motion.amplitude(12, motion)) }
				):Play()
				fade.Completed:Once(function()
					root:Destroy()
					if onClosed then
						onClosed()
					end
				end)
			end,
			setTitle = function(text)
				title.Text = string.upper(text)
			end,
		}
	return shell
end

return ModalShell
