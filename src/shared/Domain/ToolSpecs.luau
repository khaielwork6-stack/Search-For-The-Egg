--!strict
-- Pure resolution of tool numbers from SYSTEM_CONFIG + round levels + resolved modifiers. Services
-- and UI read specs from here; nothing restates a curve value. Every path in `toolUpgrades` maps to
-- one spec field; acquisition prices come from `tools.<id>`.

local EconomyMath = require(script.Parent.Parent.EconomyMath)

local ToolSpecs = {}

ToolSpecs.TOOL_IDS = table.freeze({ "nestRake", "confettiCharge", "featherVac", "scoutChick" })
ToolSpecs.HAND_PATHS = table.freeze({ "grasp", "speed", "hold" })

ToolSpecs.PATHS = table.freeze({
	nestRake = table.freeze({ "sweep", "cooldown", "hold" }),
	confettiCharge = table.freeze({ "luckyBlast", "speed", "power" }),
	featherVac = table.freeze({ "power", "cooling", "runtime" }),
	scoutChick = table.freeze({ "speed", "grasp", "capacity" }),
})

export type Levels = { [string]: number }

function ToolSpecs.isTool(toolId: any): boolean
	return type(toolId) == "string" and table.find(ToolSpecs.TOOL_IDS, toolId) ~= nil
end

function ToolSpecs.defaultLevels(): { [string]: Levels }
	local out: { [string]: Levels } = {}
	for _, toolId in ipairs(ToolSpecs.TOOL_IDS) do
		local levels: Levels = {}
		for _, pathName in ipairs(ToolSpecs.PATHS[toolId]) do
			levels[pathName] = 0
		end
		out[toolId] = levels
	end
	return out
end

function ToolSpecs.maxLevel(cfg: { [string]: any }, toolId: string, pathName: string): number
	return #cfg.toolUpgrades[toolId][pathName] - 1
end

function ToolSpecs.maxLevels(cfg: { [string]: any }, toolId: string): Levels
	local out: Levels = {}
	for _, pathName in ipairs(ToolSpecs.PATHS[toolId]) do
		out[pathName] = ToolSpecs.maxLevel(cfg, toolId, pathName)
	end
	return out
end

