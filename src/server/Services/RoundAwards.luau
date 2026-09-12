--!strict
-- Shared award path for every collection source (Hand, Rake, Charge, Vac, bundles). Applies the
-- configured overflow policy: the bag is clamped to capacity and tool overflow becomes a short-lived
-- server-owned bundle (`collection.overflowBundleSeconds`) that any party member can gather.
-- Bag values can never exceed capacity.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local EconomyMath = require(Shared.EconomyMath)

local RoundAwards = {}

export type Award = {
	standard: number,
	rainbow: number,
	overflowStandard: number,
	overflowRainbow: number,
	carried: number,
	capacity: number,
	infinite: boolean,
	bagFull: boolean,
}

-- Adds feathers to `state`'s bag up to `capacity`. Returns the accepted/overflow split.
function RoundAwards.award(state: any, standard: number, rainbow: number, capacity: EconomyMath.BagCapacity): Award
	local carried = state.carriedStandard + state.carriedRainbow
	local acceptedTotal = EconomyMath.clampToBag(carried, standard + rainbow, capacity)
	-- Rainbow feathers are accepted first (they are rarer), then standard.
	local acceptedRainbow = math.min(rainbow, acceptedTotal)
	local acceptedStandard = acceptedTotal - acceptedRainbow
	state.carriedStandard += acceptedStandard
	state.carriedRainbow += acceptedRainbow
	state.contribution.feathersCollected += acceptedTotal
	local nowCarried = state.carriedStandard + state.carriedRainbow
	return {
		standard = acceptedStandard,
		rainbow = acceptedRainbow,
		overflowStandard = standard - acceptedStandard,
		overflowRainbow = rainbow - acceptedRainbow,
		carried = nowCarried,
		capacity = if capacity.infinite then -1 else capacity.capacity,
		infinite = capacity.infinite,
		bagFull = not capacity.infinite and nowCarried >= capacity.capacity,
	}
end

-- Creates a bundle record in the runtime for overflow. Returns nil when there is nothing to drop.
function RoundAwards.dropBundle(
	runtime: any,
	idGen: () -> string,
	position: Vector3,
	standard: number,
	rainbow: number,
	expiresAt: number
): any?
	if standard + rainbow <= 0 then
		return nil
	end
	local bundle = { id = idGen(), position = position, standard = standard, rainbow = rainbow, expiresAt = expiresAt }
	runtime.bundles[bundle.id] = bundle
	return bundle
end

-- Gathers from a bundle into the player's bag (clamped); the remainder stays in the bundle.
function RoundAwards.gatherBundle(runtime: any, bundleId: string, state: any, capacity: EconomyMath.BagCapacity): (Award?, boolean)
	local bundle = runtime.bundles[bundleId]
	if not bundle then
		return nil, false
	end
	local award = RoundAwards.award(state, bundle.standard, bundle.rainbow, capacity)
	bundle.standard = award.overflowStandard
	bundle.rainbow = award.overflowRainbow
	local emptied = bundle.standard + bundle.rainbow <= 0
	if emptied then
		runtime.bundles[bundleId] = nil
	end
	return award, emptied
end

-- Removes expired bundles; returns their ids.
function RoundAwards.expireBundles(runtime: any, now: number): { string }
	local expired = {}
	for id, bundle in pairs(runtime.bundles) do
		if now >= bundle.expiresAt then
			runtime.bundles[id] = nil
			table.insert(expired, id)
		end
	end
	return expired
end

return RoundAwards
