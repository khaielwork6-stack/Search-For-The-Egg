--!strict
-- Pure rules for the round's one mid-round event (`roundEvents` in SYSTEM_CONFIG): whether a round
-- gets one and which, when it starts, the Rainbow Rush conversion pick, the Supply Drop target and
-- cash split, the preset spots, and the projection clients receive. No Roblox instances and no
-- runtime mutation here, so the server service and the tests share exactly one copy of each rule.
--
-- Nothing in this module ever reads the Egg except `rushConversions`, which only uses it to keep
-- conversions AWAY from it; spots are chosen from fixed presets with the round's RNG alone.

local WeightedRandom = require(script.Parent.Parent.WeightedRandom)
local FeatherLayout = require(script.Parent.FeatherLayout)
local PileSurface = require(script.Parent.PileSurface)

local RoundEvents = {}

RoundEvents.KINDS = table.freeze({ "rainbowRush", "supplyDrop", "chickRescue" })
RoundEvents.NAMES = table.freeze({
	rainbowRush = "RAINBOW RUSH",
	supplyDrop = "SUPPLY DROP",
	chickRescue = "CHICK RESCUE",
})

export type Plan = { kind: string, delaySeconds: number }

function RoundEvents.isKind(kind: any): boolean
	return type(kind) == "string" and table.find(RoundEvents.KINDS, kind) ~= nil
end

-- The span the start window is a fraction of: the round's time limit.
function RoundEvents.roundSeconds(cfg: { [string]: any }): number
	return cfg.round.maximumRoundSeconds
end

-- Rolls the round's event from three draws in [0,1): chance, kind, start. Returns nil for no event.
function RoundEvents.plan(cfg: { [string]: any }, roll: () -> number): Plan?
	local events = cfg.roundEvents
	if not events or events.enabled == false then
		return nil
	end
	local happens = roll()
	local kindRoll = roll()
	local startRoll = roll()
	if happens >= events.chance then
		return nil
	end
	local entries = {}
	for _, kind in ipairs(RoundEvents.KINDS) do
		local spec = events.events[kind]
		if spec and spec.weight > 0 then
			table.insert(entries, { id = kind, weight = spec.weight })
		end
	end
	if #entries == 0 then
		return nil
	end
	local kind = WeightedRandom.selectByRoll(entries, kindRoll).id
	-- Seconds after Searching begins, not a fraction of the 30-minute cap: real rounds end in minutes, so
	-- a fraction of the cap would put almost every event after the Egg was already found.
	local window = events.startSeconds
	local delay = window[1] + (window[2] - window[1]) * startRoll
	return { kind = kind, delaySeconds = math.min(delay, RoundEvents.roundSeconds(cfg)) }
end

