--!strict
-- Molly the Mole's survey: one crate of normal feathers buys one reading of one of nine regions of
-- the mound. Pure and deterministic; the server owns the Egg's region and only a category leaves it.
--
-- The map is fixed to the yard, never to the camera: columns run BARN (west, -X) to FENCE (east,
-- +X) and rows run BACK (north, -Z, away from the gate) to FRONT (south, +Z, where players arrive).
--
--     A1 A2 A3      A = BACK
--     B1 B2 B3
--     C1 C2 C3      C = FRONT
--   BARN ... FENCE
--
-- Signal: the selected region holds the Egg -> STRONG; the Egg's region is one step away along a
-- row or column (Manhattan distance 1) -> WEAK; anything else -> NO EGG SIGNAL. Configurable only
-- in the distance that counts as "near"; never random.

local NestSurvey = {}

export type Signal = "strong" | "weak" | "none"

NestSurvey.REGIONS = table.freeze({ "A1", "A2", "A3", "B1", "B2", "B3", "C1", "C2", "C3" }) :: { string }
NestSurvey.ROWS = table.freeze({ "A", "B", "C" }) :: { string }
NestSurvey.LANDMARKS = table.freeze({ left = "BARN", right = "FENCE", top = "BACK", bottom = "FRONT" })
NestSurvey.ROW_NAMES = table.freeze({ A = "Back", B = "Middle", C = "Front" })
NestSurvey.COLUMN_NAMES = table.freeze({ "Barn side", "Centre", "Fence side" })

NestSurvey.WORDS = table.freeze({
	strong = table.freeze({ title = "STRONG SIGNAL", short = "STRONG", text = "Strong signal! The Egg is somewhere inside this region!" }),
	weak = table.freeze({ title = "WEAK SIGNAL", short = "WEAK", text = "A faint vibration... the Egg may be nearby." }),
	none = table.freeze({ title = "NO EGG SIGNAL", short = "NO SIGNAL", text = "Nothing beneath this section. Search somewhere else." }),
})

-- Molly's lines. `insufficient` takes the configured crate size.
NestSurvey.LINES = table.freeze({
	insufficient = "Bring me a full survey crate - %d normal feathers - and I'll test one section of the nest.",
	ready = "One crate, one scan. Choose the region carefully.",
	used = "That was our only reliable reading this round. Now you'll have to dig.",
	exposed = "Forget the equipment - the Egg has been exposed!",
	inactive = "My equipment only works while the search is active.",
	warning = "This is your party's only survey this round. Choose carefully.",
})

function NestSurvey.crateCost(config: { [string]: any }): number
	return config.survey.SurveyCrateCost
end

function NestSurvey.isRegion(value: any): boolean
	return type(value) == "string" and table.find(NestSurvey.REGIONS, value) ~= nil
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

-- The region of a grid cell: thirds of the grid along x (barn -> fence) and z (back -> front).
function NestSurvey.regionOfCell(width: number, depth: number, cellX: number, cellZ: number): string
	local col = math.clamp(math.floor((cellX + 0.5) / width * 3), 0, 2) + 1
	local row = math.clamp(math.floor((cellZ + 0.5) / depth * 3), 0, 2) + 1
	return NestSurvey.regionAt(row, col)
end

-- The region of a mound-local offset (studs from the mound's centre), for a physical map.
function NestSurvey.regionOfOffset(halfWidth: number, halfDepth: number, dx: number, dz: number): string
	local col = math.clamp(math.floor((dx + halfWidth) / (2 * halfWidth) * 3), 0, 2) + 1
	local row = math.clamp(math.floor((dz + halfDepth) / (2 * halfDepth) * 3), 0, 2) + 1
	return NestSurvey.regionAt(row, col)
end

function NestSurvey.manhattan(a: string, b: string): number
	local ar, ac = NestSurvey.rowCol(a)
	local br, bc = NestSurvey.rowCol(b)
	return math.abs(ar - br) + math.abs(ac - bc)
end

-- The reading for a selected region given the Egg's true region.
function NestSurvey.signal(config: { [string]: any }, selected: string, actual: string): Signal
	local distance = NestSurvey.manhattan(selected, actual)
	if distance == 0 then
		return "strong"
	elseif distance <= (config.survey.weakManhattanDistance or 1) then
		return "weak"
	end
	return "none"
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

-- Controller / keyboard navigation over the grid, clamped at the edges.
function NestSurvey.step(region: string, dRow: number, dCol: number): string
	local row, col = NestSurvey.rowCol(region)
	return NestSurvey.regionAt(row + dRow, col + dCol)
end

-- "B2 - Middle, centre" for the panel and the board.
function NestSurvey.describe(region: string): string
	local row, col = NestSurvey.rowCol(region)
	local rowName = (NestSurvey.ROW_NAMES :: any)[NestSurvey.ROWS[row]]
	return string.format("%s - %s, %s", region, rowName, string.lower(NestSurvey.COLUMN_NAMES[col]))
end

export type State = { region: string, signal: Signal, byUserId: number }

-- What clients receive: the chosen region, the category, who paid. Nothing about the Egg.
function NestSurvey.project(state: State?): { [string]: any }?
	if not state then
		return nil
	end
	local words = (NestSurvey.WORDS :: any)[state.signal]
	return {
		region = state.region,
		signal = state.signal,
		title = words.title,
		short = words.short,
		text = words.text,
		byUserId = state.byUserId,
	}
end

-- Which of Molly's lines fits right now.
function NestSurvey.lineFor(
	config: { [string]: any },
	options: { active: boolean, exposed: boolean, used: boolean, carriedStandard: number }
): string
	-- An exposed Egg is still a live round: that line wins over "inactive".
	if options.exposed then
		return NestSurvey.LINES.exposed
	end
	if not options.active then
		return NestSurvey.LINES.inactive
	end
	if options.used then
		return NestSurvey.LINES.used
	end
	if options.carriedStandard < NestSurvey.crateCost(config) then
		return string.format(NestSurvey.LINES.insufficient, NestSurvey.crateCost(config))
	end
	return NestSurvey.LINES.ready
end

return NestSurvey
