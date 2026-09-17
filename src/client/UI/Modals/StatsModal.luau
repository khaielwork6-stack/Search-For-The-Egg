--!strict
-- Stats: a player header (avatar, name, total playtime) over the ledger - one dark slate row per
-- stat, caption on the left and the value on the right in white stroked lettering - then the
-- leaderboards behind a tab strip. Numbers come from the profile projection and the bounded
-- LeaderboardProjection; nothing here is computed locally beyond formatting.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Tabs = require(script.Parent.Parent.Components.Tabs)
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

-- The ledger rows: caption, glyph, and the key renderPersonal fills from the projection.
type RowSpec = { key: string, caption: string, icon: string }
local ROWS: { RowSpec } = {
	{ key = "class", caption = "CLASS", icon = "star" },
	{ key = "record", caption = "TIME RECORD", icon = "clock" },
	{ key = "wins", caption = "EGGS WON", icon = "egg" },
	{ key = "feathers", caption = "FEATHERS", icon = "feather" },
	{ key = "eggs", caption = "EGGS FOUND", icon = "egg" },
	{ key = "searches", caption = "SEARCHES", icon = "star" },
}

-- Medal tones for the top three ranks; every rank below is plain slate.
local MEDALS = { Tokens.color.gold, Tokens.color.sky, Tokens.color.gem }

-- The reference draws a thick near-black keyline around every list item; the kit row ships with the
-- standard one.
local function thicken(row: Frame)
	local stroke = row:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = Tokens.depth.keyline
		stroke.Transparency = 0
	end
end

function StatsModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local player = Players.LocalPlayer

	-- Header: avatar disc, name, total playtime on a slate tile.
	local headerHeight = tap * 2 + Tokens.spacing.md
	local header, headerFace = FrameKit.tile(container, "Header", {
		fill = Tokens.color.surface,
		deep = Tokens.color.panelDeep,
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
	avatar.BackgroundColor3 = Tokens.color.surfaceAlt
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
	FrameKit.outline(nameLabel, 3)
	local playCaption = FrameKit.text(headerFace, "PlayCaption", "TOTAL PLAYTIME", "label", {
		zIndex = z + 2,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Right,
	})
	playCaption.AnchorPoint = Vector2.new(1, 0)
	playCaption.Position = UDim2.new(1, -Tokens.spacing.md, 0, Tokens.spacing.md)
	playCaption.Size = UDim2.new(0.45, 0, 0, Tokens.typography.label.size + 4)
	playCaption.TextSize = Tokens.typography.label.size - 2
	FrameKit.outline(playCaption, 2.5)
	local playValue = FrameKit.text(headerFace, "PlayValue", "0m 00s", "display", {
		zIndex = z + 2,
		color = Tokens.color.gold,
		align = Enum.TextXAlignment.Right,
	})
	playValue.AnchorPoint = Vector2.new(1, 1)
	playValue.Position = UDim2.new(1, -Tokens.spacing.md, 1, -Tokens.spacing.sm)
	playValue.Size = UDim2.new(0.45, 0, 0, Tokens.typography.display.size + 4)
	playValue.TextSize = Tokens.typography.display.size - 4
	FrameKit.outline(playValue, 3)

	-- The ledger: one generous slate row per stat, glyph and caption left, value right.
	local rowHeight = math.floor(tap * 1.5)
	local ledger = Instance.new("Frame")
	ledger.Name = "Ledger"
	ledger.BackgroundTransparency = 1
	ledger.Size = UDim2.fromScale(1, 0)
	ledger.AutomaticSize = Enum.AutomaticSize.Y
	ledger.LayoutOrder = 2
	ledger.ZIndex = z
	local ledgerLayout = Instance.new("UIListLayout")
	ledgerLayout.SortOrder = Enum.SortOrder.LayoutOrder
	ledgerLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	ledgerLayout.Parent = ledger
	ledger.Parent = container
	local values: { [string]: TextLabel } = {}
	for index, spec in ipairs(ROWS) do
		local row = FrameKit.row(ledger, "Row_" .. spec.key, rowHeight, z + 1, { padding = Tokens.spacing.lg })
		row.LayoutOrder = index
		thicken(row)
		local glyph = Icons.build(spec.icon, row, Tokens.icon.lg, { zIndex = z + 2, color = Tokens.color.featherWhite })
		glyph.AnchorPoint = Vector2.new(0, 0.5)
		glyph.Position = UDim2.fromScale(0, 0.5)
		local left = Tokens.icon.lg + Tokens.spacing.md
		local caption = FrameKit.text(row, "Caption", spec.caption, "title", {
			zIndex = z + 2,
			color = Tokens.color.featherWhite,
		})
		caption.Position = UDim2.fromOffset(left, 0)
		caption.Size = UDim2.new(0.5, -left, 1, 0)
		caption.TextSize = Tokens.typography.title.size - 2
		caption.TextYAlignment = Enum.TextYAlignment.Center
		FrameKit.outline(caption, 2.5)
		local value = FrameKit.text(row, "Value", "-", "title", {
			zIndex = z + 2,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Right,
		})
		value.AnchorPoint = Vector2.new(1, 0)
		value.Position = UDim2.fromScale(1, 0)
		value.Size = UDim2.fromScale(0.5, 1)
		value.TextYAlignment = Enum.TextYAlignment.Center
		value.TextWrapped = false
		value.TextTruncate = Enum.TextTruncate.AtEnd
		FrameKit.outline(value, 2.5)
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
	rowsLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	rowsLayout.Parent = rowsFrame

	local selectedBoard = cfg.leaderboards.boards[1]
	local tabsHandle

	local function emptyRow(text: string)
		local empty = FrameKit.row(rowsFrame, "Empty", tap + Tokens.spacing.sm, z, { muted = true })
		local label = FrameKit.text(empty, "Text", text, "label", {
			zIndex = z + 1,
			color = Tokens.color.inkMuted,
			align = Enum.TextXAlignment.Center,
		})
		label.Size = UDim2.fromScale(1, 1)
		FrameKit.outline(label, 2)
	end

	local function renderBoard()
		for _, child in ipairs(rowsFrame:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		local snapshot = deps.leaderboards.snapshot
		if not snapshot then
			emptyRow("Loading...")
			return
		end
		for _, board in ipairs(snapshot.boards) do
			if board.id ~= selectedBoard then
				continue
			end
			if #board.rows == 0 then
				emptyRow("No entries yet")
			end
			for index, row in ipairs(board.rows) do
				local frame = FrameKit.row(rowsFrame, "Row" .. index, tap + Tokens.spacing.sm, z)
				frame.LayoutOrder = index
				thicken(frame)
				local mine = row.userId == player.UserId
				local value = if board.unit == "ms" then (formatTime(row.value) or "--:--") else tostring(row.value)
				local rank = FrameKit.badge(frame, "Rank", "#" .. index, MEDALS[index] or Tokens.color.surfaceAlt, z + 2)
				rank.AnchorPoint = Vector2.new(0, 0.5)
				rank.Position = UDim2.fromScale(0, 0.5)
				local label = FrameKit.text(frame, "Text", row.name, "label", {
					zIndex = z + 1,
					color = if mine then Tokens.color.gold else Tokens.color.featherWhite,
				})
				label.Position = UDim2.fromOffset(tap + Tokens.spacing.sm, 0)
				label.Size = UDim2.new(0.6, -(tap + Tokens.spacing.sm), 1, 0)
				label.TextTruncate = Enum.TextTruncate.AtEnd
				FrameKit.outline(label, 2.5)
				local valueLabel = FrameKit.text(frame, "Value", value, "label", {
					align = Enum.TextXAlignment.Right,
					zIndex = z + 1,
					color = Tokens.color.featherWhite,
				})
				valueLabel.AnchorPoint = Vector2.new(1, 0)
				valueLabel.Position = UDim2.fromScale(1, 0)
				valueLabel.Size = UDim2.fromScale(0.4, 1)
				FrameKit.outline(valueLabel, 2.5)
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
		values.record.Text = formatTime(best.normal) or "NO RECORD"
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