-- One preset spot, chosen by the roll alone (the Egg is never an input).
function RoundEvents.pickSpot(spots: { { number } }, roll: number): Vector3
	local index = math.clamp(math.floor(roll * #spots) + 1, 1, #spots)
	local spot = spots[index]
	return Vector3.new(spot[1], spot[2], spot[3])
end

-- True when a world XZ lies on the pile's footprint (its grid square) or within `margin` of it.
function RoundEvents.onPile(cfg: { [string]: any }, nestCenter: Vector3, position: Vector3, margin: number?): boolean
	local half = cfg.pile.gridWidth * cfg.pile.cellSizeStuds / 2 + (margin or 0)
	local halfDepth = cfg.pile.gridDepth * cfg.pile.cellSizeStuds / 2 + (margin or 0)
	return math.abs(position.X - nestCenter.X) <= half and math.abs(position.Z - nestCenter.Z) <= halfDepth
end

-- Supply Drop fill target for the players present when it lands.
function RoundEvents.supplyTarget(cfg: { [string]: any }, presentPlayers: number): number
	local drop = cfg.roundEvents.events.supplyDrop
	local extra = math.max(0, presentPlayers - 1)
	return math.max(1, math.floor(drop.target * (1 + drop.targetPerExtraPlayer * extra) + 0.5))
end

-- Chick Rescue holds needed to free the chick.
function RoundEvents.holdsRequired(cfg: { [string]: any }): number
	return math.max(1, cfg.roundEvents.events.chickRescue.holdsRequired)
end

-- Cash per contributor for a filled Supply Drop: the pool (scaled with the target) split by share of
-- the feathers deposited, each clamped to [floor, cap]. Only contributors with a deposit are paid.
function RoundEvents.supplyRewards(cfg: { [string]: any }, contributions: { [number]: number }, target: number): { [number]: number }
	local drop = cfg.roundEvents.events.supplyDrop
	local total = 0
	for _, amount in pairs(contributions) do
		total += amount
	end
	local out = {}
	if total <= 0 then
		return out
	end
	local pool = drop.rewardPoolCents * (target / drop.target)
	for userId, amount in pairs(contributions) do
		if amount > 0 then
			local share = math.floor(pool * amount / total + 0.5)
			out[userId] = math.clamp(share, drop.rewardFloorCents, drop.rewardCapCents)
		end
	end
	return out
end

-- The records a column must keep hidden before anything below them counts as buried: the widest
-- window the server would accept a pick from (the same two coat rules CollectionService checks).
local function exposedWindow(cfg: { [string]: any }, grid: any, heights: any, cell: any): number
	local minSlots = cfg.pile.visual.visibleSlotsPerCell
	return math.max(
		PileSurface.coatSlots(cfg, grid.width, grid.depth, grid.cellSize, cell.x, cell.z, cell.base, minSlots),
		PileSurface.coatSlotsAt(cfg, grid.width, grid.depth, grid.cellSize, heights, cell.x, cell.z, cell.base, minSlots)
	)
end

-- Rainbow Rush pick: up to `maxConversions` standard records that are still buried (below every
-- exposed record of their column plus a margin) but within `depthBandRecords` of the surface, none
-- within `eggExclusionStuds` of the Egg's column, at most one per column, spread round-robin across a
-- `spreadBlocks` x `spreadBlocks` partition of the nest. Returns feather ids; mutates nothing.
function RoundEvents.rushConversions(
	cfg: { [string]: any },
	grid: any,
	pile: { rainbowSeed: number?, rainbowOverrides: { [number]: boolean }? },
	eggCellX: number,
	eggCellZ: number,
	roll: () -> number
): { number }
	local rush = cfg.roundEvents.events.rainbowRush
	local blocks = math.max(1, rush.spreadBlocks)
	local heights = PileSurface.cellHeights(cfg, grid.width, grid.depth, grid.cellSize, grid.cells)
	local exclusion = rush.eggExclusionStuds
	local buckets: { { number } } = {}
	for b = 1, blocks * blocks do
		buckets[b] = {}
	end
	for _, cell in ipairs(grid.cells) do
		if cell.remaining <= 0 then
			continue
		end
		local dx, dz = (cell.x - eggCellX) * grid.cellSize, (cell.z - eggCellZ) * grid.cellSize
		if dx * dx + dz * dz <= exclusion * exclusion then
			continue
		end
		local skip = exposedWindow(cfg, grid, heights, cell) + rush.buriedMarginRecords
		local untaken = 0
		local candidates = {}
		for slot = cell.base, 1, -1 do
			if bit32.band(cell.taken, bit32.lshift(1, slot - 1)) ~= 0 then
				continue
			end
			untaken += 1
			if untaken <= skip then
				continue
			end
			if untaken > skip + rush.depthBandRecords then
				break
			end
			if not FeatherLayout.isRainbowRecord(cfg, pile, cell.index, slot) then
				table.insert(candidates, slot)
			end
		end
		if #candidates > 0 then
			local slot = candidates[math.clamp(math.floor(roll() * #candidates) + 1, 1, #candidates)]
			local bx = math.clamp(math.floor(cell.x * blocks / grid.width), 0, blocks - 1)
			local bz = math.clamp(math.floor(cell.z * blocks / grid.depth), 0, blocks - 1)
			table.insert(buckets[bz * blocks + bx + 1], FeatherLayout.featherId(cell.index, slot))
		end
	end
	-- Shuffle each block, then take one from each block in a shuffled order until the cap.
	for _, bucket in ipairs(buckets) do
		for i = #bucket, 2, -1 do
			local j = math.clamp(math.floor(roll() * i) + 1, 1, i)
			bucket[i], bucket[j] = bucket[j], bucket[i]
		end
	end
	local order = {}
	for b = 1, #buckets do
		order[b] = b
	end
	for i = #order, 2, -1 do
		local j = math.clamp(math.floor(roll() * i) + 1, 1, i)
		order[i], order[j] = order[j], order[i]
	end
	local picked = {}
	local cap = rush.maxConversions
	local progress = true
	while #picked < cap and progress do
		progress = false
		for _, b in ipairs(order) do
			local bucket = buckets[b]
			if #bucket > 0 and #picked < cap then
				table.insert(picked, table.remove(bucket) :: number)
				progress = true
			end
		end
	end
	return picked
end

-- The override set as a sorted id list (the replicated form).
function RoundEvents.overrideList(overrides: { [number]: boolean }?): { number }
	local list = {}
	for id, on in pairs(overrides or {}) do
		if on then
			table.insert(list, id)
		end
	end
	table.sort(list)
	return list
end

-- What clients see of an event: kind, name, deadline, progress and its own spot. A scheduled event is
-- not projected (nothing announces it early), and nothing about the Egg is ever included.
function RoundEvents.project(event: any?, nowMs: number): { [string]: any }?
	if not event or (event.status ~= "active" and event.status ~= "ended") then
		return nil
	end
	local projection: { [string]: any } = {
		id = event.id,
		kind = event.kind,
		name = RoundEvents.NAMES[event.kind],
		status = event.status,
		result = event.result,
		startedAtMs = event.startedAtMs,
		endsAtMs = event.endsAtMs,
		remainingMs = math.max(0, (event.endsAtMs or nowMs) - nowMs),
		serverNowMs = nowMs,
		progress = event.progress,
		target = event.target,
	}
	if event.position then
		projection.x = event.position.X
		projection.y = event.position.Y
		projection.z = event.position.Z
	end
	if event.kind == "rainbowRush" then
		projection.conversions = table.clone(event.conversions or {})
	end
	return projection
end

return RoundEvents
