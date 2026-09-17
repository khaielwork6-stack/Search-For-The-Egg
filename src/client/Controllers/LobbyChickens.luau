--!strict
-- Yard chickens: a handful of client-only, low-poly chickens pottering about in front of the barn.
-- Cosmetic only - anchored, CFrame-driven, never colliding, queried or touched - and cheap: one
-- AmbientScheduler actor steps every chicken at `updateHz` (low tier: fewer birds, `lowTierUpdateHz`),
-- chickens further than `cullDistanceStuds` from the camera are skipped entirely, and every visible
-- part moves in one workspace:BulkMoveTo per update. Where they may walk is LobbyYard (the yard
-- rectangles minus the portal corridor, spawn, pads and the spawn-to-pad walking lines) plus a ground
-- raycast at each target, so a prop standing in the yard is avoided rather than walked through.
-- Behaviour: walk with a hop gait and head bob, stop, peck a few times, sometimes look around.
-- `stats` carries the cost (os.clock around each update, rolling average) for `lobbyAmbienceStats`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local LobbyYard = require(Shared.Domain.LobbyYard)
local Tokens = require(Shared.Design.Tokens)
local WeightedRandom = require(Shared.WeightedRandom)

local LobbyChickens = {}
LobbyChickens.__index = LobbyChickens

type Chicken = {
	model: Model,
	parts: { BasePart },
	position: Vector2,
	y: number,
	yaw: number,
	targetYaw: number,
	state: string, -- "pause" | "walk" | "peck" | "turn"
	timer: number,
	pecks: number,
	peckT: number,
	gait: number,
	target: Vector2?,
	fromPosition: Vector2,
	fromY: number,
	targetY: number,
}

export type LobbyChickens = typeof(setmetatable(
	{} :: {
		_deps: any,
		_cfg: { [string]: any },
		_yard: LobbyYard.Yard,
		_rng: any,
		_folder: Folder?,
		_chickens: { Chicken },
		_actor: any?,
		_tier: string?,
		_lastT: number?,
		_rayParams: RaycastParams,
		_moveParts: { BasePart },
		_moveFrames: { CFrame },
		_hitY: number,
		_windowStart: number,
		_windowUpdates: number,
		stats: { [string]: any },
	},
	LobbyChickens
))

local LEG_COLOR = Color3.fromRGB(236, 150, 44)
local BEAK_COLOR = Color3.fromRGB(246, 176, 52)

-- Part layout in the chicken's own frame (feet at y = 0, forward is -Z), at modelScale 1.
-- `head` parts hang off the neck pivot so a peck rotates them together.
local NECK = Vector3.new(0, 1.5, -0.6)
local PARTS: { { name: string, size: Vector3, offset: Vector3, color: Color3, wedge: boolean?, head: boolean?, leg: number? } } = {
	{ name = "Body", size = Vector3.new(1.15, 1.0, 1.55), offset = Vector3.new(0, 1.1, 0.05), color = Tokens.worldColor.feather },
	{
		name = "Tail",
		size = Vector3.new(0.8, 0.8, 0.55),
		offset = Vector3.new(0, 1.75, 0.8),
		color = Tokens.worldColor.featherDeep,
		wedge = true,
	},
	{
		name = "Head",
		size = Vector3.new(0.62, 0.66, 0.62),
		offset = Vector3.new(0, 0.45, -0.1),
		color = Tokens.worldColor.feather,
		head = true,
	},
	{
		name = "Beak",
		size = Vector3.new(0.22, 0.18, 0.32),
		offset = Vector3.new(0, 0.42, -0.55),
		color = BEAK_COLOR,
		wedge = true,
		head = true,
	},
	{ name = "Comb", size = Vector3.new(0.12, 0.3, 0.46), offset = Vector3.new(0, 0.9, -0.08), color = Tokens.color.ember, head = true },
	{ name = "LegL", size = Vector3.new(0.14, 0.62, 0.14), offset = Vector3.new(-0.28, 0.62, 0.05), color = LEG_COLOR, leg = 1 },
	{ name = "LegR", size = Vector3.new(0.14, 0.62, 0.14), offset = Vector3.new(0.28, 0.62, 0.05), color = LEG_COLOR, leg = -1 },
}

local function yawToward(direction: Vector2): number
	return math.atan2(-direction.X, -direction.Y)
end

local function angleDelta(from: number, to: number): number
	return (to - from + math.pi) % (math.pi * 2) - math.pi
end

