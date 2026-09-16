--!strict
-- Professor Plume's clues: what a Rainbow Feather analysis can say about where the Egg is.
--
-- Everything here is pure and deterministic. The server knows the Egg's exact cell and slot; this
-- module turns that into one of three DIRECTION bands and one of three DEPTH bands, and the only
-- thing that ever leaves the server is the band name and its fixed sentence. There is no distance,
-- no arrow, no coordinate and no random wording anywhere in a clue: the same Egg always produces
-- the same words, so a clue can be checked against the Egg in a test.
--
-- Direction is measured along the line from the middle of the mound towards the barn: the Egg's
-- offset from the centre, projected on that line and divided by the mound's radius, gives a number
-- in about [-1, 1]. Past +sideFraction is the barn side, past -sideFraction the fence side (the
-- yard fence closes the far side of the mound), and the stripe between is the centre.
--
-- Depth is how far down its column the Egg sits: 0 is the surface, 1 is the sand. The bands split
-- the window the spawner actually uses (SYSTEM_CONFIG eggSpawn removal fractions), not [0, 1], or
-- every clue would read "packed middle".

local NestClues = {}

export type Category = "direction" | "depth"
export type Band = "barn" | "center" | "fence" | "outer" | "middle" | "core"

NestClues.CATEGORIES = table.freeze({ "direction", "depth" }) :: { string }

-- The fixed words for every band. Title is the stamp on the card; text is the sentence under it.
NestClues.WORDS = table.freeze({
	direction = table.freeze({
		barn = table.freeze({ title = "BARN SIDE", text = "The nest lies on the barn side of the mound." }),
		center = table.freeze({ title = "CENTER", text = "The nest lies near the middle of the mound." }),
		fence = table.freeze({ title = "FENCE SIDE", text = "The nest lies on the fence side of the mound." }),
	}),
	depth = table.freeze({
		outer = table.freeze({ title = "OUTER LAYER", text = "The Egg rests in the outer feathers, not far below the surface." }),
		middle = table.freeze({ title = "PACKED MIDDLE", text = "The Egg is packed into the middle of the mound." }),
		core = table.freeze({ title = "NEST CORE", text = "The Egg sits deep in the nest core, close to the ground." }),
	}),
})

NestClues.LABELS = table.freeze({ direction = "DIRECTION", depth = "DEPTH" })

-- Plume's lines, by how far the party has got. Never composed at runtime.
NestClues.LINES = table.freeze({
	none = "Rainbow Feathers remember the nest. Bring me three, and I can narrow the search.",
	insufficient = "I need more Rainbow Feathers for a reliable reading.",
	one = "Interesting... bring me five more and I can complete the analysis.",
	all = "That is everything the feathers can tell us. The rest is up to you.",
	found = "No more analysis needed - retrieve the Egg!",
})

function NestClues.isCategory(value: any): boolean
	return value == "direction" or value == "depth"
end

-- Rainbow Feathers the next clue costs, or nil when the party has bought every clue it may.
function NestClues.nextCost(config: { [string]: any }, unlockedCount: number): number?
	local costs = config.clues.costsRainbow
	local maximum = math.min(config.clues.maxPerRound, #costs)
	if unlockedCount >= maximum then
		return nil
	end
	return costs[unlockedCount + 1]
end

function NestClues.maxClues(config: { [string]: any }): number
	return math.min(config.clues.maxPerRound, #config.clues.costsRainbow)
end

-- Unit vector (x, z) from the mound's centre towards the barn, from the chapter layout.
function NestClues.barnAxis(layout: { [string]: any }): (number, number)
	local dx = layout.clueBarn.X - layout.nestCenter.X
	local dz = layout.clueBarn.Z - layout.nestCenter.Z
	local length = math.sqrt(dx * dx + dz * dz)
	if length <= 0 then
		return 0, -1
	end
	return dx / length, dz / length
end

-- Signed distance along the barn axis, as a fraction of the mound radius (about -1 .. 1).
function NestClues.sideFraction(layout: { [string]: any }, radius: number, worldX: number, worldZ: number): number
	local ax, az = NestClues.barnAxis(layout)
	local ox = worldX - layout.nestCenter.X
	local oz = worldZ - layout.nestCenter.Z
	return (ox * ax + oz * az) / math.max(radius, 1e-6)
end

function NestClues.directionBand(config: { [string]: any }, sideFraction: number): Band
	local edge = config.clues.direction.sideFraction
	if sideFraction >= edge then
		return "barn"
	elseif sideFraction <= -edge then
		return "fence"
	end
	return "center"
end

-- `depthFraction` is 0 at the surface of the Egg's column and 1 at the sand.
function NestClues.depthBand(config: { [string]: any }, depthFraction: number): Band
	local depth = config.clues.depth
	if depthFraction < depth.outerMaxFraction then
		return "outer"
	elseif depthFraction < depth.coreMinFraction then
		return "middle"
	end
	return "core"
end

-- The clue for one category from the Egg's pile-local facts. The caller (the server) resolves
-- the Egg; nothing about its exact place survives into the result.
function NestClues.clueFor(
	config: { [string]: any },
	layout: { [string]: any },
	category: string,
	egg: { worldX: number, worldZ: number, radius: number, depthFraction: number }
): { category: string, band: string, title: string, text: string }?
	local band: Band
	if category == "direction" then
		band = NestClues.directionBand(config, NestClues.sideFraction(layout, egg.radius, egg.worldX, egg.worldZ))
	elseif category == "depth" then
		band = NestClues.depthBand(config, egg.depthFraction)
	else
		return nil
	end
	local words = (NestClues.WORDS :: any)[category][band]
	return { category = category, band = band, title = words.title, text = words.text }
end

-- The round-owned clue state, as created for a fresh round.
export type State = {
	unlocked: { [string]: { category: string, band: string, title: string, text: string, byUserId: number, order: number } },
	count: number,
}

function NestClues.newState(): State
	return { unlocked = {}, count = 0 }
end

-- What clients receive: every unlocked clue's category, band and words plus the counters. Missing
-- categories are simply absent, which the Book shows as UNKNOWN.
function NestClues.project(config: { [string]: any }, state: State?): { [string]: any }
	local unlocked = {}
	local count = 0
	if state then
		count = state.count
		for category, entry in pairs(state.unlocked) do
			unlocked[category] = {
				category = entry.category,
				band = entry.band,
				title = entry.title,
				text = entry.text,
				byUserId = entry.byUserId,
				order = entry.order,
			}
		end
	end
	return {
		unlocked = unlocked,
		count = count,
		max = NestClues.maxClues(config),
		nextCost = NestClues.nextCost(config, count),
		costs = table.clone(config.clues.costsRainbow),
	}
end

-- Which of Plume's lines fits the party's progress (and the player's bag) right now.
function NestClues.lineFor(config: { [string]: any }, count: number, carriedRainbow: number, eggFound: boolean): string
	if eggFound then
		return NestClues.LINES.found
	end
	local cost = NestClues.nextCost(config, count)
	if cost == nil then
		return NestClues.LINES.all
	end
	if carriedRainbow < cost then
		return if count == 0 then NestClues.LINES.none else NestClues.LINES.insufficient
	end
	return if count == 0 then NestClues.LINES.none else NestClues.LINES.one
end

return NestClues
