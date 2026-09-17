--!strict
-- The upgrade book: Tab (or the book button, or the supplies counter) opens a two-page book over
-- the round. The Upgrades tab pages through Hand, Bag and every tool - each page shows the item's
-- paths as tiles with level pips and prices, a story box for the selected path with its current
-- and next value, and one BUY. Unowned tools show ??? tiles with locks and a buy-the-tool button.
-- The Index tab lists the feathers: Normal and Rainbow with their odds and value. Pages turn with
-- a flip; the book opens and closes with a spring. Purchases go through UpgradeActions; the
-- server's previews are the only source of levels and prices.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local EconomyMath = require(Shared.EconomyMath)
local ToolSpecs = require(Shared.Domain.ToolSpecs)
local Trove = require(Shared.Util.Trove)
local SafeArea = require(script.Parent.Parent.UI.SafeArea)
local FrameKit = require(script.Parent.Parent.UI.Components.Frame)
local Button = require(script.Parent.Parent.UI.Components.Button)
local Icons = require(script.Parent.Parent.UI.Components.Icons)
local Skin = require(script.Parent.Parent.UI.Components.Skin)
local Confetti = require(script.Parent.Parent.UI.Components.Confetti)
local UpgradeActions = require(script.Parent.Parent.UI.UpgradeActions)
local UpgradeCopy = require(script.Parent.Parent.UI.UpgradeCopy)
local Depth = require(script.Parent.Parent.UI.Components.Depth)
local EggSense = require(Shared.Domain.EggSense)
local NestSurvey = require(Shared.Domain.NestSurvey)

local UpgradeBookController = {}
UpgradeBookController.__index = UpgradeBookController

export type UpgradeBookController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_trove: any,
		_session: any?,
		stats: { opens: number, flips: number, purchases: number },
	},
	UpgradeBookController
))

-- The book is a physical object, but it is drawn in the kit's dark palette (17 Sep 2026, to the
-- reference clip): a charcoal board with a thickness under its bottom edge, a gold rule inlaid just
-- inside it, slate pages with white stroked lettering, and a shadowed gutter where the two halves
-- meet. Green buys, a red close, gold for what is lit.
local COVER = Tokens.color.panel -- the board
local COVER_DEEP = Tokens.color.panelDeep -- its thickness, seen under the bottom edge
local COVER_RULE = Tokens.color.gold -- the gold rule inlaid in the board
local PAGE = Tokens.color.surface -- the page
local PAGE_EDGE = Tokens.color.surfaceAlt -- the stack of pages under the top sheet
local GUTTER = Tokens.color.panelDeep
local BOARD_THICKNESS_PX = 7 -- how far the board's underside shows below the cover
local BOARD_RULE_INSET = 10 -- how far in from the board's edge the gold rule is inlaid

-- The items that get a page, in book order.
local function itemList(cfg: { [string]: any }): { { id: string, title: string, art: string, paths: { string } } }
	local items = {
		{ id = "hand", title = "Hand", art = "tool.hand.normal", paths = { "handHold", "handSpeed", "handGrasp" } },
		{ id = "bag", title = "Bag", art = "icon.feather", paths = { "bag" } },
	}
	for _, toolId in ipairs(ToolSpecs.TOOL_IDS) do
		local paths = {}
		for _, pathName in ipairs(ToolSpecs.PATHS[toolId]) do
			table.insert(paths, toolId .. "." .. pathName)
		end
		table.insert(items, { id = toolId, title = cfg.tools[toolId].displayName, art = "tool." .. toolId .. ".normal", paths = paths })
	end
	return items
end

function UpgradeBookController.new(deps: any): UpgradeBookController
	local self = setmetatable(
		{ _deps = deps, _trove = Trove.new(), _session = nil, stats = { opens = 0, flips = 0, purchases = 0 } },
		UpgradeBookController
	)
	self._trove:add(deps.input.actionBegan:Connect(function(action)
		if action == "Menu" then
			if self._session then
				self:close()
			elseif deps.round:phase() == "Searching" and deps.modals:openCount() == 0 then
				self:open()
			end
		elseif (action == "Cancel" or action == "Back") and self._session then
			self:close()
		end
	end))
	self._trove:add(deps.round.phaseChanged:Connect(function(phase)
		if phase ~= "Searching" and self._session then
			self:close()
		end
	end))
	return self
end

function UpgradeBookController.isOpen(self: UpgradeBookController): boolean
	return self._session ~= nil
end

function UpgradeBookController.toggle(self: UpgradeBookController)
	if self._session then
		self:close()
	else
		self:open()
	end
end

local function previewOf(round: any, upgradeId: string): any?
	return UpgradeActions.previewFor(round, upgradeId)
end

