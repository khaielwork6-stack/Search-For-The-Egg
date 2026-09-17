--!strict
-- Molly the Mole's survey: up to three paid readings per party per round, each one narrowing the
-- search. Pure and deterministic; the server owns the Egg's cell and only a category leaves it,
-- until the third reading, which is the pin itself.
--
--   Tier 1 "region"  - one of nine regions of the mound (a crate of normal feathers).
--   Tier 2 "subcell" - one of nine sub-cells inside the region read in tier 1 (a dearer crate).
--   Tier 3 "pin"     - no choice: the Egg's exact logical cell, with its region and sub-cell.
--
-- The map is fixed to the yard, never to the camera: columns run BARN (west, -X) to FENCE (east,
-- +X) and rows run BACK (north, -Z, away from the gate) to FRONT (south, +Z, where players arrive).
--
--     A1 A2 A3      A = BACK          Sub-cells inside a region read the same way:
--     B1 B2 B3                            1 2 3
--     C1 C2 C3      C = FRONT             4 5 6
--   BARN ... FENCE                        7 8 9
--
-- Signal: the selected square holds the Egg -> STRONG; the Egg's square is one step away along a
-- row or column (Manhattan distance 1) -> WEAK; anything else -> NO EGG SIGNAL. A tier-2 reading
-- measures on the fine 9x9 lattice of sub-cells, so a patch on the region's edge still hears an
-- Egg just across the border (the "gamble" after a WEAK region reading). Configurable only in the
-- distance that counts as "near"; never random.

local NestSurvey = {}

export type Signal = "strong" | "weak" | "none" | "pin"
export type Tier = "region" | "subcell" | "pin"

NestSurvey.REGIONS = table.freeze({ "A1", "A2", "A3", "B1", "B2", "B3", "C1", "C2", "C3" }) :: { string }
NestSurvey.ROWS = table.freeze({ "A", "B", "C" }) :: { string }
NestSurvey.SUBS = table.freeze({ 1, 2, 3, 4, 5, 6, 7, 8, 9 }) :: { number }
NestSurvey.TIERS = table.freeze({ "region", "subcell", "pin" }) :: { Tier }
NestSurvey.LANDMARKS = table.freeze({ left = "BARN", right = "FENCE", top = "BACK", bottom = "FRONT" })
NestSurvey.ROW_NAMES = table.freeze({ A = "Back", B = "Middle", C = "Front" })
NestSurvey.COLUMN_NAMES = table.freeze({ "Barn side", "Centre", "Fence side" })

NestSurvey.WORDS = table.freeze({
	strong = table.freeze({ title = "STRONG SIGNAL", short = "STRONG", text = "Strong signal! The Egg is somewhere inside this square!" }),
	weak = table.freeze({ title = "WEAK SIGNAL", short = "WEAK", text = "A faint vibration... the Egg may be nearby." }),
	none = table.freeze({ title = "NO EGG SIGNAL", short = "NO SIGNAL", text = "Nothing beneath this square. Search somewhere else." }),
	pin = table.freeze({ title = "NEST PINNED", short = "PIN", text = "There! The Egg is right under the pin. Dig exactly here!" }),
})

-- What each tier is called on the sign and the button.
NestSurvey.TIER_WORDS = table.freeze({
	region = table.freeze({ pick = "PICK ONE AREA", scan = "SCAN", noun = "region", hint = "an area" }),
	subcell = table.freeze({ pick = "PICK A PATCH IN %s", scan = "SCAN", noun = "patch", hint = "a patch" }),
	pin = table.freeze({ pick = "PIN THE NEST", scan = "PIN THE NEST", noun = "pin", hint = "the pin" }),
})

-- Molly's lines. `insufficient` takes the next crate's size; `ready` is per tier (tier 2 takes the
-- region being subdivided); `limit` when the round's surveys are spent.
NestSurvey.LINES = table.freeze({
	insufficient = "Bring me %d normal feathers for the next crate and I'll dig a little closer.",
	ready = table.freeze({
		"One crate, one scan. Nine sections of dirt - pick the one you fancy.",
		"Now we go finer. Pick a patch inside %s - nine little patches, one of them hums.",
		"Last one, and no choosing this time: I drop the pin right on the nest. Stand back, it's loud.",
	}),
	used = "That's every survey my drill can take this round. The rest is shovel work.",
	exposed = "Forget the equipment - the Egg has been exposed!",
	inactive = "My equipment only works while the search is active.",
	warning = "%s surveys per round. Each one digs closer.",
})

local NUMBER_WORDS = table.freeze({ "One", "Two", "Three", "Four", "Five" })

-- ----------------------------------------------------------------------------------------------
-- Config

-- The ordered crate sizes, one per survey.
function NestSurvey.costs(config: { [string]: any }): { number }
	return config.survey.crateCosts
end

-- The first crate (kept for callers that only need a headline number).
function NestSurvey.crateCost(config: { [string]: any }): number
	return config.survey.crateCosts[1]
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

