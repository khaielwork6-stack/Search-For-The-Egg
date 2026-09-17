--!strict
-- Surface-first record selection for the area tools (Nest Rake sweep, Feather Vac suction).
--
-- The pile is columns of feather records, each seated where the renderer draws it
-- (FeatherLayout.seatY: the mound as first built, one `step` down per slot). That makes the pile's
-- own occupancy a pure function: a point in space lies inside record (cell, slot) when it is over
-- that cell and inside that slot's band of the column (see occupantAt), and the record is still there. No physics,
-- no instances, so the server decides and the tests prove the same thing.
--
-- A tool may only take records the player can see:
--   * the strike is the FIRST record the aim ray meets (or the client's reticle record when the
--     server agrees it is on the ray and in sight), never a point on a smoothed surface;
--   * a candidate is exposed when a sight line from the nozzle / eye (or the rake head) reaches its
--     top face or the side facing the viewer without passing through any other present record;
--   * candidates are taken layer by layer: every exposed record in the tool's volume, nearest the
--     strike first, before anything that only becomes visible once that layer is gone.

local PileSurface = require(script.Parent.PileSurface)
local FeatherLayout = require(script.Parent.FeatherLayout)

local PileTargeting = {}

export type Model = {
	cfg: { [string]: any },
	visual: { [string]: any },
	grid: { [string]: any },
	field: PileSurface.Field, -- the seat field: the mound as first built
	minX: number,
	minZ: number,
	floorY: number,
	maxTopY: number,
	halfThickness: number, -- every record reaches this far above its seat, so column tops line up
	stride: number,
	picked: { [number]: boolean }, -- featherIds already chosen (treated as gone)
	_steps: { [number]: number },
	_windows: { [number]: number },
	_seats: { [number]: Vector3 | false },
	_pickedCells: { [number]: boolean },
	_blocked: { [number]: { eyes: { Vector3 }, by: { number } } },
	_heights: PileSurface.HeightOf?,
}

-- Seats and seat spacing never change during a round (records are seated on the mound as first
-- built), so a caller may keep one of these per round and hand it to every model.
export type SeatCache = { seats: { [number]: Vector3 | false }, steps: { [number]: number } }

export type Hit = { featherId: number, cellIndex: number, slot: number, point: Vector3, t: number }

export type Query = {
	origin: Vector3,
	direction: Vector3,
	maxDistance: number,
	amount: number,
	perCellCap: number?,
	shape: string, -- "cone" (suction sphere around the strike) or "sweep" (rake fan)
	radiusStuds: number, -- cone: suction radius; sweep: how far the tines drag back toward the player
	halfWidthStuds: number?, -- sweep: half width of the fan
	aheadStuds: number?, -- sweep: reach past the strike
	reachStuds: number?, -- ray met no record: nearest exposed record within this of fallbackPoint
	fallbackPoint: Vector3?,
	hintFeatherId: number?, -- the record under the client's reticle (validated, never trusted)
	hintToleranceStuds: number?,
	headLiftStuds: number?, -- sweep: sight lines also run from a rake head this far above the strike
	maxPasses: number?,
}

export type Selection = {
	featherIds: { number },
	records: { { index: number, slot: number } },
	strike: Vector3?,
	primary: number?,
}

function PileTargeting.newModel(
	cfg: { [string]: any },
	grid: { [string]: any },
	seatField: PileSurface.Field,
	minCorner: Vector3,
	floorY: number?,
	seatCache: SeatCache?
): Model
	local visual = cfg.pile.visual
	local lift = (visual.surfaceLiftStuds or 0) + 0.2
	local maxStep = cfg.pile.maxVisualHeightStuds / math.max(1, cfg.pile.minRecordsPerColumn or 1)
	local halfThickness = (visual.featherThicknessStuds or 0.5) / 2
	return {
		cfg = cfg,
		visual = visual,
		grid = grid,
		field = seatField,
		minX = minCorner.X,
		minZ = minCorner.Z,
		floorY = floorY or math.max(seatField.baseY, seatField.groundY),
		maxTopY = seatField.baseY + seatField.apex + lift + math.abs(visual.seatLumpStuds or 0) + maxStep + halfThickness,
		halfThickness = halfThickness,
		stride = math.min(0.15, grid.cellSize * 0.3),
		picked = {},
		_steps = if seatCache then seatCache.steps else {},
		_windows = {},
		_seats = if seatCache then seatCache.seats else {},
		_pickedCells = {},
		_blocked = {},
		_heights = nil,
	}
