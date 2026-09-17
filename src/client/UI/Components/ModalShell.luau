--!strict
-- Modal shell, rebuilt 17 Sep 2026 to the owner's reference clip: one centred charcoal panel with a
-- thick near-black keyline and a darker foot, the title floating above the panel's top-left corner
-- in big white lettering with a black stroke, a red X square sitting on the panel's top-right corner,
-- a header-right slot for the builder's chips just inside that corner, and a content frame that fills
-- the panel. Nothing is placed in screen offsets; every child is Scale relative to the card.
-- Opens with a quick pop and closes with an ease.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Depth = require(script.Parent.Depth)
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

-- Card geometry per size class: the Scale box it may fill and the aspect it keeps inside it. The
-- reference's daily and shop panels are about 57% of the screen wide and 55% tall at 16:9.
local GEOMETRY = {
	wide = { box = Vector2.new(0.74, 0.8), aspect = 1.6, maxWidth = 1500 },
	hero = { box = Vector2.new(0.6, 0.62), aspect = 1.82, maxWidth = 1250 },
	regular = { box = Vector2.new(0.58, 0.68), aspect = 1.5, maxWidth = 1000 },
	compact = { box = Vector2.new(0.44, 0.58), aspect = 1.2, maxWidth = 640 },
}
-- The title floats above the panel: this much of the card's height, hanging over the top edge.
local TITLE_HEIGHT = 0.13
-- Widest card a row-based builder (Party, Codes...) gets; their rows were drawn for it.
local LIST_MAX_WIDTH = 1040
-- Top inset and bottom rail in pixels for row-based cards (their height follows their rows).
local HEADER_PX = 30
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
		hero: boolean?,
		ambient: boolean?,
		icon: string?,
	}
): Shell
	local tap = options.minimumTapTarget or Tokens.layout.minimumTapTargetPx
	local geometry = if options.hero
		then GEOMETRY.hero
		elseif options.wide then GEOMETRY.wide
		elseif options.compact then GEOMETRY.compact
		else GEOMETRY.regular
	local z = Tokens.zIndex.modal
	-- Phones: the responsive stage shrinks offset-based HUD; a Scale-based card wants the whole
	-- screen instead, so a holder cancels the stage scale and the card fills its box.
	-- Read live: a Play client can build its first modal while the camera still reports a tiny
	-- startup viewport (classified phone), then grow to a desktop window a frame later.
	local phone = SafeArea.classOf(gui) == "phone"
	local stageScale = SafeArea.scaleOf(gui)
	local function readDevice()
		phone = SafeArea.classOf(gui) == "phone"
		stageScale = SafeArea.scaleOf(gui)
	end

	local root = Instance.new("Frame")
	root.Name = "Modal_" .. (options.id or options.title)
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = Tokens.color.overlay
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.ZIndex = z
	-- A blocking modal's backdrop swallows clicks: a press beside the card must never reach a prompt
	-- or a station in the world behind it.
	root.Active = options.blocking
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
	card.Position = UDim2.fromScale(0.5, 0.52)
	card.Size = if phone then UDim2.fromScale(0.9, 0.86) else UDim2.fromScale(geometry.box.X, geometry.box.Y)
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

	-- Board: the charcoal panel. Thick black keyline, glossy ramp, a darker foot as its thickness.
	local board = Instance.new("Frame")
	board.Name = "Board"
	board.Size = UDim2.fromScale(1, 1)
	board.BorderSizePixel = 0
	board.ZIndex = 1
	Depth.panel(board, Tokens.color.panel, { radius = Tokens.radius.xl })
	board.Parent = card
	local foot = Instance.new("Frame")
	foot.Name = "Shadow"
	foot.AnchorPoint = Vector2.new(0.5, 1)
	foot.Position = UDim2.fromScale(0.5, 1)
	foot.Size = UDim2.fromScale(1, 0.06)
	foot.BackgroundColor3 = Tokens.color.panelDeep
	foot.BorderSizePixel = 0
	foot.ZIndex = 2
	local footCorner = Instance.new("UICorner")
	footCorner.CornerRadius = UDim.new(0, Tokens.radius.xl)
	footCorner.Parent = foot
	foot.Parent = board
	-- A faint sheen band across the top of the panel so it reads as a glossy slab.
	local rail = Instance.new("Frame")
	rail.Name = "Rail"
	rail.Size = UDim2.fromScale(1, 0.12)
	rail.BackgroundColor3 = Color3.new(1, 1, 1)
	rail.BackgroundTransparency = 0.94
	rail.BorderSizePixel = 0
	rail.ZIndex = 2
	local railCorner = Instance.new("UICorner")
	railCorner.CornerRadius = UDim.new(0, Tokens.radius.xl)
	railCorner.Parent = rail
	rail.Parent = board

	-- Panel: the content host, transparent, inset from the board's edges.
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Position = UDim2.fromScale(0.02, 0.05)
	panel.Size = UDim2.fromScale(0.96, 0.91)
	panel.BackgroundTransparency = 1
	panel.BorderSizePixel = 0
	panel.ZIndex = 4
	panel.Parent = card

	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.Position = UDim2.fromScale(0, 0)
	content.Size = UDim2.fromScale(1, 1)
	content.ZIndex = 3
	content.ScrollBarThickness = 6
	content.ScrollBarImageColor3 = Tokens.color.inkMuted
	content.CanvasSize = UDim2.fromScale(0, 0)
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.ScrollingDirection = Enum.ScrollingDirection.Y
	content.ElasticBehavior = Enum.ElasticBehavior.Never
	content.SelectionGroup = false
	-- List builders (Codes, Settings...) stack their rows in order; Scale builders place one root
	-- frame that fills the window.
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

	-- Header: an invisible band along the top of the card that carries the floating title on the
	-- left, the builder's chips on the right, and the red X on the corner.
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.AnchorPoint = Vector2.new(0, 1)
	header.Position = UDim2.fromScale(0, 0.04)
	header.Size = UDim2.fromScale(1, TITLE_HEIGHT)
	header.BackgroundTransparency = 1
	header.ZIndex = 6
	header.Parent = card

	-- The title sits above the panel, left-aligned, hanging just over its top edge.
	local plaque = Instance.new("Frame")
	plaque.Name = "Plaque"
	plaque.AnchorPoint = Vector2.new(0, 1)
	plaque.Position = UDim2.fromScale(0.01, 1.05)
	plaque.Size = UDim2.fromScale(0.62, 1)
	plaque.BackgroundTransparency = 1
	plaque.ZIndex = 2
	plaque.Parent = header
	local title = Fit.text(plaque, "Title", string.upper(options.title), {
		font = Tokens.typography.display.font,
		color = Tokens.color.featherWhite,
		max = 66,
		min = 14,
		align = Enum.TextXAlignment.Left,
		valign = Enum.TextYAlignment.Bottom,
		outline = 4,
		outlineColor = Tokens.color.outline,
		zIndex = 3,
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0, 0),
		anchor = Vector2.new(0, 0),
	})
	title.TextTruncate = Enum.TextTruncate.AtEnd

	local headerRight = Instance.new("Frame")
	headerRight.Name = "HeaderRight"
	-- Centred on the panel's top edge like the close knob, so a short phone header never drops the
	-- chip onto the first row of content.
	headerRight.AnchorPoint = Vector2.new(1, 0.5)
	headerRight.Position = UDim2.fromScale(0.92, 1.0)
	headerRight.Size = UDim2.fromScale(0.36, 0.62)
	headerRight.BackgroundTransparency = 1
	headerRight.ZIndex = 3
	headerRight.Parent = header
	Fit.row(headerRight, { gap = 0.03, halign = Enum.HorizontalAlignment.Right })

	-- The X: a red square with a lit cap, on the panel's top-right corner, half outside it.
	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.Text = ""
	closeButton.AutoButtonColor = false
	closeButton.AnchorPoint = Vector2.new(0.5, 0.5)
	closeButton.Position = UDim2.fromScale(0.992, 1.0)
	closeButton.Size = UDim2.fromScale(0, 0.62)
	closeButton.BackgroundColor3 = Tokens.color.emberDeep
	closeButton.BorderSizePixel = 0
	closeButton.ZIndex = 8
	closeButton.Selectable = true
	Fit.aspect(closeButton, 1, Enum.DominantAxis.Height)
	local closeMin = Instance.new("UISizeConstraint")
	closeMin.MinSize = Vector2.new(tap, tap)
	closeMin.Parent = closeButton
	Fit.corner(closeButton, 0.24)
	Depth.keyline(closeButton)
	local closeFace = Instance.new("Frame")
	closeFace.Name = "Face"
	closeFace.Size = UDim2.fromScale(1, 0.9)
	closeFace.BackgroundColor3 = Tokens.color.ember
	closeFace.BorderSizePixel = 0
	closeFace.ZIndex = 2
	Fit.corner(closeFace, 0.24)
	Depth.applySheen(closeFace, Tokens.color.ember, Color3.fromRGB(255, 150, 140))
	Depth.rim(closeFace, Tokens.color.ember)
	closeFace.Parent = closeButton
	Fit.text(closeFace, "X", "X", {
		font = Tokens.typography.display.font,
		color = Tokens.color.featherWhite,
		max = 44,
		min = 12,
		outline = 2.6,
		outlineColor = Tokens.color.outline,
		zIndex = 3,
		size = UDim2.fromScale(0.9, 0.86),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	local closeScale = Instance.new("UIScale")
	closeScale.Parent = closeButton
	closeButton.MouseEnter:Connect(function()
		TweenService:Create(closeScale, TweenInfo.new(0.12, Enum.EasingStyle.Back), { Scale = 1.1 }):Play()
	end)
	closeButton.MouseLeave:Connect(function()
		TweenService:Create(closeScale, TweenInfo.new(0.12), { Scale = 1 }):Play()
	end)
	closeButton.MouseButton1Down:Connect(function()
		TweenService:Create(closeScale, TweenInfo.new(0.08), { Scale = 0.92 }):Play()
	end)
	closeButton.MouseButton1Up:Connect(function()
		TweenService:Create(closeScale, TweenInfo.new(0.18, Enum.EasingStyle.Back), { Scale = 1.06 }):Play()
	end)
	closeButton.Parent = header

	-- Card height: a Scale builder (AutomaticCanvasSize None) owns the whole aspect-locked box; a
	-- list builder gets a card just tall enough for its rows, capped at the box, so short lists never
	-- float in empty panel and long ones scroll inside it.
	local function relayout()
		if root.Parent == nil then
			return -- closed: the detached aspect constraint must not be re-parented to a dead card
		end
		readDevice()
		holderScale.Scale = if phone and stageScale > 0 then 1 / stageScale else 1
		local boxHeight = if phone then 0.86 else geometry.box.Y
		local boxWidth = if phone then 0.9 else geometry.box.X
		if content.AutomaticCanvasSize == Enum.AutomaticSize.None then
			-- A hero card on a phone takes the whole landscape viewport; the aspect lock would give
			-- back a third of the width for nothing.
			local wantAspect = not (options.hero and phone)
			if wantAspect and aspect.Parent ~= card then
				aspect.Parent = card
			elseif not wantAspect and aspect.Parent then
				aspect.Parent = nil
			end
			maxSize.MaxSize = Vector2.new(geometry.maxWidth, geometry.maxWidth / geometry.aspect)
			card.Size = UDim2.fromScale(boxWidth, boxHeight)
			header.Size = UDim2.fromScale(1, TITLE_HEIGHT)
			return
		end
		if aspect.Parent then
			aspect.Parent = nil
		end
		-- Row builders were drawn for the old 1040 px card; wider only stretches their tiles.
		maxSize.MaxSize = Vector2.new(math.min(geometry.maxWidth, LIST_MAX_WIDTH), 10000)
		-- Their title keeps a pixel height so a short card (Codes, an empty quest list) never
		-- squashes the lettering or the X.
		header.Size = UDim2.new(1, 0, 0, 72)
		panel.Position = UDim2.new(0.02, 0, 0, HEADER_PX)
		panel.Size = UDim2.new(0.96, 0, 1, -(HEADER_PX + BOTTOM_PX))
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
	local stage = SafeArea.stageOf(gui)
	local stageConnection = if stage then stage:GetAttributeChangedSignal("SFE_LayoutClass"):Connect(relayout) else nil
	root.Destroying:Connect(function()
		if stageConnection then
			stageConnection:Disconnect()
		end
		aspect:Destroy() -- may be parked outside the tree (phone hero), so Destroy() on the root misses it
	end)
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
			card.Position = UDim2.new(0.5, 0, 0.52, Motion.amplitude(18, motion))
			TweenService:Create(root, Motion.tweenInfo(fadeRecipe), { BackgroundTransparency = if options.blocking then 0.45 else 0.7 })
				:Play()
			TweenService:Create(cardScale, Motion.tweenInfo(openRecipe), { Scale = 1 }):Play()
			TweenService:Create(card, Motion.tweenInfo(openRecipe), { Position = UDim2.fromScale(0.5, 0.52) }):Play()
			relayout()
		end,
		close = function(onClosed)
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
			title.Text = string.upper(text)
		end,
	}
	return shell
end

return ModalShell
