--!strict
-- Deterministic per-feather placement shared by the server (validation of the exact targeted feather)
-- and the client (rendering the same feather in the same place). Every logical feather is identified
-- by a stable id = cellIndex * SLOT_STRIDE + slot (slot 1..base within its cell). Placement is a pure
-- function of the id, so no per-feather state ever replicates: the client renders exactly the
-- records the server holds. Presentation constants come from pile.visual (ASSUMED A-PILE-03).

local PileSurface = require(script.Parent.PileSurface)

local FeatherLayout = {}

FeatherLayout.SLOT_STRIDE = 64 -- cells never hold more than 63 feathers (validated in Config)

export type Placement = {
	ox: number, -- offset from the cell centre (studs)
	oz: number,
	yaw: number, -- radians about the surface normal
	tilt: number, -- radians lifted off the surface
	roll: number, -- radians about the quill
	length: number, -- studs
	width: number, -- studs (vane)
	tint: number, -- 0..1 palette position
}

function FeatherLayout.featherId(cellIndex: number, slot: number): number
	return cellIndex * FeatherLayout.SLOT_STRIDE + slot
end

-- Whether a record is a Rainbow Feather. Deterministic from the round's seed, so server and
-- client agree without any per-record replication; `pile.rainbowChance` is the rate.
function FeatherLayout.isRainbow(cfg: { [string]: any }, seed: number, cellIndex: number, slot: number): boolean
	local chance = cfg.pile.rainbowChance or 0
	if chance <= 0 then
		return false
	end
	return FeatherLayout.hash(cellIndex, slot, seed + 0.5) < chance
end

-- Returns (cellIndex, slot) or nil for a malformed id.
function FeatherLayout.decode(featherId: any): (number?, number?)
	if type(featherId) ~= "number" or featherId % 1 ~= 0 or featherId < FeatherLayout.SLOT_STRIDE then
		return nil, nil
	end
	local slot = featherId % FeatherLayout.SLOT_STRIDE
	if slot < 1 then
		return nil, nil
	end
	return (featherId - slot) / FeatherLayout.SLOT_STRIDE, slot
end

-- Deterministic pseudo-random in [0,1).
function FeatherLayout.hash(a: number, b: number, salt: number): number
	local n = math.sin(a * 12.9898 + b * 78.233 + salt * 37.719) * 43758.5453
	return n - math.floor(n)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function FeatherLayout.placement(visual: { [string]: any }, cellIndex: number, slot: number, cellSize: number): Placement
	local h = function(salt: number)
		return FeatherLayout.hash(cellIndex, slot, salt)
	end
	local spread = cellSize * visual.featherSpreadFraction
	return {
		ox = (h(1) - 0.5) * spread,
		oz = (h(2) - 0.5) * spread,
		yaw = h(3) * math.pi * 2,
		tilt = math.rad(lerp(visual.tiltRangeDegrees[1], visual.tiltRangeDegrees[2], h(4))),
		roll = (h(5) - 0.5) * math.rad(visual.rollRangeDegrees),
		length = lerp(visual.featherLengthRange[1], visual.featherLengthRange[2], h(6)),
		width = lerp(visual.featherWidthRange[1], visual.featherWidthRange[2], h(7)),
		tint = h(8),
	}
end

-- World XZ of a feather (cell centre plus its placement offset); `minCorner` is the grid's min corner.
function FeatherLayout.worldXZ(minCorner: Vector3, cellSize: number, cellX: number, cellZ: number, placement: Placement): (number, number)
	return minCorner.X + (cellX + 0.5) * cellSize + placement.ox, minCorner.Z + (cellZ + 0.5) * cellSize + placement.oz
end

-- Server-side world position of an exposed feather: on the current logical surface at its XZ.
function FeatherLayout.worldPosition(
	field: PileSurface.Field,
	minCorner: Vector3,
	cellX: number,
	cellZ: number,
	placement: Placement
): Vector3
	local x, z = FeatherLayout.worldXZ(minCorner, field.cellSize, cellX, cellZ, placement)
	return Vector3.new(x, field.baseY + PileSurface.heightAt(field, x, z), z)