function LobbyChickens.new(deps: { ambient: any, quality: any, accessibility: any, config: { [string]: any } }): LobbyChickens
	local cfg = deps.config.lobby.ambience.chickens
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	return setmetatable({
		_deps = deps,
		_cfg = cfg,
		_yard = LobbyYard.fromLayout(ChapterLayout.lobby, cfg),
		_rng = WeightedRandom.fromSeed(20260917),
		_folder = nil,
		_chickens = {},
		_actor = nil,
		_tier = nil,
		_lastT = nil,
		_rayParams = params,
		_moveParts = {},
		_moveFrames = {},
		_hitY = 0,
		_windowStart = os.clock(),
		_windowUpdates = 0,
		stats = {
			enabled = cfg.enabled == true,
			actors = 0,
			visible = 0,
			tier = "",
			updateHz = 0,
			measuredHz = 0,
			updates = 0,
			lastUpdateMs = 0,
			avgUpdateMs = 0,
			maxUpdateMs = 0,
			perFrameMsAt60 = 0,
			budgetMs = deps.config.lobby.ambience.frameBudgetMs,
			withinBudget = true,
		},
	}, LobbyChickens)
end

-- Ground under an XZ point, or nil when it is not the yard floor (a prop, a player, nothing at all).
function LobbyChickens._groundAt(self: LobbyChickens, point: Vector2): number?
	local groundY = ChapterLayout.lobby.groundY
	local result = workspace:Raycast(Vector3.new(point.X, groundY + 8, point.Y), Vector3.new(0, -16, 0), self._rayParams)
	if not result or math.abs(result.Position.Y - groundY) > self._cfg.groundToleranceStuds then
		return nil
	end
	return result.Position.Y
end

function LobbyChickens._accept(self: LobbyChickens, from: Vector2, point: Vector2): boolean
	-- The midpoint too: a crate between here and there is not ground.
	if not self:_groundAt((from + point) / 2) then
		return false
	end
	local y = self:_groundAt(point)
	if not y then
		return false
	end
	self._hitY = y
	return true
end