end

local function cellOf(model: Model, index: number): any
	return model.grid.cells[index]
end

local function isTaken(cell: any, slot: number): boolean
	return bit32.band(cell.taken, bit32.lshift(1, slot - 1)) ~= 0
end

function PileTargeting.step(model: Model, cell: any): number
	local step = model._steps[cell.index]
	if not step then
		local grid = model.grid
		step = FeatherLayout.seatStep(model.cfg, grid.width, grid.depth, grid.cellSize, cell.x, cell.z, cell.base)
		model._steps[cell.index] = step
	end
	return step
end

-- Records a column draws (and the server accepts) at the top of its stack: the hand's exposure window.
function PileTargeting.window(model: Model, cell: any): number
	local window = model._windows[cell.index]
	if not window then
		local cfg, grid = model.cfg, model.grid
		local minSlots = cfg.pile.visual.visibleSlotsPerCell
		if not model._heights then
			-- Memoised: every window samples the 5x5 around its column, and neighbours share samples.
			local sample = PileSurface.cellHeights(cfg, grid.width, grid.depth, grid.cellSize, grid.cells)
			local memo: { [number]: number } = {}
			model._heights = function(x: number, z: number): number
				if x < 0 or z < 0 or x >= grid.width or z >= grid.depth then
					return 0
				end
				local key = z * grid.width + x
				local value = memo[key]
				if value == nil then
					value = sample(x, z)
					memo[key] = value
				end
				return value
			end
		end
		window = math.max(
			PileSurface.coatSlots(cfg, grid.width, grid.depth, grid.cellSize, cell.x, cell.z, cell.base, minSlots),
			PileSurface.coatSlotsAt(
				cfg,
				grid.width,
				grid.depth,
				grid.cellSize,
				model._heights :: PileSurface.HeightOf,
				cell.x,
				cell.z,
				cell.base,
				minSlots
			)
		)
		model._windows[cell.index] = window
	end
	return window
end

-- Present = untaken on the grid and not already chosen this use.
function PileTargeting.isPresent(model: Model, cell: any, slot: number): boolean
	return slot >= 1 and slot <= cell.base and not isTaken(cell, slot) and not model.picked[FeatherLayout.featherId(cell.index, slot)]
end

-- The drawn records of a column right now (top first), counting this use's picks as gone.
function PileTargeting.drawnSlots(model: Model, cell: any): { number }
	if cell.base <= 0 then
		return {}
	end
	local mask = cell.taken
	if model._pickedCells[cell.index] then
		for slot = 1, cell.base do
			if model.picked[FeatherLayout.featherId(cell.index, slot)] then
				mask = bit32.bor(mask, bit32.lshift(1, slot - 1))
			end
		end
	end
	return FeatherLayout.exposedSlots(cell.base, mask, PileTargeting.window(model, cell))
end

-- Seat of a record in world space, or nil when the renderer draws nothing there (past the rim).
function PileTargeting.seat(model: Model, cell: any, slot: number): Vector3?
	local id = FeatherLayout.featherId(cell.index, slot)
	local cached = model._seats[id]
	if cached ~= nil then
		return if cached then cached else nil
	end
	local grid = model.grid
	-- The XZ offset of FeatherLayout.placement (salts 1 and 2), without the six hashes a seat never uses.
	local spread = grid.cellSize * model.visual.featherSpreadFraction
	local wx = model.minX + (cell.x + 0.5) * grid.cellSize + (FeatherLayout.hash(cell.index, slot, 1) - 0.5) * spread
	local wz = model.minZ + (cell.z + 0.5) * grid.cellSize + (FeatherLayout.hash(cell.index, slot, 2) - 0.5) * spread
	local scale = FeatherLayout.rimScale(model.field, model.visual, wx, wz)
	if scale <= 0 then
		model._seats[id] = false
		return nil
	end
	local y = FeatherLayout.seatY(model.visual, model.field, wx, wz, cell.base, slot, PileTargeting.step(model, cell), scale, model.floorY)
	local seat = Vector3.new(wx, y, wz)
	model._seats[id] = seat
	return seat