end

-- Vertical seat offset of a record relative to the mound surface as first built: the top slot of a
-- column sits just above the surface and every slot below it one `step` deeper. A pure function of
-- the slot (never of what has been taken), so the client seats a feather once and it never moves,
-- and the server resolves the same point for range and aim checks.
function FeatherLayout.seatOffset(visual: { [string]: any }, base: number, slot: number, step: number): number
	return visual.surfaceLiftStuds + 0.2 - (base - slot) * step
end

-- Cosmetic undulation of the coat. The logical dome is a perfect profile until it is dug, which
-- reads as a blob; rendered feathers ride this smooth deterministic wave so the mound has natural
-- rises and hollows. Shared so the server's tool targeting seats a record exactly where it is drawn.
function FeatherLayout.seatLump(visual: { [string]: any }, wx: number, wz: number): number
	local amplitude = visual.seatLumpStuds or 0
	if amplitude <= 0 then
		return 0
	end
	local broad = math.sin(wx * 0.27 + wz * 0.17) * math.cos(wz * 0.31 - wx * 0.11)
	local fine = math.sin((wx + wz) * 0.52 + 1.3)
	return amplitude * (broad * 0.62 + fine * 0.38)
end

-- Rim rule: nothing is placed past the mound's foot, and strands shrink toward the edge so there is
-- no floor overspill. Returns the length scale (0 = not drawn).
function FeatherLayout.rimScale(field: PileSurface.Field, visual: { [string]: any }, wx: number, wz: number): number
	local dx, dz = wx - field.centreX, wz - field.centreZ
	local r = math.sqrt(dx * dx + dz * dz)
	local foot = field.radius * PileSurface.RIM_STRETCH - visual.rimInsetStuds
	if r >= foot then
		return 0
	end
	return math.clamp((foot - r) / visual.rimTaperStuds, visual.rimMinScale, 1)
end

-- Seat spacing of a column: its full dome height shared among the records it was dealt, never
-- below the configured minimum.
function FeatherLayout.seatStep(
	cfg: { [string]: any },
	width: number,
	depth: number,
	cellSize: number,
	x: number,
	z: number,
	base: number
): number
	local full = PileSurface.columnFullHeight(cfg, width, depth, cellSize, x, z)
	return math.max(full / math.max(1, base), cfg.pile.visual.minSeatStepStuds or 0)
end

-- World Y of a record's seat as the renderer places it: the mound as first built (`seatField`) at
-- the record's XZ, one `step` down per slot below the top, riding the lump (faded where the coat is
-- thin), never below `floorY` + 0.06. `scale` is the record's rim scale.
function FeatherLayout.seatY(
	visual: { [string]: any },
	seatField: PileSurface.Field,
	wx: number,
	wz: number,
	base: number,
	slot: number,
	step: number,
	scale: number,
	floorY: number
): number
	local surfaceY = seatField.baseY + PileSurface.heightAt(seatField, wx, wz)
	local lumpFade = math.clamp((surfaceY - seatField.baseY) / math.max(0.01, visual.seatLumpFadeStuds or 3), 0, 1)
	local y = surfaceY + FeatherLayout.seatOffset(visual, base, slot, step) + FeatherLayout.seatLump(visual, wx, wz) * scale * lumpFade
	return math.max(y, floorY + 0.06)
end

-- The `count` highest untaken slots of a cell, top first (these are the exposed, targetable feathers).
function FeatherLayout.exposedSlots(base: number, mask: number, count: number): { number }
	local out = {}
	local slot = base
	while slot >= 1 and #out < count do
		if bit32.band(mask, bit32.lshift(1, slot - 1)) == 0 then
			table.insert(out, slot)
		end
		slot -= 1
	end
	return out
end

return FeatherLayout
