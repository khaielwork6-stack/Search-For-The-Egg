--!strict
-- Party modal: destination cards (chapters x difficulties with lock / availability states from the
-- server projection), the current party (members, leader, countdown), leader actions (start,
-- cancel, destination), member actions (leave), and the open party list (join). A "Set off alone"
-- shortcut keeps the first-run path to one tap. Every action is a validated request; the modal only
-- re-renders from projections.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)

local PartyModal = {}

export type Deps = {
	net: any,
	party: any,
	profile: any,
	audio: any,
	haptics: any,
	accessibility: any,
	config: { [string]: any },
	minimumTapTarget: number,
	toasts: any,
}

local DIFFICULTIES = { "normal", "hard" }
local DIFFICULTY_LABEL = { normal = "Normal", hard = "Hard" }

local function unlockedFor(profile: any, chapter: string, difficulty: string): boolean
	local projection = profile.projection
	if not projection then
		return false
	end
	local difficulties = projection.progression.unlockedDifficulties[chapter]
	return difficulties ~= nil and difficulties[difficulty] == true
end

function PartyModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local selected = { chapter = "chapter1", difficulty = "normal" }
	local pending = false

	local function toast(text: string, tone: string?)
		deps.toasts:push(text, tone or "warning")
	end

	local function failureCopy(result: any): string
		local message = result.message or result.code
		if message == "chapter_unavailable" then
			return "That chapter opens in a later update"
		elseif message == "destination_locked" then
			return "Someone in the party has not unlocked that yet"
		elseif message == "party_full" then
			return "That party is full"
		elseif message == "party_not_found" then
			return "That party has already set off"
		elseif message == "not_leader" then
			return "Only the party leader can do that"
		elseif message == "already_in_party" then
			return "Leave your current party first"
		elseif message == "not_ready" then
			return "The party is not ready to start"
		elseif result.code == "rate_limited" then
			return "One moment..."
		end
		return "Party action unavailable"
	end

	local function send(fn: () -> any, successSound: string?)
		if pending then
			return
		end
		pending = true
		local result = fn()
		pending = false
		if result.ok then
			deps.audio:play(successSound or Tokens.sound.uiConfirm)
			deps.haptics:pulse(0.3, 0.06)
		else
			deps.audio:play(Tokens.sound.uiError)
			toast(failureCopy(result))
		end
		return result
	end

	-- Destination section ----------------------------------------------------------------------
	FrameKit.text(container, "DestinationHeader", "Where to?", "heading", { zIndex = z }).LayoutOrder = 1
	local grid = Instance.new("Frame")
	grid.Name = "Destinations"
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.fromScale(1, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.LayoutOrder = 2
	grid.ZIndex = z
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.new(0.5, -Tokens.spacing.xs, 0, tap + Tokens.spacing.xl)
	gridLayout.CellPadding = UDim2.fromOffset(Tokens.spacing.sm, Tokens.spacing.sm)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid
	grid.Parent = container

	local cards: { [string]: { handle: any, sub: TextLabel } } = {}
	local order = 0
	for _, chapterKey in ipairs({ "chapter1", "chapter2" }) do
		local chapter = cfg.chapters[chapterKey]
		for _, difficulty in ipairs(DIFFICULTIES) do
			order += 1
			local key = chapterKey .. ":" .. difficulty
			local handle = Button.build(grid, {
				text = chapter.displayName .. "\n" .. DIFFICULTY_LABEL[difficulty],
				variant = "ghost",
				minimumTapTarget = tap,
				motion = motion,
				size = UDim2.new(0.5, 0, 0, tap + Tokens.spacing.xl),
				zIndex = z + 1,
				onActivated = function()
					selected.chapter = chapterKey
					selected.difficulty = difficulty
					if deps.party.party and deps.party:isLeader() then
						send(function()
							return deps.party:setDestination(chapterKey, difficulty)
						end)
					end
					-- Re-render is driven by projections; update selection styling immediately.
					for cardKey, card in pairs(cards) do
						card.handle.setSelected(cardKey == key)
					end
				end,
			})
			handle.button.LayoutOrder = order
			handle.button.TextWrapped = true
			handle.button.TextSize = Tokens.typography.body.size
			local sub = FrameKit.text(
				handle.button,
				"Sub",
				"",
				"caption",
				{ align = Enum.TextXAlignment.Center, zIndex = z + 2, color = Tokens.color.goldDeep }
			)
			sub.AnchorPoint = Vector2.new(0.5, 1)
			sub.Position = UDim2.new(0.5, 0, 1, -2)
			sub.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 2)
			cards[key] = { handle = handle, sub = sub }
			table.insert(cleanups, handle.destroy)
		end
	end

	-- Party section ----------------------------------------------------------------------------
	FrameKit.text(container, "PartyHeader", "Your party", "heading", { zIndex = z }).LayoutOrder = 3
	local members = Instance.new("Frame")
	members.Name = "Members"
	members.BackgroundTransparency = 1
	members.Size = UDim2.fromScale(1, 0)
	members.AutomaticSize = Enum.AutomaticSize.Y
	members.LayoutOrder = 4
	members.ZIndex = z
	local membersLayout = Instance.new("UIListLayout")
	membersLayout.SortOrder = Enum.SortOrder.LayoutOrder
	membersLayout.Padding = UDim.new(0, Tokens.spacing.xs)
	membersLayout.Parent = members
	members.Parent = container
	local status = FrameKit.text(container, "Status", "", "body", { zIndex = z, color = Tokens.color.goldDeep })
	status.LayoutOrder = 5

	local actions = Instance.new("Frame")
	actions.Name = "Actions"
	actions.BackgroundTransparency = 1
	actions.Size = UDim2.new(1, 0, 0, tap)
	actions.AutomaticSize = Enum.AutomaticSize.Y
	actions.LayoutOrder = 6
	actions.ZIndex = z
	local actionsLayout = Instance.new("UIListLayout")
	actionsLayout.FillDirection = Enum.FillDirection.Horizontal
	actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	actionsLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	actionsLayout.Wraps = true
	actionsLayout.Parent = actions
	actions.Parent = container

	local soloHandle = Button.build(actions, {
		text = "Set off alone",
		variant = "gold",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(180, tap),
		zIndex = z + 1,
		onActivated = function()
			local created = send(function()
				return deps.party:create(selected.chapter, selected.difficulty)
			end)
			if created and created.ok then
				send(function()
					return deps.party:start()
				end, Tokens.sound.partyReady)
			end
		end,
	})
	soloHandle.button.LayoutOrder = 1
	soloHandle.button.Name = "SoloButton"
	local createHandle = Button.build(actions, {
		text = "Open a party",
		variant = "secondary",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(160, tap),
		zIndex = z + 1,
		onActivated = function()
			send(function()
				return deps.party:create(selected.chapter, selected.difficulty)
			end)
		end,
	})
	createHandle.button.LayoutOrder = 2
	local startHandle = Button.build(actions, {
		text = "Start",
		variant = "gold",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(140, tap),
		zIndex = z + 1,
		onActivated = function()
			send(function()
				return deps.party:start()
			end, Tokens.sound.partyReady)
		end,
	})
	startHandle.button.LayoutOrder = 3
	startHandle.button.Name = "StartButton"
	local cancelHandle = Button.build(actions, {
		text = "Cancel countdown",
		variant = "danger",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(190, tap),
		zIndex = z + 1,
		onActivated = function()
			send(function()
				return deps.party:cancel()
			end, Tokens.sound.uiCancel)
		end,
	})
	cancelHandle.button.LayoutOrder = 4
	local leaveHandle = Button.build(actions, {
		text = "Leave party",
		variant = "ghost",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(150, tap),
		zIndex = z + 1,
		onActivated = function()
			send(function()
				return deps.party:leave()
			end, Tokens.sound.uiCancel)
		end,
	})
	leaveHandle.button.LayoutOrder = 5
	for _, handle in ipairs({ soloHandle, createHandle, startHandle, cancelHandle, leaveHandle }) do
		table.insert(cleanups, handle.destroy)
	end
	api.setInitialFocus(soloHandle.button)

	-- Open parties -----------------------------------------------------------------------------
	FrameKit.text(container, "ListHeader", "Parties forming", "heading", { zIndex = z }).LayoutOrder = 7
	local listFrame = Instance.new("Frame")
	listFrame.Name = "OpenParties"
	listFrame.BackgroundTransparency = 1
	listFrame.Size = UDim2.fromScale(1, 0)
	listFrame.AutomaticSize = Enum.AutomaticSize.Y
	listFrame.LayoutOrder = 8
	listFrame.ZIndex = z
	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, Tokens.spacing.xs)
	listLayout.Parent = listFrame
	listFrame.Parent = container
	local emptyList = FrameKit.text(
		container,
		"EmptyList",
		"No open parties right now. Open one and friends can join from here.",
		"caption",
		{ zIndex = z, color = Tokens.color.inkMuted }
	)
	emptyList.LayoutOrder = 9

	local rowHandles: { any } = {}
	local function renderList()
		for _, handle in ipairs(rowHandles) do
			handle.destroy()
		end
		table.clear(rowHandles)
		for _, child in ipairs(listFrame:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		local mine = deps.party.party
		local shown = 0
		for index, entry in ipairs(deps.party.list or {}) do
			if mine and mine.partyId == entry.partyId then
				continue
			end
			shown += 1
			local row = FrameKit.row(listFrame, "Party" .. index, tap + Tokens.spacing.sm, z)
			row.LayoutOrder = index
			local text = FrameKit.text(
				row,
				"Text",
				string.format(
					"%s's party  -  %s %s  -  %d/%d",
					entry.leaderName or "Forager",
					cfg.chapters[entry.chapter] and cfg.chapters[entry.chapter].displayName or entry.chapter,
					DIFFICULTY_LABEL[entry.difficulty] or entry.difficulty,
					#entry.members,
					entry.maxMembers
				),
				"body",
				{ zIndex = z + 1 }
			)
			text.Size = UDim2.new(1, -(tap * 2 + Tokens.spacing.md), 1, 0)
			local joinHandle = Button.build(row, {
				text = "Join",
				variant = "gold",
				minimumTapTarget = tap,
				motion = motion,
				size = UDim2.fromOffset(tap * 2, tap),
				zIndex = z + 1,
				onActivated = function()
					send(function()
						return deps.party:join(entry.partyId)
					end)
				end,
			})
			joinHandle.button.AnchorPoint = Vector2.new(1, 0.5)
			joinHandle.button.Position = UDim2.fromScale(1, 0.5)
			table.insert(rowHandles, joinHandle)
		end
		emptyList.Visible = shown == 0
	end

	local function render()
		local party = deps.party.party
		local isLeader = deps.party:isLeader()
		local projection = deps.profile.projection
		for key, card in pairs(cards) do
			local chapterKey, difficulty = string.match(key, "^(%w+):(%w+)$")
			local chapter = cfg.chapters[chapterKey]
			local available = chapter.availableDifficulties and chapter.availableDifficulties[difficulty] == true
			local unlocked = unlockedFor(deps.profile, chapterKey, difficulty)
			local active = party ~= nil and party.chapter == chapterKey and party.difficulty == difficulty
			local isSelected = active or (party == nil and selected.chapter == chapterKey and selected.difficulty == difficulty)
			card.handle.setEnabled(available and unlocked and (party == nil or isLeader))
			card.sub.Text = if not available
				then "Opens in a later update"
				elseif not unlocked then "Locked - win Sunlit Henhouse"
				else (if active then "Chosen" else "")
			card.handle.setSelected(isSelected)
		end
		for _, child in ipairs(members:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		if party then
			for index, memberId in ipairs(party.members) do
				local row = FrameKit.row(members, "Member" .. index, tap, z)
				row.LayoutOrder = index
				local name = party.memberNames and party.memberNames[tostring(memberId)] or ("Forager " .. tostring(memberId))
				local locked = table.find(party.lockedUserIds or {}, memberId) ~= nil
				local suffix = (if memberId == party.leaderUserId then "  -  leader" else "")
					.. (if locked then "  -  needs the unlock" else "")
				local label = FrameKit.text(row, "Name", name .. suffix, "body", {
					zIndex = z + 1,
					color = if memberId == Players.LocalPlayer.UserId then Tokens.color.goldDeep else Tokens.color.inkStrong,
				})
				label.Size = UDim2.fromScale(1, 1)
			end
			for index = #party.members + 1, party.maxMembers do
				local row = FrameKit.row(members, "Empty" .. index, tap, z)
				row.LayoutOrder = index
				row.BackgroundTransparency = 0.7
				FrameKit.text(row, "Name", "Open seat", "caption", { zIndex = z + 1, color = Tokens.color.inkMuted }).Size =
					UDim2.fromScale(1, 1)
			end
			local phase = party.phase
			if phase == "Countdown" then
				status.Text = "Setting off..."
			elseif phase == "Reserving" or phase == "Teleporting" then
				status.Text = "Finding a henhouse..."
			elseif not party.valid then
				status.Text = if party.invalidReason == "destination_locked"
					then "Waiting on an unlock for the chosen destination"
					else "Choose an available destination"
			elseif isLeader then
				status.Text = "Ready when you are, leader"
			else
				status.Text = "Waiting for the leader to start"
			end
			soloHandle.button.Visible = false
			createHandle.button.Visible = false
			startHandle.button.Visible = isLeader and phase ~= "Countdown" and phase ~= "Reserving" and phase ~= "Teleporting"
			startHandle.setEnabled(party.valid == true)
			cancelHandle.button.Visible = isLeader and phase == "Countdown"
			leaveHandle.button.Visible = phase ~= "Reserving" and phase ~= "Teleporting"
		else
			status.Text = "Set off alone, open a party for friends, or join one below"
			soloHandle.button.Visible = true
			createHandle.button.Visible = true
			startHandle.button.Visible = false
			cancelHandle.button.Visible = false
			leaveHandle.button.Visible = false
			local _ = projection
		end
		renderList()
	end

	render()
	table.insert(cleanups, deps.party.changed:Connect(render))
	table.insert(cleanups, deps.party.listChanged:Connect(renderList))
	table.insert(cleanups, deps.profile.changed:Connect(render))
	-- Countdown text ticks from the projection deadline; the server owns the deadline.
	table.insert(
		cleanups,
		RunService.RenderStepped:Connect(function()
			local remaining = deps.party:countdownRemaining()
			if remaining then
				status.Text = string.format("Setting off in %d...", math.ceil(remaining))
			end
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
		for _, handle in ipairs(rowHandles) do
			handle.destroy()
		end
		deps.audio:play(Tokens.sound.uiClose)
	end
end

return PartyModal
