--!strict
-- Injected RNG and weighted selection. The server owns every roll; clients never supply seeds or
-- results. A deterministic PRNG (xorshift-style over integers) is implemented in Luau so tests
-- produce identical sequences in Studio and headless runs.

local WeightedRandom = {}

export type Rng = {
	next: (self: Rng) -> number, -- [0, 1)
	nextInteger: (self: Rng, min: number, max: number) -> number,
	seed: number,
}

export type WeightedEntry = { id: string, weight: number }

local MODULUS = 2 ^ 31 -- Park-Miller style LCG, exact in doubles
local MULTIPLIER = 48271

local Rng = {}
Rng.__index = Rng

-- Deterministic PRNG seeded from an integer; identical sequence for identical seeds.
function WeightedRandom.fromSeed(seed: number): Rng
	assert(type(seed) == "number" and seed == seed, "seed must be a number")
	local state = math.floor(math.abs(seed)) % (MODULUS - 1)
	if state == 0 then
		state = 1
	end
	local self = setmetatable({ seed = seed, _state = state }, Rng)
	return (self :: any) :: Rng
end

function Rng.next(self): number
	local state = (self :: any)._state
	state = (state * MULTIPLIER) % (MODULUS - 1);
	(self :: any)._state = state
	return (state - 1) / (MODULUS - 2)
end

function Rng.nextInteger(self, min: number, max: number): number
	assert(max >= min, "max must be >= min")
	local r: number = (self :: any):next()
	return min + math.floor(r * (max - min + 1))
end

-- Wraps a function returning [0,1) (e.g. Random.new():NextNumber) as an Rng.
function WeightedRandom.fromFunction(fn: () -> number): Rng
	local self = { seed = -1 }
	function self.next(_)
		local r = fn()
		assert(r >= 0 and r < 1, "rng function must return [0,1)")
		return r
	end
	function self.nextInteger(_, min: number, max: number)
		return min + math.floor(fn() * (max - min + 1))
	end
	return (self :: any) :: Rng
end

function WeightedRandom.totalWeight(entries: { WeightedEntry }): number
	local total = 0
	for _, entry in ipairs(entries) do
		assert(type(entry.weight) == "number" and entry.weight >= 0, "weights must be non-negative numbers")
		total += entry.weight
	end
	return total
end

-- Selects an entry by a roll in [0,1). Deterministic boundary behaviour: an entry owns the
-- half-open interval [cumulativeStart, cumulativeEnd). Zero-weight entries are never chosen.
function WeightedRandom.selectByRoll(entries: { WeightedEntry }, roll: number): WeightedEntry
	assert(#entries > 0, "no entries")
	assert(roll >= 0 and roll < 1, "roll must be in [0,1)")
	local total = WeightedRandom.totalWeight(entries)
	assert(total > 0, "total weight must be > 0")
	local target = roll * total
	local cumulative = 0
	local last: WeightedEntry? = nil
	for _, entry in ipairs(entries) do
		if entry.weight > 0 then
			cumulative += entry.weight
			last = entry
			if target < cumulative then
				return entry
			end
		end
	end
	-- Floating error guard: fall back to the last positive-weight entry.
	return last :: WeightedEntry
end

function WeightedRandom.select(entries: { WeightedEntry }, rng: Rng): WeightedEntry
	return WeightedRandom.selectByRoll(entries, rng:next())
end

-- Returns the [start, finish) interval each id owns on the [0,1) roll line. Used by boundary tests.
function WeightedRandom.intervals(entries: { WeightedEntry }): { [string]: { start: number, finish: number } }
	local total = WeightedRandom.totalWeight(entries)
	local out = {}
	local cumulative = 0
	for _, entry in ipairs(entries) do
		local start = cumulative / total
		cumulative += entry.weight
		out[entry.id] = { start = start, finish = cumulative / total }
	end
	return out
end

export type LuckPolicy = { mode: string, rareWeightThreshold: number }

-- ASSUMED policy (A-CLS-01): entries whose weight is at or below the threshold are doubled, and the
-- added probability is removed from the `newcomer` baseline so the total stays exactly 100.
-- Isolated here so a later evidence change touches one function.
function WeightedRandom.applyLuckTransform(entries: { WeightedEntry }, policy: LuckPolicy, baselineId: string?): { WeightedEntry }
	assert(
		policy.mode == "double_odds_at_or_below_weight_then_renormalize_from_newcomer",
		"unknown luck transform mode " .. tostring(policy.mode)
	)
	local baseline = baselineId or "newcomer"
	local total = WeightedRandom.totalWeight(entries)
	local out: { WeightedEntry } = {}
	local added = 0
	local baselineIndex: number? = nil
	for index, entry in ipairs(entries) do
		local weight = entry.weight
		if entry.id == baseline then
			baselineIndex = index
		elseif weight <= policy.rareWeightThreshold then
			added += weight
			weight = weight * 2
		end
		table.insert(out, { id = entry.id, weight = weight })
	end
	assert(baselineIndex ~= nil, "luck transform requires a baseline entry '" .. baseline .. "'")
	local newBaseline = out[baselineIndex :: number].weight - added
	assert(newBaseline >= 0, "luck transform would make the baseline weight negative")
	out[baselineIndex :: number].weight = newBaseline
	-- Exact renormalization guard against floating error.
	local newTotal = WeightedRandom.totalWeight(out)
	if math.abs(newTotal - total) > 1e-9 then
		local scale = total / newTotal
		for _, entry in ipairs(out) do
			entry.weight *= scale
		end
	end
	return out
end

return WeightedRandom
