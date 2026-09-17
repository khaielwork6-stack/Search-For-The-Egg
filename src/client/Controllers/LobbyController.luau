--!strict
-- Lobby meta controller: owns the station rail (screen buttons in the owner's art), routes world
-- station prompts and server ModalDirectives to the eight lobby modals, keeps the leaderboard
-- snapshot, feeds the world station hooks (party silhouettes, ledger board), and celebrates
-- server-acknowledged reward grants on the HUD. One blocking modal at a time through ModalController.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Feedback = require(script.Parent.Parent.UI.Feedback)
local AssetManifest = require(Shared.Design.AssetManifest)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local SafeArea = require(script.Parent.Parent.UI.SafeArea)
local LobbyOffer = require(script.Parent.Parent.UI.LobbyOffer)
local UpgradeActions = require(script.Parent.Parent.UI.UpgradeActions)
local Button = require(script.Parent.Parent.UI.Components.Button)
local FrameKit = require(script.Parent.Parent.UI.Components.Frame)
local PartyModal = require(script.Parent.Parent.UI.Modals.PartyModal)
local ClassesModal = require(script.Parent.Parent.UI.Modals.ClassesModal)
local ShopModal = require(script.Parent.Parent.UI.Modals.ShopModal)
local DailyModal = require(script.Parent.Parent.UI.Modals.DailyModal)
local QuestsModal = require(script.Parent.Parent.UI.Modals.QuestsModal)
local CodesModal = require(script.Parent.Parent.UI.Modals.CodesModal)
local InventoryModal = require(script.Parent.Parent.UI.Modals.InventoryModal)
local StatsModal = require(script.Parent.Parent.UI.Modals.StatsModal)
local EventModal = require(script.Parent.Parent.UI.Modals.EventModal)

local LobbyController = {}
LobbyController.__index = LobbyController

export type LobbyController = typeof(setmetatable(
	{} :: {
		_deps: any,
		gui: ScreenGui,
		rail: Frame,
		leaderboards: { snapshot: any?, changed: any, request: () -> () },
		_buttons: { [string]: any },
		_titles: { [string]: string },
		_inRound: boolean,
		_offer: any?,
		_trove: Trove.Trove,
		stats: { opened: number, directives: number, prompts: number, rewards: number },
	},
	LobbyController
))

-- Rail order and copy (original). Image roles resolve through the asset manifest; roles without art
-- render the gold pill with the short label.
-- Permanent side menu: only the three account screens. Everything else opens from the world
-- (NPCs, the portal, the nest, the chest) so the lobby stays the way to find things.
local SIDE_MENU: { { id: string, title: string, short: string, image: string } } = {
	{ id = "quests", title = "Daily Quests", short = "Quests", image = "station.daily.normal" },
	{ id = "stats", title = "Forager Ledger", short = "Stats", image = "station.stats" },
	{ id = "inventory", title = "Tool Rack", short = "Inventory", image = "station.inventory" },
	{ id = "codes", title = "Nest Mailbox", short = "Codes", image = "station.codes" },
}
-- Titles for the modals that open from the world rather than the side menu.
local WORLD_TITLES: { [string]: string } = {
	gems = "Plume's Market",
	party = "Sunlit Henhouse",
	daily = "Daily Nest",
	classes = "Class Forge",
	shop = "Plume's Market",
	event = "Moonlit Chest",
}

function LobbyController.new(deps: any): LobbyController
	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_Lobby"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = Tokens.zIndex.hud + 1
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = deps.parent or Players.LocalPlayer:WaitForChild("PlayerGui")
	local _, scaleCleanup, stage = SafeArea.applyScale(gui, deps.config)

	local self = setmetatable({
		_deps = deps,
		_offer = nil,
		gui = gui,
		rail = nil :: any,
		leaderboards = { snapshot = nil, changed = Signal.new(), request = nil :: any },
		_buttons = {},
		_titles = {},
		_inRound = false,
		_railHidden = false,
		_trove = Trove.new(),
		stats = { opened = 0, directives = 0, prompts = 0, rewards = 0 },
	}, LobbyController)
	self._trove:add(gui)
	self._trove:add(scaleCleanup)
	self.leaderboards.request = function()
		deps.net:request("LeaderboardRequest", nil)
	end

	-- Side menu: a vertical stack of big painted icons on the right edge, no frame around any of
	-- them, a short white stroked name beneath each - the reference's SHOP / BADGES / STATS column.
	local rail = Instance.new("Frame")
	rail.Name = "SideMenu"
	rail.AnchorPoint = Vector2.new(1, 0)
	rail.Position = UDim2.new(1, -Tokens.layout.safeAreaPaddingPx, 0.5, 0) -- layoutRail places it
	rail.Size = UDim2.fromOffset(Tokens.layout.stationButtonPx + Tokens.spacing.md, 0)
	rail.AutomaticSize = Enum.AutomaticSize.Y
	rail.BackgroundTransparency = 1
	rail.ZIndex = Tokens.zIndex.hud + 1
	local railLayout = Instance.new("UIListLayout")
	railLayout.FillDirection = Enum.FillDirection.Vertical
	railLayout.SortOrder = Enum.SortOrder.LayoutOrder
	railLayout.Padding = UDim.new(0, Tokens.spacing.md)
	railLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	railLayout.Parent = rail
	rail.Parent = stage
	self._rail = rail
	self.rail = rail

	local minimumTap = SafeArea.minimumTapTarget(gui, deps.config)
	local size = math.max(minimumTap, Tokens.layout.stationButtonPx)
	for id, title in pairs(WORLD_TITLES) do
		self._titles[id] = title
	end
	local labelHeight = Tokens.typography.label.size + Tokens.spacing.sm
	local slots: { { slot: Frame, button: GuiButton, label: TextLabel } } = {}
	for index, entry in ipairs(SIDE_MENU) do
		self._titles[entry.id] = entry.title
		local image = AssetManifest.image(entry.image .. ".normal") or AssetManifest.image(entry.image)
		-- Each item is a slot holding the tile and the name label so the list spacing stays even.
		local slot = Instance.new("Frame")
		slot.Name = "Slot_" .. entry.id
		slot.BackgroundTransparency = 1
		slot.Size = UDim2.fromOffset(size + Tokens.spacing.md, size + labelHeight)
		slot.LayoutOrder = index
		slot.ZIndex = rail.ZIndex
		slot.Parent = rail
		local handle = Button.build(slot, {
			text = entry.short,
			variant = if image then "gold" else "pill",
			image = image,
			pressedImage = AssetManifest.image(entry.image .. ".pressed"),
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			minimumTapTarget = minimumTap,
			motion = deps.accessibility:motionSettings(),
			size = UDim2.fromOffset(size, size),
			zIndex = rail.ZIndex + 1,
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
			onActivated = function()
				self:open(entry.id)
			end,
		})
		handle.button.AnchorPoint = Vector2.new(0.5, 0)
		handle.button.Position = UDim2.fromScale(0.5, 0)
		handle.button.Name = "Station_" .. entry.id
		if not image then
			handle.button.TextSize = Tokens.typography.caption.size + 1
		end
		local label = FrameKit.text(slot, "Name", string.upper(entry.short), "label", {
			zIndex = rail.ZIndex + 2,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Center,
		})
		label.Font = Tokens.typography.label.font
		label.TextSize = Tokens.typography.label.size
		label.TextScaled = true
		local labelCap = Instance.new("UITextSizeConstraint")
		labelCap.MaxTextSize = Tokens.typography.label.size
		labelCap.MinTextSize = Tokens.typography.minimumBodySize
		labelCap.Parent = label
		label.AnchorPoint = Vector2.new(0.5, 1)
		label.Position = UDim2.fromScale(0.5, 1)
		-- Wider than the slot: the stroked name may overhang the tile (INVENTORY on a phone tile).
		label.Size = UDim2.fromOffset(108, labelHeight)
		FrameKit.outline(label, 3)
		self._buttons[entry.id] = handle
		self._trove:add(handle.destroy)
		table.insert(slots, { slot = slot, button = handle.button, label = label })
	end
	-- The column shrinks with the stage: four 84 px tiles overrun a landscape phone, so the tile
	-- size comes from the height on offer (pre-scale), never below the tap minimum.
	local function layoutRail()
		local available = stage.AbsoluteSize.Y / math.max(0.1, SafeArea.scaleOf(stage))
		local phone = SafeArea.classOf(stage) == "phone"
		local gap = if phone then Tokens.spacing.sm else Tokens.spacing.md
		local nameHeight = if phone then Tokens.typography.caption.size + Tokens.spacing.xs else labelHeight
		railLayout.Padding = UDim.new(0, gap)
		-- The strip under the settings gear, above the bottom safe padding.
		local gearBottom = Tokens.layout.safeAreaPaddingPx + Tokens.layout.minimumTapTargetPx + Tokens.spacing.md
		local usable = available - gearBottom - Tokens.layout.safeAreaPaddingPx
		local count = math.max(1, #slots)
		local tile = math.clamp(math.floor((usable - gap * (count - 1)) / count - nameHeight), math.max(minimumTap, 52), size)
		-- A landscape phone has no height for four tiles with names beneath: the names move to the
		-- left of the tiles and each slot is just one tile tall.
		local beside = phone and count * (tile + nameHeight) + gap * (count - 1) > usable
		local nameWidth = 108
		rail.Size = UDim2.fromOffset(tile + Tokens.spacing.md + (if beside then nameWidth + Tokens.spacing.sm else 0), 0)
		for _, item in ipairs(slots) do
			item.button.Size = UDim2.fromOffset(tile, tile)
			if beside then
				item.slot.Size = UDim2.fromOffset(tile + Tokens.spacing.md + nameWidth + Tokens.spacing.sm, tile)
				item.button.AnchorPoint = Vector2.new(1, 0)
				item.button.Position = UDim2.new(1, -Tokens.spacing.md / 2, 0, 0)
				item.label.AnchorPoint = Vector2.new(1, 0.5)
				item.label.Position = UDim2.new(1, -(tile + Tokens.spacing.md), 0.5, 0)
				item.label.Size = UDim2.fromOffset(nameWidth, nameHeight)
				item.label.TextXAlignment = Enum.TextXAlignment.Right
			else
				item.slot.Size = UDim2.fromOffset(tile + Tokens.spacing.md, tile + nameHeight)
				item.button.AnchorPoint = Vector2.new(0.5, 0)
				item.button.Position = UDim2.fromScale(0.5, 0)
				item.label.AnchorPoint = Vector2.new(0.5, 1)
				item.label.Position = UDim2.fromScale(0.5, 1)
				item.label.Size = UDim2.fromOffset(nameWidth, nameHeight)
				item.label.TextXAlignment = Enum.TextXAlignment.Center
			end
		end
		local railHeight = count * (tile + (if beside then 0 else nameHeight)) + gap * (count - 1)
		-- Centred when there is room, otherwise pinned into the strip.
		local top = math.clamp(
			available / 2 - railHeight / 2 + gearBottom / 2,
			gearBottom,
			math.max(gearBottom, available - Tokens.layout.safeAreaPaddingPx - railHeight)
		)
		rail.Position = UDim2.new(1, -Tokens.layout.safeAreaPaddingPx, 0, math.floor(top))
	end
	self._trove:add(stage:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutRail))
	layoutRail()

	-- World prompts and server directives open the same modals.
	self._trove:add(deps.interaction.stationRequested:Connect(function(stationId)
		self.stats.prompts += 1
		self:open(stationId)
	end))
	self._trove:add(deps.net:on("ModalDirective", function(payload)
		self.stats.directives += 1
		if payload.action == "open" then
			self:open(payload.modalId)
		else
			deps.modals:close(payload.modalId)
		end
	end))
	self._trove:add(deps.net:on("LeaderboardProjection", function(payload)
		self.leaderboards.snapshot = payload
		self.leaderboards.changed:Fire(payload)
		if deps.lobbyShell and deps.lobbyShell.setLeaderboard then
			deps.lobbyShell:setLeaderboard(payload)
		end
	end))
	self._trove:add(deps.net:on("RewardGranted", function(grant)
		self.stats.rewards += 1
		-- Currency chips already re-render from the acknowledged projection; this is the celebration.
		-- Silent: the claim that caused the grant (Daily, Quests, Codes) already has its own sound, and
		-- a tick here layered a second one onto the same moment.
		deps.hud:celebrateCurrency("gems", grant.gems or 0)
	end))
	-- Rail state: the station whose modal is open lifts and holds its pressed art; the Daily station
	-- breathes only while a reward is ready to claim.
	local function refreshRail()
		local open = deps.modals:topId()
		for id, handle in pairs(self._buttons) do
			handle.setSelected(open == id)
		end
	end
	self._trove:add(deps.modals.changed:Connect(refreshRail))
	refreshRail()
	-- Stepping onto an empty nest pad opens the party screen.
	self._trove:add(deps.net:on("PadPrompt", function()
		if not self._inRound and deps.modals:openCount() == 0 and deps.party.party == nil then
			self:open("party")
		end
	end))
	-- The banner narrates the party: waiting count, then the countdown. The countdown is silent after
	-- its start chime (owner 17 Sep 2026: the per-second tick is gone).
	local lastPhase: string? = nil
	local lastMembers = 0
	local lastTick = -1
	local countdownThread: thread? = nil
	local function stopCountdown()
		if countdownThread then
			task.cancel(countdownThread)
			countdownThread = nil
		end
	end
	self._trove:add(deps.party.changed:Connect(function(party)
		if deps.lobbyShell and deps.lobbyShell.setPartySilhouettes then
			deps.lobbyShell:setPartySilhouettes(party)
		end
		if self._inRound then
			return
		end
		if not party then
			stopCountdown()
			if lastPhase then
				deps.hud:setObjective("Step onto a nest pad", "Create a party there and set off together")
			end
			lastPhase, lastMembers = nil, 0
			return
		end
		local members = #party.members
		if members > lastMembers and lastMembers > 0 then
			deps.audio:play(Tokens.sound.uiConfirm)
		elseif members < lastMembers then
			deps.audio:play(Tokens.sound.uiCancel)
		end
		lastMembers = members
		if party.phase == "Countdown" then
			if lastPhase ~= "Countdown" then
				deps.audio:play(Tokens.sound.partyReady)
				stopCountdown()
				lastTick = -1
				countdownThread = task.spawn(function()
					while true do
						local remaining = deps.party:countdownRemaining()
						if not remaining then
							break
						end
						local whole = math.max(1, math.ceil(remaining))
						if whole ~= lastTick then
							lastTick = whole
							deps.hud:setObjective(string.format("Setting off in %d", whole), "Stay on the pad")
						end
						task.wait(0.1)
					end
				end)
			end
		else
			stopCountdown()
			local max = party.maxMembers or deps.config.project.maxPartyPlayers
			if party.phase == "Reserving" or party.phase == "Teleporting" then
				deps.hud:setObjective("Good luck!", "Off to the henhouse")
			elseif members >= max then
				deps.hud:setObjective("Party full", "Setting off in a moment")
			else
				deps.hud:setObjective(string.format("Party %d / %d", members, max), string.format("Waiting for %d more", max - members))
			end
		end
		lastPhase = party.phase
	end))
	self._trove:add(function()
		stopCountdown()
	end)
	-- The permanent 2x Gems offer: lobby only, and never prompted to someone who already owns it.
	local offerConfig = deps.config.lobby.offer
	local offer = LobbyOffer.create(stage, {
		config = deps.config,
		motion = function()
			return deps.accessibility:motionSettings()
		end,
		onActivated = function()
			UpgradeActions.promptPurchase(
				{ net = deps.net, audio = deps.audio, toasts = deps.hud.toasts },
				offerConfig.productKey,
				"2x Gems"
			)
		end,
	})
	if offer then
		self._offer = offer
		self._trove:add(offer)
		local function applyOwnership()
			local projection = deps.profile.projection
			local entitlements = projection and projection.entitlements
			offer.setOwned(entitlements ~= nil and entitlements[offerConfig.productKey] == true)
		end
		applyOwnership()
		self._trove:add(deps.profile.changed:Connect(applyOwnership))
	end

	self._trove:add(deps.round.phaseChanged:Connect(function(phase)
		local inRound = phase ~= nil and phase ~= "Returning" and phase ~= "Abandoned"
		self._inRound = inRound
		rail.Visible = not inRound and not self._railHidden
		if offer then
			offer.setVisible(not inRound)
		end
		if inRound then
			for _, id in ipairs({ "party", "classes", "shop", "daily", "quests", "codes", "inventory", "stats", "event" }) do
				deps.modals:close(id)
			end
		end
	end))
	self._trove:add(deps.input.actionBegan:Connect(function(action)
		if action == "Menu" and not self._inRound and deps.modals:openCount() == 0 then
			self:open("party")
		end
	end))
	return self
end

-- Opens a lobby modal by station id. Returns whether it opened (false when blocked or in a round).
function LobbyController.open(self: LobbyController, id: string): boolean
	local deps = self._deps
	if self._inRound then
		Feedback.deny("lobby:in_round", "Finish the search first", { tone = "info", silent = true })
		return false
	end
	if deps.modals:isOpen(id) then
		return true
	end
	local minimumTap = SafeArea.minimumTapTarget(deps.modals.gui, deps.config)
	local common = {
		net = deps.net,
		profile = deps.profile,
		party = deps.party,
		audio = deps.audio,
		haptics = deps.haptics,
		accessibility = deps.accessibility,
		config = deps.config,
		minimumTapTarget = minimumTap,
		toasts = deps.hud.toasts,
		leaderboards = self.leaderboards,
		modals = deps.modals,
		hud = deps.hud,
		quality = deps.quality,
		entitlements = function()
			local projection = deps.profile.projection
			return projection and projection.entitlements or {}
		end,
		openGemShop = function()
			self:open("gems")
		end,
	}
	local builders: { [string]: any } = {
		party = PartyModal.build,
		gems = ShopModal.buildGems,
		classes = ClassesModal.build,
		shop = ShopModal.build,
		daily = DailyModal.build,
		quests = QuestsModal.build,
		codes = CodesModal.build,
		inventory = InventoryModal.build,
		stats = StatsModal.build,
		event = EventModal.build,
	}
	local builder = builders[id]
	if not builder then
		return false
	end
	local priority = if id == "party" then deps.modals.Priority.Party else deps.modals.Priority.Shop
	local opened = deps.modals:open(
		id,
		priority,
		true,
		function(container, api)
			return builder(container, api, common)
		end,
		self._titles[id] or id,
		{
			wide = id == "classes" or id == "stats" or id == "party" or id == "gems" or id == "shop",
			hero = id == "daily",
			icon = "header." .. (if id == "gems" then "shop" else id),
		}
	)
	if opened then
		self.stats.opened += 1
		local handle = self._buttons[id]
		if handle then
			handle.punch()
		end
	end
	return opened
end

-- The side menu steps aside while a modal owns the screen (it used to show through the frame).
function LobbyController.setRailHidden(self: LobbyController, hidden: boolean)
	self._railHidden = hidden
	local rail = self._rail
	if rail then
		rail.Visible = not self._inRound and not hidden
	end
end

function LobbyController.isOpen(self: LobbyController, id: string): boolean
	return self._deps.modals:isOpen(id)
end

function LobbyController.stationIds(): { string }
	return table.clone(ChapterLayout.lobby.stationOrder)
end

function LobbyController.railButton(self: LobbyController, id: string): TextButton?
	local handle = self._buttons[id]
	return handle and handle.button or nil
end

function LobbyController.destroy(self: LobbyController)
	self.leaderboards.changed:Destroy()
	self._trove:destroy()
end

return LobbyController
