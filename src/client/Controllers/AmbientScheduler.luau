--!strict
-- One Heartbeat connection drives every ambient actor on a seeded, time-sliced schedule. Actors
-- register an update interval; the scheduler culls by distance to the camera and caps the number
-- of active actors per quality tier. No per-object loops, no per-object connections.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local WeightedRandom = require(Shared.WeightedRandom)

local AmbientScheduler = {}
AmbientScheduler.__index = AmbientScheduler

export type Actor = {
	id: string,
	position: () -> Vector3,
	interval: number, -- seconds between updates
	update: (dt: number, t: number, rng: any) -> (),
	cleanup: (() -> ())?,
	_next: number,
	_phase: number,
}

export type AmbientScheduler = typeof(setmetatable(
	{} :: {
		_actors: { Actor },
		_quality: any,
		_accessibility: any,
		_rng: any,
		_connection: RBXScriptConnection?,
		_cullDistance: number,
		_elapsed: number,
		_trove: Trove.Trove,
		stats: { updates: number, culled: number },
	},
	AmbientScheduler
))

function AmbientScheduler.new(quality: any, accessibility: any, seed: number?): AmbientScheduler
	local self = setmetatable({
		_actors = {},
		_quality = quality,
		_accessibility = accessibility,
		_rng = WeightedRandom.fromSeed(seed or 20260912),
		_connection = nil,
		_cullDistance = 160,
		_elapsed = 0,
		_trove = Trove.new(),
		stats = { updates = 0, culled = 0 },
	}, AmbientScheduler)
	return self
end

function AmbientScheduler.register(
	self: AmbientScheduler,
	actor: {
		id: string,
		position: () -> Vector3,
		interval: number,
		update: (dt: number, t: number, rng: any) -> ...any,
		cleanup: (() -> ())?,
	}
): Actor
	local entry: Actor = {
		id = actor.id,
		position = actor.position,
		interval = actor.interval,
		update = actor.update,
		cleanup = actor.cleanup,
		_next = self._elapsed + self._rng:next() * actor.interval, -- stagger start
		_phase = self._rng:next() * math.pi * 2,
	}
	table.insert(self._actors, entry)
	return entry
end

function AmbientScheduler.unregister(self: AmbientScheduler, actor: Actor)
	local index = table.find(self._actors, actor)
	if index then
		table.remove(self._actors, index)
		if actor.cleanup then
			actor.cleanup()
		end
	end
end

function AmbientScheduler.start(self: AmbientScheduler)
	if self._connection then
		return
	end
	self._connection = RunService.Heartbeat:Connect(function(dt)
		self:step(dt)
	end)
end

-- Exposed for tests/Studio verification: one scheduler step.
function AmbientScheduler.step(self: AmbientScheduler, dt: number)
	-- Reduced motion slows the shared time base, so every sine-driven actor moves less, not just
	-- the actors that integrate dt.
	local motionScale = self._accessibility:motionScale()
	self._elapsed += dt * motionScale
	local t = self._elapsed
	local camera = workspace.CurrentCamera
	local cameraPosition = camera and camera.CFrame.Position or Vector3.zero
	local maxActive = self._quality:budgets().ambientActors
	local active = 0
	for _, actor in ipairs(self._actors) do
		if t < actor._next then
			continue
		end
		actor._next = t + actor.interval
		if (actor.position() - cameraPosition).Magnitude > self._cullDistance or active >= maxActive then
			self.stats.culled += 1
			continue
		end
		active += 1
		self.stats.updates += 1
		local ok, err = pcall(actor.update, dt * motionScale, t + actor._phase, self._rng)
		if not ok then
			warn("[SFE][Ambient] actor " .. actor.id .. " failed: " .. tostring(err))
		end
	end
end

function AmbientScheduler.stop(self: AmbientScheduler)
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
end

function AmbientScheduler.actorCount(self: AmbientScheduler): number
	return #self._actors
end

function AmbientScheduler.connectionCount(self: AmbientScheduler): number
	return if self._connection then 1 else 0
end

function AmbientScheduler.clear(self: AmbientScheduler)
	for _, actor in ipairs(self._actors) do
		if actor.cleanup then
			actor.cleanup()
		end
	end
	table.clear(self._actors)
end

function AmbientScheduler.destroy(self: AmbientScheduler)
	self:stop()
	self:clear()
	self._trove:destroy()
end

return AmbientScheduler