end

-- The present record occupying a point, if any: (cell, slot). Slot s of a column fills the band
-- (seat_s + halfThickness - step, seat_s + halfThickness]: a slab's upper face is the same height
-- above its seat whatever the column's spacing, so neighbouring columns' tops line up the way the
-- drawn coat does, and each slot below is exactly one step of the column.
function PileTargeting.occupantAt(model: Model, p: Vector3): (any?, number?)
	if p.Y > model.maxTopY then
		return nil, nil
	end
	local grid = model.grid
	local cx = math.floor((p.X - model.minX) / grid.cellSize)
	local cz = math.floor((p.Z - model.minZ) / grid.cellSize)
	if cx < 0 or cz < 0 or cx >= grid.width or cz >= grid.depth then
		return nil, nil
	end
	local cell = cellOf(model, cz * grid.width + cx + 1)
	if not cell or cell.base <= 0 or cell.remaining <= 0 then
		return nil, nil
	end
	local scale = FeatherLayout.rimScale(model.field, model.visual, p.X, p.Z)
	if scale <= 0 then
		return nil, nil
	end
	local step = PileTargeting.step(model, cell)
	-- Top slot's seat at this XZ without the floor clamp; each slot below is one step deeper.
	local top = FeatherLayout.seatY(model.visual, model.field, p.X, p.Z, cell.base, cell.base, step, scale, -math.huge)
	local slot = cell.base - math.floor((top + model.halfThickness - p.Y) / step)
	if not PileTargeting.isPresent(model, cell, slot) then
		return nil, nil
	end
	return cell, slot
end

-- Walks from `target` toward `from`; false as soon as the line passes through a present record that
-- is not (cell, slot) itself.
local function clearLine(model: Model, target: Vector3, from: Vector3, cell: any, slot: number, startT: number): (boolean, number?)
	local delta = from - target
	local distance = delta.Magnitude
	if distance < 1e-4 then
		return true, nil
	end
	local direction = delta / distance
	local t = startT
	while t < distance do
		local p = target + direction * t
		if p.Y > model.maxTopY then
			if direction.Y >= 0 then
				return true, nil -- above everything and still climbing: nothing further can block
			end
		else
			local other, otherSlot = PileTargeting.occupantAt(model, p)
			if other and otherSlot and not (other == cell and otherSlot == slot) then
				return false, FeatherLayout.featherId(other.index, otherSlot)
			end
		end
		t += model.stride
	end
	return true, nil
end

-- True when a sight line from `from` reaches the record's top face or the side of it facing `from`.
-- When hidden, the second value lists the records blocking each sight line: while all of them stay,
-- the record stays hidden from `from` (occlusion only ever shrinks as records leave).
function PileTargeting.visibleFrom(model: Model, cell: any, slot: number, from: Vector3): (boolean, { number })
	local seat = PileTargeting.seat(model, cell, slot)
	if not seat then
		return false, {}
	end
	local step = PileTargeting.step(model, cell)
	-- Top face: just inside the record's own band, so the first thing above it is the next record.
	local topClear, topBlocker =
		clearLine(model, seat + Vector3.new(0, model.halfThickness - step * 0.1, 0), from, cell, slot, model.stride * 0.5)
	if topClear then
		return true, {}
	end
	-- Side face: the record's height, stepped horizontally out of its own column toward the viewer.
	-- A present neighbour at that height covers it; a dug neighbour (a pit wall) does not.
	local flat = Vector3.new(from.X - seat.X, 0, from.Z - seat.Z)
	if flat.Magnitude < 1e-3 then
		return false, { topBlocker :: number }
	end
	local dir = flat.Unit
	local grid = model.grid
	local cellMinX = model.minX + cell.x * grid.cellSize
	local cellMinZ = model.minZ + cell.z * grid.cellSize
	local exitX = if dir.X > 1e-6
		then (cellMinX + grid.cellSize - seat.X) / dir.X
		elseif dir.X < -1e-6 then (cellMinX - seat.X) / dir.X
		else math.huge
	local exitZ = if dir.Z > 1e-6
		then (cellMinZ + grid.cellSize - seat.Z) / dir.Z
		elseif dir.Z < -1e-6 then (cellMinZ - seat.Z) / dir.Z
		else math.huge
	local side = seat + dir * (math.min(exitX, exitZ) + 0.01) + Vector3.new(0, model.halfThickness - step * 0.5, 0)
	local sideClear, sideBlocker = clearLine(model, side, from, cell, slot, 0)
	if sideClear then
		return true, {}
	end
	return false, { topBlocker :: number, sideBlocker :: number }
