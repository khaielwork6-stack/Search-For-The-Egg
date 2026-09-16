--!strict
-- Professor Plume's analysis card: his line, the Rainbow Feather count against the next cost, the
-- two clue categories (UNKNOWN or stamped ANALYZED), and one ANALYZE button that is disabled until
-- the trade is affordable and a category is free. The trade itself goes through a confirmation
-- dialog and the caller's `onAnalyze`, so this file never talks to the server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local NestClues = require(Shared.Domain.NestClues)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)
local Dialog = require(script.Parent.Parent.Components.Dialog)
local Depth = require(script.Parent.Parent.Components.Depth)
local Skin = require(script.Parent.Parent.Components.Skin)

local ClueModal = {}

ClueModal.ID = "clues"

local PARCHMENT = Color3.fromRGB(246, 232, 196)
local PARCHMENT_DEEP = Color3.fromRGB(222, 200, 152)
local FOG = Color3.fromRGB(206, 194, 170)
local STAMP = Color3.fromRGB(196, 52, 44)

export type Deps = {
	modals: any,
	round: any,
	audio: any,
	haptics: any,
	accessibility: any,
	config: { [string]: any },
}

export type Options = {
	line: string,
	onAnalyze: (category: string) -> any,
	onClosed: (() -> ())?,
}

local function readState(deps: Deps)
	local round = deps.round.round
	local clues = round and round.clues
	local count = clues and clues.count or 0
	local unlocked = clues and clues.unlocked or {}
	local player = deps.round.player
	return {
		count = count,
		unlocked = unlocked,
		cost = NestClues.nextCost(deps.config, count),
		carried = player and player.carriedRainbow or 0,
		searching = deps.round:phase() == "Searching",
	}
end