-- Builds one page (left or right) for an item, or the index pages.
function UpgradeBookController._renderPage(self: UpgradeBookController, page: Frame, item: any?)
	local session = self._session
	if not session then
		return
	end
	local deps = self._deps
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = Tokens.layout.minimumTapTargetPx
	for _, child in ipairs(page:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	if not item then
		return
	end
	local z = page.ZIndex + 1
	-- The section heading sits over a gold rule, the way a chapter head does in a printed book:
	-- white display lettering with a thick black stroke.
	local head = Instance.new("Frame")
	head.Name = "Head"
	head.Size = UDim2.new(1, 0, 0, Tokens.typography.display.size + Tokens.spacing.sm)
	head.BackgroundTransparency = 1
	head.ZIndex = z
	head.Parent = page
	local title = FrameKit.text(
		head,
		"Title",
		item.title,
		"display",
		{ zIndex = z + 1, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center }
	)
	title.Size = UDim2.fromScale(1, 1)
	title.TextSize = Tokens.typography.display.size - 2
	FrameKit.outline(title, 3)
	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.AnchorPoint = Vector2.new(0.5, 1)
	rule.Position = UDim2.fromScale(0.5, 1)
	rule.Size = UDim2.new(0.62, 0, 0, 3)
	rule.BackgroundColor3 = COVER_RULE
	rule.BorderSizePixel = 0
	rule.ZIndex = z
	rule.Parent = head
	local ruleCorner = Instance.new("UICorner")
	ruleCorner.CornerRadius = UDim.new(1, 0)
	ruleCorner.Parent = rule
	local ruleFade = Instance.new("UIGradient")
	ruleFade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	ruleFade.Parent = rule

	local owned = true
	local acquire: any = nil
	if item.id ~= "hand" and item.id ~= "bag" then
		acquire = previewOf(deps.round, "tool:" .. item.id)
		owned = acquire ~= nil and acquire.maxed == true
	end

	-- Path tiles.
	local tileTop = Tokens.typography.display.size + Tokens.spacing.md
	-- The tiles sit straight on the paper. They used to float in a translucent cream wash with a faint
	-- stroke, which is exactly the flat washed-out panel the owner called out - and it made three
	-- strong little cards look like one weak big one.
	local tiles = Instance.new("Frame")
	tiles.Name = "Tiles"
	tiles.BackgroundTransparency = 1
	tiles.Position = UDim2.fromOffset(0, tileTop)
	tiles.Size = UDim2.new(1, 0, 0, tap * 3 + Tokens.spacing.lg)
	tiles.ZIndex = z
	local tilesLayout = Instance.new("UIListLayout")
	tilesLayout.FillDirection = Enum.FillDirection.Horizontal
	tilesLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	tilesLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	tilesLayout.Padding = UDim.new(0, Tokens.spacing.md)
	tilesLayout.Parent = tiles
	tiles.Parent = page

	local selected = session.selectedPath[item.id] or item.paths[1]
	session.selectedPath[item.id] = selected
	for index, pathId in ipairs(item.paths) do
		local copy = UpgradeCopy.LABELS[pathId]
		local preview = previewOf(deps.round, pathId)
		-- Each path is a card: a slate face on a darker lip, a thick black keyline, a faint rim. The
		-- selected one is lifted with a gold keyline and a lighter face.
		local isSelected = pathId == selected and owned
		local tile = Instance.new("Frame")
		tile.Name = "Path_" .. pathId
		tile.BackgroundColor3 = Tokens.color.panelDeep
		tile.Size = UDim2.fromOffset(tap * 2 + Tokens.spacing.md, tap * 3)
		tile.LayoutOrder = index
		tile.ZIndex = z + 1
		local tileCorner = Instance.new("UICorner")
		tileCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
		tileCorner.Parent = tile
		Depth.keyline(tile, if isSelected then Tokens.stroke.frame else Tokens.depth.keyline, if isSelected then Tokens.color.gold else nil)
		local tileFace = Instance.new("Frame")
		tileFace.Name = "Face"
		tileFace.Size = UDim2.new(1, 0, 1, -Tokens.depth.lipPx)
		tileFace.BackgroundColor3 = if not owned
			then Tokens.color.surfaceAlt
			elseif isSelected then Depth.shade(Tokens.color.surface, 0.12)
			else Tokens.color.surface
		tileFace.BorderSizePixel = 0
		tileFace.ZIndex = z + 2
		local faceCorner = Instance.new("UICorner")
		faceCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
		faceCorner.Parent = tileFace
		Depth.applySheen(tileFace, tileFace.BackgroundColor3)
		Depth.rim(tileFace, tileFace.BackgroundColor3)
		tileFace.Parent = tile
		tile.Parent = tiles
		local name = FrameKit.text(tileFace, "Name", if owned then (copy and copy.title or pathId) else "???", "label", {
			zIndex = z + 2,
			color = if owned then Tokens.color.featherWhite else Tokens.color.inkMuted,
			align = Enum.TextXAlignment.Center,
		})
		name.Size = UDim2.new(1, 0, 0, Tokens.typography.label.size + 4)
		FrameKit.outline(name, 2)
		-- Level pips as little feathers.
		local pips = Instance.new("Frame")
		pips.Name = "Pips"
		pips.BackgroundTransparency = 1
		pips.Position = UDim2.fromOffset(0, Tokens.typography.label.size + 6)
		pips.Size = UDim2.new(1, 0, 0, 12)
		pips.ZIndex = z + 2
		local pipLayout = Instance.new("UIListLayout")
		pipLayout.FillDirection = Enum.FillDirection.Horizontal
		pipLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		pipLayout.Padding = UDim.new(0, 2)
		pipLayout.SortOrder = Enum.SortOrder.LayoutOrder
		pipLayout.Parent = pips
		pips.Parent = tileFace
		local maxLevel = preview and preview.maxLevel or 0
		-- Every step of the ladder, not the first eight. The dots used to stop at 8 while the Shop drew
		-- all ten for the same kind of track, so a long ladder looked shorter than it was and a player
		-- could not see how far they had left. Dots shrink instead of disappearing.
		local dotSize = if maxLevel > 8 then 8 elseif maxLevel > 6 then 9 else 10
		for level = 1, maxLevel do
			local dot = Instance.new("Frame")
			dot.Size = UDim2.fromOffset(dotSize, dotSize)
			dot.BackgroundColor3 = if preview and level <= preview.level then Tokens.color.gold else Tokens.color.panelDeep
			dot.BorderSizePixel = 0
			dot.ZIndex = z + 2
			dot.LayoutOrder = level
			local dotCorner = Instance.new("UICorner")
			dotCorner.CornerRadius = UDim.new(1, 0)
			dotCorner.Parent = dot
			local dotStroke = Instance.new("UIStroke")
			dotStroke.Thickness = 1.5
			dotStroke.Color = Tokens.color.outline
			dotStroke.Parent = dot
			dot.Parent = pips
		end
		-- Art square (or a lock).
		local square = Instance.new("Frame")
		square.Name = "Art"
		square.AnchorPoint = Vector2.new(0.5, 0)
		square.Position = UDim2.new(0.5, 0, 0, Tokens.typography.label.size + Tokens.spacing.lg + 4)
		square.Size = UDim2.fromOffset(tap + Tokens.spacing.lg, tap + Tokens.spacing.lg)
		-- A dark well for the art to sit in, so the icon reads as inlaid rather than pasted on.
		square.BackgroundColor3 = Tokens.color.panelDeep
		square.ZIndex = z + 3
		local squareCorner = Instance.new("UICorner")
		squareCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
		squareCorner.Parent = square
		Depth.keyline(square, Tokens.depth.keylineThin, if isSelected then Tokens.color.gold else nil)
		square.Parent = tileFace
		if owned then
			local art = Skin.icon(square, (copy and copy.icon) or item.art, tap, z + 3)
				or Icons.build("star", square, tap - Tokens.spacing.md, { zIndex = z + 3 })
			art.AnchorPoint = Vector2.new(0.5, 0.5)
			art.Position = UDim2.fromScale(0.5, 0.5)
		else
			local lock = Icons.lock(square, tap - Tokens.spacing.md, { zIndex = z + 3, color = Tokens.color.gold })
			lock.AnchorPoint = Vector2.new(0.5, 0.5)
			lock.Position = UDim2.fromScale(0.5, 0.5)
		end
		local price = FrameKit.text(
			tileFace,
			"Price",
			"",
			"label",
			{ zIndex = z + 2, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center }
		)
		price.AnchorPoint = Vector2.new(0.5, 1)
		price.Position = UDim2.fromScale(0.5, 1)
		price.Size = UDim2.new(1, 0, 0, Tokens.typography.label.size + 4)
		FrameKit.outline(price, 2)
		if not owned then
			price.Text = "?"
		elseif not preview then
			price.Text = "-"
		elseif preview.maxed then
			price.Text = "MAX"
			price.TextColor3 = Tokens.color.success
		elseif preview.costGems then
			price.Text = string.format("%d Gems", preview.costGems)
		else
			price.Text = EconomyMath.formatCents(preview.costCents or 0)
		end
		if owned then
			local hit = Instance.new("TextButton")
			hit.Text = ""
			hit.BackgroundTransparency = 1
			hit.Size = UDim2.fromScale(1, 1)
			hit.ZIndex = z + 5
			hit.Parent = tile
			session.pageTrove:add(hit.Activated:Connect(function()
				deps.audio:play(Tokens.sound.uiTab)
				session.selectedPath[item.id] = pathId
				self:_renderPage(page, item)
			end))
		end
	end

	-- Story box for the selected path (or the tool itself when unowned) and the BUY.
	local boxTop = tileTop + tap * 3 + Tokens.spacing.lg + Tokens.spacing.md
	-- The detail panel: a darker slate box inset into the page with a keyline and a rim, and a dark
	-- cap with a green line under it so the name of the thing you are about to buy has somewhere to
	-- sit.
	local box = Instance.new("Frame")
	box.Name = "Story"
	box.BackgroundColor3 = Tokens.color.surfaceAlt
	box.Position = UDim2.fromOffset(0, boxTop)
	box.Size = UDim2.new(1, 0, 0, tap * 2 + Tokens.spacing.xl)
	box.ZIndex = z
	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
	boxCorner.Parent = box
	Depth.keyline(box)
	Depth.rim(box, Tokens.color.surfaceAlt)
	Depth.applySheen(box, Tokens.color.surfaceAlt)
	local cap = Instance.new("Frame")
	cap.Name = "Cap"
	cap.Size = UDim2.new(1, 0, 0, Tokens.typography.title.size + Tokens.spacing.sm)
	cap.BackgroundColor3 = Tokens.color.panelDeep
	cap.BorderSizePixel = 0
	cap.ZIndex = z + 1
	local capCorner = Instance.new("UICorner")
	capCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
	capCorner.Parent = cap
	Depth.applySheen(cap, Tokens.color.panelDeep)
	cap.Parent = box
	-- Square off the cap's bottom corners so it reads as a band across the top of the panel, and
	-- rule it off with the green line.
	local capFoot = Instance.new("Frame")
	capFoot.Name = "CapFoot"
	capFoot.AnchorPoint = Vector2.new(0.5, 1)
	capFoot.Position = UDim2.fromScale(0.5, 1)
	capFoot.Size = UDim2.new(1, 0, 0, Tokens.radius.md)
	capFoot.BackgroundColor3 = Tokens.color.panelDeep
	capFoot.BorderSizePixel = 0
	capFoot.ZIndex = z + 1
	capFoot.Parent = cap
	local capLine = Instance.new("Frame")
	capLine.Name = "Line"
	capLine.AnchorPoint = Vector2.new(0.5, 1)
	capLine.Position = UDim2.fromScale(0.5, 1)
	capLine.Size = UDim2.new(1, 0, 0, 3)
	capLine.BackgroundColor3 = Tokens.color.success
	capLine.BorderSizePixel = 0
	capLine.ZIndex = z + 2
	capLine.Parent = cap
	local boxPadding = Instance.new("UIPadding")
	boxPadding.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	boxPadding.PaddingRight = UDim.new(0, Tokens.spacing.md)
	boxPadding.PaddingTop = UDim.new(0, Tokens.spacing.sm)
	boxPadding.PaddingBottom = UDim.new(0, Tokens.spacing.sm)
	boxPadding.Parent = box
	box.Parent = page
	local copy = UpgradeCopy.LABELS[selected]
	local preview = previewOf(deps.round, selected)
	local storyTitle =
		FrameKit.text(cap, "Title", "", "title", { zIndex = z + 3, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center })
	storyTitle.Size = UDim2.fromScale(1, 1)
	FrameKit.outline(storyTitle, 2, Tokens.color.outline)
	local storyText = FrameKit.text(
		box,
		"Text",
		"",
		"body",
		{ zIndex = z + 1, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center, wrap = true }
	)
	storyText.Position = UDim2.fromOffset(0, Tokens.typography.title.size + Tokens.spacing.lg)
	storyText.Size = UDim2.new(1, 0, 0, Tokens.typography.body.size * 2 + 6)
	storyText.TextYAlignment = Enum.TextYAlignment.Top
	FrameKit.outline(storyText, 2)
	local values =
		FrameKit.text(box, "Values", "", "label", { zIndex = z + 1, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center })
	values.AnchorPoint = Vector2.new(0.5, 1)
	values.Position = UDim2.fromScale(0.5, 1)
	values.Size = UDim2.new(1, 0, 0, Tokens.typography.label.size + 4)
	values.RichText = true
	FrameKit.outline(values, 2)
	local buyText = ""
	local buyId: string? = nil
	local buyEnabled = false
	if not owned then
		storyTitle.Text = item.title
		storyText.Text = UpgradeCopy.TOOL_TAGLINES[item.id] or ""
		values.Text = ""
		if acquire and not acquire.maxed then
			-- "BUY (250 Gems)" twice over is a parenthesis nobody needs: the number is the point.
			buyText = if acquire.costGems
				then string.format("BUY  %d Gems", acquire.costGems)
				else string.format("BUY  %s", EconomyMath.formatCents(acquire.costCents or 0))
			buyId = "tool:" .. item.id
			buyEnabled = true
		else
			buyText = "SOLD IN THE BARN"
		end
	else
		storyTitle.Text = copy and copy.title or selected
		storyText.Text = copy and copy.story or ""
		if preview and copy then
			local current = copy.describe(preview.current)
			if preview.maxed then
				values.Text = string.format('%s  <font color="#%s">MAX</font>', current, Tokens.color.success:ToHex())
				buyText = "MAXED"
			else
				values.Text =
					string.format('%s  <font color="#%s">→  %s</font>', current, Tokens.color.gold:ToHex(), copy.describe(preview.next))
				buyText = if preview.costGems
					then string.format("BUY  %d Gems", preview.costGems)
					else string.format("BUY  %s", EconomyMath.formatCents(preview.costCents or 0))
				buyId = selected
				buyEnabled = true
			end
		else
			values.Text = ""
			buyText = "-"
		end
	end
	-- The BUY: green, with a gem or a coin beside the price so the currency reads before the number.
	local buyCurrency = if not owned then acquire else preview
	local buy = Button.build(page, {
		text = buyText,
		variant = "success",
		icon = if buyId then (if buyCurrency and buyCurrency.costGems then "gem" else "coin") else nil,
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.new(0.66, 0, 0, tap + Tokens.spacing.xs),
		zIndex = z + 2,
		textSize = Tokens.typography.title.size - 2,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onActivated = function()
			if not buyId then
				return
			end
			local result = UpgradeActions.purchase({
				net = deps.net,
				round = deps.round,
				audio = deps.audio,
				haptics = deps.haptics,
				toasts = deps.hud.toasts,
				config = cfg,
			}, buyId)
			if result and result.ok then
				self.stats.purchases += 1
				Confetti.burst(page, { origin = UDim2.new(0.5, 0, 1, -tap), count = 16, spread = 120, motion = motion })
			end
		end,
	})
	buy.button.AnchorPoint = Vector2.new(0.5, 1)
	buy.button.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.sm)
	buy.setEnabled(buyEnabled)
	session.pageTrove:add(buy.destroy)
