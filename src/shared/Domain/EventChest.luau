--!strict
-- Event chest rolls (MASTER_SPEC 17; A-META-05/09). Pure: weights and costs come from
-- monetization.eventChest, the roll uses an injected rng, and `apply` mutates a profile table the
-- caller already holds inside a transaction. Duplicate skins convert to Event Tokens by the
-- configured policy so no opening is ever a dead reward.

local WeightedRandom = require(script.Parent.Parent.WeightedRandom)
local SkinCatalog = require(script.Parent.SkinCatalog)

local EventChest = {}

export type Reward = { id: string, kind: "gems" | "skin", gems: number?, skinId: string?, category: string? }
export type Outcome = {
	rewardId: string,
	kind: "gems" | "skin",
	gems: number,
	skinId: string?,
	category: string?,
	duplicate: boolean,
	tokens: number, -- tokens returned for a duplicate skin
}

function EventChest.entries(cfg: { [string]: any }): { { id: string, weight: number } }
	local out = {}
	for _, reward in ipairs(cfg.monetization.eventChest.rewards) do
		table.insert(out, { id = reward.id, weight = reward.weight })
	end
	return out
end

function EventChest.rewardById(cfg: { [string]: any }, id: string): { [string]: any }?
	for _, reward in ipairs(cfg.monetization.eventChest.rewards) do
		if reward.id == id then
			return reward
		end
	end
	return nil
end

-- Rolls one reward from a unit roll in [0,1) (boundary-testable) and a second roll for gem amounts.
function EventChest.rollFrom(cfg: { [string]: any }, roll: number, amountRoll: number): Reward
	local entry = WeightedRandom.selectByRoll(EventChest.entries(cfg), roll)
	local reward = EventChest.rewardById(cfg, entry.id) :: { [string]: any }
	if reward.min then
		local span = reward.max - reward.min
		local gems = reward.min + math.floor(math.clamp(amountRoll, 0, 0.999999) * (span + 1))
		return { id = reward.id, kind = "gems", gems = math.clamp(gems, reward.min, reward.max) }
	end
	return { id = reward.id, kind = "skin", skinId = reward.id, category = SkinCatalog.categoryFor(cfg, reward.id) }
end

function EventChest.roll(cfg: { [string]: any }, rng: any): Reward
	return EventChest.rollFrom(cfg, rng:next(), rng:next())
end

-- Applies a rolled reward to profile data (inside the caller's transaction). Gems credit
-- currencies.gems; a new skin is added to inventory.toolSkins; a duplicate converts to tokens.
function EventChest.apply(cfg: { [string]: any }, data: { [string]: any }, reward: Reward): Outcome
	local chest = cfg.monetization.eventChest
	if reward.kind == "gems" then
		data.currencies.gems = math.min(cfg.currencies.gems.maximum, data.currencies.gems + (reward.gems :: number))
		return { rewardId = reward.id, kind = "gems", gems = reward.gems :: number, duplicate = false, tokens = 0 }
	end
	local skinId = reward.skinId :: string
	if data.inventory.toolSkins[skinId] then
		local tokens = (chest.duplicateTokenValues and chest.duplicateTokenValues[skinId]) or 0
		if chest.duplicatePolicy == "convert_to_eventTokens" then
			data.currencies.eventTokens = math.min(cfg.currencies.eventTokens.maximum, data.currencies.eventTokens + tokens)
		else
			tokens = 0
		end
		return {
			rewardId = reward.id,
			kind = "skin",
			gems = 0,
			skinId = skinId,
			category = reward.category,
			duplicate = true,
			tokens = tokens,
		}
	end
	data.inventory.toolSkins[skinId] = true
	return { rewardId = reward.id, kind = "skin", gems = 0, skinId = skinId, category = reward.category, duplicate = false, tokens = 0 }
end

-- Opens `count` chests against data (caller's transaction), returning every outcome.
function EventChest.openMany(cfg: { [string]: any }, data: { [string]: any }, rng: any, count: number): { Outcome }
	local outcomes = {}
	for _ = 1, count do
		table.insert(outcomes, EventChest.apply(cfg, data, EventChest.roll(cfg, rng)))
	end
	data.stats.chestsOpened += count
	return outcomes
end

return EventChest
