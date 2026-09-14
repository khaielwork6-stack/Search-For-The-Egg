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

local PAGE_BLUE = Color3.fromRGB(46, 96, 150)
local COVER = Color3.fromRGB(38, 78, 128)
local PAGE = Color3.fromRGB(250, 243, 226)

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
	local title = FrameKit.text(page, "Title", item.title, "display", { zIndex = z, color = PAGE_BLUE, align = Enum.TextXAlignment.Center })
	title.Size = UDim2.new(1, 0, 0, Tokens.typography.display.size + 4)
	title.TextSize = Tokens.typography.display.size - 2
	FrameKit.outline(title, 2, Tokens.color.featherWhite)

	local owned = true
	local acquire: any = nil
	if item.id ~= "hand" and item.id ~= "bag" then
		acquire = previewOf(deps.round, "tool:" .. item.id)
		owned = acquire ~= nil and acquire.maxed == true
	end

	-- Path tiles.
	local tileTop = Tokens.typography.display.size + Tokens.spacing.md
	local tiles = Instance.new("Frame")
	tiles.Name = "Tiles"
	tiles.BackgroundColor3 = Tokens.color.creamDeep
	tiles.BackgroundTransparency = 0.35
	tiles.Position = UDim2.fromOffset(0, tileTop)
	tiles.Size = UDim2.new(1, 0, 0, tap * 3 + Tokens.spacing.lg)
	tiles.ZIndex = z
	local tilesCorner = Instance.new("UICorner")
	tilesCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
	tilesCorner.Parent = tiles
	local tilesStroke = Instance.new("UIStroke")
	tilesStroke.Thickness = 1.5
	tilesStroke.Color = Tokens.color.strawDeep
	tilesStroke.Transparency = 0.4
	tilesStroke.Parent = tiles
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
		local tile = Instance.new("Frame")
		tile.Name = "Path_" .. pathId
		tile.BackgroundTransparency = 1
		tile.Size = UDim2.fromOffset(tap * 2 + Tokens.spacing.md, tap * 3)
		tile.LayoutOrder = index
		tile.ZIndex = z + 1
		tile.Parent = tiles
		local name = FrameKit.text(tile, "Name", if owned then (copy and copy.title or pathId) else "???", "label", {
			zIndex = z + 2,
			color = Tokens.color.inkStrong,
			align = Enum.TextXAlignment.Center,
		})
		name.Size = UDim2.new(1, 0, 0, Tokens.typography.label.size + 4)
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
		pips.Parent = tile
		local maxLevel = preview and preview.maxLevel or 0
		for level = 1, math.min(maxLevel, 8) do
			local dot = Instance.new("Frame")
			dot.Size = UDim2.fromOffset(10, 10)
			dot.BackgroundColor3 = if preview and level <= preview.level then Tokens.color.gold else Tokens.color.creamDeep
			dot.BorderSizePixel = 0
			dot.ZIndex = z + 2
			dot.LayoutOrder = level
			local dotCorner = Instance.new("UICorner")
			dotCorner.CornerRadius = UDim.new(1, 0)
			dotCorner.Parent = dot
			local dotStroke = Instance.new("UIStroke")
			dotStroke.Thickness = 1.2
			dotStroke.Color = Tokens.color.strawDeep
			dotStroke.Parent = dot
			dot.Parent = pips
		end
		-- Art square (or a lock).
		local square = Instance.new("Frame")
		square.Name = "Art"
		square.AnchorPoint = Vector2.new(0.5, 0)
		square.Position = UDim2.new(0.5, 0, 0, Tokens.typography.label.size + Tokens.spacing.lg + 4)
		square.Size = UDim2.fromOffset(tap + Tokens.spacing.lg, tap + Tokens.spacing.lg)
		square.BackgroundColor3 = if owned then Tokens.color.featherWhite else Tokens.color.inkMuted
		square.ZIndex = z + 2
		local squareCorner = Instance.new("UICorner")
		squareCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
		squareCorner.Parent = square
		local squareStroke = Instance.new("UIStroke")
		squareStroke.Thickness = if pathId == selected and owned then Tokens.stroke.frame else Tokens.stroke.standard
		squareStroke.Color = if pathId == selected and owned then Tokens.color.gold else Tokens.color.strawDeep
		squareStroke.Parent = square
		square.Parent = tile
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
			tile,
			"Price",
			"",
			"label",
			{ zIndex = z + 2, color = Tokens.color.inkStrong, align = Enum.TextXAlignment.Center }
		)
		price.AnchorPoint = Vector2.new(0.5, 1)
		price.Position = UDim2.fromScale(0.5, 1)
		price.Size = UDim2.new(1, 0, 0, Tokens.typography.label.size + 4)
		if not owned then
			price.Text = "?"
		elseif not preview then
			price.Text = "-"
		elseif preview.maxed then
			price.Text = "MAX"
			price.TextColor3 = Tokens.color.leafDeep
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
			session.trove:add(hit.Activated:Connect(function()
				deps.audio:play(Tokens.sound.uiTab)
				session.selectedPath[item.id] = pathId
				self:_renderPage(page, item)
			end))
		end
	end

	-- Story box for the selected path (or the tool itself when unowned) and the BUY.
	local boxTop = tileTop + tap * 3 + Tokens.spacing.lg + Tokens.spacing.md
	local box = Instance.new("Frame")
	box.Name = "Story"
	box.BackgroundColor3 = Color3.fromRGB(190, 186, 204)
	box.BackgroundTransparency = 0.25
	box.Position = UDim2.fromOffset(0, boxTop)
	box.Size = UDim2.new(1, 0, 0, tap * 2 + Tokens.spacing.xl)
	box.ZIndex = z
	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
	boxCorner.Parent = box
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
		FrameKit.text(box, "Title", "", "title", { zIndex = z + 1, color = Tokens.color.inkStrong, align = Enum.TextXAlignment.Center })
	storyTitle.Size = UDim2.new(1, 0, 0, Tokens.typography.title.size + 2)
	local storyText = FrameKit.text(
		box,
		"Text",
		"",
		"body",
		{ zIndex = z + 1, color = Tokens.color.inkStrong, align = Enum.TextXAlignment.Center, wrap = true }
	)
	storyText.Position = UDim2.fromOffset(0, Tokens.typography.title.size + Tokens.spacing.xs)
	storyText.Size = UDim2.new(1, 0, 0, Tokens.typography.body.size * 2 + 6)
	storyText.TextYAlignment = Enum.TextYAlignment.Top
	local values =
		FrameKit.text(box, "Values", "", "label", { zIndex = z + 1, color = Tokens.color.inkStrong, align = Enum.TextXAlignment.Center })
	values.AnchorPoint = Vector2.new(0.5, 1)
	values.Position = UDim2.fromScale(0.5, 1)
	values.Size = UDim2.new(1, 0, 0, Tokens.typography.label.size + 4)
	values.RichText = true
	local buyText = ""
	local buyId: string? = nil
	local buyEnabled = false
	if not owned then
		storyTitle.Text = item.title
		storyText.Text = UpgradeCopy.TOOL_TAGLINES[item.id] or ""
		values.Text = ""
		if acquire and not acquire.maxed then
			buyText = string.format(
				"BUY  (%s)",
				if acquire.costGems then acquire.costGems .. " Gems" else EconomyMath.formatCents(acquire.costCents or 0)
			)
			buyId = "tool:" .. item.id
			buyEnabled = true
		else
			buyText = "NOT FOR SALE HERE"
		end
	else
		storyTitle.Text = copy and copy.title or selected
		storyText.Text = copy and copy.story or ""
		if preview and copy then
			local current = copy.describe(preview.current)
			if preview.maxed then
				values.Text = string.format('%s  <font color="#%s">MAX</font>', current, Tokens.color.leafDeep:ToHex())
				buyText = "MAXED"
			else
				values.Text = string.format(
					'%s  <font color="#%s">→  %s</font>',
					current,
					Tokens.color.goldDeep:ToHex(),
					copy.describe(preview.next)
				)
				buyText = string.format(
					"BUY  (%s)",
					if preview.costGems then preview.costGems .. " Gems" else EconomyMath.formatCents(preview.costCents or 0)
				)
				buyId = selected
				buyEnabled = true
			end
		else
			values.Text = ""
			buyText = "-"
		end
	end
	local buy = Button.build(page, {
		text = buyText,
		variant = "primary",
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
	session.trove:add(buy.destroy)
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
		square.BackgroundColor3 = if entry.rainbow then Tokens.color.gem else Tokens.color.creamPill
		square.ZIndex = z + 1
		local squareCorner = Instance.new("UICorner")
		squareCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
		squareCorner.Parent = square
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
		local name = FrameKit.text(row, "Name", if entry.found then entry.name else "???", "title", { zIndex = z + 1, color = PAGE_BLUE })
		name.Position = UDim2.fromOffset(left2, Tokens.spacing.xs)
		name.Size = UDim2.new(1, -(left2 + tap * 2), 0, Tokens.typography.title.size + 2)
		local chance = FrameKit.text(row, "Chance", entry.chance, "body", { zIndex = z + 1, color = Tokens.color.ink })
		chance.Position = UDim2.fromOffset(left2, Tokens.typography.title.size + Tokens.spacing.sm)
		chance.Size = UDim2.new(1, -(left2 + tap * 2), 0, Tokens.typography.body.size + 4)
		local value = FrameKit.text(row, "Value", string.format("x%d", entry.value), "display", {
			zIndex = z + 1,
			color = PAGE_BLUE,
			align = Enum.TextXAlignment.Right,
		})
		value.AnchorPoint = Vector2.new(1, 0.5)
		value.Position = UDim2.fromScale(1, 0.5)
		value.Size = UDim2.fromOffset(tap * 2, Tokens.typography.display.size)
		value.TextSize = Tokens.typography.display.size - 6
	end
	local title = FrameKit.text(right, "Title", "FEATHER INDEX", "display", { zIndex = z, color = PAGE_BLUE })
	title.Size = UDim2.new(1, 0, 0, Tokens.typography.display.size + 4)
	title.TextSize = Tokens.typography.display.size - 4
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
	story.Size = UDim2.new(1, 0, 0, Tokens.typography.body.size * 6)
	story.TextYAlignment = Enum.TextYAlignment.Top
	local found = 1 + (if rainbowCarried > 0 or session.rainbowSeen then 1 else 0)
	local count = FrameKit.text(right, "Found", string.format("FEATHERS FOUND:\n%d/%d", found, #entries), "display", {
		zIndex = z,
		color = Tokens.color.inkStrong,
		align = Enum.TextXAlignment.Center,
	})
	count.AnchorPoint = Vector2.new(0.5, 1)
	count.Position = UDim2.new(0.5, 0, 1, -tap)
	count.Size = UDim2.new(1, 0, 0, Tokens.typography.display.size * 2 + 8)
	count.TextSize = Tokens.typography.display.size - 4
end

function UpgradeBookController._renderSpread(self: UpgradeBookController)
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
	session.money.Text = "your money :  " .. EconomyMath.formatCents(player and player.cashCents or 0)
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
	self._deps.audio:play(Tokens.sound.uiTab)
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

	-- Cover, spine, pages.
	local cover = Instance.new("Frame")
	cover.Name = "Book"
	cover.AnchorPoint = Vector2.new(0.5, 0.5)
	cover.Position = UDim2.fromScale(0.5, 0.5)
	cover.Size = UDim2.fromScale(0.74, 0.82)
	cover.BackgroundColor3 = COVER
	cover.ZIndex = 2
	local coverCorner = Instance.new("UICorner")
	coverCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	coverCorner.Parent = cover
	local coverStroke = Instance.new("UIStroke")
	coverStroke.Thickness = Tokens.stroke.frame
	coverStroke.Color = Tokens.color.outline
	coverStroke.Parent = cover
	local coverPadding = Instance.new("UIPadding")
	coverPadding.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	coverPadding.PaddingRight = UDim.new(0, Tokens.spacing.md)
	coverPadding.PaddingTop = UDim.new(0, Tokens.spacing.md)
	coverPadding.PaddingBottom = UDim.new(0, Tokens.spacing.md)
	coverPadding.Parent = cover
	local bookScale = Instance.new("UIScale")
	bookScale.Scale = 0.6
	bookScale.Parent = cover
	cover.Parent = stage
	session.cover = cover
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
		Skin.texture(page, "texture.studs", { zIndex = 3, transparency = 0.96, tile = 28 })
		page.Parent = cover
		return page
	end
	session.left = pageFrame("LeftPage", 0)
	session.right = pageFrame("RightPage", 1)
	local spine = Instance.new("Frame")
	spine.Name = "Spine"
	spine.AnchorPoint = Vector2.new(0.5, 0)
	spine.Position = UDim2.fromScale(0.5, 0)
	spine.Size = UDim2.new(0, Tokens.spacing.md, 1, 0)
	spine.BackgroundColor3 = Tokens.color.tealDeep
	spine.BorderSizePixel = 0
	spine.ZIndex = 4
	spine.Parent = cover

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
			textSize = Tokens.typography.title.size - 2,
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
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
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

	local money =
		FrameKit.text(cover, "Money", "", "label", { zIndex = 6, color = Tokens.color.featherWhite, align = Enum.TextXAlignment.Right })
	money.AnchorPoint = Vector2.new(1, 1)
	money.Position = UDim2.new(1, 0, 1, Tokens.spacing.lg + Tokens.typography.label.size)
	money.Size = UDim2.new(0.5, 0, 0, Tokens.typography.label.size + 4)
	FrameKit.outline(money, 2)
	session.money = money

	self:_renderSpread()
	session.trove:add(deps.round.upgrade:Connect(function()
		self:_renderSpread()
	end))
	session.trove:add(deps.round.playerChanged:Connect(function()
		self:_renderSpread()
	end))
end

function UpgradeBookController.close(self: UpgradeBookController)
	local session = self._session
	if not session then
		return
	end
	self._session = nil
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
