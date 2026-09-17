--!strict
-- Barn shop displays: the owner's item models on the FEATHER SUPPLIES counter and wall boards each
-- carry a floating price card (name, price or state) and a Buy prompt. Prices and states come from
-- the server's round previews and the profile's entitlements; buying goes through the same
-- requests the workbench uses, so nothing here decides what anything costs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local EconomyMath = require(Shared.EconomyMath)
local Trove = require(Shared.Util.Trove)
local WorldBillboard = require(script.Parent.Parent.UI.Components.WorldBillboard)
local UpgradeActions = require(script.Parent.Parent.UI.UpgradeActions)

local DisplayController = {}
DisplayController.__index = DisplayController

export type DisplayController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_trove: any,
		_cards: {
			[string]: { model: Model, gui: BillboardGui, price: TextLabel, priceFill: Frame, caption: TextLabel, scale: UIScale },
		},
		stats: { purchases: number, prompts: number },
	},
	DisplayController
))

-- What each display sells. `upgradeId` rows use the round's UpgradePurchase; `productKey` rows
-- open the native Robux prompt for a permanent pass.
local DISPLAYS: { [string]: { name: string, upgradeId: string?, productKey: string?, pass: string? } } = {
	bag = { name = "Upgrade Bag", upgradeId = "bag" },
	infiniteBag = { name = "Infinite Bag", productKey = "infiniteBag", pass = "infiniteBag" },
	nestRake = { name = "Nest Rake", upgradeId = "tool:nestRake" },
	confettiCharge = { name = "Confetti Charge", upgradeId = "tool:confettiCharge" },
	featherVac = { name = "Feather Vac", upgradeId = "tool:featherVac" },
	scoutChick = { name = "Scout Chick", upgradeId = "tool:scoutChick" },
}

function DisplayController.new(deps: any): DisplayController
	local self = setmetatable({
		_deps = deps,
		_trove = Trove.new(),
		_cards = {},
		stats = { purchases = 0, prompts = 0 },
	}, DisplayController)

	-- The barn streams in and out with distance, so a display model can arrive before its parts
	-- (or its attribute); every arrival re-runs the scan until each card exists.
	local watched: { [Instance]: boolean } = {}
	local scan
	local function watch(model: Instance)
		if watched[model] then
			return
		end
		watched[model] = true
		self._trove:add(model.ChildAdded:Connect(function()
			task.defer(scan)
		end))
		self._trove:add(model.AttributeChanged:Connect(function()
			task.defer(scan)
		end))
	end
	scan = function()
		for _, child in ipairs(workspace:GetChildren()) do
			if not child:IsA("Model") then
				continue
			end
			local key = child:GetAttribute("SFE_Display")
			if type(key) == "string" and DISPLAYS[key] then
				if not self._cards[key] and not self:_buildCard(key, child) then
					watch(child)
				end
			elseif key == nil and not watched[child] and child.PrimaryPart == nil then
				-- A model still arriving: its attribute may follow the instance.
				watch(child)
			end
		end
		self:refresh()
	end
	scan()
	self._trove:add(workspace.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			task.defer(scan)
		end
	end))
	self._trove:add(workspace.ChildRemoved:Connect(function(child)
		for key, card in pairs(self._cards) do
			if card.model == child then
				self._cards[key] = nil
			end
		end
		watched[child] = nil
	end))
	self._trove:add(deps.round.upgrade:Connect(function()
		self:refresh()
	end))
	self._trove:add(deps.round.playerChanged:Connect(function()
		self:refresh()
	end))
	self._trove:add(deps.round.phaseChanged:Connect(function()
		self:refresh()
	end))
	self._trove:add(deps.profile.changed:Connect(function()
		self:refresh()
	end))
	self._trove:add(deps.interaction.displayRequested:Connect(function(key: string)
		local card = self._cards[key]
		if deps.inspect and card then
			-- The prompt opens the inspection; buying happens from its option row.
			deps.inspect:open(key, card.model)
		else
			self:buy(key)
		end
	end))
	return self
end

function DisplayController._buildCard(self: DisplayController, key: string, model: Model): boolean
	local spec = DISPLAYS[key]
	local adornee = model.PrimaryPart
	if not adornee then
		return false
	end
	local _, size = model:GetBoundingBox()
	-- A world billboard: studs-sized, occluded by the counter and shelves, culled past its range.
	local world = Tokens.world
	local gui = WorldBillboard.create(
		adornee,
		"PriceCard",
		world.displayCardStuds,
		Vector3.new(0, size.Y * 0.5 + 0.9, 0),
		world.displayCardMaxDistance
	)
	local scale = Instance.new("UIScale")
	scale.Parent = gui
	WorldBillboard.text(gui, "Name", spec.name, { size = UDim2.fromScale(1, 0.36), outline = 2.2 })
	local priceFill, price = WorldBillboard.pill(gui, "Price", "-", {
		size = UDim2.fromScale(1, 0.38),
		position = UDim2.fromScale(0.5, 0.37),
		anchor = Vector2.new(0.5, 0),
		fill = Tokens.color.gold,
		textColor = Tokens.color.inkStrong,
	})
	local caption = WorldBillboard.text(gui, "Caption", "", {
		size = UDim2.fromScale(1, 0.22),
		position = UDim2.fromScale(0.5, 1),
		anchor = Vector2.new(0.5, 1),
		font = Tokens.typography.caption.font,
		outline = 1.5,
	})
	self._cards[key] = { model = model, gui = gui, price = price, priceFill = priceFill, caption = caption, scale = scale }
	self._trove:add(gui)
	return true
