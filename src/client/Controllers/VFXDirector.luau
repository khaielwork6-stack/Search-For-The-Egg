--!strict
-- Pooled VFX with quality-tier budgets. Effects are lightweight anchored parts with a
-- ParticleEmitter (PLACEHOLDER primitives, owner: Phase 6 VFX pass). The pool never grows past the
-- configured budget; requests beyond it are dropped, not queued, so the instance count is bounded.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Tokens = require(Shared.Design.Tokens)

local VFXDirector = {}
VFXDirector.__index = VFXDirector

type Effect = { part: Part, emitter: ParticleEmitter, busy: boolean }

export type VFXDirector = typeof(setmetatable(
	{} :: {
		_quality: any,
		_config: { [string]: any },
		_pool: { Effect },
		_active: { Effect },
		_container: Folder,
		_maxActive: number,
		_trove: Trove.Trove,
		stats: { emitted: number, dropped: number },
	},
	VFXDirector
))

type Kind = { color: Color3, rate: number, lifetime: number, size: number, speed: NumberRange?, spread: number?, light: boolean? }
local KINDS: { [string]: Kind } = {
	featherPuff = { color = Tokens.color.cream, rate = 12, lifetime = 1.4, size = 0.6 },
	dust = { color = Tokens.color.creamDeep, rate = 4, lifetime = 3, size = 0.3 },
	sparkle = { color = Tokens.color.straw, rate = 20, lifetime = 0.8, size = 0.25 },
	-- Tool feel: blast fire, rolling smoke, fast sparks, wind wisps.
	blast = {
		color = Tokens.color.ember,
		rate = 90,
		lifetime = 0.55,
		size = 1.1,
		speed = NumberRange.new(8, 16),
		spread = 180,
		light = true,
	},
	smoke = { color = Color3.fromRGB(168, 158, 146), rate = 16, lifetime = 2.4, size = 1.8, speed = NumberRange.new(1.5, 4), spread = 120 },
	spark = {
		color = Tokens.color.honey,
		rate = 60,
		lifetime = 0.35,
		size = 0.12,
		speed = NumberRange.new(6, 12),
		spread = 180,
		light = true,
	},
	wind = { color = Tokens.color.featherWhite, rate = 30, lifetime = 0.3, size = 0.15, speed = NumberRange.new(4, 8), spread = 40 },
}

local function newEffect(container: Folder): Effect
	local part = Instance.new("Part")
	part.Name = "VFX"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part:SetAttribute("SFE_Placeholder", "PHASE_6_VFX")
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	emitter.Parent = part
	part.Parent = container
	return { part = part, emitter = emitter, busy = false }
end

function VFXDirector.new(quality: any, config: { [string]: any }): VFXDirector
	local container = Instance.new("Folder")
	container.Name = "SFE_VFX"
	container.Parent = workspace
	local self = setmetatable({
		_quality = quality,
		_config = config,
		_pool = {},
		_active = {},
		_container = container,
		_maxActive = 0,
		_trove = Trove.new(),
		stats = { emitted = 0, dropped = 0 },
	}, VFXDirector)
	self._trove:add(container)
	local function applyBudget()
		-- Each effect emits at most ~rate*lifetime particles; budget effects so the particle cap holds.
		local budget = quality:budgets().particles
		self._maxActive = math.max(4, math.floor(budget / 40))
	end
	applyBudget()
	self._trove:add(quality.changed:Connect(applyBudget))
	return self
end

-- Emits a burst of `kind` at `position` for `seconds`. Returns false when the budget is exhausted.
function VFXDirector.burst(self: VFXDirector, kind: string, position: Vector3, seconds: number?): boolean
	local spec = KINDS[kind]
	if not spec then
		warn("[SFE][VFX] unknown effect kind " .. tostring(kind))
		return false
	end
	if #self._active >= self._maxActive then
		self.stats.dropped += 1
		return false
	end
	local effect = table.remove(self._pool) or newEffect(self._container)
	effect.busy = true
	effect.part.Position = position
	local emitter = effect.emitter
	emitter.Color = ColorSequence.new(spec.color)
	emitter.Rate = spec.rate
	emitter.Lifetime = NumberRange.new(spec.lifetime * 0.7, spec.lifetime)
	emitter.Size = NumberSequence.new(spec.size)
	emitter.Speed = spec.speed or NumberRange.new(1, 3)
	emitter.SpreadAngle = Vector2.new(spec.spread or 60, spec.spread or 60)
	emitter.LightEmission = if spec.light then 0.8 else 0
	emitter.Transparency = if spec.light then NumberSequence.new(0, 1) else NumberSequence.new(0.1, 1)
	emitter.Enabled = true
	table.insert(self._active, effect)
	self.stats.emitted += 1
	task.delay(seconds or 0.6, function()
		emitter.Enabled = false
		task.delay(spec.lifetime, function()
			local index = table.find(self._active, effect)
			if index then
				table.remove(self._active, index)
			end
			effect.busy = false
			table.insert(self._pool, effect)
		end)
	end)
	return true
end

function VFXDirector.activeCount(self: VFXDirector): number
	return #self._active
end

function VFXDirector.pooledCount(self: VFXDirector): number
	return #self._pool
end

function VFXDirector.instanceCount(self: VFXDirector): number
	return #self._container:GetDescendants()
end

function VFXDirector.destroy(self: VFXDirector)
	self._trove:destroy()
	table.clear(self._pool)
	table.clear(self._active)
end

return VFXDirector
