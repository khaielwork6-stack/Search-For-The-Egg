--!strict
-- Pure class-roll domain (MASTER_SPEC 10, ASSUMED A-CLS-01/05/06). Builds the effective weight table
-- (verified base weights, 2x Luck transform when the entitlement is owned), rolls with injected RNG,
-- resolves slot counts from entitlements, and describes odds for display. The server owns every
-- roll; the client only animates toward the committed result.

local WeightedRandom = require(script.Parent.Parent.WeightedRandom)

local ClassRoll = {}

export type Entry = WeightedRandom.WeightedEntry

ClassRoll.BASELINE = "newcomer"

-- Effective weights: base config weights, transformed once when 2x Luck is owned.
function ClassRoll.weights(cfg: { [string]: any }, doubleLuck: boolean): { Entry }
	local entries: { Entry } = {}
	for _, entry in ipairs(cfg.classes.weights) do
		table.insert(entries, { id = entry.id, weight = entry.weight })
	end
	if doubleLuck then
		return WeightedRandom.applyLuckTransform(entries, cfg.classes.luckTransform, ClassRoll.BASELINE)
	end
	return entries
end

-- Displayed odds (percent, two decimals) per class in config order.
function ClassRoll.odds(
	cfg: { [string]: any },
	doubleLuck: boolean
): { { id: string, displayName: string, percent: number, rarity: string } }
	local weights = ClassRoll.weights(cfg, doubleLuck)
	local total = WeightedRandom.totalWeight(weights)
	local out = {}
	for index, entry in ipairs(weights) do
		out[index] = {
			id = entry.id,
			displayName = cfg.classes.weights[index].displayName,
			percent = math.floor((entry.weight / total) * 10000 + 0.5) / 100,
			rarity = ClassRoll.rarity(cfg.classes.weights[index].weight),
		}
	end
	return out
end

-- Rarity band from the base weight (presentation only; never gameplay).
function ClassRoll.rarity(weight: number): string
	if weight >= 25 then
		return "common"
	elseif weight >= 9 then
		return "uncommon"
	elseif weight >= 3 then
		return "rare"
	elseif weight >= 1 then
		return "epic"
	end
	return "legendary"
end

-- Slot count: default slots plus the extra-slot entitlement, capped by config.
function ClassRoll.slotCount(cfg: { [string]: any }, entitlements: { [string]: boolean }?): number
	local slots = cfg.classes.slotsDefault
	if entitlements and entitlements.extraClassSlot then
		slots += 1
	end
	return math.min(slots, cfg.classes.maximumSlots)
end

-- Animation duration the client must land before revealing (Fast Rolls entitlement shortens it).
function ClassRoll.animationSeconds(cfg: { [string]: any }, entitlements: { [string]: boolean }?): number
	if entitlements and entitlements.fastRolls then
		return cfg.lobby.classRollFastAnimationSeconds
	end
	return cfg.lobby.classRollAnimationSeconds
end

-- Rolls one class with the injected RNG. Returns the id and the roll used (for evidence/tests).
function ClassRoll.roll(cfg: { [string]: any }, rng: WeightedRandom.Rng, doubleLuck: boolean): (string, number)
	local roll = rng:next()
	local entry = WeightedRandom.selectByRoll(ClassRoll.weights(cfg, doubleLuck), roll)
	return entry.id, roll
end

-- Places `classId` into `slot`: a class never occupies two slots, empty lower slots fill with the
-- baseline, and the list never exceeds slotCount. Mutates `classes.equipped`.
local function place(classes: { [string]: any }, classId: string, slot: number, slotCount: number)
	local equipped = table.clone(classes.equipped)
	for index = #equipped, 1, -1 do
		if equipped[index] == classId and index ~= slot then
			table.remove(equipped, index)
		end
	end
	while #equipped < slot - 1 do
		table.insert(equipped, ClassRoll.BASELINE)
	end
	equipped[slot] = classId
	while #equipped > slotCount do
		table.remove(equipped)
	end
	-- Baseline fillers can collide with a baseline placement: keep the first occurrence of any id.
	local seen: { [string]: boolean } = {}
	local unique = {}
	for _, id in ipairs(equipped) do
		if not seen[id] then
			seen[id] = true
			table.insert(unique, id)
		end
	end
	classes.equipped = unique
	classes.slotCount = slotCount
end

-- Applies a roll result to the profile classes block: owns the class and equips it in `slot`
-- (replacing the previous occupant; a duplicate simply re-equips, A-CLS-05). Returns `duplicate`.
function ClassRoll.applyResult(classes: { [string]: any }, classId: string, slot: number, slotCount: number): boolean
	local duplicate = classes.owned[classId] == true
	classes.owned[classId] = true
	classes.rollCount = (classes.rollCount or 0) + 1
	place(classes, classId, slot, slotCount)
	return duplicate
end

-- Equips an owned class into a slot (same single-occupancy rule). Returns ok, reason.
function ClassRoll.equip(classes: { [string]: any }, classId: string, slot: number, slotCount: number): (boolean, string?)
	if classes.owned[classId] ~= true then
		return false, "not_owned"
	end
	if slot < 1 or slot > slotCount or slot % 1 ~= 0 then
		return false, "invalid_slot"
	end
	place(classes, classId, slot, slotCount)
	return true, nil
end

return ClassRoll
