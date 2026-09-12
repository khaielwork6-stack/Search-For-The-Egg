--!strict
-- Pure composition of class / permanent-perk / difficulty / entitlement / tool modifiers.
-- Sources are identified by a unique id; a duplicate id is applied once (prevents double
-- application when the same class is equipped in two slots or a caller passes a source twice).
-- No service checks class names; they build sources from config and ask this resolver.

local Types = require(script.Parent.Types)

local ModifierResolver = {}

export type ModifierSource = Types.ModifierSource
export type ResolvedModifiers = Types.ResolvedModifiers

local MULTIPLIER_KEYS = table.freeze({
	"bagCapacityMultiplier",
	"sellMultiplier",
	"toolYieldMultiplier",
	"rakeYieldMultiplier",
	"rakeUpgradeCostMultiplier",
	"blastRadiusMultiplier",
	"pileHealthMultiplier",
	"rewardMultiplier",
	"gemValueMultiplier",
	"handGrabMultiplier",
})

function ModifierResolver.identity(): ResolvedModifiers
	local out: any = {
		infiniteBag = false,
		procs = {},
		params = {},
		entitlements = {},
		appliedSources = {},
	}
	for _, key in ipairs(MULTIPLIER_KEYS) do
		out[key] = 1
	end
	return out :: ResolvedModifiers
end

local function assertMultiplier(value: any, sourceId: string, key: string)
	if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
		error("ModifierResolver: source " .. sourceId .. " has invalid " .. key .. " = " .. tostring(value))
	end
end

-- Composes sources multiplicatively. Procs (chance-style values) are additive and clamped to [0,1].
-- Entitlements are OR-ed. Returns a fresh table; inputs are never mutated.
function ModifierResolver.resolve(sources: { ModifierSource }): ResolvedModifiers
	local resolved: any = ModifierResolver.identity()
	local seen: { [string]: boolean } = {}

	for _, source in ipairs(sources) do
		assert(type(source.id) == "string" and #source.id > 0, "modifier source needs an id")
		if seen[source.id] then
			continue -- exact same source: never double-apply
		end
		seen[source.id] = true
		table.insert(resolved.appliedSources, source.id)

		for _, key in ipairs(MULTIPLIER_KEYS) do
			local value = (source :: any)[key]
			if value ~= nil then
				assertMultiplier(value, source.id, key)
				resolved[key] *= value
			end
		end
		if source.infiniteBag then
			resolved.infiniteBag = true
		end
		if source.procs then
			for procId, chance in pairs(source.procs) do
				assertMultiplier(chance, source.id, "procs." .. procId)
				resolved.procs[procId] = math.clamp((resolved.procs[procId] or 0) + chance, 0, 1)
			end
		end
		if source.params then
			for paramId, value in pairs(source.params) do
				assertMultiplier(value, source.id, "params." .. paramId)
				resolved.params[paramId] = math.max(resolved.params[paramId] or 0, value)
			end
		end
		if source.entitlements then
			for entitlementId, owned in pairs(source.entitlements) do
				if owned then
					resolved.entitlements[entitlementId] = true
				end
			end
		end
	end

	table.sort(resolved.appliedSources)
	return resolved :: ResolvedModifiers
end

-- Builds a modifier source from a configured class entry (classes.weights[i]).
-- Effect keys map 1:1 onto source fields; unknown effect keys become procs so nothing is dropped
-- silently and future phases can read them.
function ModifierResolver.sourceFromClass(classEntry: { id: string, effect: { [string]: any } }): ModifierSource
	local effect = classEntry.effect or {}
	local source: any = { id = "class:" .. classEntry.id, kind = "class", procs = {}, params = {}, entitlements = {} }
	for key, value in pairs(effect) do
		if table.find(MULTIPLIER_KEYS, key) then
			source[key] = value
		elseif key == "grantsScoutChick" and value == true then
			source.entitlements.scoutChickRoundGrant = true
		elseif key == "grantsAllPassiveBonuses" and value == true then
			source.entitlements.allPassiveBonuses = true
		elseif
			type(value) == "number" and (string.find(key, "Count$") or string.find(key, "Seconds$") or string.find(key, "Multiplier$"))
		then
			source.params[key] = value -- counts, durations, and tool-specific multipliers are not chances
		elseif type(value) == "number" then
			source.procs[key] = value
		elseif type(value) == "boolean" and value then
			source.entitlements[key] = true
		end
	end
	return source :: ModifierSource
end

-- Builds a source from a permanent perk level (+valuePerLevel per level, linear, ASSUMED A-ECO-10).
function ModifierResolver.sourceFromPerk(perkId: string, level: number, valuePerLevel: number): ModifierSource
	assert(level >= 0 and level % 1 == 0, "perk level must be a non-negative integer")
	local multiplier = 1 + level * valuePerLevel
	local source: any = { id = "perk:" .. perkId, kind = "perk" }
	if perkId == "bagSize" then
		source.bagCapacityMultiplier = multiplier
	elseif perkId == "handGrab" then
		source.handGrabMultiplier = multiplier
	elseif perkId == "gemValue" then
		source.gemValueMultiplier = multiplier
	elseif perkId == "featherValue" then
		source.sellMultiplier = multiplier
	else
		error("unknown perk " .. perkId)
	end
	return source :: ModifierSource
end

-- Builds a source from a difficulty entry (difficulty.normal / difficulty.hard).
function ModifierResolver.sourceFromDifficulty(difficultyId: string, entry: { [string]: any }): ModifierSource
	local source: any = {
		id = "difficulty:" .. difficultyId,
		kind = "difficulty",
		pileHealthMultiplier = entry.pileHealthMultiplier,
		toolYieldMultiplier = entry.toolYieldMultiplier,
		sellMultiplier = entry.sellMultiplier,
		rewardMultiplier = entry.rewardMultiplier,
	}
	return source :: ModifierSource
end

function ModifierResolver.sourceFromEntitlements(passes: { [string]: boolean }): ModifierSource
	local source: any = { id = "entitlements", kind = "entitlement", entitlements = {} }
	for passId, owned in pairs(passes) do
		if owned then
			source.entitlements[passId] = true
		end
	end
	if source.entitlements.infiniteBag then
		source.infiniteBag = true
	end
	return source :: ModifierSource
end

ModifierResolver.MULTIPLIER_KEYS = MULTIPLIER_KEYS

return ModifierResolver
