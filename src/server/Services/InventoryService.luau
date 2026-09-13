--!strict
-- Inventory authority (MASTER_SPEC 11 "Inventory"): tool-skin categories with owned-only equips.
-- The client requests an equip by owned item id; the server validates the category, the catalog
-- membership, and ownership, then returns the new projection. Cosmetics never change power.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local SkinCatalog = require(Shared.Domain.SkinCatalog)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)

local InventoryService = {}
InventoryService.__index = InventoryService

export type InventoryService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_getProfile: (userId: number) -> any?,
		_analytics: any?,
		equipped: any, -- (userId, category, itemId)
		stats: { equips: number, rejected: number },
	},
	InventoryService
))

function InventoryService.new(
	options: { config: { [string]: any }, getProfile: (userId: number) -> any?, analytics: any? }
): InventoryService
	return setmetatable({
		_config = options.config,
		_getProfile = options.getProfile,
		_analytics = options.analytics,
		equipped = Signal.new(),
		stats = { equips = 0, rejected = 0 },
	}, InventoryService)
end

local function reject(self: InventoryService, code: string, message: string?): Envelope.Envelope<any>
	self.stats.rejected += 1
	return Envelope.fail(code, message)
end

-- Client view: the full catalog with owned/equipped flags for one player.
function InventoryService.view(self: InventoryService, userId: number): { [string]: any }
	local profile = self._getProfile(userId)
	local inventory = profile and profile.data.inventory or { toolSkins = {}, equippedSkins = {} }
	local items = {}
	for _, skin in ipairs(SkinCatalog.all(self._config)) do
		table.insert(items, {
			id = skin.id,
			category = skin.category,
			displayName = skin.displayName,
			source = skin.source,
			owned = inventory.toolSkins[skin.id] == true,
			equipped = inventory.equippedSkins[skin.category] == skin.id,
		})
	end
	return { categories = table.clone(SkinCatalog.CATEGORIES), items = items }
end

function InventoryService.equip(self: InventoryService, userId: number, category: string, itemId: string): Envelope.Envelope<any>
	local profile = self._getProfile(userId)
	if not profile or not profile:isActive() then
		return reject(self, Envelope.Codes.INVALID_STATE, "profile")
	end
	if not table.find(SkinCatalog.CATEGORIES, category) then
		return reject(self, Envelope.Codes.NOT_FOUND, "category")
	end
	local skinCategory = SkinCatalog.categoryFor(self._config, itemId)
	if skinCategory ~= category then
		return reject(self, Envelope.Codes.NOT_FOUND, "item")
	end
	if profile.data.inventory.toolSkins[itemId] ~= true then
		return reject(self, Envelope.Codes.NOT_AUTHORIZED, "not_owned")
	end
	if profile.data.inventory.equippedSkins[category] == itemId then
		return Envelope.ok({
			category = category,
			itemId = itemId,
			equippedSkins = table.clone(profile.data.inventory.equippedSkins),
			unchanged = true,
		})
	end
	profile:update(function(data)
		data.inventory.equippedSkins[category] = itemId
	end)
	self.stats.equips += 1
	if self._analytics then
		self._analytics:track("skin_equipped", { tool = category }, userId)
	end
	self.equipped:Fire(userId, category, itemId)
	return Envelope.ok({ category = category, itemId = itemId, equippedSkins = table.clone(profile.data.inventory.equippedSkins) })
end

return InventoryService
