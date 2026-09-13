--!strict
-- Pure permanent-perk math (SYSTEM_CONFIG.permanentPerks, ASSUMED A-ECO-10): cost curve per level,
-- old -> new effect previews, caps. Effects apply through ModifierResolver.sourceFromPerk only.

local EconomyMath = require(script.Parent.Parent.EconomyMath)

local Perks = {}

Perks.IDS = table.freeze({ "bagSize", "handGrab", "gemValue", "featherValue" })

export type Preview = {
	perkId: string,
	level: number,
	maxLevel: number,
	currentMultiplier: number,
	nextMultiplier: number?,
	costGems: number?,
	maxed: boolean,
}

function Perks.isPerk(cfg: { [string]: any }, perkId: any): boolean
	return type(perkId) == "string" and perkId ~= "evidence" and type(cfg.permanentPerks[perkId]) == "table"
end

function Perks.multiplier(cfg: { [string]: any }, perkId: string, level: number): number
	local perk = cfg.permanentPerks[perkId]
	return 1 + level * perk.valuePerLevel
end

function Perks.costGems(cfg: { [string]: any }, perkId: string, level: number): number?
	local perk = cfg.permanentPerks[perkId]
	if level >= perk.maxLevel then
		return nil
	end
	return EconomyMath.perkCostGems(perk.baseGemCost, perk.costGrowth, level)
end

function Perks.preview(cfg: { [string]: any }, perkId: string, level: number): Preview
	local perk = cfg.permanentPerks[perkId]
	local maxed = level >= perk.maxLevel
	return {
		perkId = perkId,
		level = level,
		maxLevel = perk.maxLevel,
		currentMultiplier = Perks.multiplier(cfg, perkId, level),
		nextMultiplier = if maxed then nil else Perks.multiplier(cfg, perkId, level + 1),
		costGems = Perks.costGems(cfg, perkId, level),
		maxed = maxed,
	}
end

function Perks.previews(cfg: { [string]: any }, levels: { [string]: number }): { Preview }
	local out = {}
	for _, perkId in ipairs(Perks.IDS) do
		if Perks.isPerk(cfg, perkId) then
			table.insert(out, Perks.preview(cfg, perkId, levels[perkId] or 0))
		end
	end
	return out
end

return Perks