end

local function hitOf(cell: any, slot: number, point: Vector3, t: number): Hit
	return { featherId = FeatherLayout.featherId(cell.index, slot), cellIndex = cell.index, slot = slot, point = point, t = t }
end

-- The first drawn record the ray enters within `maxDistance`, or nil.
function PileTargeting.firstHit(model: Model, origin: Vector3, direction: Vector3, maxDistance: number): Hit?
	if direction.Magnitude < 1e-6 then
		return nil
	end
	direction = direction.Unit
	local stride = model.stride * 0.5
	local t = 0
	if origin.Y > model.maxTopY and direction.Y < 0 then
		t = math.max(0, (origin.Y - model.maxTopY) / -direction.Y - stride)
	end
	while t <= maxDistance do
		local p = origin + direction * t
		if p.Y > model.maxTopY then
			if direction.Y >= 0 then
				return nil
			end
		elseif p.Y < model.field.baseY - 1 and direction.Y <= 0 then
			return nil -- under the nest floor and still descending: nothing left to meet
		else
			local cell, slot = PileTargeting.occupantAt(model, p)
			if cell and slot then
				-- The first record the ray enters is the strike. One the coat does not draw (packed
				-- under it) means the ray is already inside the mass: never look past it.
				local seat = if table.find(PileTargeting.drawnSlots(model, cell), slot) then PileTargeting.seat(model, cell, slot) else nil
				return if seat then hitOf(cell, slot, seat, t) else nil
			end
		end
		t += stride
	end
	return nil
end

-- The client's reticle record, accepted only when it is present, drawn, on the aim ray (within the
-- miss tolerance, in front, in range) and in sight of the origin.
function PileTargeting.validateHint(
	model: Model,
	featherId: any,
	origin: Vector3,
	direction: Vector3,
	maxDistance: number,
	toleranceStuds: number
): Hit?
	local cellIndex, slot = FeatherLayout.decode(featherId)
	if not cellIndex or not slot or direction.Magnitude < 1e-6 then
		return nil
	end
	local cell = cellOf(model, cellIndex)
	if not cell or not PileTargeting.isPresent(model, cell, slot) then
		return nil
	end
	if not table.find(PileTargeting.drawnSlots(model, cell), slot) then
		return nil
	end
	local seat = PileTargeting.seat(model, cell, slot)
	if not seat then
		return nil
	end
	local unit = direction.Unit
	local to = seat - origin
	local along = unit:Dot(to)
	if along < 0 or along > maxDistance or (to - unit * along).Magnitude > toleranceStuds then
		return nil
	end
	if not PileTargeting.visibleFrom(model, cell, slot, origin) then
		return nil
	end
	return hitOf(cell, slot, seat, along)
end

