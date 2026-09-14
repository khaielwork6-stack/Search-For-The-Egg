--!strict
-- Forager Ledger modal: personal stats (playtime, equipped class, best times, wins, feathers, Eggs)
-- from the profile projection and the leaderboards (bounded refresh) from LeaderboardProjection,
-- one board at a time behind pill tabs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Tabs = require(script.Parent.Parent.Components.Tabs)

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

local function formatTime(ms: number?): string
	if not ms then
		return "--:--"
	end
	local totalSeconds = math.floor(ms / 1000)
	return string.format("%02d:%02d.%02d", math.floor(totalSeconds / 60), totalSeconds % 60, math.floor((ms % 1000) / 10))
end

function StatsModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1

	FrameKit.heading(container, "PersonalHeader", "Your ledger", z).LayoutOrder = 1
	local personal = Instance.new("Frame")
	personal.Name = "Personal"
	personal.BackgroundTransparency = 1
	personal.Size = UDim2.fromScale(1, 0)
	personal.AutomaticSize = Enum.AutomaticSize.Y
	personal.LayoutOrder = 2
	personal.ZIndex = z
	local personalLayout = Instance.new("UIGridLayout")
	personalLayout.CellSize = UDim2.new(0.5, -Tokens.spacing.xs, 0, Tokens.typography.body.size * 2 + Tokens.spacing.sm)
	personalLayout.CellPadding = UDim2.fromOffset(Tokens.spacing.xs, Tokens.spacing.xs)
	personalLayout.SortOrder = Enum.SortOrder.LayoutOrder
	personalLayout.Parent = personal
	personal.Parent = container
	local statLabels: { [string]: TextLabel } = {}
	for index, key in ipairs({ "playtime", "class", "wins", "eggs", "feathers", "best1n", "best1h", "rounds" }) do
		local cell = FrameKit.row(personal, "Stat_" .. key, Tokens.typography.body.size * 2 + Tokens.spacing.sm, z)
		cell.LayoutOrder = index
		local label = FrameKit.text(cell, "Value", "", "body", { zIndex = z + 1, color = Tokens.color.inkStrong })
		label.Size = UDim2.fromScale(1, 1)
		label.RichText = true
		statLabels[key] = label
	end

	FrameKit.heading(container, "BoardHeader", "Leaderboards", z).LayoutOrder = 3
	local age = FrameKit.text(container, "Age", "", "caption", { zIndex = z, color = Tokens.color.inkMuted })
	age.LayoutOrder = 5
	local rowsFrame = Instance.new("Frame")
	rowsFrame.Name = "Rows"
	rowsFrame.BackgroundTransparency = 1
	rowsFrame.Size = UDim2.fromScale(1, 0)
	rowsFrame.AutomaticSize = Enum.AutomaticSize.Y
	rowsFrame.LayoutOrder = 6
	rowsFrame.ZIndex = z
	local rowsLayout = Instance.new("UIListLayout")
	rowsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowsLayout.Padding = UDim.new(0, Tokens.spacing.xs)
	rowsLayout.Parent = rowsFrame
	rowsFrame.Parent = container

	local selectedBoard = cfg.leaderboards.boards[1]
	local tabsHandle

	local function renderBoard()
		for _, child in ipairs(rowsFrame:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		local snapshot = deps.leaderboards.snapshot
		if not snapshot then
			age.Text = "Fetching the ledger..."
			return
		end
		age.Text = if snapshot.ageSeconds
			then string.format("Refreshed %ds ago  -  updates every %ds", snapshot.ageSeconds, snapshot.refreshSeconds)
			else "Waiting for the first refresh"
		for _, board in ipairs(snapshot.boards) do
			if board.id ~= selectedBoard then
				continue
			end
			if #board.rows == 0 then
				local empty = FrameKit.row(rowsFrame, "Empty", tap, z)
				FrameKit.text(
					empty,
					"Text",
					"No entries yet - be the first forager on this board",
					"caption",
					{ zIndex = z + 1, color = Tokens.color.inkMuted }
				).Size =
					UDim2.fromScale(1, 1)
			end
			for index, row in ipairs(board.rows) do
				local frame = FrameKit.row(rowsFrame, "Row" .. index, tap, z)
				frame.LayoutOrder = index
				local mine = row.userId == Players.LocalPlayer.UserId
				local value = if board.unit == "ms" then formatTime(row.value) else tostring(row.value)
				local label = FrameKit.text(
					frame,
					"Text",
					string.format("%d.  %s", index, row.name),
					"body",
					{ zIndex = z + 1, color = if mine then Tokens.color.goldDeep else Tokens.color.inkStrong }
				)
				label.Size = UDim2.fromScale(0.7, 1)
				local valueLabel = FrameKit.text(
					frame,
					"Value",
					value,
					"numeral",
					{ align = Enum.TextXAlignment.Right, zIndex = z + 1, color = Tokens.color.goldDeep }
				)
				valueLabel.AnchorPoint = Vector2.new(1, 0)
				valueLabel.Position = UDim2.fromScale(1, 0)
				valueLabel.Size = UDim2.fromScale(0.3, 1)
				valueLabel.TextSize = Tokens.typography.body.size
			end
		end
	end

	local items = {}
	for _, boardId in ipairs(cfg.leaderboards.boards) do
		local labelText = boardId
		local snapshot = deps.leaderboards.snapshot
		if snapshot then
			for _, board in ipairs(snapshot.boards) do
				if board.id == boardId then
					labelText = board.label
				end
			end
		end
		table.insert(items, { id = boardId, label = labelText })
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
	tabsHandle.frame.LayoutOrder = 4
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
		local extra = ""
		if #projection.classes.equipped > 1 then
			for _, entry in ipairs(cfg.classes.weights) do
				if entry.id == projection.classes.equipped[2] then
					extra = " + " .. entry.displayName
				end
			end
		end
		local muted = string.format(
			"rgb(%d,%d,%d)",
			math.floor(Tokens.color.inkMuted.R * 255),
			math.floor(Tokens.color.inkMuted.G * 255),
			math.floor(Tokens.color.inkMuted.B * 255)
		)
		local function tile(caption: string, value: string): string
			return string.format('<font color="%s" size="%d">%s</font>\n<b>%s</b>', muted, Tokens.typography.caption.size, caption, value)
		end
		statLabels.playtime.Text = tile("Time in the nest", playtime(projection.stats.playtimeSeconds))
		statLabels.class.Text = tile("Class", className .. extra)
		statLabels.wins.Text = tile("Eggs won", tostring(projection.progression.totalWins))
		statLabels.eggs.Text = tile("Eggs found first", tostring(projection.stats.eggsFound))
		statLabels.feathers.Text = tile("Feathers gathered", tostring(projection.stats.feathersCollected))
		local best = projection.progression.bestTimeMs.chapter1 or {}
		statLabels.best1n.Text = tile("Best Henhouse (Normal)", formatTime(best.normal))
		statLabels.best1h.Text = tile("Best Henhouse (Hard)", formatTime(best.hard))
		statLabels.rounds.Text = tile("Searches finished", tostring(projection.stats.roundsCompleted))
	end

	renderPersonal()
	renderBoard()
	deps.leaderboards.request()
	table.insert(cleanups, deps.profile.changed:Connect(renderPersonal))
	table.insert(
		cleanups,
		deps.leaderboards.changed:Connect(function()
			local snapshot = deps.leaderboards.snapshot
			if snapshot then
				for _, board in ipairs(snapshot.boards) do
					tabsHandle.setLabel(board.id, board.label)
				end
			end
			renderBoard()
		end)
	)
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
