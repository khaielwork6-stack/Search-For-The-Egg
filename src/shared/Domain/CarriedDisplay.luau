--!strict
-- How many feathers the handless carried stack shows for a bag (owner requirement): it grows one by
-- one with bag fullness up to `maxVisibleFeathers`, never past it. A finite bag maps fullness
-- linearly (full bag = every visible feather); an infinite bag grows logarithmically so the first
-- feathers show quickly and the cap is reached at `infiniteCapCount` carried, while the bag counter
-- keeps showing the true amount. Pure so it is unit-tested headlessly.

local CarriedDisplay = {}

function CarriedDisplay.count(config: { [string]: any }, carried: number, capacity: number, infinite: boolean): number
	local carriedStack = config.hud.carriedStack
	local maxVisible = carriedStack.maxVisibleFeathers
	if carried <= 0 then
		return 0
	end
	if infinite then
		-- One feather shows one; the cap count shows them all; log-spaced in between.
		local cap = math.max(2, carriedStack.infiniteCapCount)
		local shown = 1 + (maxVisible - 1) * math.log(math.max(1, carried)) / math.log(cap)
		return math.clamp(math.floor(shown + 1e-9), 1, maxVisible)
	end
	local fullness = carried / math.max(1, capacity)
	return math.clamp(math.ceil(fullness * maxVisible - 1e-9), 1, maxVisible)
end

-- Coarse label for reports and debug snapshots.
function CarriedDisplay.tier(count: number, maxVisible: number): string
	if count <= 0 then
		return "empty"
	elseif count >= maxVisible then
		return "full"
	end
	return "partial"
end

return CarriedDisplay
