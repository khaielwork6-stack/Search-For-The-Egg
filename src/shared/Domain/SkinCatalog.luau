--!strict
-- Tool-skin catalog derived from configuration (ASSUMED A-META-09): the four default skins plus the
-- event-chest cosmetic rewards, each mapped to the tool category it dresses. Cosmetics never change
-- power; ownership and equips are validated server-side against this catalog.

local SkinCatalog = {}

export type Skin = { id: string, category: string, displayName: string, source: string }

SkinCatalog.CATEGORIES = table.freeze({ "nestRake", "confettiCharge", "featherVac", "scoutChick" })

local DEFAULTS: { [string]: string } = {
	nestRake = "defaultRake",
	confettiCharge = "defaultCharge",
	featherVac = "defaultVac",
	scoutChick = "defaultChick",
}

-- Event skin ids name their tool by suffix (ASSUMED naming convention from SYSTEM_CONFIG).
local SUFFIX_TO_CATEGORY: { { suffix: string, category: string } } = {
	{ suffix = "RakeSkin", category = "nestRake" },
	{ suffix = "ChargeSkin", category = "confettiCharge" },
	{ suffix = "VacSkin", category = "featherVac" },
	{ suffix = "DroneSkin", category = "scoutChick" },
}

local function prettify(id: string): string
	local spaced = string.gsub(id, "(%l)(%u)", "%1 %2")
	return string.upper(string.sub(spaced, 1, 1)) .. string.sub(spaced, 2)
end

function SkinCatalog.categoryFor(cfg: { [string]: any }, skinId: string): string?
	for category, defaultId in pairs(DEFAULTS) do
		if defaultId == skinId then
			return category
		end
	end
	for _, reward in ipairs(cfg.monetization.eventChest.rewards) do
		if reward.id == skinId and reward.min == nil and reward.max == nil then
			for _, rule in ipairs(SUFFIX_TO_CATEGORY) do
				if string.sub(skinId, -#rule.suffix) == rule.suffix then
					return rule.category
				end
			end
		end
	end
	return nil
end

-- Every skin in config order: defaults first, then event rewards (only those with a known category).
function SkinCatalog.all(cfg: { [string]: any }): { Skin }
	local out: { Skin } = {}
	for _, category in ipairs(SkinCatalog.CATEGORIES) do
		local id = DEFAULTS[category]
		table.insert(out, { id = id, category = category, displayName = "Classic " .. cfg.tools[category].displayName, source = "default" })
	end
	for _, reward in ipairs(cfg.monetization.eventChest.rewards) do
		if reward.min == nil and reward.max == nil then
			local category = SkinCatalog.categoryFor(cfg, reward.id)
			if category then
				table.insert(out, { id = reward.id, category = category, displayName = prettify(reward.id), source = "eventChest" })
			end
		end
	end
	return out
end

function SkinCatalog.defaultFor(category: string): string?
	return DEFAULTS[category]
end

return SkinCatalog
