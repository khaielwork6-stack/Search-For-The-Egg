--!strict
-- Modal shell: one centred root card sized in Scale with a locked aspect, a wooden board with a
-- parchment face, the painted station-sign plaque over the top rail, a header-right slot for the
-- builder's chips, a round ember close knob inside the header, and a content frame that fills the
-- parchment. Nothing is placed in screen offsets; every child is Scale relative to the card.
-- Opens with a lift and Back-out scale, closes with an ease.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Depth = require(script.Parent.Depth)
local Skin = require(script.Parent.Skin)
local Icons = require(script.Parent.Icons)
local Fit = require(script.Parent.Fit)
local SafeArea = require(script.Parent.Parent.SafeArea)

local ModalShell = {}

export type Shell = {
	root: Frame,
	headerRight: Frame,
	header: Frame,
	plaque: Frame,
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

local WOOD = Color3.fromRGB(150, 108, 60)
local WOOD_DEEP = Color3.fromRGB(96, 64, 34)
local WOOD_LIGHT = Color3.fromRGB(204, 158, 100)
local PAPER = Color3.fromRGB(250, 241, 220)
local PAPER_DEEP = Color3.fromRGB(226, 208, 170)

-- Card geometry per size class: the Scale box it may fill and the aspect it keeps inside it.
local GEOMETRY = {
	wide = { box = Vector2.new(0.94, 0.9), aspect = 1.72, maxWidth = 1700 },
	regular = { box = Vector2.new(0.62, 0.88), aspect = 1.18, maxWidth = 760 },
	compact = { box = Vector2.new(0.5, 0.72), aspect = 1.0, maxWidth = 520 },
}
-- Header band height as a fraction of the card; the parchment starts under it.
local HEADER = 0.145
-- Widest card a row-based builder (Party, Daily, Codes...) gets; their rows were drawn for it.
local LIST_MAX_WIDTH = 1040
-- Header and bottom rail in pixels for row-based cards (their height follows their rows).
local HEADER_PX = 76
local BOTTOM_PX = 18

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
	local geometry = if options.wide then GEOMETRY.wide elseif options.compact then GEOMETRY.compact else GEOMETRY.regular
	local z = Tokens.zIndex.modal
	-- Phones: the responsive stage shrinks offset-based HUD; a Scale-based card wants the whole
	-- screen instead, so a holder cancels the stage scale and the card fills its box.
	local phone = SafeArea.classOf(gui) == "phone"
	local stageScale = SafeArea.scaleOf(gui)

	local root = Instance.new("Frame")
	root.Name = "Modal_" .. (options.id or options.title)
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = Tokens.color.overlay
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.ZIndex = z
	root.Parent = gui

	local holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromScale(1, 1)
	holder.BackgroundTransparency = 1
	holder.ZIndex = z + 1
	local holderScale = Instance.new("UIScale")
	holderScale.Scale = if phone and stageScale > 0 then 1 / stageScale else 1
	holderScale.Parent = holder
	holder.Parent = root

	-- The one centred root container. Scale box + aspect lock; a max width keeps 4K sane.
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = if phone then UDim2.fromScale(0.97, 0.97) else UDim2.fromScale(geometry.box.X, geometry.box.Y)
	card.BackgroundTransparency = 1
	card.BorderSizePixel = 0
	card.ZIndex = z + 1
	card.SelectionGroup = true
	card.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
	card.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
	card.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
	card.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
	local aspect = Fit.aspect(card, geometry.aspect)
	local maxSize = Instance.new("UISizeConstraint")
	maxSize.MaxSize = Vector2.new(geometry.maxWidth, geometry.maxWidth / geometry.aspect)
	maxSize.Parent = card
	local cardScale = Instance.new("UIScale")
	cardScale.Parent = card
	card.Parent = holder

	-- Board: wood face, dark keyline, light rim, banded sheen; the top rail is a lighter plank.
	local board = Instance.new("Frame")
	board.Name = "Board"
	board.Size = UDim2.fromScale(1, 1)
	board.BorderSizePixel = 0
	board.ZIndex = 1
	Depth.panel(board, WOOD, { radius = Tokens.radius.xl, rim = WOOD_LIGHT })
	board.Parent = card
	local rail = Instance.new("Frame")
	rail.Name = "Rail"
	rail.Size = UDim2.fromScale(1, HEADER)
	rail.BackgroundColor3 = WOOD_LIGHT
	rail.BackgroundTransparency = 0.55
	rail.BorderSizePixel = 0
	rail.ZIndex = 2
	local railCorner = Instance.new("UICorner")
	railCorner.CornerRadius = UDim.new(0, Tokens.radius.xl)
	railCorner.Parent = rail
	rail.Parent = board
	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.Size = UDim2.fromScale(1, 0.045)
	shadow.Position = UDim2.fromScale(0, 0.955)
	shadow.BackgroundColor3 = WOOD_DEEP
	shadow.BackgroundTransparency = 0.5
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 2
	local shadowCorner = Instance.new("UICorner")
	shadowCorner.CornerRadius = UDim.new(0, Tokens.radius.xl)
	shadowCorner.Parent = shadow
	shadow.Parent = board

	-- Parchment: the panel every builder fills. Gold rim, warm inner shade.
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Position = UDim2.fromScale(0.028, HEADER)
	panel.Size = UDim2.fromScale(0.944, 0.965 - HEADER)
	panel.BorderSizePixel = 0
	panel.ZIndex = 4
	Depth.panel(panel, PAPER, { radius = Tokens.radius.lg, rim = Color3.new(1, 1, 1) })
	local panelLine = Depth.keylineOf(panel)
	if panelLine then
		panelLine.Color = Tokens.color.goldDeep
		panelLine.Thickness = 2.5
	end
	panel.Parent = card
	local weave = Skin.texture(panel, "texture.studs", { transparency = 0.94, tile = 96, name = "Weave", zIndex = 1 })
	if weave then
		weave.ImageColor3 = PAPER_DEEP
	end
	local inner = Depth.innerShadow(panel, 10, 2)
	inner.BackgroundTransparency = 0.88

	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.Position = UDim2.fromScale(0.02, 0.03)
	content.Size = UDim2.fromScale(0.96, 0.94)
	content.ZIndex = 3
	content.ScrollBarThickness = 6
	content.ScrollBarImageColor3 = Tokens.color.goldDeep
	content.CanvasSize = UDim2.fromScale(0, 0)
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.ScrollingDirection = Enum.ScrollingDirection.Y
	content.ElasticBehavior = Enum.ElasticBehavior.Never
	content.SelectionGroup = false
	-- List builders (Daily, Codes, Settings...) stack their rows in order; Scale builders place one
	-- root frame that fills the window.
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

	local footer = Instance.new("Frame")
	footer.Name = "Footer"
	footer.BackgroundTransparency = 1
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.fromScale(0, 1)
	footer.Size = UDim2.fromScale(1, 0)
	footer.Visible = false
	footer.ZIndex = 4
	footer.Parent = panel

	-- Header: plaque centred over the rail; chips and the close knob on the right, inside the card.
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.fromScale(1, HEADER)
	header.BackgroundTransparency = 1
	header.ZIndex = 6
	header.Parent = card

	local plaque = Instance.new("Frame")
	plaque.Name = "Plaque"
	plaque.AnchorPoint = Vector2.new(0.5, 0.5)
	plaque.Position = UDim2.fromScale(0.5, 0.52)
	plaque.Size = UDim2.fromScale(if options.wide then 0.4 elseif options.compact then 0.78 else 0.62, 0.9)
	plaque.BackgroundTransparency = 1
	plaque.ZIndex = 2
	plaque.Parent = header
	-- Wooden sign: dark plank, light inner border, four nail heads, gold lettering.
	local sign = Instance.new("Frame")
	sign.Name = "Sign"
	sign.Size = UDim2.fromScale(1, 1)
	sign.BorderSizePixel = 0
	sign.ZIndex = 1
	Depth.panel(sign, WOOD_DEEP, { radius = Tokens.radius.md, rim = WOOD })
	Fit.corner(sign, 0.18)
	local signLine = Depth.keylineOf(sign)
	if signLine then
		signLine.Color = Tokens.color.goldDeep
		signLine.Thickness = 2.5
	end
	sign.Parent = plaque
	local signInner = Instance.new("Frame")
	signInner.Name = "Inner"
	signInner.AnchorPoint = Vector2.new(0.5, 0.5)
	signInner.Position = UDim2.fromScale(0.5, 0.5)
	signInner.Size = UDim2.fromScale(0.96, 0.84)
	signInner.BackgroundTransparency = 1
	signInner.ZIndex = 2
	local innerLine = Depth.keyline(signInner, 1.5, Tokens.color.gold)
	innerLine.Transparency = 0.45
	Fit.corner(signInner, 0.16)
	signInner.Parent = sign
	for index, spot in ipairs({ { 0.035, 0.18 }, { 0.965, 0.18 }, { 0.035, 0.82 }, { 0.965, 0.82 } }) do
		local nail = Instance.new("Frame")
		nail.Name = "Nail" .. index
		nail.AnchorPoint = Vector2.new(0.5, 0.5)
		nail.Position = UDim2.fromScale(spot[1], spot[2])
		nail.Size = UDim2.fromScale(0, 0.12)
		nail.BackgroundColor3 = Tokens.color.gold
		nail.BorderSizePixel = 0
		nail.ZIndex = 3
		Fit.aspect(nail, 1, Enum.DominantAxis.Height)
		Fit.corner(nail, 0.5)
		Depth.keyline(nail, 1, Tokens.color.goldDeep)
		nail.Parent = sign
	end
	local title = Fit.text(plaque, "Title", string.upper(options.title), {
		font = Tokens.typography.display.font,
		color = Tokens.color.goldLight,
		max = 46,
		min = 12,
		outline = 2.5,
		outlineColor = WOOD_DEEP,
		zIndex = 3,
		size = UDim2.fromScale(if options.icon then 0.6 else 0.78, 0.6),
		position = UDim2.fromScale(if options.icon then 0.59 else 0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	local titleGradient = Instance.new("UIGradient")
	titleGradient.Rotation = 90
	titleGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 244, 200)),
		ColorSequenceKeypoint.new(0.55, Tokens.color.goldLight),
		ColorSequenceKeypoint.new(1, Tokens.color.gold),
	})
	titleGradient.Parent = title
	Fit.image(plaque, "modal.leaf.left", {
		size = UDim2.fromScale(0.1, 0.62),
		position = UDim2.fromScale(0.06, 0.5),
		zIndex = 4,
		name = "LeafLeft",
	})
	Fit.image(plaque, "modal.leaf.right", {
		size = UDim2.fromScale(0.1, 0.62),
		position = UDim2.fromScale(0.94, 0.5),
		zIndex = 4,
		name = "LeafRight",
	})
	if options.icon then
		Fit.image(plaque, options.icon, {
			size = UDim2.fromScale(0.13, 0.9),
			position = UDim2.fromScale(0.09, 0.5),
			zIndex = 5,
			name = "Glyph",
		})
	end

	local headerRight = Instance.new("Frame")
	headerRight.Name = "HeaderRight"
	headerRight.AnchorPoint = Vector2.new(1, 0.5)
	headerRight.Position = UDim2.fromScale(0.985, 0.5)
	headerRight.Size = UDim2.fromScale(0.36, 0.66)
	headerRight.BackgroundTransparency = 1
	headerRight.ZIndex = 3
	headerRight.Parent = header
	Fit.row(headerRight, { gap = 0.03, halign = Enum.HorizontalAlignment.Right })

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.Text = ""
	closeButton.AutoButtonColor = false
	closeButton.LayoutOrder = 100
	closeButton.Size = UDim2.fromScale(0, 1)
	closeButton.BackgroundColor3 = Tokens.color.emberDeep
	closeButton.BorderSizePixel = 0
	closeButton.ZIndex = 2
	closeButton.Selectable = true
	Fit.aspect(closeButton, 1, Enum.DominantAxis.Height)
	local closeMin = Instance.new("UISizeConstraint")
	closeMin.MinSize = Vector2.new(tap, tap)
	closeMin.Parent = closeButton
	Fit.corner(closeButton, 0.5)
	Depth.keyline(closeButton)
	local closeFace = Instance.new("Frame")
	closeFace.Name = "Face"
	closeFace.Size = UDim2.fromScale(1, 0.9)
	closeFace.BackgroundColor3 = Tokens.color.ember
	closeFace.BorderSizePixel = 0
	closeFace.ZIndex = 2
	Fit.corner(closeFace, 0.5)
	Depth.applySheen(closeFace, Tokens.color.ember)
	Depth.rim(closeFace, Tokens.color.ember)
	closeFace.Parent = closeButton
	local cross = Icons.close(closeFace, 10, { color = Tokens.color.featherWhite, zIndex = 3 })
	cross.AnchorPoint = Vector2.new(0.5, 0.5)
	cross.Position = UDim2.fromScale(0.5, 0.5)
	cross.Size = UDim2.fromScale(0.46, 0.46)
	local closeScale = Instance.new("UIScale")
	closeScale.Parent = closeButton
	closeButton.MouseEnter:Connect(function()
		TweenService:Create(closeScale, TweenInfo.new(0.12), { Scale = 1.08 }):Play()
	end)
	closeButton.MouseLeave:Connect(function()
		TweenService:Create(closeScale, TweenInfo.new(0.12), { Scale = 1 }):Play()
	end)
	closeButton.Parent = headerRight

	-- Card height: a Scale builder (AutomaticCanvasSize None) owns the whole aspect-locked box; a
	-- list builder gets a card just tall enough for its rows, capped at the box, so short lists never
	-- float in empty parchment and long ones scroll inside the panel.
	local function relayout()
		local boxHeight = if phone then 0.97 else geometry.box.Y
		local boxWidth = if phone then 0.97 else geometry.box.X
		if content.AutomaticCanvasSize == Enum.AutomaticSize.None then
			if aspect.Parent ~= card then
				aspect.Parent = card
			end
			maxSize.MaxSize = Vector2.new(geometry.maxWidth, geometry.maxWidth / geometry.aspect)
			card.Size = UDim2.fromScale(boxWidth, boxHeight)
			return
		end
		if aspect.Parent then
			aspect.Parent = nil
		end
		-- Row builders were drawn for the old 1040 px card; wider only stretches their tiles.
		maxSize.MaxSize = Vector2.new(math.min(geometry.maxWidth, LIST_MAX_WIDTH), 10000)
		-- Their header keeps a pixel height so a short card (Codes, an empty quest list) never
		-- squashes the plaque and close knob.
		header.Size = UDim2.new(1, 0, 0, HEADER_PX)
		rail.Size = UDim2.new(1, 0, 0, HEADER_PX)
		plaque.Size = UDim2.new(if options.compact then 0.78 else 0.62, 0, 0, HEADER_PX - 8)
		headerRight.Size = UDim2.new(0.36, 0, 0, HEADER_PX - 24)
		panel.Position = UDim2.new(0.028, 0, 0, HEADER_PX)
		panel.Size = UDim2.new(0.944, 0, 1, -(HEADER_PX + BOTTOM_PX))
		local holderHeight = holder.AbsoluteSize.Y
		if holderHeight <= 0 then
			return
		end
		local scale = SafeArea.scaleOf(card)
		local chrome = card.AbsoluteSize.Y - content.AbsoluteWindowSize.Y
		local rows = contentLayout.AbsoluteContentSize.Y + (contentPadding.PaddingTop.Offset + contentPadding.PaddingBottom.Offset) * scale
		local floor = (chrome + 48 * scale) / holderHeight
		local wanted = math.clamp((rows + chrome) / holderHeight, math.min(floor, boxHeight), boxHeight)
		card.Size = UDim2.fromScale(boxWidth, wanted)
	end
	contentLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(relayout)
	content:GetPropertyChangedSignal("AutomaticCanvasSize"):Connect(relayout)
	holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
	task.defer(relayout)

	local motion = options.motion
	local shell: Shell = {
		root = root,
		card = card,
		panel = panel,
		content = content,
		footer = footer,
		header = header,
		plaque = plaque,
		headerRight = headerRight,
		closeButton = closeButton,
		titleLabel = title,
		open = function()
			local openRecipe = Motion.recipe("panelOpen", motion)
			local fadeRecipe = Motion.recipe("panelFadeIn", motion)
			cardScale.Scale = openRecipe.fromScale or 0.82
			card.Position = UDim2.new(0.5, 0, 0.5, Motion.amplitude(18, motion))
			TweenService:Create(root, Motion.tweenInfo(fadeRecipe), { BackgroundTransparency = if options.blocking then 0.45 else 0.7 })
				:Play()
			TweenService:Create(cardScale, Motion.tweenInfo(openRecipe), { Scale = 1 }):Play()
			TweenService:Create(card, Motion.tweenInfo(openRecipe), { Position = UDim2.fromScale(0.5, 0.5) }):Play()
			relayout()
		end,
		close = function(onClosed)
			local closeRecipe = Motion.recipe("panelClose", motion)
			local fadeRecipe = Motion.recipe("panelFadeOut", motion)
			local fade = TweenService:Create(root, Motion.tweenInfo(fadeRecipe), { BackgroundTransparency = 1 })
			fade:Play()
			TweenService:Create(cardScale, Motion.tweenInfo(closeRecipe), { Scale = closeRecipe.toScale or 0.86 }):Play()
			TweenService:Create(card, Motion.tweenInfo(closeRecipe), { Position = UDim2.new(0.5, 0, 0.5, Motion.amplitude(12, motion)) })
				:Play()
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
