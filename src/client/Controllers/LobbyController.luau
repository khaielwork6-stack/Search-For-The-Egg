--!strict
-- Lobby meta controller: owns the station rail (screen buttons in the owner's art), routes world
-- station prompts and server ModalDirectives to the eight lobby modals, keeps the leaderboard
-- snapshot, feeds the world station hooks (party silhouettes, ledger board), and celebrates
-- server-acknowledged reward grants on the HUD. One blocking modal at a time through ModalController.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local AssetManifest = require(Shared.Design.AssetManifest)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local SafeArea = require(script.Parent.Parent.UI.SafeArea)
local Button = require(script.Parent.Parent.UI.Components.Button)
local FrameKit = require(script.Parent.Parent.UI.Components.Frame)
local PartyModal = require(script.Parent.Parent.UI.Modals.PartyModal)
local ClassesModal = require(script.Parent.Parent.UI.Modals.ClassesModal)
local ShopModal = require(script.Parent.Parent.UI.Modals.ShopModal)
local DailyModal = require(script.Parent.Parent.UI.Modals.DailyModal)
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
	{ id = "stats", title = "Forager Ledger", short = "Stats", image = "station.stats" },
	{ id = "inventory", title = "Tool Rack", short = "Inventory", image = "station.inventory" },
	{ id = "codes", title = "Nest Mailbox", short = "Codes", image = "station.codes" },
}
-- Titles for the modals that open from the world rather than the side menu.
local WORLD_TITLES: { [string]: string } = {
	party = "Sunlit Henhouse",
	daily = "Daily Nest",
	classes = "Class Cards",
	shop = "Perk Shop",
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
		gui = gui,
		rail = nil :: any,
		leaderboards = { snapshot = nil, changed = Signal.new(), request = nil :: any },
		_buttons = {},
		_titles = {},
		_inRound = false,
		_trove = Trove.new(),
		stats = { opened = 0, directives = 0, prompts = 0, rewards = 0 },
	}, LobbyController)
	self._trove:add(gui)
	self._trove:add(scaleCleanup)
	self.leaderboards.request = function()
		deps.net:request("LeaderboardRequest", nil)
	end

	-- Side menu: a vertical stack on the right edge, one square tile with its name beneath.
	local rail = Instance.new("Frame")
	rail.Name = "SideMenu"
	rail.AnchorPoint = Vector2.new(1, 0.5)
	rail.Position = UDim2.new(1, -Tokens.layout.safeAreaPaddingPx, 0.5, 0)
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
	self.rail = rail

	local minimumTap = SafeArea.minimumTapTarget(gui, deps.config)
	local size = math.max(minimumTap, Tokens.layout.stationButtonPx)
	for id, title in pairs(WORLD_TITLES) do
		self._titles[id] = title
	end
	local labelHeight = Tokens.typography.caption.size + Tokens.spacing.sm
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
		local label = FrameKit.text(slot, "Name", entry.short, "caption", {
			zIndex = rail.ZIndex + 2,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Center,
		})
		label.Font = Tokens.typography.label.font
		label.TextSize = Tokens.typography.caption.size + 1
		label.AnchorPoint = Vector2.new(0.5, 1)
		label.Position = UDim2.fromScale(0.5, 1)
		label.Size = UDim2.new(1, 0, 0, labelHeight)
		FrameKit.outline(label, 1.6)
		self._buttons[entry.id] = handle
		self._trove:add(handle.destroy)
	end

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
		deps.hud:celebrateCurrency("gems", grant.gems or 0)
		deps.audio:play(Tokens.sound.rewardTick)
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
	self._trove:add(deps.party.changed:Connect(function(party)
		if deps.lobbyShell and deps.lobbyShell.setPartySilhouettes then
			deps.lobbyShell:setPartySilhouettes(party)
		end
	end))
	self._trove:add(deps.round.phaseChanged:Connect(function(phase)
		local inRound = phase ~= nil and phase ~= "Returning" and phase ~= "Abandoned"
		self._inRound = inRound
		rail.Visible = not inRound
		if inRound then
			for _, id in ipairs({ "party", "classes", "shop", "daily", "codes", "inventory", "stats", "event" }) do
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
		deps.hud.toasts:push("Finish the search first", "info")
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
		quality = deps.quality,
		entitlements = function()
			local projection = deps.profile.projection
			return projection and projection.entitlements or {}
		end,
	}
	local builders: { [string]: any } = {
		party = PartyModal.build,
		classes = ClassesModal.build,
		shop = ShopModal.build,
		daily = DailyModal.build,
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
	local opened = deps.modals:open(id, priority, true, function(container, api)
		return builder(container, api, common)
	end, self._titles[id] or id, { wide = id == "classes" or id == "stats" or id == "party", icon = "header." .. id })
	if opened then
		self.stats.opened += 1
		local handle = self._buttons[id]
		if handle then
			handle.punch()
		end
	end
	return opened
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