-- Drawn records of every cell whose centre lies within `radius` (+ a cell) of `point` in XZ.
local function gather(model: Model, point: Vector3, radius: number): { { cell: any, slot: number, seat: Vector3 } }
	local grid = model.grid
	local out = {}
	local reach = radius + grid.cellSize
	local reachSq = (radius + grid.cellSize * 0.75) ^ 2
	local lift = (model.visual.surfaceLiftStuds or 0) + 0.2
	-- Lump amplitude, the dome's rise across a cell's jitter, and a slot's step.
	local margin = math.abs(model.visual.seatLumpStuds or 0) + grid.cellSize * 1.5
	local cx0 = math.max(0, math.floor((point.X - reach - model.minX) / grid.cellSize))
	local cx1 = math.min(grid.width - 1, math.floor((point.X + reach - model.minX) / grid.cellSize))
	local cz0 = math.max(0, math.floor((point.Z - reach - model.minZ) / grid.cellSize))
	local cz1 = math.min(grid.depth - 1, math.floor((point.Z + reach - model.minZ) / grid.cellSize))
	for z = cz0, cz1 do
		for x = cx0, cx1 do
			local cell = cellOf(model, z * grid.width + x + 1)
			local dx = model.minX + (x + 0.5) * grid.cellSize - point.X
			local dz = model.minZ + (z + 0.5) * grid.cellSize - point.Z
			if cell and cell.remaining > 0 and dx * dx + dz * dz <= reachSq then
				-- Cheap height screen before a seat is resolved: the column top at the cell centre, one
				-- step per slot below it, with room for the lump and the slope across a cell. Every
				-- caller's volume is at most `radius` tall either side of `point`.
				local step = PileTargeting.step(model, cell)
				local index = cell.index
				local top = model.field.baseY + (model.field.seatHeights[index] or 0) + lift
				for _, slot in ipairs(PileTargeting.drawnSlots(model, cell)) do
					local approx = math.max(top - (cell.base - slot) * step, model.floorY)
					if math.abs(approx - point.Y) <= radius + margin then
						local seat = PileTargeting.seat(model, cell, slot)
						if seat then
							table.insert(out, { cell = cell, slot = slot, seat = seat })
						end
					end
				end
			end
		end
	end
	return out
end

