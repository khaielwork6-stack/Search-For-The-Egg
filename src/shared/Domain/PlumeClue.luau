--!strict
-- Professor Plume's analysis: the arithmetic behind one clue. Pure and deterministic given its
-- rolls; the server owns the Egg and the rolls, and only the clue's words ever leave it.
--
-- A player pays `plume.rainbowCost` Rainbow Feathers, once per round, and hears ONE vague clue,
-- chosen by the server:
--   direction  which half of the nest the Egg is in, along one axis picked at random: the barn
--              side or the fence side (west/east), or the back or the front (north/south). The
--              halves are the same ones Molly's map uses.
--   depth      how deep it is buried: near the surface, middling, or deep, from the fraction of its
--              column that covers it (`plume.depthBands`).
-- `plume.directionChance` is the chance of a direction clue; the rest are depth clues. Never both,
-- and never anything finer than a half of the nest.

local PlumeClue = {}

export type Kind = "direction" | "depth"
export type Clue = { kind: Kind, key: string, title: string, text: string }

PlumeClue.DIRECTIONS = table.freeze({
	barn = table.freeze({ title = "BARN SIDE", text = "My analysis says the Egg is somewhere on the barn side of the nest." }),
	fence = table.freeze({ title = "FENCE SIDE", text = "My analysis says the Egg is somewhere on the fence side of the nest." }),
	back = table.freeze({ title = "BACK HALF", text = "My analysis says the Egg is somewhere in the back half of the nest." }),
	front = table.freeze({ title = "FRONT HALF", text = "My analysis says the Egg is somewhere in the front half of the nest." }),
})

PlumeClue.DEPTHS = table.freeze({
	shallow = table.freeze({ title = "NEAR THE SURFACE", text = "My analysis says the Egg is buried near the surface." }),
	middling = table.freeze({ title = "MIDDLING DEPTH", text = "My analysis says the Egg is buried at a middling depth." }),
	deep = table.freeze({ title = "BURIED DEEP", text = "My analysis says the Egg is buried deep in the nest." }),
})

-- Plume's short lines over his head.
PlumeClue.LINES = table.freeze({
	ready = "Ten Rainbow Feathers and I can run one analysis. One, mind you.",
	insufficient = "The analyzer only runs on Rainbow Feathers. Bring me %d.",
	used = "I've told you all my analysis can tell. Once a round, that's the rule.",
	found = "The Egg is out! No need for science now.",
	inactive = "My analyzer only works while the search is on.",
})

function PlumeClue.cost(config: { [string]: any }): number
	return config.plume.rainbowCost
end

-- The half of the nest a grid cell is in, along one axis. `axisRoll` in [0, 1): below 0.5 reads
-- barn/fence, otherwise back/front.
function PlumeClue.directionOf(width: number, depth: number, cellX: number, cellZ: number, axisRoll: number): string
	if axisRoll < 0.5 then
		return if (cellX + 0.5) / width < 0.5 then "barn" else "fence"
	end
	return if (cellZ + 0.5) / depth < 0.5 then "back" else "front"
end

-- The depth band of a covering fraction (0 = on top, 1 = at the bottom of its column).
function PlumeClue.depthOf(config: { [string]: any }, depthFraction: number): string
	local bands = config.plume.depthBands
	if depthFraction < bands.shallowBelow then
		return "shallow"
	elseif depthFraction >= bands.deepFrom then
		return "deep"
	end
	return "middling"
end

-- One clue. `kindRoll` and `axisRoll` are server rolls in [0, 1).
function PlumeClue.compose(
	config: { [string]: any },
	egg: { width: number, depth: number, cellX: number, cellZ: number, depthFraction: number },
	kindRoll: number,
	axisRoll: number
): Clue
	if kindRoll < config.plume.directionChance then
		local key = PlumeClue.directionOf(egg.width, egg.depth, egg.cellX, egg.cellZ, axisRoll)
		local words = (PlumeClue.DIRECTIONS :: any)[key]
		return { kind = "direction", key = key, title = words.title, text = words.text }
	end
	local key = PlumeClue.depthOf(config, egg.depthFraction)
	local words = (PlumeClue.DEPTHS :: any)[key]
	return { kind = "depth", key = key, title = words.title, text = words.text }
end

-- Why this player cannot run the analysis right now, or nil when they can.
function PlumeClue.refusal(
	config: { [string]: any },
	options: { searching: boolean, eggOut: boolean, used: boolean, carriedRainbow: number }
): string?
	if options.eggOut then
		return "egg_found"
	elseif not options.searching then
		return "phase"
	elseif options.used then
		return "used"
	elseif options.carriedRainbow < PlumeClue.cost(config) then
		return "insufficient"
	end
	return nil
end

-- Plume's line for a refusal (or the ready line).
function PlumeClue.lineFor(config: { [string]: any }, reason: string?): string
	if reason == "egg_found" then
		return PlumeClue.LINES.found
	elseif reason == "phase" then
		return PlumeClue.LINES.inactive
	elseif reason == "used" then
		return PlumeClue.LINES.used
	elseif reason == "insufficient" then
		return string.format(PlumeClue.LINES.insufficient, PlumeClue.cost(config))
	end
	return PlumeClue.LINES.ready
end

return PlumeClue
