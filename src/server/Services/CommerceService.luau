--!strict
-- Monetization authority (MASTER_SPEC 17, STATE_MACHINES 12, DATASTORE_SCHEMA 9). One place owns:
--   * the product catalogue the client may show (prices from config, ids only as "configured"),
--   * purchase prompts through the Marketplace adapter (never for unconfigured or already-owned),
--   * every developer-product grant handler registered on the single ReceiptService,
--   * game-pass completion: ownership is re-verified through the adapter before anything grants,
--   * pending round grants (one-round tools, skip upgrades) bought outside a round and consumed
--     by the next round the player enters,
--   * event chest openings paid with tokens (the Robux bundles arrive as receipts).
-- Native prompt completion is never proof: only a persisted receipt or a verified pass grants.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local EventChest = require(Shared.Domain.EventChest)
local ToolSpecs = require(Shared.Domain.ToolSpecs)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)

local CommerceService = {}
CommerceService.__index = CommerceService

export type CommerceService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_productMap: any,
		_marketplace: any,
		_receipts: any,
		_entitlements: any,
		_profiles: any,
		_rounds: any,
		_tools: any,
		_upgrades: any,
		_rng: any,
		_analytics: any,
		_log: any,
		_playerOf: (userId: number) -> any?,
		granted: any, -- (userId, grant) after persistence / verification
		stats: {
			prompts: number,
			promptsRefused: number,
			grants: number,
			passesVerified: number,
			passesRefused: number,
			chestsOpened: number,
			pendingConsumed: number,
		},
	},
	CommerceService
))

CommerceService.PASS_COPY = table.freeze({
	doubleGems = { name = "2x Gems", grant = "Doubles every Gem you earn from rounds and rewards" },
	infiniteBag = { name = "Infinite Bag", grant = "Your bag never fills. Every feather is yours" },
	doubleLuck = { name = "2x Luck", grant = "Rarer classes twice as often on every roll" },
	fastRolls = { name = "Fast Rolls", grant = "Class roll animation plays at full speed" },
	extraClassSlot = { name = "Extra Class Slot", grant = "Equip one more class at the same time" },
})

function CommerceService.new(options: {
	config: { [string]: any },
	productMap: any,
	marketplace: any,
	receipts: any,
	entitlements: any,
	profiles: any,
	rounds: any,
	tools: any,
	upgrades: any,
	rng: any,
	playerOf: (userId: number) -> any?,
	analytics: any?,
	log: any?,
}): CommerceService
	local self = setmetatable({
		_config = options.config,
		_productMap = options.productMap,
		_marketplace = options.marketplace,
		_receipts = options.receipts,
		_entitlements = options.entitlements,
		_profiles = options.profiles,
		_rounds = options.rounds,
		_tools = options.tools,
		_upgrades = options.upgrades,
		_rng = options.rng,
		_analytics = options.analytics,
		_log = options.log,
		_playerOf = options.playerOf,
		granted = Signal.new(),
		stats = {
			prompts = 0,
			promptsRefused = 0,
			grants = 0,
			passesVerified = 0,
			passesRefused = 0,
			chestsOpened = 0,
			pendingConsumed = 0,
		},
	}, CommerceService)
	self:_registerGrants()
	options.receipts.granted:Connect(function(userId, entry, result, replayed, purchaseId)
		self:_onReceiptGranted(userId, entry, result, replayed, purchaseId)
	end)
	options.marketplace:bindPassPurchaseFinished(function(userId, gamePassId, wasPurchased)
		self:onPassPurchaseFinished(userId, gamePassId, wasPurchased)
	end)
	return self
end

local function log(self: CommerceService, level: string, code: string, fields: { [string]: any }?)
	if self._log then
		self._log[level](self._log, code, fields)
	end
end