local function entry(cfg: { [string]: any }, toolId: string, pathName: string, level: number): any
	local path = cfg.toolUpgrades[toolId][pathName]
	return path[math.clamp(level, 0, #path - 1) + 1]
end

-- Discrete Hand spec: feathers per action, cooldown seconds, walk speed, hold interval.
function ToolSpecs.hand(cfg: { [string]: any }, levels: { grasp: number, speed: number, hold: number }, modifiers: any)
	local grasp = cfg.handUpgrades.grasp[levels.grasp + 1]
	local speed = cfg.handUpgrades.speed[levels.speed + 1]
	local hold = cfg.handUpgrades.hold[levels.hold + 1]
	local cooldown = if hold.enabled and hold.intervalSeconds then hold.intervalSeconds else cfg.collection.baseHandCooldownSeconds
	return {
		toolId = "hand",
		amount = math.max(1, math.floor(grasp.amount * modifiers.handGrabMultiplier * modifiers.toolYieldMultiplier + 0.5)),
		radiusCells = 0,
		cooldownSeconds = cooldown,
		holdEnabled = hold.enabled == true,
		walkSpeed = speed.walkSpeed,
	}
end

-- Nest Rake: deeper, wider discrete extraction.
function ToolSpecs.nestRake(cfg: { [string]: any }, levels: Levels, modifiers: any)
	local sweep = entry(cfg, "nestRake", "sweep", levels.sweep)
	local cooldown = entry(cfg, "nestRake", "cooldown", levels.cooldown)
	local hold = entry(cfg, "nestRake", "hold", levels.hold)
	local tool = cfg.tools.nestRake
	local cellSize = cfg.pile.cellSizeStuds
	return {
		toolId = "nestRake",
		amount = math.max(1, math.floor(sweep.yield * modifiers.rakeYieldMultiplier * modifiers.toolYieldMultiplier + 0.5)),
		radiusCells = math.max(1, math.ceil((tool.sweepRadiusStuds or cellSize) / cellSize)),
		radiusStuds = tool.sweepRadiusStuds or cellSize,
		reachStuds = tool.reachStuds or cellSize * 3,
		focusWeight = tool.focusWeight or 0.6,
		cooldownSeconds = if hold.enabled and hold.intervalSeconds then hold.intervalSeconds else cooldown.seconds,
		holdEnabled = hold.enabled == true,
	}
end

-- Confetti Charge: burst area clearing with rainbow conversion and optional class mini-charges.
function ToolSpecs.confettiCharge(cfg: { [string]: any }, levels: Levels, modifiers: any)
	local lucky = entry(cfg, "confettiCharge", "luckyBlast", levels.luckyBlast)
	local speed = entry(cfg, "confettiCharge", "speed", levels.speed)
	local power = entry(cfg, "confettiCharge", "power", levels.power)
	local tool = cfg.tools.confettiCharge
	return {
		toolId = "confettiCharge",
		yield = math.max(1, math.floor(power.yield * modifiers.toolYieldMultiplier + 0.5)),
		radiusStuds = power.radiusStuds * modifiers.blastRadiusMultiplier,
		fuseSeconds = speed.fuseSeconds,
		rainbowChance = lucky.rainbowChance,
		throwDistanceStuds = tool.throwDistanceStuds,
		cooldownSeconds = tool.cooldownSeconds,
		miniChargeChance = modifiers.procs.miniChargeChance or 0,
		miniChargeCount = modifiers.params.miniChargeCount or 0,
		miniChargeFuseSeconds = tool.miniChargeFuseSeconds,
		craterFocus = tool.craterFocus or 2,
	}
end

-- Feather Vac: continuous suction with runtime/heat and forced cooling.
function ToolSpecs.featherVac(cfg: { [string]: any }, levels: Levels, modifiers: any)
	local power = entry(cfg, "featherVac", "power", levels.power)
	local cooling = entry(cfg, "featherVac", "cooling", levels.cooling)
	local runtime = entry(cfg, "featherVac", "runtime", levels.runtime)
	local tool = cfg.tools.featherVac
	local cellSize = cfg.pile.cellSizeStuds
	return {
		toolId = "featherVac",
		perSecond = power.perSecond * modifiers.toolYieldMultiplier,
		runtimeSeconds = runtime.seconds,
		coolingSeconds = cooling.seconds,
		radiusCells = math.max(1, math.ceil((tool.suctionRadiusStuds or cellSize) / cellSize)),
		radiusStuds = tool.suctionRadiusStuds or cellSize,
		reachStuds = tool.reachStuds or cellSize * 2,
		focusWeight = tool.focusWeight or 0.7,
	}
end

-- Scout Chick: autonomous companion trips.
function ToolSpecs.scoutChick(cfg: { [string]: any }, levels: Levels, modifiers: any)
	local speed = entry(cfg, "scoutChick", "speed", levels.speed)
	local grasp = entry(cfg, "scoutChick", "grasp", levels.grasp)
	local capacity = entry(cfg, "scoutChick", "capacity", levels.capacity)
	local tool = cfg.tools.scoutChick
	return {
		toolId = "scoutChick",
		moveSpeed = speed.value * (modifiers.params.droneSpeedMultiplier or 1),
		grasp = math.max(1, math.floor(grasp.value * modifiers.toolYieldMultiplier + 0.5)),
		capacity = math.max(1, math.floor(capacity.value * (modifiers.params.droneCapacityMultiplier or 1) + 0.5)),
		collectIntervalSeconds = tool.collectIntervalSeconds,
		depositSeconds = tool.depositSeconds,
		swarmChance = modifiers.procs.swarmChancePerTrip or 0,
		swarmCount = modifiers.params.swarmCount or 0,
	}
end

function ToolSpecs.resolve(cfg: { [string]: any }, toolId: string, levels: Levels, modifiers: any): any
	local resolver = (ToolSpecs :: any)[toolId]
	assert(type(resolver) == "function", "unknown tool " .. tostring(toolId))
	return resolver(cfg, levels, modifiers)
end

-- Acquisition price: { cashCents } or { gems } (soft currency only; Robux packaging is deployment-mapped).
function ToolSpecs.acquisitionPrice(cfg: { [string]: any }, toolId: string): { cashCents: number?, gems: number? }
	local tool = cfg.tools[toolId]
	assert(tool, "unknown tool " .. tostring(toolId))
	if tool.softCashPrice then
		return { cashCents = EconomyMath.dollarsToCents(tool.softCashPrice) }
	end
	return { gems = tool.softGemPrice }
end

-- Upgrade preview for a tool path: current entry, next entry, cost in cents (with an optional
-- discount multiplier applied once), maxed flag.
function ToolSpecs.pathPreview(cfg: { [string]: any }, toolId: string, pathName: string, level: number, discountMultiplier: number?)
	local path = cfg.toolUpgrades[toolId][pathName]
	local current = path[level + 1]
	local nextEntry = path[level + 2]
	local cost = nil
	if current and current.nextCash then
		cost = EconomyMath.dollarsToCents(current.nextCash)
		if discountMultiplier and discountMultiplier ~= 1 then
			cost = EconomyMath.discountedCents(cost, discountMultiplier)
		end
	end
	return {
		upgradeId = toolId .. "." .. pathName,
		toolId = toolId,
		pathName = pathName,
		level = level,
		maxLevel = #path - 1,
		current = current,
		next = nextEntry,
		costCents = cost,
		maxed = nextEntry == nil,
	}
end

return ToolSpecs