end

-- Re-reads price and state for every display from the round previews and entitlements.
function DisplayController.refresh(self: DisplayController)
	local deps = self._deps
	local round = deps.round
	local player = round.player
	local projection = deps.profile.projection
	local entitlements = projection and projection.entitlements or {}
	for key, card in pairs(self._cards) do
		local spec = DISPLAYS[key]
		local text, caption, fill, textColor = "-", "", Tokens.color.gold, Tokens.color.inkStrong
		if spec.pass then
			if entitlements[spec.pass] == true then
				text, caption, fill, textColor = "OWNED", "Your bag never fills", Tokens.color.leafBright, Tokens.color.inkStrong
			else
				local passes = deps.config.monetization and deps.config.monetization.passes
				local robux = passes and passes[spec.pass] and passes[spec.pass].robux
				text = if robux then string.format("R$ %d", robux) else "R$"
				caption = "Permanent - never fills"
				fill, textColor = Tokens.color.gem, Tokens.color.featherWhite
			end
		else
			local preview = UpgradeActions.previewFor(round, spec.upgradeId :: string)
			if not preview then
				text, caption = "-", "Open during a search"
			elseif preview.maxed then
				text = if preview.kind == "acquire" then "OWNED" else "MAX"
				caption = if preview.kind == "acquire" then "In your hotbar" else "Fully upgraded"
				fill = Tokens.color.leafBright
			elseif preview.costGems then
				-- Gem-priced (the Scout Chick): the price reads in Gems against the profile balance.
				text = string.format("%d Gems", preview.costGems)
				caption = "Adds the chick this search"
				local gems = projection and projection.currencies and projection.currencies.gems or 0
				local affordable = gems >= preview.costGems
				fill = if affordable then Tokens.color.gem else Tokens.color.creamDeep
				textColor = if affordable then Tokens.color.featherWhite else Tokens.color.inkMuted
			else
				local cents = preview.costCents or 0
				text = EconomyMath.formatCents(cents)
				local affordable = player ~= nil and (player.cashCents or 0) >= cents
				if preview.kind == "bag" then
					local nextCapacity = preview.next and preview.next.capacity
					caption = if nextCapacity then string.format("Lv %d - holds %d", preview.level + 1, nextCapacity) else ""
				else
					caption = "Adds the tool this search"
				end
				fill = if affordable then Tokens.color.gold else Tokens.color.creamDeep
				textColor = if affordable then Tokens.color.inkStrong else Tokens.color.inkMuted
			end
		end
		card.price.Text = text
		card.priceFill.BackgroundColor3 = fill
		card.price.TextColor3 = textColor
		-- Only a state reads under the price; plain descriptions stay off the world.
		local isState = text == "OWNED" or text == "MAX" or text == "-"
		card.caption.Text = if isState then caption else ""
	end
end

-- Buys what a display sells; the server answers, this celebrates or explains.
function DisplayController.buy(self: DisplayController, key: string)
	local spec = DISPLAYS[key]
	local card = self._cards[key]
	if not spec then
		return
	end
	local deps = self._deps
	local result
	if spec.productKey then
		self.stats.prompts += 1
		result = UpgradeActions.promptPurchase({ net = deps.net, audio = deps.audio, toasts = deps.hud.toasts }, spec.productKey, spec.name)
	else
		result = UpgradeActions.purchase({
			net = deps.net,
			round = deps.round,
			audio = deps.audio,
			haptics = deps.haptics,
			toasts = deps.hud.toasts,
			config = deps.config,
		}, spec.upgradeId :: string, spec.name)
		if result == nil then
			deps.audio:play(Tokens.sound.uiError)
			deps.hud.toasts:push("Nothing to buy here right now", "warning")
		end
	end
	if result and result.ok then
		self.stats.purchases += 1
		if card then
			local pivot = card.model:GetPivot()
			deps.vfx:burst("sparkle", pivot.Position + Vector3.new(0, 1.5, 0), 0.8)
			card.scale.Scale = 1.25
			TweenService:Create(card.scale, TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
	end
	self:refresh()
end

function DisplayController.cardCount(self: DisplayController): number
	local count = 0
	for _ in pairs(self._cards) do
		count += 1
	end
	return count
end

function DisplayController.destroy(self: DisplayController)
	self._trove:destroy()
end

return DisplayController