local function visibleFromAny(model: Model, cell: any, slot: number, eyes: { Vector3 }): boolean
	local id = FeatherLayout.featherId(cell.index, slot)
	local known = model._blocked[id]
	if known and known.eyes == eyes then
		local stillBlocked = true
		for _, blocker in ipairs(known.by) do
			if model.picked[blocker] then
				stillBlocked = false
				break
			end
		end
		if stillBlocked then
			return false
		end
	end
	local by = {}
	for _, eye in ipairs(eyes) do
		local visible, blockers = PileTargeting.visibleFrom(model, cell, slot, eye)
		if visible then
			model._blocked[id] = nil
			return true
		end
		table.move(blockers, 1, #blockers, #by + 1, by)
	end
	model._blocked[id] = { eyes = eyes, by = by }
	return false
end

-- Nearest exposed drawn record within `reach` of `point` (a bare-spot aim pulls the closest visible
-- feathers, never a buried one).
function PileTargeting.nearestExposed(model: Model, point: Vector3, reach: number, eyes: { Vector3 }): Hit?
	-- Two rings: a near one first (cheap, and almost always enough), then the rest of the reach. Every
	-- seat within a ring's radius is gathered for that ring, so the first visible one is the nearest.
	local inner = math.min(reach, model.grid.cellSize * 1.5)
	local tested = 0
	for _, radius in ipairs({ inner, reach }) do
		local keyed = {}
		for _, candidate in ipairs(gather(model, point, radius)) do
			local d = (candidate.seat - point).Magnitude
			if d <= radius and d > tested then
				candidate.key = d
				table.insert(keyed, candidate)
			end
		end
		table.sort(keyed, function(a: any, b: any)
			if a.key == b.key then
				return FeatherLayout.featherId(a.cell.index, a.slot) < FeatherLayout.featherId(b.cell.index, b.slot)
			end
			return a.key < b.key
		end)
		for _, candidate in ipairs(keyed) do
			if visibleFromAny(model, candidate.cell, candidate.slot, eyes) then
				return hitOf(candidate.cell, candidate.slot, candidate.seat, (candidate.seat - eyes[1]).Magnitude)
			end
		end
		tested = radius
		if radius >= reach then
			break
		end
	end
	return nil
end

-- Whether a seat lies inside the tool's volume around the strike; returns the ordering key.
local function inVolume(query: Query, strike: Vector3, seat: Vector3, flatDir: Vector3?): number?
	local v = seat - strike
	if query.shape == "sweep" and flatDir then
		local along = v.X * flatDir.X + v.Z * flatDir.Z
		local lateral = math.abs(v.X * flatDir.Z - v.Z * flatDir.X)
		if lateral > (query.halfWidthStuds or query.radiusStuds) then
			return nil
		end
		if along > (query.aheadStuds or 0.35) or along < -query.radiusStuds then
			return nil
		end
		if math.abs(v.Y) > query.radiusStuds then
			return nil
		end
		return v.Magnitude
	end
	local d = v.Magnitude
	return if d <= query.radiusStuds then d else nil
end

-- Chooses the exact records one tool use takes, surface first, capped at `query.amount` (and
-- `perCellCap` per column). Does not mutate the grid; `model.picked` holds the result afterwards.
function PileTargeting.select(model: Model, query: Query): Selection
	local selection: Selection = { featherIds = {}, records = {}, strike = nil, primary = nil }
	local amount = math.max(0, math.floor(query.amount))
	if amount <= 0 or query.direction.Magnitude < 1e-6 then
		return selection
	end
	local direction = query.direction.Unit
	local eyes = { query.origin }
	local primary: Hit? = nil
	if query.hintFeatherId ~= nil then
		primary = PileTargeting.validateHint(
			model,
			query.hintFeatherId,
			query.origin,
			direction,
			query.maxDistance,
			query.hintToleranceStuds or 0
		)
	end
	if not primary then
		primary = PileTargeting.firstHit(model, query.origin, direction, query.maxDistance)
	end
	if not primary and query.fallbackPoint and query.reachStuds then
		primary = PileTargeting.nearestExposed(model, query.fallbackPoint, query.reachStuds, eyes)
	end
	if not primary then
		return selection
	end
	local strike = primary.point
	selection.strike = strike
	selection.primary = primary.featherId
	if query.headLiftStuds then
		table.insert(eyes, strike + Vector3.new(0, query.headLiftStuds, 0))
	end
	local cap = query.perCellCap or math.huge
	local perCell: { [number]: number } = {}
	local function take(cellIndex: number, slot: number)
		local id = FeatherLayout.featherId(cellIndex, slot)
		model.picked[id] = true
		model._pickedCells[cellIndex] = true
		perCell[cellIndex] = (perCell[cellIndex] or 0) + 1
		table.insert(selection.featherIds, id)
		table.insert(selection.records, { index = cellIndex, slot = slot })
	end
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local flatDir = if flat.Magnitude > 0.05 then flat.Unit else nil
	-- Farthest a seat inside the volume can lie from the strike in XZ.
	local bound = if query.shape == "sweep"
		then math.sqrt(math.max(query.radiusStuds, query.aheadStuds or 0) ^ 2 + (query.halfWidthStuds or query.radiusStuds) ^ 2)
		else query.radiusStuds
	-- Layer by layer: a pass sees the pile as it stood when the pass began, so a record uncovered by
	-- this pass's picks waits for the next pass and the top layer always goes first.
	for pass = 1, query.maxPasses or amount do
		if #selection.featherIds >= amount then
			break
		end
		local layer = {}
		local layerPerCell: { [number]: number } = {}
		if pass == 1 then
			-- The strike belongs to the first layer: what lies under it is not uncovered until the
			-- whole layer has gone.
			local cell = cellOf(model, primary.cellIndex)
			table.insert(layer, { cell = cell, slot = primary.slot })
			layerPerCell[primary.cellIndex] = 1
		end
		local keyed = {}
		local wanted = #selection.featherIds + #layer < amount
		for _, candidate in ipairs(if wanted then gather(model, strike, bound) else {}) do
			local id = FeatherLayout.featherId(candidate.cell.index, candidate.slot)
			if id ~= primary.featherId and (perCell[candidate.cell.index] or 0) < cap then
				local key = inVolume(query, strike, candidate.seat, flatDir)
				if key then
					candidate.key = key
					candidate.id = id
					table.insert(keyed, candidate)
				end
			end
		end
		table.sort(keyed, function(a: any, b: any)
			if a.key == b.key then
				return a.id < b.id
			end
			return a.key < b.key
		end)
		for _, candidate in ipairs(keyed) do
			if #selection.featherIds + #layer >= amount then
				break
			end
			local index = candidate.cell.index
			if (perCell[index] or 0) + (layerPerCell[index] or 0) < cap then
				if visibleFromAny(model, candidate.cell, candidate.slot, eyes) then
					table.insert(layer, candidate)
					layerPerCell[index] = (layerPerCell[index] or 0) + 1
				end
			end
		end
		if #layer == 0 then
			break
		end
		for _, candidate in ipairs(layer) do
			take(candidate.cell.index, candidate.slot)
		end
	end
	return selection
end

return PileTargeting
