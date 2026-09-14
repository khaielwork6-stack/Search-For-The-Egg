--!strict
-- Stats: a player header (avatar, name, total playtime) over big picture stat cards, then the
-- leaderboards behind a tab strip. Numbers come from the profile projection and the bounded
-- LeaderboardProjection; nothing here is computed locally beyond formatting.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Tabs = require(script.Parent.Parent.Components.Tabs)
local Skin = require(script.Parent.Parent.Components.Skin)
local Icons = require(script.Parent.Parent.Components.Icons)

local TAB_LABELS: { [string]: string } = {
	totalWins = "Eggs won",
	bestTimeChapter1Normal = "Fastest",
	feathersCollected = "Feathers",
	eggsFound = "Eggs found",
}

local function humanise(id: string): string
	local spaced = id:gsub("(%l)(%u)", "%1 %2"):gsub("(%a)(%d)", "%1 %2")
	return spaced:sub(1, 1):upper() .. spaced:sub(2):lower()
end

local StatsModal = {}

export type Deps = {
	net: any,
	profile: any,
	leaderboards: any, -- { snapshot: table?, changed: Signal, request: () -> () }
	audio: any,
	accessibility: any,
	config: { [string]: any },
	minimumTapTarget: number,
}

local function playtime(seconds: number): string
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor(seconds % 3600 / 60)
	if hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	end
	return string.format("%dm %02ds", minutes, math.floor(seconds % 60))
end

local function formatTime(ms: number?): string?
	if not ms then
		return nil
	end
	local totalSeconds = math.floor(ms / 1000)
	return string.format("%02d:%02d.%02d", math.floor(totalSeconds / 60), totalSeconds % 60, math.floor((ms % 1000) / 10))
end

-- The picture cards: caption, art, tint, and how to read the value from the projection.
type CardSpec = { key: string, caption: string, art: string, icon: string, fill: Color3, deep: Color3 }
local CARDS: { CardSpec } = {
	{
		key = "class",
		caption = "CLASS",
		art = "station.classes.normal",
		icon = "star",
		fill = Tokens.color.gold,
		deep = Tokens.color.goldDeep,
	},
	{
		key = "record",
		caption = "TIME RECORD",
		art = "none",
		icon = "clock",
		fill = Tokens.color.ember,
		deep = Tokens.color.emberDeep,
	},
	{ key = "wins", caption = "EGGS WON", art = "icon.egg", icon = "egg", fill = Tokens.color.leaf, deep = Tokens.color.leafDeep },
	{
		key = "feathers",
		caption = "FEATHERS",
		art = "icon.feather",
		icon = "feather",
		fill = Tokens.color.sky,
		deep = Tokens.color.skyDeep,
	},
	{ key = "eggs", caption = "EGGS FOUND", art = "hud.token", icon = "egg", fill = Tokens.color.gem, deep = Tokens.color.gemDeep },
	{
		key = "searches",
		caption = "SEARCHES",
		art = "station.party.normal",
		icon = "star",
		fill = Tokens.color.tealAccent,
		deep = Tokens.color.tealDeep,
	},
}

function StatsModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local player = Players.LocalPlayer

	-- Header: avatar disc, name, total playtime.
	local headerHeight = tap * 2 + Tokens.spacing.md
	local header, headerFace = FrameKit.tile(container, "Header", {
		fill = Tokens.color.tealPanel,
		deep = Tokens.color.tealDeep,
		zIndex = z,
		radius = Tokens.radius.xl,
		size = UDim2.new(1, 0, 0, headerHeight),
	})
	header.LayoutOrder = 1
	local avatar = Instance.new("ImageLabel")
	avatar.Name = "Avatar"
	avatar.AnchorPoint = Vector2.new(0, 0.5)
	avatar.Position = UDim2.new(0, Tokens.spacing.md, 0.5, -2)
	avatar.Size = UDim2.fromOffset(headerHeight - Tokens.spacing.lg, headerHeight - Tokens.spacing.lg)
	avatar.BackgroundColor3 = Tokens.color.creamPill
	avatar.ZIndex = z + 2
	local avatarCorner = Instance.new("UICorner")
	avatarCorner.CornerRadius = UDim.new(1, 0)
	avatarCorner.Parent = avatar
	local avatarStroke = Instance.new("UIStroke")
	avatarStroke.Thickness = Tokens.stroke.frame
	avatarStroke.Color = Tokens.color.outline
	avatarStroke.Parent = avatar
	avatar.Parent = headerFace
	if player then
		task.spawn(function()
			local ok, content = pcall(function()
				return Players:GetUserThumbnailAsync(player.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
			end)
			if ok and avatar.Parent then
				avatar.Image = content
			end
		end)
	end
	local nameLeft = headerHeight - Tokens.spacing.lg + Tokens.spacing.md * 2
	local nameLabel = FrameKit.text(headerFace, "Name", if player then player.DisplayName else "Forager", "display", {
		zIndex = z + 2,
		color = Tokens.color.featherWhite,
	})
	nameLabel.Position = UDim2.new(0, nameLeft, 0.5, -Tokens.typography.display.size / 2 - 2)
	nameLabel.Size = UDim2.new(0.55, -nameLeft, 0, Tokens.typography.display.size + 4)
	nameLabel.TextSize = Tokens.typography.display.size - 4
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	FrameKit.outline(nameLabel, 2.6)
	local playCaption = FrameKit.text(headerFace, "PlayCaption", "TOTAL PLAYTIME", "label", {
		zIndex = z + 2,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Right,
	})
	playCaption.AnchorPoint = Vector2.new(1, 0)
	playCaption.Position = UDim2.new(1, -Tokens.spacing.md, 0, Tokens.spacing.md)
	playCaption.Size = UDim2.new(0.45, 0, 0, Tokens.typography.label.size + 4)
	playCaption.TextSize = Tokens.typography.label.size - 2
	FrameKit.outline(playCaption, 2)
	local playValue = FrameKit.text(headerFace, "PlayValue", "0m 00s", "display", {
		zIndex = z + 2,
		color = Tokens.color.goldLight,
		align = Enum.TextXAlignment.Right,
	})
	playValue.AnchorPoint = Vector2.new(1, 1)
	playValue.Position = UDim2.new(1, -Tokens.spacing.md, 1, -Tokens.spacing.sm)
	playValue.Size = UDim2.new(0.45, 0, 0, Tokens.typography.display.size + 4)
	playValue.TextSize = Tokens.typography.display.size - 4
	FrameKit.outline(playValue, 2.6)

	-- Picture cards, two per row.
	local cardHeight = tap * 2 + Tokens.spacing.xs
	local grid = Instance.new("Frame")
	grid.Name = "Cards"
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.new(1, 0, 0, (cardHeight + Tokens.spacing.sm) * math.ceil(#CARDS / 2))
	grid.LayoutOrder = 2
	grid.ZIndex = z
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.new(0.5, -Tokens.spacing.xs, 0, cardHeight)
	gridLayout.CellPadding = UDim2.fromOffset(Tokens.spacing.sm, Tokens.spacing.sm)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid
	grid.Parent = container
	local values: { [string]: TextLabel } = {}
	for index, spec in ipairs(CARDS) do
		local tile, face =
			FrameKit.tile(grid, "Card_" .. spec.key, { fill = spec.fill, deep = spec.deep, zIndex = z + 1, radius = Tokens.radius.lg })
		tile.LayoutOrder = index
		local artSize = cardHeight - Tokens.spacing.lg
		local artHolder = Instance.new("Frame")
		artHolder.Name = "Art"
		artHolder.AnchorPoint = Vector2.new(0, 0.5)
		artHolder.Position = UDim2.new(0, Tokens.spacing.sm, 0.5, -2)
		artHolder.Size = UDim2.fromOffset(artSize, artSize)
		artHolder.BackgroundTransparency = 1
		artHolder.ZIndex = z + 2
		artHolder.Parent = face
		Skin.texture(artHolder, "texture.sunburst", { zIndex = z + 2, transparency = 0.7, color = Tokens.color.featherWhite })
		local glyph = Skin.icon(artHolder, spec.art, artSize - Tokens.spacing.sm, z + 4)
			or Icons.build(spec.icon, artHolder, artSize - Tokens.spacing.md, { zIndex = z + 4, color = Tokens.color.featherWhite })
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromScale(0.5, 0.5)
		local left = artSize + Tokens.spacing.md
		local caption = FrameKit.text(face, "Caption", spec.caption, "label", {
			zIndex = z + 3,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Center,
		})
		caption.Position = UDim2.new(0, left, 0.5, -(Tokens.typography.label.size + Tokens.spacing.xs) - 2)
		caption.Size = UDim2.new(1, -(left + Tokens.spacing.sm), 0, Tokens.typography.label.size + 4)
		caption.TextSize = Tokens.typography.label.size - 2
		FrameKit.outline(caption, 2)
		local value = FrameKit.text(face, "Value", "-", "display", {
			zIndex = z + 3,
			color = Tokens.color.goldLight,
			align = Enum.TextXAlignment.Center,
		})
		value.Position = UDim2.new(0, left, 0.5, -2)
		value.Size = UDim2.new(1, -(left + Tokens.spacing.sm), 0, Tokens.typography.display.size + 2)
		value.TextSize = Tokens.typography.display.size - 6
		value.TextScaled = false
		value.TextTruncate = Enum.TextTruncate.AtEnd
		FrameKit.outline(value, 2.6)
		values[spec.key] = value
	end

	-- Leaderboards: tab strip then the rows.
	local rowsFrame = Instance.new("Frame")
	rowsFrame.Name = "Board"
	rowsFrame.BackgroundTransparency = 1
	rowsFrame.Size = UDim2.fromScale(1, 0)
	rowsFrame.AutomaticSize = Enum.AutomaticSize.Y
	rowsFrame.LayoutOrder = 4
	rowsFrame.ZIndex = z
	local rowsLayout = Instance.new("UIListLayout")
	rowsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowsLayout.Padding = UDim.new(0, Tokens.spacing.xs)
	rowsLayout.Parent = rowsFrame

	local selectedBoard = cfg.leaderboards.boards[1]
	local tabsHandle
	local medalColors = { Tokens.color.gold, Color3.fromRGB(196, 200, 210), Color3.fromRGB(205, 137, 84) }

	local function renderBoard()
		for _, child in ipairs(rowsFrame:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		local snapshot = deps.leaderboards.snapshot
		if not snapshot then
			local empty = FrameKit.row(rowsFrame, "Empty", tap, z)
			FrameKit.text(
				empty,
				"Text",
				"Loading...",
				"body",
				{ zIndex = z + 1, color = Tokens.color.inkMuted, align = Enum.TextXAlignment.Center }
			).Size =
				UDim2.fromScale(1, 1)
			return
		end
		for _, board in ipairs(snapshot.boards) do
			if board.id ~= selectedBoard then
				continue
			end
			if #board.rows == 0 then
				local empty = FrameKit.row(rowsFrame, "Empty", tap, z)
				FrameKit.text(
					empty,
					"Text",
					"No entries yet",
					"body",
					{ zIndex = z + 1, color = Tokens.color.inkMuted, align = Enum.TextXAlignment.Center }
				).Size =
					UDim2.fromScale(1, 1)
			end
			for index, row in ipairs(board.rows) do
				local frame = FrameKit.row(rowsFrame, "Row" .. index, tap, z)
				frame.LayoutOrder = index
				local mine = row.userId == player.UserId
				local value = if board.unit == "ms" then (formatTime(row.value) or "--:--") else tostring(row.value)
				local rank = FrameKit.badge(frame, "Rank", "#" .. index, medalColors[index] or Tokens.color.strawDeep, z + 2)
				rank.AnchorPoint = Vector2.new(0, 0.5)
				rank.Position = UDim2.fromScale(0, 0.5)
				rank.TextColor3 = Tokens.color.inkStrong
				local label = FrameKit.text(frame, "Text", row.name, "label", {
					zIndex = z + 1,
					color = if mine then Tokens.color.goldDeep else Tokens.color.inkStrong,
				})
				label.Position = UDim2.fromOffset(tap, 0)
				label.Size = UDim2.new(0.6, -tap, 1, 0)
				local valueLabel = FrameKit.text(frame, "Value", value, "label", {
					align = Enum.TextXAlignment.Right,
					zIndex = z + 1,
					color = Tokens.color.goldDeep,
				})
				valueLabel.AnchorPoint = Vector2.new(1, 0)
				valueLabel.Position = UDim2.fromScale(1, 0)
				valueLabel.Size = UDim2.fromScale(0.4, 1)
			end
		end
	end

	local items = {}
	for _, boardId in ipairs(cfg.leaderboards.boards) do
		table.insert(items, { id = boardId, label = TAB_LABELS[boardId] or humanise(boardId) })
	end
	tabsHandle = Tabs.build(container, {
		items = items,
		selected = selectedBoard,
		minimumTapTarget = tap,
		motion = motion,
		zIndex = z + 1,
		sound = function()
			deps.audio:play(Tokens.sound.uiTab)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onSelect = function(id)
			selectedBoard = id
			renderBoard()
		end,
	})
	tabsHandle.frame.LayoutOrder = 3
	rowsFrame.Parent = container
	table.insert(cleanups, tabsHandle.destroy)
	local firstTab = tabsHandle.buttons[selectedBoard]
	if firstTab then
		api.setInitialFocus(firstTab.button)
	end

	local function renderPersonal()
		local projection = deps.profile.projection
		if not projection then
			return
		end
		local className = "Newcomer"
		for _, entry in ipairs(cfg.classes.weights) do
			if entry.id == projection.classes.equipped[1] then
				className = entry.displayName
			end
		end
		playValue.Text = playtime(projection.stats.playtimeSeconds)
		values.class.Text = className
		local best = projection.progression.bestTimeMs.chapter1 or {}
		local record = formatTime(best.normal)
		values.record.Text = record or "NO RECORD"
		values.record.TextSize = if record then Tokens.typography.display.size - 6 else Tokens.typography.title.size - 2
		values.wins.Text = tostring(projection.progression.totalWins)
		values.feathers.Text = tostring(projection.stats.feathersCollected)
		values.eggs.Text = tostring(projection.stats.eggsFound)
		values.searches.Text = tostring(projection.stats.roundsCompleted)
	end

	renderPersonal()
	renderBoard()
	deps.leaderboards.request()
	table.insert(cleanups, deps.profile.changed:Connect(renderPersonal))
	table.insert(cleanups, deps.leaderboards.changed:Connect(renderBoard))
	deps.audio:play(Tokens.sound.uiOpen)

	return function()
		for _, cleanup in ipairs(cleanups) do
			if type(cleanup) == "function" then
				cleanup()
			else
				cleanup:Disconnect()
			end
		end
		deps.audio:play(Tokens.sound.uiClose)
	end
end

return StatsModal