function LobbyChickens._buildOne(self: LobbyChickens, index: number): Chicken?
	local folder = self._folder
	if not folder then
		return nil
	end
	local position: Vector2? = nil
	local y = ChapterLayout.lobby.groundY
	for _ = 1, 8 do
		local candidate = LobbyYard.randomPoint(self._yard, self._rng)
		local ground = candidate and self:_groundAt(candidate)
		if candidate and ground then
			position, y = candidate, ground
			break
		end
	end
	if not position then
		return nil
	end
	local scale = self._cfg.modelScale
	local model = Instance.new("Model")
	model.Name = "Chicken" .. index
	local parts: { BasePart } = {}
	for _, spec in ipairs(PARTS) do
		local part: BasePart = if spec.wedge then Instance.new("WedgePart") :: BasePart else Instance.new("Part") :: BasePart
		part.Name = spec.name
		part.Size = spec.size * scale
		part.Color = spec.color
		part.Material = Enum.Material.SmoothPlastic
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = spec.name == "Body"
		part.Massless = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
		table.insert(parts, part)
	end
	model.Parent = folder
	local yaw = self._rng:next() * math.pi * 2
	local chicken: Chicken = {
		model = model,
		parts = parts,
		position = position,
		y = y,
		yaw = yaw,
		targetYaw = yaw,
		state = "pause",
		timer = self._rng:next() * self._cfg.pauseMaxSeconds,
		pecks = 0,
		peckT = 0,
		gait = 0,
		target = nil,
		fromPosition = position,
		fromY = y,
		targetY = y,
	}
	self:_pose(chicken)
	if #self._moveParts > 0 then
		workspace:BulkMoveTo(self._moveParts, self._moveFrames, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(self._moveParts)
		table.clear(self._moveFrames)
	end
	return chicken
end

function LobbyChickens._rebuild(self: LobbyChickens, count: number)
	for _, chicken in ipairs(self._chickens) do
		chicken.model:Destroy()
	end
	table.clear(self._chickens)
	for index = 1, count do
		local chicken = self:_buildOne(index)
		if chicken then
			table.insert(self._chickens, chicken)
		end
	end
	self.stats.actors = #self._chickens
end

function LobbyChickens.start(self: LobbyChickens)
	if self._folder or self._cfg.enabled ~= true then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "SFE_LobbyChickens"
	folder.Parent = workspace
	self._folder = folder
	self._rayParams.FilterDescendantsInstances = { folder }
	local sum = Vector2.zero
	for _, rect in ipairs(self._yard.rects) do
		sum += (rect.min + rect.max) / 2
	end
	local center = sum / math.max(1, #self._yard.rects)
	local anchor = Vector3.new(center.X, ChapterLayout.lobby.groundY, center.Y)
	self._actor = self._deps.ambient:register({
		id = "lobbyChickens",
		position = function()
			return anchor
		end,
		interval = 1 / self._cfg.updateHz,
		update = function(_dt: number, t: number)
			self:update(t)
		end,
	})
	self:_applyTier()
end

-- Flock size and update rate for the current quality tier (low: fewer birds, slower updates).
function LobbyChickens._applyTier(self: LobbyChickens)
	local cfg = self._cfg
	local tier = self._deps.quality:tier()
	self._tier = tier
	self:_rebuild(cfg.countByTier[tier] or cfg.countByTier.medium)
	local hz = if tier == "low" then cfg.lowTierUpdateHz else cfg.updateHz
	if self._actor then
		self._actor.interval = 1 / hz
	end
	self.stats.tier = tier
	self.stats.updateHz = hz
end

function LobbyChickens._chooseNext(self: LobbyChickens, chicken: Chicken)
	local cfg = self._cfg
	local rng = self._rng
	if chicken.pecks > 0 then
		chicken.state = "peck"
		chicken.peckT = 0
		return
	end
	if rng:next() < cfg.lookAroundChance then
		chicken.state = "turn"
		chicken.targetYaw = chicken.yaw + (rng:next() - 0.5) * 2.6
		return
	end
	local target = LobbyYard.pickTarget(self._yard, rng, chicken.position, cfg.wanderStepMaxStuds, function(point)
		return self:_accept(chicken.position, point)
	end)
	if not target then
		chicken.state = "pause"
		chicken.timer = cfg.pauseMinSeconds
		chicken.pecks = cfg.peckMin
		return
	end
	chicken.state = "walk"
	chicken.target = target
	chicken.fromPosition = chicken.position
	chicken.fromY = chicken.y
	chicken.targetY = self._hitY
	chicken.targetYaw = yawToward(target - chicken.position)
end

function LobbyChickens._step(self: LobbyChickens, chicken: Chicken, dt: number)
	local cfg = self._cfg
	local rng = self._rng
	local turn = cfg.turnRadiansPerSecond * dt
	local yawError = angleDelta(chicken.yaw, chicken.targetYaw)
	chicken.yaw += math.clamp(yawError, -turn, turn)
	if chicken.state == "pause" then
		chicken.timer -= dt
		if chicken.timer <= 0 then
			self:_chooseNext(chicken)
		end
	elseif chicken.state == "turn" then
		if math.abs(yawError) < 0.05 then
			chicken.state = "pause"
			chicken.timer = cfg.pauseMinSeconds * 0.5
		end
	elseif chicken.state == "peck" then
		chicken.peckT += dt
		if chicken.peckT >= cfg.peckSeconds then
			chicken.peckT = 0
			chicken.pecks -= 1
			if chicken.pecks <= 0 then
				chicken.pecks = 0
				chicken.state = "pause"
				chicken.timer = cfg.pauseMinSeconds + rng:next() * (cfg.pauseMaxSeconds - cfg.pauseMinSeconds)
			end
		end
	elseif chicken.state == "walk" then
		local target = chicken.target :: Vector2
		local toTarget = target - chicken.position
		local distance = toTarget.Magnitude
		-- Mostly turned before setting off, so it never moonwalks.
		local speed = if math.abs(yawError) > 1.2 then 0 else cfg.walkSpeedStuds
		local stepLength = speed * dt
		chicken.gait += dt * cfg.stepHz
		if distance <= stepLength or distance < 0.05 then
			chicken.position = target
			chicken.y = chicken.targetY
			chicken.target = nil
			chicken.state = "pause"
			chicken.timer = 0.25 + rng:next() * 0.35
			chicken.pecks = cfg.peckMin + math.floor(rng:next() * (cfg.peckMax - cfg.peckMin + 1))
		else
			chicken.position += toTarget.Unit * stepLength
			local total = (target - chicken.fromPosition).Magnitude
			local progress = if total > 0 then 1 - (target - chicken.position).Magnitude / total else 1
			chicken.y = chicken.fromY + (chicken.targetY - chicken.fromY) * progress
		end
	end
end

-- Appends this chicken's part CFrames to the pending bulk move.
function LobbyChickens._pose(self: LobbyChickens, chicken: Chicken)
	local cfg = self._cfg
	local scale = cfg.modelScale
	local walking = chicken.state == "walk"
	local reduced = self._deps.accessibility:reducedMotion()
	local hopScale = if reduced then cfg.reducedMotionHopScale else 1
	local stride = math.sin(chicken.gait * math.pi)
	local hop = if walking then cfg.hopHeightStuds * hopScale * math.abs(stride) else 0
	local bob = if walking then cfg.headBobStuds * math.sin(chicken.gait * math.pi * 2) else 0
	local peck = if chicken.state == "peck" then math.sin(chicken.peckT / cfg.peckSeconds * math.pi) * 1.05 else 0
	local lean = if walking then 0.08 else 0
	local root = CFrame.new(chicken.position.X, chicken.y + hop, chicken.position.Y) * CFrame.Angles(0, chicken.yaw, 0)
	local body = root * CFrame.Angles(-lean, 0, 0)
	local neck = body * CFrame.new((NECK + Vector3.new(0, -peck * 0.18, -bob - peck * 0.12)) * scale) * CFrame.Angles(-peck, 0, 0)
	local moveParts = self._moveParts
	local moveFrames = self._moveFrames
	for index, spec in ipairs(PARTS) do
		local frame: CFrame
		if spec.head then
			frame = neck * CFrame.new(spec.offset * scale)
		elseif spec.leg then
			local swing = if walking then stride * 0.45 * spec.leg else 0
			local hip = spec.offset * scale
			frame = root * CFrame.new(hip) * CFrame.Angles(swing, 0, 0) * CFrame.new(0, -spec.size.Y * scale / 2, 0)
		else
			frame = body * CFrame.new(spec.offset * scale)
		end
		table.insert(moveParts, chicken.parts[index])
		table.insert(moveFrames, frame)
	end
end

-- One scheduler update: `t` is the scheduler's (reduced-motion scaled) time base.
function LobbyChickens.update(self: LobbyChickens, t: number)
	local started = os.clock()
	local cfg = self._cfg
	if self._deps.quality:tier() ~= self._tier then
		-- A quality change rebuilds the flock; the build is not ambience frame cost.
		self:_applyTier()
		started = os.clock()
	end
	local dt = if self._lastT then math.clamp(t - self._lastT, 0, 0.25) else 0
	self._lastT = t
	local camera = workspace.CurrentCamera
	local cameraPosition = if camera then camera.CFrame.Position else Vector3.zero
	local cullSq = cfg.cullDistanceStuds * cfg.cullDistanceStuds
	local visible = 0
	for _, chicken in ipairs(self._chickens) do
		local dx, dz = chicken.position.X - cameraPosition.X, chicken.position.Y - cameraPosition.Z
		local dy = chicken.y - cameraPosition.Y
		if dx * dx + dy * dy + dz * dz > cullSq then
			continue
		end
		visible += 1
		self:_step(chicken, dt)
		self:_pose(chicken)
	end
	if #self._moveParts > 0 then
		workspace:BulkMoveTo(self._moveParts, self._moveFrames, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(self._moveParts)
		table.clear(self._moveFrames)
	end
	self:_record(visible, (os.clock() - started) * 1000)
end

function LobbyChickens._record(self: LobbyChickens, visible: number, ms: number)
	local stats = self.stats
	stats.visible = visible
	stats.updates += 1
	stats.lastUpdateMs = ms
	stats.avgUpdateMs = if stats.updates == 1 then ms else stats.avgUpdateMs + (ms - stats.avgUpdateMs) * 0.05
	if ms > stats.maxUpdateMs then
		stats.maxUpdateMs = ms
	end
	self._windowUpdates += 1
	local now = os.clock()
	local window = now - self._windowStart
	if window >= 1 then
		stats.measuredHz = self._windowUpdates / window
		self._windowUpdates = 0
		self._windowStart = now
	end
	-- One update per frame at most, so the amortised per-frame cost is the average times the share
	-- of 60 Hz frames that run one.
	stats.perFrameMsAt60 = stats.avgUpdateMs * math.min(1, stats.measuredHz / 60)
	stats.withinBudget = stats.lastUpdateMs <= stats.budgetMs
end

function LobbyChickens.snapshot(self: LobbyChickens): { [string]: any }
	local copy = table.clone(self.stats)
	local states: { [string]: number } = {}
	for _, chicken in ipairs(self._chickens) do
		states[chicken.state] = (states[chicken.state] or 0) + 1
	end
	copy.states = states
	return copy
end

function LobbyChickens.resetStats(self: LobbyChickens)
	self.stats.maxUpdateMs = 0
	self.stats.updates = 0
	self.stats.avgUpdateMs = 0
end

function LobbyChickens.destroy(self: LobbyChickens)
	if self._actor then
		self._deps.ambient:unregister(self._actor)
		self._actor = nil
	end
	for _, chicken in ipairs(self._chickens) do
		chicken.model:Destroy()
	end
	table.clear(self._chickens)
	if self._folder then
		self._folder:Destroy()
		self._folder = nil
	end
end

return LobbyChickens