function ClueModal.open(deps: Deps, options: Options): boolean
	local opened = deps.modals:open(ClueModal.ID, deps.modals.Priority.Party, true, function(container, api)
		local z = container.ZIndex + 1
		local tap = api.minimumTapTarget
		local motion = deps.accessibility:motionSettings()
		local cleanups: { any } = {}
		local selected: string? = nil

		local list = Instance.new("UIListLayout")
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Padding = UDim.new(0, Tokens.spacing.md)
		list.Parent = container

		-- Plume's line, on a parchment card with his name over it.
		local speech = Instance.new("Frame")
		speech.Name = "Speech"
		speech.LayoutOrder = 1
		speech.Size = UDim2.fromScale(1, 0)
		speech.AutomaticSize = Enum.AutomaticSize.Y
		speech.ZIndex = z
		Depth.panel(speech, PARCHMENT, { radius = Tokens.radius.md })
		local speechPad = Instance.new("UIPadding")
		speechPad.PaddingTop = UDim.new(0, Tokens.spacing.sm)
		speechPad.PaddingBottom = UDim.new(0, Tokens.spacing.sm)
		speechPad.PaddingLeft = UDim.new(0, Tokens.spacing.md)
		speechPad.PaddingRight = UDim.new(0, Tokens.spacing.md)
		speechPad.Parent = speech
		local speechList = Instance.new("UIListLayout")
		speechList.SortOrder = Enum.SortOrder.LayoutOrder
		speechList.Padding = UDim.new(0, Tokens.spacing.xs)
		speechList.Parent = speech
		local who = FrameKit.text(speech, "Who", "PROFESSOR PLUME", "caption", { zIndex = z + 1, color = Tokens.color.inkMuted })
		who.LayoutOrder = 1
		local line = FrameKit.text(
			speech,
			"Line",
			options.line,
			"body",
			{ zIndex = z + 1, color = Tokens.color.inkStrong, wrap = true, autoHeight = true }
		)
		line.LayoutOrder = 2
		line.Size = UDim2.fromScale(1, 0)
		speech.Parent = container

		-- The count against the next cost.
		local countRow = Instance.new("Frame")
		countRow.Name = "Count"
		countRow.LayoutOrder = 2
		countRow.BackgroundTransparency = 1
		countRow.Size = UDim2.new(1, 0, 0, tap)
		countRow.ZIndex = z
		countRow.Parent = container
		local countPill = FrameKit.pill(countRow, "Pill", "", {
			size = UDim2.fromScale(1, 1),
			zIndex = z + 1,
			fill = Tokens.color.creamPill,
			textColor = Tokens.color.inkStrong,
			art = false,
		})
		local countArt = Skin.icon(countPill, "icon.feather", Tokens.icon.md, z + 2)
		if countArt then
			countArt.AnchorPoint = Vector2.new(0, 0.5)
			countArt.Position = UDim2.new(0, Tokens.spacing.md, 0.5, 0)
			countArt.ImageColor3 = Color3.fromHSV(0.8, 0.5, 1)
		end

		-- The two categories side by side.
		local cards = Instance.new("Frame")
		cards.Name = "Cards"
		cards.LayoutOrder = 3
		cards.BackgroundTransparency = 1
		cards.Size = UDim2.new(1, 0, 0, tap * 2.4)
		cards.ZIndex = z
		cards.Parent = container
		local cardViews: { [string]: any } = {}
		for index, category in ipairs(NestClues.CATEGORIES) do
			local tile, face = FrameKit.tile(cards, "Card_" .. category, {
				fill = PARCHMENT,
				deep = PARCHMENT_DEEP,
				zIndex = z + 1,
				radius = Tokens.radius.md,
				size = UDim2.new(0.5, -Tokens.spacing.sm / 2, 1, 0),
			})
			tile.Position = UDim2.fromScale(if index == 1 then 0 else 1, 0)
			tile.AnchorPoint = Vector2.new(if index == 1 then 0 else 1, 0)
			local label = FrameKit.text(face, "Label", NestClues.LABELS[category], "caption", {
				zIndex = z + 3,
				color = Tokens.color.inkMuted,
				align = Enum.TextXAlignment.Center,
			})
			label.Position = UDim2.fromOffset(0, Tokens.spacing.sm)
			local value = FrameKit.text(face, "Value", "UNKNOWN", "heading", {
				zIndex = z + 3,
				color = FOG,
				align = Enum.TextXAlignment.Center,
				wrap = true,
			})
			value.AnchorPoint = Vector2.new(0.5, 0.5)
			value.Position = UDim2.fromScale(0.5, 0.56)
			value.Size = UDim2.new(1, -Tokens.spacing.md, 0, Tokens.typography.heading.size * 2)
			local stamp = FrameKit.badge(face, "Stamp", "ANALYZED", STAMP, z + 4)
			stamp.AnchorPoint = Vector2.new(0.5, 1)
			stamp.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.sm)
			stamp.Rotation = -6
			stamp.Visible = false
			local hint = FrameKit.text(face, "Hint", "", "caption", {
				zIndex = z + 3,
				color = Tokens.color.inkMuted,
				align = Enum.TextXAlignment.Center,
			})
			hint.AnchorPoint = Vector2.new(0.5, 1)
			hint.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.xs)
			-- Selecting: the whole tile is the button.
			local hit = Instance.new("TextButton")
			hit.Name = "Hit"
			hit.Text = ""
			hit.BackgroundTransparency = 1
			hit.Size = UDim2.fromScale(1, 1)
			hit.ZIndex = z + 5
			hit.Parent = tile
			cardViews[category] = { tile = tile, face = face, value = value, stamp = stamp, hint = hint, hit = hit }
		end

		local analyze = Button.build(container, {
			text = "ANALYZE",
			variant = "gem",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.new(1, 0, 0, tap + Tokens.spacing.sm),
			zIndex = z + 1,
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
		})
		analyze.button.LayoutOrder = 4
		table.insert(cleanups, analyze.destroy)

		local function refresh()
			local state = readState(deps)
			local cost = state.cost
			-- Selection: keep the player's pick if it is still free, else the first free category.
			if selected and state.unlocked[selected] then
				selected = nil
			end
			if not selected then
				for _, category in ipairs(NestClues.CATEGORIES) do
					if not state.unlocked[category] then
						selected = category
						break
					end
				end
			end
			if cost then
				countPill.Text = string.format("RAINBOW FEATHERS: %d / %d", state.carried, cost)
				countPill.TextColor3 = if state.carried >= cost then Tokens.color.inkStrong else STAMP
			else
				countPill.Text = "ALL CLUES ANALYZED"
				countPill.TextColor3 = Tokens.color.inkStrong
			end
			for category, view in pairs(cardViews) do
				local entry = state.unlocked[category]
				local isSelected = selected == category and not entry
				if entry then
					view.value.Text = entry.title
					view.value.TextColor3 = Tokens.color.inkStrong
					view.stamp.Visible = true
					view.hint.Text = ""
					view.face.BackgroundColor3 = PARCHMENT
				else
					view.value.Text = "UNKNOWN"
					view.value.TextColor3 = FOG
					view.stamp.Visible = false
					view.hint.Text = if isSelected then "SELECTED" elseif cost then "TAP TO SELECT" else ""
					view.face.BackgroundColor3 = if isSelected then Tokens.color.creamPill else PARCHMENT
				end
				local keyline = Depth.keylineOf(view.tile)
				if keyline then
					keyline.Color = if isSelected then Tokens.color.gold else Tokens.color.outline
					keyline.Thickness = if isSelected then Tokens.stroke.bold else Tokens.depth.keyline
				end
			end
			local canAnalyze = cost ~= nil and selected ~= nil and state.carried >= cost and state.searching
			analyze.setText(if cost then string.format("ANALYZE  -  %d Rainbow Feathers", cost) else "NOTHING LEFT TO ANALYZE")
			analyze.setEnabled(canAnalyze)
		end

		for category, view in pairs(cardViews) do
			table.insert(
				cleanups,
				view.hit.Activated:Connect(function()
					local state = readState(deps)
					if state.unlocked[category] then
						return
					end
					deps.audio:play(Tokens.sound.uiSelect)
					selected = category
					refresh()
				end)
			)
		end

		analyze.button.Activated:Connect(function()
			local state = readState(deps)
			local cost = state.cost
			local category = selected
			if not (cost and category) or state.carried < cost or not state.searching then
				deps.audio:play(Tokens.sound.uiError)
				return
			end
			Dialog.open(deps.modals, {
				id = "clueTrade",
				title = "Nest Clue",
				message = string.format("Trade %d Rainbow Feathers for a Nest Clue?", cost),
				confirmText = "Trade",
				cancelText = "Not yet",
				tone = "info",
				audio = deps.audio,
				accessibility = deps.accessibility,
				config = deps.config,
				onConfirm = function()
					analyze.setPending(true, "ANALYZING")
					local result = options.onAnalyze(category :: string)
					if result and result.ok then
						api.close()
					else
						analyze.setPending(false)
						refresh()
					end
				end,
			})
		end)

		table.insert(cleanups, deps.round.playerChanged:Connect(refresh))
		table.insert(cleanups, deps.round.snapshot:Connect(refresh))
		refresh()
		api.setInitialFocus(analyze.button)
		return function()
			for _, cleanup in ipairs(cleanups) do
				if typeof(cleanup) == "function" then
					cleanup()
				elseif typeof(cleanup) == "RBXScriptConnection" or (type(cleanup) == "table" and cleanup.Disconnect) then
					cleanup:Disconnect()
				end
			end
			if options.onClosed then
				options.onClosed()
			end
		end
	end, "PROFESSOR PLUME", { compact = true })
	return opened == true
end

return ClueModal
