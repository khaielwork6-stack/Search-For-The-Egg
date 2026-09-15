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
		-- Never more feathers than the player is carrying. Without this the log curve jumps two at a
		-- time over the first few pickups on a large bundle, which reads as the stack glitching rather
		-- than filling; capping at `carried` makes the opening feathers land one per pickup and leaves
		-- the log shape in charge from there on.
		return math.clamp(math.floor(math.min(shown, carried) + 1e-9), 1, maxVisible)
	end
	local fullness = carried / math.max(1, capacity)
	return math.clamp(math.ceil(fullness * maxVisible - 1e-9), 1, maxVisible)
end

-- How the shown bundle splits between ordinary and Rainbow feathers. The bundle is a picture of the
-- bag, so it has to carry composition and not just size: a player holding a Rainbow Feather must be
-- able to see it. Any rainbow at all therefore shows at least one rainbow feather, even when the
-- honest proportion would round to none, and the rest of the bundle is ordinary.
function CarriedDisplay.split(
	config: { [string]: any },
	standard: number,
	rainbow: number,
	capacity: number,
	infinite: boolean
): (number, number)
	local total = CarriedDisplay.count(config, math.max(0, standard) + math.max(0, rainbow), capacity, infinite)
	if total <= 0 or rainbow <= 0 then
		return total, 0
	end
	local carried = math.max(1, math.max(0, standard) + math.max(0, rainbow))
	local shown = math.floor(total * (rainbow / carried) + 0.5)
	return total, math.clamp(shown, 1, total)
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
