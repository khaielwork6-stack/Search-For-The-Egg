--!strict
-- Integer-cents economy primitives. Every currency mutation on the server passes through these
-- helpers so floating-point drift cannot occur. Rounding mode follows selling.cashRounding
-- ("round_half_up_to_cent").

local EconomyMath = {}

export type SaleInput = { standardCount: number, rainbowCount: number }

export type SaleRates = {
	standardCents: number, -- cents per standard feather (integer)
	rainbowMultiplier: number, -- e.g. 5
	classSellMultiplier: number, -- resolved once by ModifierResolver
	perkSellMultiplier: number, -- permanent featherValue perk, resolved once
	difficultySellMultiplier: number?, -- optional, defaults to 1
}

export type SaleResult = {
	standardCount: number,
	rainbowCount: number,
	baseCents: number,
	rainbowCents: number,
	classAdjustedCents: number,
	perkAdjustedCents: number,
	finalCents: number,
}

local function assertFinite(value: number, label: string)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		error("EconomyMath: " .. label .. " must be a finite number, got " .. tostring(value))
	end
end

-- Round half up (away from zero for positives; we never handle negative money).
function EconomyMath.roundHalfUp(value: number): number
	assertFinite(value, "value")
	if value < 0 then
		return -math.floor(-value + 0.5)
	end
	return math.floor(value + 0.5)
end

-- Converts a configured dollar amount (e.g. 0.01, 69.99) into integer cents exactly.
function EconomyMath.dollarsToCents(dollars: number): number
	assertFinite(dollars, "dollars")
	-- Configured prices carry at most two decimals; the epsilon absorbs binary representation
	-- error (1.005 * 100 = 100.4999...) so half-up rounding stays exact.
	local scaled = dollars * 100
	local epsilon = if scaled >= 0 then 1e-7 else -1e-7
	return EconomyMath.roundHalfUp(scaled + epsilon)
end

function EconomyMath.centsToDollars(cents: number): number
	return cents / 100
end

-- "$0.25" style display string. Display only; never parsed back.
function EconomyMath.formatCents(cents: number): string
	assert(cents % 1 == 0, "formatCents expects integer cents")
	local negative = cents < 0
	local abs = math.abs(cents)
	local dollars = math.floor(abs / 100)
	local remainder = abs % 100
	return string.format("%s$%d.%02d", negative and "-" or "", dollars, remainder)
end

-- Multiplies integer cents by a multiplier and rounds once (half up).
function EconomyMath.applyMultiplierCents(cents: number, multiplier: number): number
	assert(cents % 1 == 0, "applyMultiplierCents expects integer cents")
	assertFinite(multiplier, "multiplier")
	assert(multiplier >= 0, "multiplier must be >= 0")
	return EconomyMath.roundHalfUp(cents * multiplier)
end

-- Sale calculation exactly as STATE_MACHINES.md section 5.
function EconomyMath.computeSale(input: SaleInput, rates: SaleRates): SaleResult
	assert(input.standardCount >= 0 and input.standardCount % 1 == 0, "standardCount must be a non-negative integer")
	assert(input.rainbowCount >= 0 and input.rainbowCount % 1 == 0, "rainbowCount must be a non-negative integer")
	assert(rates.standardCents % 1 == 0 and rates.standardCents >= 0, "standardCents must be a non-negative integer")

	local baseCents = input.standardCount * rates.standardCents
	local rainbowCents = EconomyMath.roundHalfUp(input.rainbowCount * rates.standardCents * rates.rainbowMultiplier)
	local difficulty = rates.difficultySellMultiplier or 1
	local classAdjusted = EconomyMath.roundHalfUp((baseCents + rainbowCents) * rates.classSellMultiplier * difficulty)
	local perkAdjusted = EconomyMath.roundHalfUp(classAdjusted * rates.perkSellMultiplier)
	local finalCents = math.max(0, perkAdjusted)

	return {
		standardCount = input.standardCount,
		rainbowCount = input.rainbowCount,
		baseCents = baseCents,
		rainbowCents = rainbowCents,
		classAdjustedCents = classAdjusted,
		perkAdjustedCents = perkAdjusted,
		finalCents = finalCents,
	}
end

-- Clamps a currency balance to configured bounds. Returns the clamped value and whether clamping happened.
function EconomyMath.clampCurrency(value: number, minimum: number, maximum: number): (number, boolean)
	if type(value) ~= "number" or value ~= value then
		return minimum, true
	end
	if value < minimum then
		return minimum, true
	elseif value > maximum then
		return maximum, true
	end
	return value, false
end

-- Adds `amount` (integer) to `balance`, saturating at `maximum`. Returns new balance and amount actually added.
function EconomyMath.addBounded(balance: number, amount: number, maximum: number): (number, number)
	assert(amount % 1 == 0, "amount must be an integer")
	local target = balance + amount
	if target > maximum then
		return maximum, maximum - balance
	end
	if target < 0 then
		return 0, -balance
	end
	return target, amount
end

export type BagCapacityInput = {
	roundBagLevelCapacity: number,
	permanentBagPerkMultiplier: number,
	classBagMultiplier: number,
	infiniteBag: boolean,
}

export type BagCapacity = { infinite: boolean, capacity: number }

-- Bag capacity order from MASTER_SPEC section 6: level capacity * perk * class, floored, unless
-- the Infinite Bag entitlement is active (explicit state, never a giant sentinel).
function EconomyMath.bagCapacity(input: BagCapacityInput): BagCapacity
	if input.infiniteBag then
		return { infinite = true, capacity = 0 }
	end
	local capacity = math.floor(input.roundBagLevelCapacity * input.permanentBagPerkMultiplier * input.classBagMultiplier)
	return { infinite = false, capacity = math.max(0, capacity) }
end

-- Normal collection clamps to free space. Returns amount accepted and amount that overflowed.
function EconomyMath.clampToBag(carried: number, requested: number, capacity: BagCapacity): (number, number)
	assert(requested >= 0, "requested must be >= 0")
	if capacity.infinite then
		return requested, 0
	end
	local free = math.max(0, capacity.capacity - carried)
	local accepted = math.min(free, requested)
	return accepted, requested - accepted
end

-- Permanent perk cost curve: baseGemCost * costGrowth ^ level, rounded half up to whole gems.
function EconomyMath.perkCostGems(baseGemCost: number, costGrowth: number, level: number): number
	assert(level >= 0 and level % 1 == 0, "level must be a non-negative integer")
	return EconomyMath.roundHalfUp(baseGemCost * (costGrowth ^ level))
end

-- Applies a discount multiplier to a cent price exactly once, deterministic rounding.
function EconomyMath.discountedCents(cents: number, discountMultiplier: number): number
	return EconomyMath.applyMultiplierCents(cents, discountMultiplier)
end

return EconomyMath
