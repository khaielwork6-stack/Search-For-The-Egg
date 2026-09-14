--!strict
-- Modal shell for the rebuilt UI: a dim overlay, a gold-bevelled cream card with a soft shadow, a
-- nameplate title pill that overlaps the top edge, feather accents, a round close button, a
-- scrolling content frame sized for phone and desktop, and an optional footer row. Open lifts and
-- scales in (Back-out) while the overlay fades; close eases out. The card is a controller selection
-- group so focus never escapes an open modal; a slow gold sheen sweeps the frame as ambient motion.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local FrameKit = require(script.Parent.Frame)
local Icons = require(script.Parent.Icons)
local Tween = require(script.Parent.Tween)
local Skin = require(script.Parent.Skin)
local SafeArea = require(script.Parent.Parent.SafeArea)

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

	local card, panel =
		FrameKit.goldPanel(root, "Card", { radius = Tokens.radius.xl, padding = Tokens.spacing.md, zIndex = root.ZIndex + 1 })
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.52)
	if options.compact then
		card.Size = UDim2.fromScale(0.8, 0)
		card.AutomaticSize = Enum.AutomaticSize.Y
	else
		card.Size = UDim2.fromScale(if options.wide then 0.96 else 0.92, Tokens.layout.cardMaxHeightFraction)
	end
	card.SelectionGroup = true
	card.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
	card.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
	card.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
	card.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
	local maxSize = Instance.new("UISizeConstraint")
	maxSize.MaxSize = Vector2.new(if options.compact then 420 elseif options.wide then 860 else Tokens.layout.cardMaxWidthPx, 900)
	maxSize.Parent = card
	local cardScale = Instance.new("UIScale")
	cardScale.Parent = card
	if Skin.has("modal.leaf.left") then
		for index, role in ipairs({ "modal.leaf.left", "modal.leaf.right" }) do
			local leaf = Skin.icon(card, role, 26, card.ZIndex + 2)
			if leaf then
				leaf.Size = UDim2.fromOffset(52, 28)
				leaf.AnchorPoint = Vector2.new(if index == 1 then 0 else 1, 1)
				leaf.Position = UDim2.new(if index == 1 then 0 else 1, if index == 1 then -6 else 6, 1, 6)
			end
		end
	else
		FrameKit.leaves(card, card.ZIndex)
	end

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Tokens.spacing.md)
	layout.Parent = panel

	-- Header: nameplate pill overlapping the card's top edge, close button top-right.
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, tap)
	header.LayoutOrder = 1
	header.ZIndex = panel.ZIndex
	header.Parent = panel

	local title = FrameKit.pill(header, "Title", options.title, {
		size = UDim2.fromOffset(0, tap),
		zIndex = panel.ZIndex + 3,
		textSize = Tokens.typography.title.size,
		fitText = true,
	})
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.new(0.5, 0, 0, -(Tokens.spacing.md + Tokens.spacing.sm))
	title.TextXAlignment = Enum.TextXAlignment.Center
	local titleMax = Instance.new("UISizeConstraint")
	titleMax.MaxSize = Vector2.new(9999, tap)
	titleMax.Parent = title
	FrameKit.shadow(title, { radius = Tokens.radius.pill })

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.fromScale(1, 0)
	closeButton.Size = UDim2.fromOffset(tap, tap)
	closeButton.BackgroundColor3 = Tokens.color.featherWhite
	closeButton.Text = ""
	closeButton.AutoButtonColor = false
	closeButton.ZIndex = panel.ZIndex + 2
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(1, 0)
	closeCorner.Parent = closeButton
	local closeStroke = Instance.new("UIStroke")
	closeStroke.Thickness = Tokens.stroke.bold
	closeStroke.Color = Tokens.color.outline
	closeStroke.Parent = closeButton
	local closeGradient = Instance.new("UIGradient")
	closeGradient.Rotation = 90
	closeGradient.Color =
		ColorSequence.new({ ColorSequenceKeypoint.new(0, Tokens.color.featherWhite), ColorSequenceKeypoint.new(1, Tokens.color.creamDeep) })
	closeGradient.Parent = closeButton
	local closeScale = Instance.new("UIScale")
	closeScale.Parent = closeButton
	FrameKit.shadow(closeButton, { radius = Tokens.radius.pill })
	local closeArt = Skin.label(closeButton, "button.close.normal", { zIndex = closeButton.ZIndex + 1, inset = 3, name = "ArtFace" })
	if closeArt then
		closeStroke.Enabled = false
		closeButton.BackgroundTransparency = 1
		closeButton.MouseButton1Down:Connect(function()
			Skin.apply(closeArt, "button.close.pressed")
		end)
		closeButton.MouseButton1Up:Connect(function()
			Skin.apply(closeArt, "button.close.normal")
		end)
	else
		local closeIcon = Icons.close(closeButton, Tokens.icon.md, { zIndex = closeButton.ZIndex + 1, color = Tokens.color.ember })
		closeIcon.AnchorPoint = Vector2.new(0.5, 0.5)
		closeIcon.Position = UDim2.fromScale(0.5, 0.5)
	end
	-- Optional header glyph (station art) to the left of the nameplate.
	if options.icon then
		local glyph = Skin.icon(header, options.icon, tap, panel.ZIndex + 3)
		if glyph then
			glyph.AnchorPoint = Vector2.new(0, 0)
			glyph.Position = UDim2.fromScale(0, 0)
		end
	end
	closeButton.MouseEnter:Connect(function()
		Tween.scale(closeScale, "hover", options.motion)
	end)
	closeButton.MouseLeave:Connect(function()
		Tween.scale(closeScale, "release", options.motion, 1)
	end)
	closeButton.SelectionGained:Connect(function()
		closeStroke.Color = Tokens.color.goldLight
		closeStroke.Thickness = Tokens.stroke.frame
		Tween.scale(closeScale, "hover", options.motion)
	end)
	closeButton.SelectionLost:Connect(function()
		closeStroke.Color = Tokens.color.outline
		closeStroke.Thickness = Tokens.stroke.bold
		Tween.scale(closeScale, "release", options.motion, 1)
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
	if options.compact then
		content.AutomaticSize = Enum.AutomaticSize.Y
		content.Size = UDim2.fromScale(1, 0)
		content.ScrollingEnabled = false
	end
	local contentLayout = Instance.new("UIListLayout")
	contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
	contentLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	contentLayout.Parent = content
	local contentPadding = Instance.new("UIPadding")
	contentPadding.PaddingRight = UDim.new(0, Tokens.spacing.sm)
	contentPadding.PaddingTop = UDim.new(0, Tokens.spacing.xs)
	contentPadding.PaddingBottom = UDim.new(0, Tokens.spacing.xs)
	contentPadding.Parent = content
	content.Parent = panel

	local function relayout()
		if options.compact then
			return
		end
		local footerHeight = if footer.Visible then footer.AbsoluteSize.Y + Tokens.spacing.md else 0
		content.Size = UDim2.new(1, 0, 1, -(tap + Tokens.spacing.md + footerHeight))
		-- The card is only as tall as its content needs (up to the viewport cap), so short screens
		-- like Daily or Codes never float in an empty card; long ones scroll inside.
		local stageHeight = (gui :: GuiBase2d).AbsoluteSize.Y / SafeArea.scaleOf(gui)
		local maxHeight = stageHeight * Tokens.layout.cardMaxHeightFraction
		local chrome = tap + Tokens.spacing.md + footerHeight + (Tokens.spacing.md + Tokens.spacing.sm) * 2 + Tokens.spacing.lg
		local inner = contentLayout.AbsoluteContentSize.Y / SafeArea.scaleOf(gui) + Tokens.spacing.xs * 2
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
	local alive = true
	-- Ambient sheen: a slow highlight sweep across the gold bevel every few seconds.
	if options.ambient ~= false and not motion.reducedMotion then
		local bevel = card:FindFirstChild("Bevel") :: UIGradient?
		task.spawn(function()
			while alive and bevel do
				task.wait(5 + math.random() * 3)
				if alive then
					local sweep = Instance.new("UIGradient")
					sweep.Name = "Sheen"
					sweep.Rotation = 20
					sweep.Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 1),
						NumberSequenceKeypoint.new(0.45, 1),
						NumberSequenceKeypoint.new(0.5, 0.55),
						NumberSequenceKeypoint.new(0.55, 1),
						NumberSequenceKeypoint.new(1, 1),
					})
					sweep.Parent = nil
					local shine = Instance.new("Frame")
					shine.Name = "Shine"
					shine.Size = UDim2.new(1, Tokens.spacing.sm * 2, 1, Tokens.spacing.sm * 2)
					shine.Position = UDim2.fromOffset(-Tokens.spacing.sm, -Tokens.spacing.sm)
					shine.BackgroundColor3 = Tokens.color.featherWhite
					shine.BackgroundTransparency = 0.7
					shine.BorderSizePixel = 0
					shine.ZIndex = card.ZIndex
					local shineCorner = Instance.new("UICorner")
					shineCorner.CornerRadius = UDim.new(0, Tokens.radius.xl)
					shineCorner.Parent = shine
					sweep.Parent = shine
					shine.Parent = card
					Tween.sheen(sweep, motion, function()
						shine:Destroy()
					end)
				end
			end
		end)
	end

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
			card.Position = UDim2.new(0.5, 0, 0.52, Motion.amplitude(18, motion))
			TweenService:Create(root, Motion.tweenInfo(fadeRecipe), { BackgroundTransparency = if options.blocking then 0.5 else 0.72 })
				:Play()
			TweenService:Create(cardScale, Motion.tweenInfo(openRecipe), { Scale = 1 }):Play()
			TweenService:Create(card, Motion.tweenInfo(openRecipe), { Position = UDim2.fromScale(0.5, 0.52) }):Play()
			relayout()
		end,
		close = function(onClosed)
			alive = false
			local closeRecipe = Motion.recipe("panelClose", motion)
			local fadeRecipe = Motion.recipe("panelFadeOut", motion)
			local fade = TweenService:Create(root, Motion.tweenInfo(fadeRecipe), { BackgroundTransparency = 1 })
			fade:Play()
			TweenService:Create(cardScale, Motion.tweenInfo(closeRecipe), { Scale = closeRecipe.toScale or 0.86 }):Play()
			TweenService:Create(card, Motion.tweenInfo(closeRecipe), { Position = UDim2.new(0.5, 0, 0.52, Motion.amplitude(12, motion)) })
				:Play()
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