end

-- Index pages: the feathers of the nest.
function UpgradeBookController._renderIndex(self: UpgradeBookController, left: Frame, right: Frame)
	local session = self._session
	if not session then
		return
	end
	local deps = self._deps
	local cfg = deps.config
	local tap = Tokens.layout.minimumTapTargetPx
	for _, page in ipairs({ left, right }) do
		for _, child in ipairs(page:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end
	local z = left.ZIndex + 1
	local player = deps.round.player
	local rainbowCarried = player and player.carriedRainbow or 0
	local entries = {
		{ name = "NORMAL", chance = "100% Chance", value = 1, art = "icon.feather", found = true, rainbow = false },
		{
			name = "RAINBOW",
			chance = string.format("%.1f%% Chance", (cfg.pile.rainbowChance or 0) * 100),
			value = cfg.selling.rainbowFeatherMultiplier,
			art = "icon.feather",
			found = rainbowCarried > 0 or session.rainbowSeen,
			rainbow = true,
		},
	}
	local list = Instance.new("Frame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.Size = UDim2.fromScale(1, 1)
	list.ZIndex = z
	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	listLayout.Parent = list
	list.Parent = left
	for index, entry in ipairs(entries) do
		local row = FrameKit.row(list, "Feather_" .. entry.name, tap * 2, z)
		row.LayoutOrder = index
		local square = Instance.new("Frame")
		square.AnchorPoint = Vector2.new(0, 0.5)
		square.Position = UDim2.fromScale(0, 0.5)
		square.Size = UDim2.fromOffset(tap + Tokens.spacing.lg, tap + Tokens.spacing.lg)
		square.BackgroundColor3 = if entry.rainbow then Tokens.color.gem else Tokens.color.panelDeep
		square.ZIndex = z + 1
		local squareCorner = Instance.new("UICorner")
		squareCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
		squareCorner.Parent = square
		Depth.keyline(square, Tokens.depth.keylineThin)
		square.Parent = row
		local art = Skin.icon(square, entry.art, tap, z + 2)
		if art then
			art.AnchorPoint = Vector2.new(0.5, 0.5)
			art.Position = UDim2.fromScale(0.5, 0.5)
			if entry.rainbow then
				art.ImageColor3 = Color3.fromHSV(0.8, 0.5, 1)
			end
			if not entry.found then
				art.ImageColor3 = Color3.new(0, 0, 0)
			end
		end
		local left2 = tap + Tokens.spacing.lg + Tokens.spacing.md
		local name = FrameKit.text(
			row,
			"Name",
			if entry.found then entry.name else "???",
			"title",
			{ zIndex = z + 1, color = Tokens.color.featherWhite }
		)
		name.Position = UDim2.fromOffset(left2, Tokens.spacing.xs)
		name.Size = UDim2.new(1, -(left2 + tap * 2), 0, Tokens.typography.title.size + 2)
		FrameKit.outline(name, 2.5)
		local chance = FrameKit.text(row, "Chance", entry.chance, "body", { zIndex = z + 1, color = Tokens.color.ink })
		chance.Position = UDim2.fromOffset(left2, Tokens.typography.title.size + Tokens.spacing.sm)
		chance.Size = UDim2.new(1, -(left2 + tap * 2), 0, Tokens.typography.body.size + 4)
		FrameKit.outline(chance, 2)
		local value = FrameKit.text(row, "Value", string.format("x%d", entry.value), "display", {
			zIndex = z + 1,
			color = Tokens.color.gold,
			align = Enum.TextXAlignment.Right,
		})
		value.AnchorPoint = Vector2.new(1, 0.5)
		value.Position = UDim2.fromScale(1, 0.5)
		value.Size = UDim2.fromOffset(tap * 2, Tokens.typography.display.size)
		value.TextSize = Tokens.typography.display.size - 6
		FrameKit.outline(value, 3)
	end
	local title = FrameKit.text(right, "Title", "FEATHER INDEX", "display", { zIndex = z, color = Tokens.color.featherWhite })
	title.Size = UDim2.new(1, 0, 0, Tokens.typography.display.size + 4)
	title.TextSize = Tokens.typography.display.size - 4
	FrameKit.outline(title, 3)
	local story = FrameKit.text(
		right,
		"Story",
		"Rare feathers hide in every nest.\n\nRainbow Feathers sell for ten times a normal feather. Find one and it goes in your index.",
		"body",
		{
			zIndex = z,
			color = Tokens.color.ink,
			wrap = true,
		}
	)
	story.Position = UDim2.fromOffset(0, Tokens.typography.display.size + Tokens.spacing.md)
	story.Size = UDim2.new(1, 0, 0, Tokens.typography.body.size * 5)
	story.TextYAlignment = Enum.TextYAlignment.Top
	FrameKit.outline(story, 2)
	-- NEST INTEL: Professor Plume's rod loans and Molly's survey this round. One row each; the
	-- data is the round snapshot's `plume` and `survey`, so a member who paid nothing and a member
	-- who joined late read the same rows.
	local round = deps.round.round
	local plume = round and round.plume
	local usesLeft = if plume then (plume.usesLeft or 0) else EggSense.maxUses(deps.config)
	local nextCost = if plume then plume.nextCost else EggSense.nextCost(deps.config, 0)
	local cluesTop = Tokens.typography.display.size + Tokens.spacing.md + Tokens.typography.body.size * 5 + Tokens.spacing.md
	local cluesTitle = FrameKit.text(right, "CluesTitle", "NEST INTEL", "title", { zIndex = z, color = Tokens.color.featherWhite })
	cluesTitle.Position = UDim2.fromOffset(0, cluesTop)
	cluesTitle.Size = UDim2.new(1, 0, 0, Tokens.typography.title.size + 2)
	FrameKit.outline(cluesTitle, 2.5)
	local rowHeight = tap - 4
	-- A live row is a slate card with a gold keyline; a spent one sinks into the page behind a black
	-- one.
	local rodRow = Instance.new("Frame")
	rodRow.Name = "Clue_rod"
	rodRow.Position = UDim2.fromOffset(0, cluesTop + Tokens.typography.title.size + Tokens.spacing.sm)
	rodRow.Size = UDim2.new(1, 0, 0, rowHeight)
	rodRow.BackgroundColor3 = if usesLeft > 0 then Tokens.color.surfaceAlt else Tokens.color.panelDeep
	rodRow.BorderSizePixel = 0
	rodRow.ZIndex = z
	local rodCorner = Instance.new("UICorner")
	rodCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
	rodCorner.Parent = rodRow
	Depth.keyline(rodRow, Tokens.depth.keylineThin, if usesLeft > 0 then Tokens.color.gold else nil)
	rodRow.Parent = right
	local rodLabel = FrameKit.text(rodRow, "Label", "EGG SENSE", "heading", { zIndex = z + 1, color = Tokens.color.featherWhite })
	rodLabel.AnchorPoint = Vector2.new(0, 0.5)
	rodLabel.Position = UDim2.new(0, Tokens.spacing.md, 0.5, 0)
	rodLabel.Size = UDim2.new(0.4, 0, 0, Tokens.typography.heading.size + 2)
	FrameKit.outline(rodLabel, 2)
	local rodValue = FrameKit.text(
		rodRow,
		"Value",
		if nextCost then string.format("%d LEFT - NEXT %d", usesLeft, nextCost) else "NO LOANS LEFT",
		"heading",
		{
			zIndex = z + 1,
			color = if nextCost then Tokens.color.gold else Tokens.color.inkMuted,
			align = Enum.TextXAlignment.Right,
		}
	)
	rodValue.AnchorPoint = Vector2.new(1, 0.5)
	rodValue.Position = UDim2.new(1, -Tokens.spacing.md, 0.5, 0)
	rodValue.Size = UDim2.new(0.6, -Tokens.spacing.md, 0, Tokens.typography.heading.size + 2)
	rodValue.TextSize = Tokens.typography.heading.size - 2
	FrameKit.outline(rodValue, 2)
	-- Molly's survey: the party's latest reading of the round (of up to three), or NOT RUN.
	local surveyState = round and round.survey
	local survey = surveyState and surveyState.latest
	local surveyRow = Instance.new("Frame")
	surveyRow.Name = "Clue_survey"
	surveyRow.Position =
		UDim2.fromOffset(0, cluesTop + Tokens.typography.title.size + Tokens.spacing.sm + 1 * (rowHeight + Tokens.spacing.xs))
	surveyRow.Size = UDim2.new(1, 0, 0, rowHeight)
	surveyRow.BackgroundColor3 = if survey then Tokens.color.surfaceAlt else Tokens.color.panelDeep
	surveyRow.BorderSizePixel = 0
	surveyRow.ZIndex = z
	local surveyCorner = Instance.new("UICorner")
	surveyCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
	surveyCorner.Parent = surveyRow
	Depth.keyline(surveyRow, Tokens.depth.keylineThin, if survey then Tokens.color.gold else nil)
	surveyRow.Parent = right
	local surveyLabel = FrameKit.text(surveyRow, "Label", "SURVEY", "heading", { zIndex = z + 1, color = Tokens.color.featherWhite })
	surveyLabel.AnchorPoint = Vector2.new(0, 0.5)
	surveyLabel.Position = UDim2.new(0, Tokens.spacing.md, 0.5, 0)
	surveyLabel.Size = UDim2.new(0.4, 0, 0, Tokens.typography.heading.size + 2)
	FrameKit.outline(surveyLabel, 2)
	local surveyValue = FrameKit.text(
		surveyRow,
		"Value",
		if survey
			then string.format(
				"%s: %s (%d/%d)",
				tostring(survey.id or survey.region),
				tostring(((NestSurvey.WORDS :: any)[survey.signal] or NestSurvey.WORDS.none).title),
				tonumber(surveyState.count) or 0,
				tonumber(surveyState.max) or 0
			)
			else "NOT RUN",
		"heading",
		{
			zIndex = z + 1,
			color = if survey
				then (if survey.signal == "none" then Tokens.color.inkMuted else Tokens.color.gold)
				else Tokens.color.inkMuted,
			align = Enum.TextXAlignment.Right,
		}
	)
	surveyValue.AnchorPoint = Vector2.new(1, 0.5)
	surveyValue.Position = UDim2.new(1, -Tokens.spacing.md, 0.5, 0)
	surveyValue.Size = UDim2.new(0.6, -Tokens.spacing.md, 0, Tokens.typography.heading.size + 2)
	surveyValue.TextSize = Tokens.typography.heading.size - 2
	FrameKit.outline(surveyValue, 2)
	local found = 1 + (if rainbowCarried > 0 or session.rainbowSeen then 1 else 0)
	local count = FrameKit.text(right, "Found", string.format("FEATHERS FOUND:\n%d/%d", found, #entries), "display", {
		zIndex = z,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Center,
	})
	count.AnchorPoint = Vector2.new(0.5, 1)
	count.Position = UDim2.new(0.5, 0, 1, -tap)
	count.Size = UDim2.new(1, 0, 0, Tokens.typography.display.size * 2 + 8)
	count.TextSize = Tokens.typography.display.size - 4
	FrameKit.outline(count, 3)
end

function UpgradeBookController._renderSpread(self: UpgradeBookController)
	-- Everything a spread creates lives on its own trove, replaced here. Before this, each re-render
	-- added another set of button handles and tile connections to the session trove, which only
	-- emptied when the book closed: a long session leaked one set per click.
	local existing = self._session
	if existing then
		if existing.pageTrove then
			existing.pageTrove:destroy()
		end
		existing.pageTrove = Trove.new()
	end
	local session = self._session
	if not session then
		return
	end
	if session.tab == "index" then
		self:_renderIndex(session.left, session.right)
	else
		local items = session.items
		local leftItem = items[session.page]
		local rightItem = items[session.page + 1]
		self:_renderPage(session.left, leftItem)
		self:_renderPage(session.right, rightItem)
	end
	session.tabButtons.upgrades.setSelected(session.tab == "upgrades")
	session.tabButtons.index.setSelected(session.tab == "index")
	session.prev.button.Visible = session.tab == "upgrades" and session.page > 1
	session.next.button.Visible = session.tab == "upgrades" and session.page + 1 < #session.items
	local player = self._deps.round.player
	session.money.Text = "Your money: " .. EconomyMath.formatCents(player and player.cashCents or 0)
end

-- Page turn: the right page folds to the spine and back with the new spread.
function UpgradeBookController._flip(self: UpgradeBookController, direction: number)
	local session = self._session
	if not session or session.flipping then
		return
	end
	local target = math.clamp(session.page + direction * 2, 1, math.max(1, #session.items - 1))
	if target == session.page then
		return
	end
	session.flipping = true
	self.stats.flips += 1
	-- The only page-turn sound. The arrow buttons deliberately carry no click of their own: a press
	-- that does not change the page (already at an end, or mid-flip) returns above and stays silent.
	self._deps.audio:play(Tokens.sound.uiPageFlip)
	local motion = self._deps.accessibility:motionSettings()
	local seconds = if motion.reducedMotion then 0.02 else 0.16
	local page = if direction > 0 then session.right else session.left
	local fold = TweenService:Create(
		page,
		TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Size = UDim2.new(0.02, 0, page.Size.Y.Scale, page.Size.Y.Offset) }
	)
	fold:Play()
	fold.Completed:Once(function()
		session.page = target
		self:_renderSpread()
		local open = TweenService:Create(
			page,
			TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.new(0.5, -Tokens.spacing.md, page.Size.Y.Scale, page.Size.Y.Offset) }
		)
		open:Play()
		open.Completed:Once(function()
			session.flipping = false
		end)
	end)
end

function UpgradeBookController.open(self: UpgradeBookController)
	if self._session then
		return
	end
	local deps = self._deps
	local player = Players.LocalPlayer
	if not player then
		return
	end
	self.stats.opens += 1
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local session = {
		trove = Trove.new(),
		tab = "upgrades",
		page = 1,
		items = itemList(cfg),
		selectedPath = {},
		pageTrove = Trove.new(),
		flipping = false,
		rainbowSeen = false,
	}
	self._session = session
	deps.audio:play(Tokens.sound.uiOpen)
	deps.input:setSuspended(true)
	deps.modals:setExternalUnlock(true)
	session.trove:add(function()
		deps.modals:setExternalUnlock(false)
		deps.input:setSuspended(false)
	end)

	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_Book"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = Tokens.zIndex.modal
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	local _, scaleCleanup, stage = SafeArea.applyScale(gui, cfg)
	session.trove:add(gui)
	session.trove:add(scaleCleanup)
	local tap = Tokens.layout.minimumTapTargetPx

	local dim = Instance.new("TextButton")
	dim.Name = "Dim"
	dim.Text = ""
	dim.BackgroundColor3 = Tokens.color.overlay
	dim.BackgroundTransparency = 0.45
	dim.Size = UDim2.fromScale(1, 1)
	dim.ZIndex = 1
	dim.Parent = stage
	session.trove:add(dim.Activated:Connect(function()
		self:close()
	end))

	-- The book, built as an object rather than a panel: a charcoal board with a thickness under its
	-- bottom edge, a gold rule inlaid just inside the board, the stack of pages showing along the
	-- outer edges, and a shadowed gutter where the two halves meet. A flat rectangle with a corner
	-- radius is what made this read as UI cards on a flat background.
	local holder = Instance.new("Frame")
	holder.Name = "Book"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromScale(0.76, 0.84)
	holder.BackgroundTransparency = 1
	holder.ZIndex = 2
	holder.Parent = stage
	local bookScale = Instance.new("UIScale")
	bookScale.Scale = 0.6
	bookScale.Parent = holder

	-- The board's thickness. Sits a few pixels low and wide, so the book has a bottom edge you can see.
	local thickness = Instance.new("Frame")
	thickness.Name = "Thickness"
	thickness.AnchorPoint = Vector2.new(0.5, 0.5)
	thickness.Position = UDim2.new(0.5, 0, 0.5, BOARD_THICKNESS_PX)
	thickness.Size = UDim2.new(1, 6, 1, 0)
	thickness.BackgroundColor3 = COVER_DEEP
	thickness.BorderSizePixel = 0
	thickness.ZIndex = 2
	local thickCorner = Instance.new("UICorner")
	thickCorner.CornerRadius = UDim.new(0, Tokens.radius.xl)
	thickCorner.Parent = thickness
	Depth.keyline(thickness, Tokens.stroke.frame)
	thickness.Parent = holder

	local cover = Instance.new("Frame")
	cover.Name = "Board"
	cover.Size = UDim2.fromScale(1, 1)
	cover.BackgroundColor3 = COVER
	cover.ZIndex = 3
	local coverCorner = Instance.new("UICorner")
	coverCorner.CornerRadius = UDim.new(0, Tokens.radius.xl)
	coverCorner.Parent = cover
	Depth.keyline(cover, Tokens.stroke.frame)
	Depth.applySheen(cover, COVER)
	Depth.rim(cover, COVER)
	cover.Parent = holder

	-- The gold rule: a thin inlaid border a few pixels in from the board's edge. This one detail is
	-- most of what makes a blue rectangle read as a bound cover.
	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.AnchorPoint = Vector2.new(0.5, 0.5)
	rule.Position = UDim2.fromScale(0.5, 0.5)
	rule.Size = UDim2.new(1, -BOARD_RULE_INSET * 2, 1, -BOARD_RULE_INSET * 2)
	rule.BackgroundTransparency = 1
	rule.ZIndex = 4
	local ruleCorner = Instance.new("UICorner")
	ruleCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	ruleCorner.Parent = rule
	local ruleStroke = Instance.new("UIStroke")
	ruleStroke.Thickness = 2
	ruleStroke.Color = COVER_RULE
	ruleStroke.Transparency = 0.15
	ruleStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ruleStroke.Parent = rule
	rule.Parent = cover

	local coverPadding = Instance.new("UIPadding")
	coverPadding.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
	coverPadding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	coverPadding.PaddingTop = UDim.new(0, Tokens.spacing.lg)
	-- The bottom margin is a band deep enough for the money readout under the pages.
	coverPadding.PaddingBottom = UDim.new(0, Tokens.spacing.xl + Tokens.typography.label.size)
	coverPadding.Parent = cover

	session.cover = cover
	session.holder = holder
	session.scale = bookScale
	TweenService:Create(
		bookScale,
		TweenInfo.new(if motion.reducedMotion then 0.05 else 0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	):Play()

	local function pageFrame(name: string, anchorX: number): Frame
		local page = Instance.new("Frame")
		page.Name = name
		page.AnchorPoint = Vector2.new(anchorX, 0)
		page.Position = UDim2.fromScale(anchorX, 0)
		page.Size = UDim2.new(0.5, -Tokens.spacing.md, 1, 0)
		page.BackgroundColor3 = PAGE
		page.ZIndex = 3
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, Tokens.radius.md)
		corner.Parent = page
		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
		padding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
		padding.PaddingTop = UDim.new(0, Tokens.spacing.md)
		padding.PaddingBottom = UDim.new(0, Tokens.spacing.md)
		padding.Parent = page
		Depth.keyline(page, Tokens.depth.keylineThin)

		-- The page is lit like every other surface in the kit (the glossy ramp), with a darker edge
		-- where it meets the spine so the two halves read as one bound object.
		Depth.applySheen(page, PAGE)
		local gutter = Instance.new("Frame")
		gutter.Name = "Gutter"
		gutter.AnchorPoint = Vector2.new(1 - anchorX, 0)
		gutter.Position = UDim2.fromScale(1 - anchorX, 0)
		gutter.Size = UDim2.new(0, 14, 1, 0)
		gutter.BackgroundColor3 = Tokens.color.overlay
		gutter.BorderSizePixel = 0
		gutter.ZIndex = 4
		gutter.Parent = page
		local gutterFade = Instance.new("UIGradient")
		gutterFade.Rotation = if anchorX == 0 then 0 else 180
		gutterFade.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 0.45),
		})
		gutterFade.Parent = gutter
		page.Parent = cover
		-- The stack of sheets under the top one, along the outer edge. Two thin slivers stepped out and
		-- down is all it takes for a page to stop being a rectangle and become paper. Built after the
		-- page is parented, and as its siblings under the board, so they sit behind it.
		for sheet = 2, 1, -1 do
			local edge = Instance.new("Frame")
			edge.Name = "Sheet" .. sheet
			edge.AnchorPoint = page.AnchorPoint
			edge.Position = page.Position + UDim2.fromOffset((if anchorX == 0 then -1 else 1) * sheet * 3, sheet * 3)
			edge.Size = page.Size - UDim2.fromOffset(0, sheet * 3)
			edge.BackgroundColor3 = if sheet == 1 then PAGE_EDGE else GUTTER
			edge.BorderSizePixel = 0
			edge.ZIndex = page.ZIndex - sheet
			local edgeCorner = Instance.new("UICorner")
			edgeCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
			edgeCorner.Parent = edge
			edge.Parent = cover
		end
		return page
	end
	session.left = pageFrame("LeftPage", 0)
	session.right = pageFrame("RightPage", 1)
	local spine = Instance.new("Frame")
	spine.Name = "Spine"
	spine.AnchorPoint = Vector2.new(0.5, 0)
	spine.Position = UDim2.fromScale(0.5, 0)
	spine.Size = UDim2.new(0, Tokens.spacing.md, 1, 0)
	spine.BackgroundColor3 = Tokens.color.panelDeep
	spine.BorderSizePixel = 0
	spine.ZIndex = 6
	spine.Parent = cover
	local spineShade = Instance.new("UIGradient")
	spineShade.Rotation = 0
	spineShade.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Tokens.color.overlay),
		ColorSequenceKeypoint.new(0.5, Tokens.color.cocoa),
		ColorSequenceKeypoint.new(1, Tokens.color.overlay),
	})
	spineShade.Parent = spine
	for _, at in ipairs({ 0.16, 0.84 }) do
		local band = Instance.new("Frame")
		band.Name = "SpineBand"
		band.AnchorPoint = Vector2.new(0.5, 0.5)
		band.Position = UDim2.fromScale(0.5, at)
		band.Size = UDim2.new(1, 6, 0, 7)
		band.BackgroundColor3 = Tokens.color.gold
		band.BorderSizePixel = 0
		band.ZIndex = 7
		band.Parent = spine
	end

	-- Side tabs.
	local tabs = Instance.new("Frame")
	tabs.Name = "Tabs"
	tabs.AnchorPoint = Vector2.new(1, 0)
	tabs.Position = UDim2.fromOffset(-Tokens.spacing.md, tap * 2)
	tabs.Size = UDim2.fromOffset(tap * 3, tap * 3)
	tabs.BackgroundTransparency = 1
	tabs.ZIndex = 5
	tabs.Parent = cover
	local tabsLayout = Instance.new("UIListLayout")
	tabsLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	tabsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	tabsLayout.Parent = tabs
	session.tabButtons = {}
	for index, spec in ipairs({
		{ id = "upgrades", text = "Upgrades", variant = "success" },
		{ id = "index", text = "Index", variant = "teal" },
	}) do
		local handle = Button.build(tabs, {
			text = spec.text,
			variant = spec.variant,
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromOffset(tap * 3, tap + Tokens.spacing.xs),
			zIndex = 5,
			textSize = Tokens.typography.label.size + 2,
			sound = function()
				deps.audio:play(Tokens.sound.uiTab)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = function()
				if session.tab ~= spec.id then
					session.tab = spec.id
					self:_renderSpread()
				end
			end,
		})
		handle.button.LayoutOrder = index
		handle.button.Name = "Tab_" .. spec.id
		session.tabButtons[spec.id] = handle
		session.trove:add(handle.destroy)
	end

	-- Close and page arrows.
	local close = Button.build(cover, {
		text = "",
		variant = "danger",
		round = true,
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(tap + Tokens.spacing.sm, tap + Tokens.spacing.sm),
		zIndex = 6,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		onActivated = function()
			self:close()
		end,
	})
	close.button.AnchorPoint = Vector2.new(1, 0)
	close.button.Position = UDim2.new(1, Tokens.spacing.lg, 0, -Tokens.spacing.lg)
	local xGlyph =
		Icons.close(close.button:FindFirstChild("Face") :: Frame, Tokens.icon.lg, { zIndex = 8, color = Tokens.color.featherWhite })
	xGlyph.AnchorPoint = Vector2.new(0.5, 0.5)
	xGlyph.Position = UDim2.fromScale(0.5, 0.5)
	session.trove:add(close.destroy)
	local function arrow(name: string, anchorX: number, rotation: number, direction: number)
		local handle = Button.build(cover, {
			text = "",
			variant = "primary",
			round = true,
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromOffset(tap + Tokens.spacing.md, tap + Tokens.spacing.md),
			zIndex = 6,
			sound = function() end,
			onActivated = function()
				self:_flip(direction)
			end,
		})
		handle.button.Name = name
		handle.button.AnchorPoint = Vector2.new(anchorX, 0.5)
		handle.button.Position = UDim2.new(anchorX, (anchorX - 0.5) * 2 * (tap + Tokens.spacing.lg), 0.5, 0)
		local chevron =
			Icons.chevron(handle.button:FindFirstChild("Face") :: Frame, Tokens.icon.lg, { zIndex = 8, color = Tokens.color.featherWhite })
		chevron.AnchorPoint = Vector2.new(0.5, 0.5)
		chevron.Position = UDim2.fromScale(0.5, 0.5)
		chevron.Rotation = rotation
		session.trove:add(handle.destroy)
		return handle
	end
	session.prev = arrow("Previous", 0, 180, -1)
	session.next = arrow("Next", 1, 0, 1)

	-- Sits on the cover's bottom margin under the pages, so it never lands on the HUD below the book.
	local money =
		FrameKit.text(cover, "Money", "", "label", { zIndex = 6, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Center })
	money.AnchorPoint = Vector2.new(0.5, 1)
	money.Position = UDim2.new(0.5, 0, 1, Tokens.typography.label.size + Tokens.spacing.xl - Tokens.spacing.sm)
	money.Size = UDim2.new(0.5, 0, 0, Tokens.typography.label.size + 4)
	FrameKit.outline(money, 2.5)
	session.money = money

	self:_renderSpread()
	session.trove:add(deps.round.upgrade:Connect(function()
		self:_renderSpread()
	end))
	session.trove:add(deps.round.playerChanged:Connect(function()
		self:_renderSpread()
	end))
end

-- Switches the open book to a tab ("upgrades" | "index"); what the tab buttons do.
function UpgradeBookController.setTab(self: UpgradeBookController, tab: string): boolean
	local session = self._session
	if not session or (tab ~= "upgrades" and tab ~= "index") or session.tab == tab then
		return false
	end
	session.tab = tab
	self:_renderSpread()
	return true
end

function UpgradeBookController.close(self: UpgradeBookController)
	local session = self._session
	if not session then
		return
	end
	self._session = nil
	-- The current spread's handles go with the book, not with whatever renders next.
	if session.pageTrove then
		session.pageTrove:destroy()
		session.pageTrove = Trove.new()
	end
	self._deps.audio:play(Tokens.sound.uiClose)
	local motion = self._deps.accessibility:motionSettings()
	if motion.reducedMotion then
		session.trove:destroy()
		return
	end
	local shrink = TweenService:Create(session.scale, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.6 })
	shrink:Play()
	shrink.Completed:Once(function()
		session.trove:destroy()
	end)
end

function UpgradeBookController.destroy(self: UpgradeBookController)
	self:close()
	self._trove:destroy()
end

return UpgradeBookController