local function reject(self: CommerceService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.promptsRefused += 1
	return Envelope.fail(code, message)
end

-- ---------------------------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------------------------

-- Describes one product key from config: what it grants, whether it is permanent, and its price.
function CommerceService.describe(self: CommerceService, key: string): { [string]: any }?
	local cfg = self._config
	local entry = self._productMap:resolve(key)
	if not entry or entry.kind == "place" then
		return nil
	end
	local item: { [string]: any } = { key = key, kind = entry.kind, grant = entry.grant, configured = entry.id ~= nil }
	local grantKind, arg = string.match(entry.grant, "^(%w+):(.+)$")
	if grantKind == "pass" then
		local copy = CommerceService.PASS_COPY[arg]
		item.family = "pass"
		item.scope = "permanent"
		item.name = copy and copy.name or key
		item.summary = copy and copy.grant or ""
		local price = cfg.monetization.passes[arg] and cfg.monetization.passes[arg].robux
		if not price then
			local classPrices = { doubleLuck = "doubleLuckRobux", fastRolls = "fastRollsRobux", extraClassSlot = "extraSlotRobux" }
			price = classPrices[arg] and cfg.classes.products[classPrices[arg]]
		end
		item.robux = price
	elseif grantKind == "permanentTool" then
		local tool = cfg.tools[arg]
		item.family = "permanentTool"
		item.scope = "permanent"
		item.toolId = arg
		item.name = tool.displayName .. " (permanent)"
		item.summary = "Own the "
			.. tool.displayName
			.. " in every round"
			.. (if tool.permanentIncludesMaxUpgrades then ", fully upgraded" else "")
		item.robux = tool.permanentRobux
	elseif grantKind == "oneRoundTool" then
		local tool = cfg.tools[arg]
		item.family = "oneRoundTool"
		item.scope = "oneRound"
		item.toolId = arg
		item.name = tool.displayName .. " (one round)"
		item.summary = "Use the " .. tool.displayName .. " for one round only. Bought in the lobby, it applies to your next round"
		item.robux = tool.oneRoundRobux
	elseif grantKind == "gems" then
		item.family = "gems"
		item.scope = "consumable"
		item.gems = tonumber(arg)
		item.name = arg .. " Gems"
		item.summary = "Adds " .. arg .. " Gems to your balance immediately"
		for _, bundle in ipairs(cfg.monetization.gemBundles) do
			if bundle.gems == tonumber(arg) then
				item.robux = bundle.robux
			end
		end
	elseif grantKind == "eventChest" then
		item.family = "eventChest"
		item.scope = "consumable"
		item.count = tonumber(arg)
		item.name = arg .. " Moonlit Chests"
		item.summary = "Opens " .. arg .. " chests at once. Duplicate skins turn into Event Tokens"
		for _, bundle in ipairs(cfg.monetization.eventChest.robuxBundles) do
			if bundle.count == tonumber(arg) then
				item.robux = bundle.robux
			end
		end
	elseif grantKind == "skipUpgrade" then
		item.family = "skipUpgrade"
		item.scope = "oneRound"
		item.name = "Skip Bag Upgrade"
		item.summary = "Raises your bag one level this round at no cash cost (next round if bought in the lobby)"
		local levels = cfg.bags.levels
		item.robux = levels[1].skipRobux
		item.robuxByLevel = {}
		for _, level in ipairs(levels) do
			item.robuxByLevel[tostring(level.level)] = level.skipRobux
		end
	else
		return nil
	end
	return item
end

-- Full catalogue for a player: every non-place product with ownership for passes.
function CommerceService.catalog(self: CommerceService, userId: number): { { [string]: any } }
	local passes = self._entitlements:snapshot(userId)
	local out = {}
	for key, entry in pairs(self._productMap._entries) do
		if entry.kind ~= "place" then
			local item = self:describe(key)
			if item then
				if item.family == "pass" then
					item.owned = passes[string.match(entry.grant, "^pass:(.+)$") :: string] == true
				elseif item.family == "permanentTool" then
					item.owned = passes[key] == true
				end
				table.insert(out, item)
			end
		end
	end
	table.sort(out, function(a, b)
		if a.family ~= b.family then
			return a.family < b.family
		end
		return (a.robux or 0) < (b.robux or 0)
	end)
	return out
end

-- ---------------------------------------------------------------------------------------------
-- Prompts and pass verification
-- ---------------------------------------------------------------------------------------------

function CommerceService.prompt(self: CommerceService, userId: number, key: string): Envelope.Envelope<any>
	local item = self:describe(key)
	if not item then
		return reject(self, Envelope.Codes.NOT_FOUND, "product")
	end
	if not item.configured then
		return reject(self, Envelope.Codes.INVALID_STATE, "not_available")
	end
	local entry = self._productMap:resolve(key)
	if entry.kind == "gamePass" then
		local passKey = string.match(entry.grant, "^pass:(.+)$") or key
		if self._entitlements:snapshot(userId)[passKey] == true then
			return reject(self, Envelope.Codes.ALREADY_DONE, "owned")
		end
	end
	local player = self._playerOf(userId)
	if not player then
		return reject(self, Envelope.Codes.INVALID_STATE, "no_player")
	end
	local ok = if entry.kind == "gamePass"
		then self._marketplace:promptGamePassPurchase(player, entry.id)
		else self._marketplace:promptProductPurchase(player, entry.id)
	if not ok then
		return reject(self, Envelope.Codes.INVALID_STATE, "prompt_failed")
	end
	self.stats.prompts += 1
	if self._analytics then
		self._analytics:track("purchase_prompted", { productKey = key, kind = entry.kind }, userId)
	end
	return Envelope.ok({ productKey = key, kind = entry.kind, scope = item.scope, robux = item.robux })
end

-- Native pass prompt closed. A purchase grants nothing by itself: ownership is re-read from Roblox
-- and only a verified owner receives the in-round effects and the confirmation.
function CommerceService.onPassPurchaseFinished(self: CommerceService, userId: number, gamePassId: number, wasPurchased: boolean): boolean
	local entry = self._productMap:lookupGamePass(gamePassId)
	if not entry then
		log(self, "warn", "pass_unknown_id", { userId = userId, gamePassId = gamePassId })
		return false
	end
	if not wasPurchased then
		return false
	end
	self._entitlements:forget(userId)
	local passes = self._entitlements:refresh(userId)
	local passKey = string.match(entry.grant, "^pass:(.+)$") or entry.key
	if passes[passKey] ~= true then
		self.stats.passesRefused += 1
		log(self, "warn", "pass_not_verified", { userId = userId, key = entry.key })
		return false
	end
	self.stats.passesVerified += 1
	local profile = self._profiles:get(userId)
	if profile then
		profile:update(function(data)
			data.entitlementsCache = { checkedAt = os.time(), passes = passes }
		end)
	end
	-- Permanent tools apply to the live round at once (start-of-round is the normal path).
	local toolId = string.match(entry.grant, "^permanentTool:(.+)$")
	if toolId and self._tools.grantPermanentNow then
		self._tools:grantPermanentNow(userId, toolId)
	end
	if self._analytics then
		self._analytics:track("pass_verified", { productKey = entry.key }, userId)
		self._analytics:track("purchase_completed", { productKey = entry.key }, userId)
	end
	self.stats.grants += 1
	self.granted:Fire(userId, { kind = "pass", productKey = entry.key, passKey = passKey, scope = "permanent" })
	return true
end

-- ---------------------------------------------------------------------------------------------
-- Developer product grants (run inside the receipt transaction: profile data only)
-- ---------------------------------------------------------------------------------------------

function CommerceService._registerGrants(self: CommerceService)
	local cfg = self._config
	local receipts = self._receipts
	for _, bundle in ipairs(cfg.monetization.gemBundles) do
		receipts:registerGrant("gems:" .. tostring(bundle.gems), function(data)
			data.currencies.gems = math.min(cfg.currencies.gems.maximum, data.currencies.gems + bundle.gems)
			return { gems = bundle.gems }
		end)
	end
	for toolId in pairs(cfg.tools) do
		receipts:registerGrant("oneRoundTool:" .. toolId, function(data)
			data.pendingGrants.oneRoundTools[toolId] = (data.pendingGrants.oneRoundTools[toolId] or 0) + 1
			return { toolId = toolId, pending = data.pendingGrants.oneRoundTools[toolId] }
		end)
	end
	receipts:registerGrant("skipUpgrade:bag", function(data)
		data.pendingGrants.skipBagUpgrades += 1
		return { pending = data.pendingGrants.skipBagUpgrades }
	end)
	for _, bundle in ipairs(cfg.monetization.eventChest.robuxBundles) do
		receipts:registerGrant("eventChest:" .. tostring(bundle.count), function(data)
			return { outcomes = EventChest.openMany(cfg, data, self._rng, bundle.count), count = bundle.count }
		end)
	end
end

-- After a receipt persisted: consume round grants if a round is live, then confirm to the client.
function CommerceService._onReceiptGranted(
	self: CommerceService,
	userId: number,
	entry: any,
	result: any,
	replayed: boolean,
	purchaseId: string
)
	self.stats.grants += 1
	local consumed = self:consumePending(userId)
	self.granted:Fire(userId, {
		kind = "product",
		productKey = entry.key,
		grant = entry.grant,
		scope = (self:describe(entry.key) or {}).scope,
		result = result,
		replayed = replayed,
		purchaseId = purchaseId,
		consumed = consumed,
	})
end

-- Applies pending round grants to the player's live round (if any). Returns what was applied.
function CommerceService.consumePending(self: CommerceService, userId: number): { [string]: any }
	local applied = { oneRoundTools = {}, skipBagUpgrades = 0 }
	local profile = self._profiles:get(userId)
	local runtime = self._rounds:roundOf(userId)
	if not profile or not runtime then
		return applied
	end
	local pending = profile.data.pendingGrants
	for toolId, count in pairs(table.clone(pending.oneRoundTools)) do
		if count > 0 and ToolSpecs.isTool(toolId) then
			local granted = self._tools:grantOneRound(userId, toolId, "product")
			if granted or (runtime.players[userId] and runtime.players[userId].roundTools[toolId]) then
				profile:update(function(data)
					local left = (data.pendingGrants.oneRoundTools[toolId] or 1) - 1
					data.pendingGrants.oneRoundTools[toolId] = if left > 0 then left else nil
				end)
				table.insert(applied.oneRoundTools, toolId)
				self.stats.pendingConsumed += 1
			end
		end
	end
	while (profile.data.pendingGrants.skipBagUpgrades or 0) > 0 do
		local result = self._upgrades:skipBag(userId, "product")
		profile:update(function(data)
			data.pendingGrants.skipBagUpgrades -= 1
		end)
		if not result.ok then
			break -- maxed: the remaining skips are consumed but cannot exceed the top level
		end
		applied.skipBagUpgrades += 1
		self.stats.pendingConsumed += 1
	end
	return applied
end

-- ---------------------------------------------------------------------------------------------
-- Event chest with tokens
-- ---------------------------------------------------------------------------------------------

function CommerceService.openChest(self: CommerceService, userId: number, count: number): Envelope.Envelope<any>
	if not self._config.featureFlags.eventChestEnabled then
		return Envelope.fail(Envelope.Codes.INVALID_STATE, "disabled")
	end
	if type(count) ~= "number" or count < 1 or count > 10 or count % 1 ~= 0 then
		return Envelope.fail(Envelope.Codes.INVALID_PAYLOAD, "count")
	end
	local profile = self._profiles:get(userId)
	if not profile then
		return Envelope.fail(Envelope.Codes.INVALID_STATE, "no_profile")
	end
	local cost = self._config.monetization.eventChest.tokenCost * count
	if profile.data.currencies.eventTokens < cost then
		return Envelope.fail(Envelope.Codes.INSUFFICIENT_FUNDS, "tokens")
	end
	local outcomes
	profile:update(function(data)
		data.currencies.eventTokens -= cost
		outcomes = EventChest.openMany(self._config, data, self._rng, count)
	end)
	self.stats.chestsOpened += count
	if self._analytics then
		self._analytics:track("chest_opened", { count = count, tokens = cost, source = "tokens" }, userId)
	end
	return Envelope.ok({
		count = count,
		tokensSpent = cost,
		outcomes = outcomes,
		gems = profile.data.currencies.gems,
		eventTokens = profile.data.currencies.eventTokens,
	})
end

return CommerceService
