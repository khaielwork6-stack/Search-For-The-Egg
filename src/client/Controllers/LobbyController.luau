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
local RAIL: { { id: string, title: string, short: string, image: string } } = {
	{ id = "party", title = "Sunlit Henhouse", short = "Play", image = "station.party" },
	{ id = "daily", title = "Daily Nest", short = "Daily", image = "station.daily" },
	{ id = "classes", title = "Class Cards", short = "Classes", image = "station.classes" },
	{ id = "shop", title = "Perk Bench", short = "Shop", image = "station.shop" },
	{ id = "inventory", title = "Tool Rack", short = "Rack", image = "station.inventory" },
	{ id = "stats", title = "Forager Ledger", short = "Stats", image = "station.stats" },
	{ id = "codes", title = "Nest Mailbox", short = "Codes", image = "station.codes" },
	{ id = "event", title = "Moonlit Chest", short = "Chest", image = "station.event" },
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

	-- Station rail: bottom-center row, one square button per station, inside the safe area.
	local rail = Instance.new("Frame")
	rail.Name = "StationRail"
	rail.AnchorPoint = Vector2.new(0.5, 1)
	rail.Position = UDim2.new(0.5, 0, 1, -Tokens.layout.safeAreaPaddingPx)
	rail.Size = UDim2.fromOffset(0, Tokens.layout.stationButtonPx + Tokens.spacing.sm)
	rail.AutomaticSize = Enum.AutomaticSize.X
	rail.BackgroundTransparency = 1
	rail.ZIndex = Tokens.zIndex.hud + 1
	local railLayout = Instance.new("UIListLayout")
	railLayout.FillDirection = Enum.FillDirection.Horizontal
	railLayout.SortOrder = Enum.SortOrder.LayoutOrder
	railLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	railLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	railLayout.Parent = rail
	rail.Parent = stage
	self.rail = rail

	local minimumTap = SafeArea.minimumTapTarget(gui, deps.config)
	local size = math.max(minimumTap, Tokens.layout.stationButtonPx)
	for index, entry in ipairs(RAIL) do
		self._titles[entry.id] = entry.title
		local image = AssetManifest.image(entry.image .. ".normal") or AssetManifest.image(entry.image)
		local handle = Button.build(rail, {
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
		handle.button.LayoutOrder = index
		handle.button.Name = "Station_" .. entry.id
		if not image then
			handle.button.TextSize = Tokens.typography.caption.size + 1
		end
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
		local projection = deps.profile.projection
		local daily = projection and projection.rewards and projection.rewards.daily
		local ready = daily ~= nil and (daily.status == "ready" or daily.status == "reset")
		local dailyHandle = self._buttons.daily
		if dailyHandle then
			dailyHandle.pulse(ready and open ~= "daily")
		end
	end
	self._trove:add(deps.modals.changed:Connect(refreshRail))
	self._trove:add(deps.profile.changed:Connect(refreshRail))
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
