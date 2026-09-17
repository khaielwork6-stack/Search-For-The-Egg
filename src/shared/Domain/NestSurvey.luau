--!strict
-- Molly the Mole's survey: up to three paid readings per party per round. The nest is split into
-- four large, named areas on a top-down map; the player picks one, pays the next crate, and hears
-- exactly one word back: STRONG, WEAK or NO SIGNAL. Pure and deterministic; the server owns the
-- Egg's cell and only the word ever leaves it.
--
-- The map is fixed to the yard, never to the camera: columns run BARN (west, -X) to FENCE (east,
-- +X) and rows run BACK (north, -Z, away from the gate) to FRONT (south, +Z, where players arrive).
--
--              BACK
--        +------------+------------+
--        | BACK BARN  | BACK FENCE |
--   BARN +------------+------------+ FENCE
--        | FRONT BARN | FRONT FENCE|
--        +------------+------------+
--              FRONT
--
-- The rule (config `survey.weakBorderFraction`, a fraction of the nest's width and depth):
--   STRONG    the Egg's cell is inside the chosen area.
--   WEAK      it is outside, but within weakBorderFraction of the chosen area's border - the chosen
--             area grown by that margin on every side (so just across a border, or just across the
--             centre corner, reads WEAK).
--   NO SIGNAL anything else.
-- No position, cell, sub-area or distance is ever projected.

local NestSurvey = {}

export type Signal = "strong" | "weak" | "none"

-- Row-major, back row first, barn column first.
NestSurvey.REGIONS = table.freeze({ "backBarn", "backFence", "frontBarn", "frontFence" }) :: { string }
NestSurvey.REGION_NAMES = table.freeze({
	backBarn = "BACK BARN",
	backFence = "BACK FENCE",
	frontBarn = "FRONT BARN",
	frontFence = "FRONT FENCE",
})
NestSurvey.LANDMARKS = table.freeze({ left = "BARN", right = "FENCE", top = "BACK", bottom = "FRONT" })

NestSurvey.WORDS = table.freeze({
	strong = table.freeze({ title = "STRONG SIGNAL", short = "STRONG", text = "Strong signal! The Egg is somewhere in this area." }),
	weak = table.freeze({ title = "WEAK SIGNAL", short = "WEAK", text = "A faint hum. The Egg is close to this area, but not in it." }),
	none = table.freeze({ title = "NO SIGNAL", short = "NO SIGNAL", text = "Nothing here, and nothing close. Search somewhere else." }),
})

-- Molly's lines. `insufficient` takes the next crate's size.
NestSurvey.LINES = table.freeze({
	insufficient = "Bring me %d normal feathers for the next crate and I'll have a listen.",
	ready = "Four areas, one crate. Pick an area and I'll tell you what I hear.",
	used = "That's every survey my drill can take this round. The rest is shovel work.",
	exposed = "Forget the equipment - the Egg has been exposed!",
	inactive = "My equipment only works while the search is active.",
})

-- ----------------------------------------------------------------------------------------------
-- Config

-- The ordered crate sizes, one per survey.
function NestSurvey.costs(config: { [string]: any }): { number }
	return config.survey.crateCosts
end

-- How many surveys a party may buy in one round.
function NestSurvey.maxSurveys(config: { [string]: any }): number
	return math.min(config.survey.maxPerRound, #config.survey.crateCosts)
end

-- The price of the next survey after `usedCount` readings; nil once the limit is reached.
function NestSurvey.nextCost(config: { [string]: any }, usedCount: number): number?
	if usedCount >= NestSurvey.maxSurveys(config) then
		return nil
	end
	return config.survey.crateCosts[usedCount + 1]
end

-- ----------------------------------------------------------------------------------------------
-- Areas

function NestSurvey.isRegion(value: any): boolean
	return type(value) == "string" and table.find(NestSurvey.REGIONS, value) ~= nil
end

-- "BACK BARN".
function NestSurvey.name(region: string): string
	return (NestSurvey.REGION_NAMES :: any)[region] or string.upper(region)
end

-- Row 1 (back) or 2 (front), column 1 (barn) or 2 (fence).
function NestSurvey.rowCol(region: string): (number, number)
	local index = table.find(NestSurvey.REGIONS, region) or 1
	return (index - 1) // 2 + 1, (index - 1) % 2 + 1
end

function NestSurvey.regionAt(row: number, col: number): string
	return NestSurvey.REGIONS[(math.clamp(row, 1, 2) - 1) * 2 + math.clamp(col, 1, 2)]
end

-- Where a grid cell's centre sits on the nest, 0..1 along x (barn -> fence) and z (back -> front).
function NestSurvey.normalised(width: number, depth: number, cellX: number, cellZ: number): (number, number)
	return (cellX + 0.5) / width, (cellZ + 0.5) / depth
end

-- The area of a grid cell: halves of the grid along x and z.
function NestSurvey.regionOfCell(width: number, depth: number, cellX: number, cellZ: number): string
	local u, v = NestSurvey.normalised(width, depth, cellX, cellZ)
	return NestSurvey.regionAt(if v < 0.5 then 1 else 2, if u < 0.5 then 1 else 2)
end

-- The reading for `region` given the Egg's grid cell. See the rule at the top of this file.
function NestSurvey.signal(config: { [string]: any }, width: number, depth: number, region: string, cellX: number, cellZ: number): Signal
	local u, v = NestSurvey.normalised(width, depth, cellX, cellZ)
	local row, col = NestSurvey.rowCol(region)
	local minU, maxU = (col - 1) * 0.5, col * 0.5
	local minV, maxV = (row - 1) * 0.5, row * 0.5
	local outU = math.max(0, minU - u, u - maxU)
	local outV = math.max(0, minV - v, v - maxV)
	if outU == 0 and outV == 0 then
		-- On the centre line a cell belongs to exactly one area: the same halves as regionOfCell.
		if NestSurvey.regionOfCell(width, depth, cellX, cellZ) == region then
			return "strong"
		end
	end
	local margin = config.survey.weakBorderFraction
	if outU <= margin and outV <= margin then
		return "weak"
	end
	return "none"
end

-- Controller / keyboard navigation over the 2x2, clamped at the edges.
function NestSurvey.step(region: string, dRow: number, dCol: number): string
	local row, col = NestSurvey.rowCol(region)
	return NestSurvey.regionAt(row + dRow, col + dCol)
end

-- ----------------------------------------------------------------------------------------------
-- State and projection

export type Reading = {
	index: number,
	region: string,
	signal: Signal,
	byUserId: number,
}

export type State = { readings: { Reading }, count: number }

function NestSurvey.newState(): State
	return { readings = {}, count = 0 }
end

-- One reading as clients see it: the area, the word, and who paid.
function NestSurvey.projectReading(reading: Reading): { [string]: any }
	local words = (NestSurvey.WORDS :: any)[reading.signal]
	return {
		index = reading.index,
		region = reading.region,
		name = NestSurvey.name(reading.region),
		signal = reading.signal,
		title = words.title,
		short = words.short,
		text = words.text,
		byUserId = reading.byUserId,
	}
end

-- What clients receive: every reading so far, the count, what is left and what it costs. Always a
-- table (an unused survey is `count = 0`), so the map can show the price before the first scan.
function NestSurvey.project(config: { [string]: any }, state: State?): { [string]: any }
	local readings = {}
	local count = if state then state.count else 0
	if state then
		for _, reading in ipairs(state.readings) do
			table.insert(readings, NestSurvey.projectReading(reading))
		end
	end
	local max = NestSurvey.maxSurveys(config)
	return {
		readings = readings,
		count = count,
		latest = readings[#readings],
		max = max,
		usesLeft = math.max(0, max - count),
		nextCost = NestSurvey.nextCost(config, count),
	}
end

-- The latest reading of each area, for the map and the board.
function NestSurvey.latestByRegion(readings: { { [string]: any } }): { [string]: { [string]: any } }
	local out = {}
	for _, reading in ipairs(readings) do
		if NestSurvey.isRegion(reading.region) then
			out[reading.region] = reading
		end
	end
	return out
end

-- Which of Molly's lines fits right now.
function NestSurvey.lineFor(
	config: { [string]: any },
	options: { active: boolean, exposed: boolean, count: number, carriedStandard: number }
): string
	-- An exposed Egg is still a live round: that line wins over "inactive".
	if options.exposed then
		return NestSurvey.LINES.exposed
	end
	if not options.active then
		return NestSurvey.LINES.inactive
	end
	local cost = NestSurvey.nextCost(config, options.count)
	if cost == nil then
		return NestSurvey.LINES.used
	end
	if options.carriedStandard < cost then
		return string.format(NestSurvey.LINES.insufficient, cost)
	end
	return NestSurvey.LINES.ready
end

return NestSurvey
