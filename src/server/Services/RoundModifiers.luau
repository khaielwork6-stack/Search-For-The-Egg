--!strict
-- Resolves the per-player modifier set for a round from server-owned state only: equipped classes
-- (profile), permanent perks (profile), difficulty (round), and verified entitlements. Gameplay
-- services call this instead of inspecting class names (MASTER_SPEC section 10).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local ModifierResolver = require(Shared.ModifierResolver)
local Config = require(Shared.Config)

local RoundModifiers = {}

function RoundModifiers.resolve(
	cfg: { [string]: any },
	profileData: { [string]: any }?,
	difficulty: string,
	entitlements: { [string]: boolean }?
): ModifierResolver.ResolvedModifiers
	local sources: { ModifierResolver.ModifierSource } = {}
	if profileData then
		for _, classId in ipairs(profileData.classes.equipped) do
			local entry = Config.class(cfg, classId)
			if entry then
				table.insert(sources, ModifierResolver.sourceFromClass(entry))
			end
		end
		for perkId, perk in pairs(cfg.permanentPerks) do
			if perkId ~= "evidence" then
				local level = profileData.permanentPerks[perkId] or 0
				if level > 0 then
					table.insert(sources, ModifierResolver.sourceFromPerk(perkId, level, perk.valuePerLevel))
				end
			end
		end
	end
	local difficultyEntry = Config.difficulty(cfg, difficulty)
	if difficultyEntry then
		table.insert(sources, ModifierResolver.sourceFromDifficulty(difficulty, difficultyEntry))
	end
	if entitlements then
		table.insert(sources, ModifierResolver.sourceFromEntitlements(entitlements))
	end
	return ModifierResolver.resolve(sources)
end

return RoundModifiers
