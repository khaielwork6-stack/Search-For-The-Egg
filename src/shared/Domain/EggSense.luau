--!strict
-- Professor Plume's Egg Sense rod: the arithmetic behind a loan and a reading.
--
-- Everything here is pure and deterministic. The server knows where the Egg is; this module turns
-- the distance between the player's aim point and the Egg into one HEAT number in [0, 1], and heat
-- is the only thing that ever leaves the server. It is quantised to HEAT_STEP so two readings a
-- hair apart come back identical: the rod says "warmer" and "colder", never "3.7 studs that way",
-- and no client can triangulate the Egg from a few precise samples.
--
-- Heat drives everything the player feels: the tick rate (Geiger-counter style, faster when
-- warmer), the crystal's colour (cold blue to warm orange), the haptic pulse and the reticle tint.

local EggSense = {}

-- Heat resolution. Twenty steps (0.05 each) give 21 distinct readings across the rod's radius,
-- which is plenty to feel and too coarse to measure with.
EggSense.HEAT_STEPS = 20
EggSense.HEAT_STEP = 1 / EggSense.HEAT_STEPS
-- Heat at or above this is "locked": the rod is on top of the Egg as far as it can tell.
EggSense.LOCK_HEAT = 0.95

export type Point = { x: number, y: number, z: number }

-- Plume's short lines. Never composed at runtime; the client picks one by state.
EggSense.LINES = table.freeze({
	none = "Feathers in, rod out. One hundred of the ordinary kind and the Egg Sense is yours for a spell.",
	insufficient = "The rod runs on feathers, not enthusiasm. Come back with more.",
	lend = "Careful, it bites when it's warm. Sweep the nest and listen for the ticking!",
	active = "Less talking, more sweeping. The rod is losing its charge while you stand here.",
	expired = "And there goes the charge. Feathers cannot hold a reading forever, you know.",
	limit = "Three loans is my limit. The rod needs a rest, and frankly so do I.",
	found = "The Egg is out! Put the rod down before it singes your eyebrows.",
})

-- Normal feathers the next loan costs, or nil when the party has used every loan it may.
function EggSense.nextCost(config: { [string]: any }, usedCount: number): number?
	local costs = config.plume.costsStandard
	local maximum = math.min(config.plume.maxPerRound, #costs)
	if usedCount >= maximum then
		return nil
	end
	return costs[usedCount + 1]
end

function EggSense.maxUses(config: { [string]: any }): number
	return math.min(config.plume.maxPerRound, #config.plume.costsStandard)
end

-- Heat for one reading: 1 at the Egg, 0 at the rod's radius and beyond, quantised. Distance is
-- the full 3D distance, so a buried Egg reads warmer as the nest above it is dug away.
function EggSense.heatFor(config: { [string]: any }, aim: Point, egg: Point): number
	local radius = config.plume.rod.radiusStuds
	local dx, dy, dz = aim.x - egg.x, aim.y - egg.y, aim.z - egg.z
	local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
	local raw = math.clamp(1 - distance / math.max(radius, 1e-6), 0, 1)
	return EggSense.quantise(raw)
end

function EggSense.quantise(heat: number): number
	-- Division by the step count (not multiplication by the step) so 19 steps is exactly 0.95.
	local steps = math.floor(math.clamp(heat, 0, 1) * EggSense.HEAT_STEPS + 0.5)
	return math.clamp(steps / EggSense.HEAT_STEPS, 0, 1)
end

-- Ticks per second at a given heat: linear from the cold rate to the hot rate.
function EggSense.tickHzFor(config: { [string]: any }, heat: number): number
	local rod = config.plume.rod
	local h = math.clamp(heat, 0, 1)
	return rod.minTickHz + (rod.maxTickHz - rod.minTickHz) * h
end

function EggSense.tickIntervalFor(config: { [string]: any }, heat: number): number
	return 1 / EggSense.tickHzFor(config, heat)
end

function EggSense.isLocked(heat: number): boolean
	return heat >= EggSense.LOCK_HEAT
end

-- Crystal colour at a given heat, as three channels in [0, 255] (the client wraps it in a Color3).
function EggSense.colorFor(config: { [string]: any }, heat: number): (number, number, number)
	local rod = config.plume.rod
	local h = math.clamp(heat, 0, 1)
	local cold, warm = rod.coldColor, rod.warmColor
	return cold[1] + (warm[1] - cold[1]) * h, cold[2] + (warm[2] - cold[2]) * h, cold[3] + (warm[3] - cold[3]) * h
end

-- The round-owned loan state, as created for a fresh round. `activeUntilByUserId` is the loan
-- book: who holds a rod and until when (server monotonic seconds).
export type State = {
	count: number,
	activeUntilByUserId: { [number]: number },
}

function EggSense.newState(): State
	return { count = 0, activeUntilByUserId = {} }
end

-- What clients receive: the counters, the price list and who holds a live rod (with the seconds
-- left, never a timestamp the client could not read). Nothing about the Egg is in it.
function EggSense.project(config: { [string]: any }, state: State?, now: number): { [string]: any }
	local count = 0
	local active = {}
	if state then
		count = state.count
		for userId, until_ in pairs(state.activeUntilByUserId) do
			local remaining = until_ - now
			if remaining > 0 then
				table.insert(active, { userId = userId, remainingMs = math.floor(remaining * 1000 + 0.5) })
			end
		end
		table.sort(active, function(a, b)
			return a.userId < b.userId
		end)
	end
	return {
		count = count,
		max = EggSense.maxUses(config),
		usesLeft = math.max(0, EggSense.maxUses(config) - count),
		nextCost = EggSense.nextCost(config, count),
		costs = table.clone(config.plume.costsStandard),
		activeSeconds = config.plume.rod.activeSeconds,
		active = active,
	}
end

-- Which of Plume's lines fits the party's progress, the player's bag and the Egg right now.
function EggSense.lineFor(config: { [string]: any }, count: number, carriedStandard: number, eggFound: boolean, holdingRod: boolean): string
	if eggFound then
		return EggSense.LINES.found
	end
	if holdingRod then
		return EggSense.LINES.active
	end
	local cost = EggSense.nextCost(config, count)
	if cost == nil then
		return EggSense.LINES.limit
	end
	if carriedStandard < cost then
		return if count == 0 then EggSense.LINES.none else EggSense.LINES.insufficient
	end
	return EggSense.LINES.none
end

return EggSense