-- The tier of the reading at `index` (1-based): 1 = region, 2 = sub-cell, 3 and up = pin.
function NestSurvey.tierAt(index: number): Tier
	return NestSurvey.TIERS[math.clamp(index, 1, #NestSurvey.TIERS)]
end

-- The tier the next survey would be; nil once the limit is reached.
function NestSurvey.nextTier(config: { [string]: any }, usedCount: number): Tier?
	if NestSurvey.nextCost(config, usedCount) == nil then
		return nil
	end
	return NestSurvey.tierAt(usedCount + 1)
end

-- "Three surveys per round. Each one digs closer."
function NestSurvey.warning(config: { [string]: any }): string
	local n = NestSurvey.maxSurveys(config)
	return string.format(NestSurvey.LINES.warning, NUMBER_WORDS[n] or tostring(n))
end

-- ----------------------------------------------------------------------------------------------
-- Regions and sub-cells

function NestSurvey.isRegion(value: any): boolean
	return type(value) == "string" and table.find(NestSurvey.REGIONS, value) ~= nil
end

function NestSurvey.isSub(value: any): boolean
	return type(value) == "number" and value == math.floor(value) and value >= 1 and value <= 9
end

-- Row 1..3 (A..C) and column 1..3 of a region id.
function NestSurvey.rowCol(region: string): (number, number)
	local row = table.find(NestSurvey.ROWS, string.sub(region, 1, 1)) or 1
	local col = tonumber(string.sub(region, 2, 2)) or 1
	return row, math.clamp(col, 1, 3)
end

function NestSurvey.regionAt(row: number, col: number): string
	return NestSurvey.ROWS[math.clamp(row, 1, 3)] .. tostring(math.clamp(col, 1, 3))
end

-- Row 1..3 and column 1..3 of a sub-cell number (1..9, reading order).
function NestSurvey.subRowCol(sub: number): (number, number)
	local index = math.clamp(math.floor(sub), 1, 9) - 1
	return index // 3 + 1, index % 3 + 1
end

function NestSurvey.subAt(row: number, col: number): number
	return (math.clamp(row, 1, 3) - 1) * 3 + math.clamp(col, 1, 3)
end

-- "B2-5": a region with a sub-cell, or just the region.
function NestSurvey.id(region: string, sub: number?): string
	if sub then
		return string.format("%s-%d", region, sub)
	end
	return region
end

-- Thirds of a span: which third (1..3) `value` falls in, and how far through that third (0..1).
local function third(value: number, span: number): (number, number)
	local scaled = value / span * 3
	local index = math.clamp(math.floor(scaled), 0, 2)
	return index + 1, math.clamp(scaled - index, 0, 1)
end

-- The region of a grid cell: thirds of the grid along x (barn -> fence) and z (back -> front).
function NestSurvey.regionOfCell(width: number, depth: number, cellX: number, cellZ: number): string
	local col = third(cellX + 0.5, width)
	local row = third(cellZ + 0.5, depth)
	return NestSurvey.regionAt(row, col)
end

-- The sub-cell (1..9) of a grid cell inside `region`: thirds of that region's cell span. A cell
-- outside the region clamps to the nearest edge sub-cell.
function NestSurvey.subCellOfCell(width: number, depth: number, region: string, cellX: number, cellZ: number): number
	local row, col = NestSurvey.rowCol(region)
	local scaledX = (cellX + 0.5) / width * 3 - (col - 1)
	local scaledZ = (cellZ + 0.5) / depth * 3 - (row - 1)
	local subCol = math.clamp(math.floor(scaledX * 3), 0, 2) + 1
	local subRow = math.clamp(math.floor(scaledZ * 3), 0, 2) + 1
	return NestSurvey.subAt(subRow, subCol)
end

-- Region and sub-cell of a grid cell in one call.
function NestSurvey.locate(width: number, depth: number, cellX: number, cellZ: number): (string, number)
	local region = NestSurvey.regionOfCell(width, depth, cellX, cellZ)
	return region, NestSurvey.subCellOfCell(width, depth, region, cellX, cellZ)
end

-- Where a cell sits inside its region, 0..1 along x and z (for placing a pin on a map tile).
function NestSurvey.fractionInRegion(width: number, depth: number, cellX: number, cellZ: number): (number, number)
	local _, fx = third(cellX + 0.5, width)
	local _, fz = third(cellZ + 0.5, depth)
	return fx, fz
end

-- The region of a mound-local offset (studs from the mound's centre), for a physical map.
function NestSurvey.regionOfOffset(halfWidth: number, halfDepth: number, dx: number, dz: number): string
	local col = third(dx + halfWidth, 2 * halfWidth)
	local row = third(dz + halfDepth, 2 * halfDepth)
	return NestSurvey.regionAt(row, col)
end

function NestSurvey.manhattan(a: string, b: string): number
	local ar, ac = NestSurvey.rowCol(a)
	local br, bc = NestSurvey.rowCol(b)
	return math.abs(ar - br) + math.abs(ac - bc)
end

-- Row and column on the fine 9x9 lattice of sub-cells.
function NestSurvey.fineRowCol(region: string, sub: number): (number, number)
	local row, col = NestSurvey.rowCol(region)
	local subRow, subCol = NestSurvey.subRowCol(sub)
	return (row - 1) * 3 + subRow, (col - 1) * 3 + subCol
end

local function classify(config: { [string]: any }, distance: number): Signal
	if distance == 0 then
		return "strong"
	elseif distance <= (config.survey.weakManhattanDistance or 1) then
		return "weak"
	end
	return "none"
end

-- The tier-1 reading for a selected region given the Egg's true region.
function NestSurvey.signal(config: { [string]: any }, selected: string, actual: string): Signal
	return classify(config, NestSurvey.manhattan(selected, actual))
end

-- The tier-2 reading for a selected sub-cell given the Egg's true region and sub-cell, measured
-- on the fine lattice so a neighbour across the region border still counts as adjacent.
function NestSurvey.subSignal(config: { [string]: any }, region: string, sub: number, actualRegion: string, actualSub: number): Signal
	local sr, sc = NestSurvey.fineRowCol(region, sub)
	local ar, ac = NestSurvey.fineRowCol(actualRegion, actualSub)
	return classify(config, math.abs(sr - ar) + math.abs(sc - ac))
end

-- The up-to-four regions a WEAK reading points at (never which one).
function NestSurvey.adjacent(region: string): { string }
	local row, col = NestSurvey.rowCol(region)
	local out = {}
	for _, d in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
		local r, c = row + d[1], col + d[2]
		if r >= 1 and r <= 3 and c >= 1 and c <= 3 then
			table.insert(out, NestSurvey.regionAt(r, c))
		end
	end
	return out
end

-- The up-to-four sub-cells (inside the same region) a WEAK sub-cell reading points at.
function NestSurvey.adjacentSubs(sub: number): { number }
	local row, col = NestSurvey.subRowCol(sub)
	local out = {}
	for _, d in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
		local r, c = row + d[1], col + d[2]
		if r >= 1 and r <= 3 and c >= 1 and c <= 3 then
			table.insert(out, NestSurvey.subAt(r, c))
		end
	end
	return out
end

-- Controller / keyboard navigation over a 3x3, clamped at the edges.
function NestSurvey.step(region: string, dRow: number, dCol: number): string
	local row, col = NestSurvey.rowCol(region)
	return NestSurvey.regionAt(row + dRow, col + dCol)
end

function NestSurvey.stepSub(sub: number, dRow: number, dCol: number): number
	local row, col = NestSurvey.subRowCol(sub)
	return NestSurvey.subAt(row + dRow, col + dCol)
end

-- "B2 - Middle, centre" for the panel and the board; "B2-5 - Middle, centre, patch 5" with a sub.
function NestSurvey.describe(region: string, sub: number?): string
	local row, col = NestSurvey.rowCol(region)
	local rowName = (NestSurvey.ROW_NAMES :: any)[NestSurvey.ROWS[row]]
	if sub then
		return string.format("%s - %s, %s, patch %d", NestSurvey.id(region, sub), rowName, string.lower(NestSurvey.COLUMN_NAMES[col]), sub)
	end
	return string.format("%s - %s, %s", region, rowName, string.lower(NestSurvey.COLUMN_NAMES[col]))
end

-- ----------------------------------------------------------------------------------------------
-- State and projection

export type Reading = {
	tier: number,
	region: string,
	sub: number?, -- tiers 2 and 3
	signal: Signal,
	cellX: number?, -- tier 3 only: the pin
	cellZ: number?,
	byUserId: number,
}

export type State = { readings: { Reading }, count: number }

function NestSurvey.newState(): State
	return { readings = {}, count = 0 }
end

-- One reading as clients see it. Only the tier-3 pin carries a cell; every other reading is the
-- chosen square, the category, the words and who paid.
function NestSurvey.projectReading(reading: Reading): { [string]: any }
	local words = (NestSurvey.WORDS :: any)[reading.signal]
	local out: { [string]: any } = {
		tier = reading.tier,
		region = reading.region,
		sub = reading.sub,
		id = NestSurvey.id(reading.region, reading.sub),
		signal = reading.signal,
		title = words.title,
		short = words.short,
		text = words.text,
		byUserId = reading.byUserId,
	}
	if reading.tier >= 3 then
		out.cellX = reading.cellX
		out.cellZ = reading.cellZ
	end
	return out
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
		nextTier = NestSurvey.nextTier(config, count),
	}
end

-- Which of Molly's lines fits right now.
function NestSurvey.lineFor(
	config: { [string]: any },
	options: { active: boolean, exposed: boolean, count: number, carriedStandard: number, region: string? }
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
	local index = math.clamp(options.count + 1, 1, #NestSurvey.LINES.ready)
	return string.format(NestSurvey.LINES.ready[index], options.region or "that region")
end

return NestSurvey
