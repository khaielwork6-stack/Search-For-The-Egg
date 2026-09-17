--!strict
-- The sold-feathers crate run (owner requirement; ASSUMED A-SELL-02). The map's collection crate is the
-- one and only sale point: a sale is accepted only while the crate is parked, and an accepted sale
-- starts one run - every client animates the same authored crate along the same timeline (lift onto
-- the front belt, through the processor, out on the side belt, over to the earth pit, tip, fall,
-- vanish, reset). The server owns the gate (busy flag), the timeline, and the cash; it never moves
-- the crate itself. Timings come from selling.crate; distances from the chapter layout.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local Signal = require(Shared.Util.Signal)
local Envelope = require(Shared.Net.Envelope)

local CrateService = {}
CrateService.__index = CrateService

export type Segment = { name: string, seconds: number }

export type CrateService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_clock: any,
		_schedule: (seconds: number, callback: () -> ()) -> (),
		_busyUntil: number,
		_runId: number,
		_generation: number,
		runStarted: any, -- (roundId, payload)
		crateRespawned: any, -- (roundId, runId): a fresh crate is parked again; sales may resume
		runFinished: any, -- (roundId, runId)
		stats: { runs: number, refused: number },
	},
	CrateService
))

function CrateService.new(
	options: { config: { [string]: any }, clock: any, schedule: ((seconds: number, callback: () -> ()) -> ())? }
): CrateService
	return setmetatable({
		_config = options.config,
		_clock = options.clock,
		_schedule = options.schedule or function(seconds, callback)
			task.delay(seconds, callback)
		end,
		_busyUntil = 0,
		_runId = 0,
		_generation = 0,
		runStarted = Signal.new(),
		crateRespawned = Signal.new(),
		runFinished = Signal.new(),
		stats = { runs = 0, refused = 0 },
	}, CrateService)
end

-- The run timeline for a chapter: ordered segments with durations (seconds) the clients replay.
function CrateService.timeline(self: CrateService, chapter: string): { Segment }
	local layout = ChapterLayout[chapter]
	local crate = self._config.selling.crate
	local geometry = layout.crate
	if not geometry then
		return {}
	end
	local speed = crate.beltStudsPerSecond
	local function studs(a: Vector3, b: Vector3): number
		return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
	end
	return {
		{ name = "lift", seconds = crate.liftSeconds },
		{ name = "frontBelt", seconds = studs(geometry.frontBeltStart, geometry.machineEntry) / speed },
		{ name = "machine", seconds = crate.machineSeconds },
		{ name = "turn", seconds = crate.turnSeconds },
		{ name = "sideBelt", seconds = studs(geometry.sideBeltStart, geometry.sideBeltEnd) / speed },
		{ name = "toPit", seconds = crate.toPitSeconds },
		{ name = "tip", seconds = crate.tipSeconds },
		{ name = "fall", seconds = crate.fallSeconds },
		{ name = "reset", seconds = crate.resetDelaySeconds },
	}
end

function CrateService.totalSeconds(self: CrateService, chapter: string): number
	local total = 0
	for _, segment in ipairs(self:timeline(chapter)) do
		total += segment.seconds
	end
	return total
end

function CrateService.isBusy(self: CrateService): boolean
	return self._clock:monotonic() < self._busyUntil
end

-- Gate for a sale attempt: nil when the crate is parked, else the rejection envelope.
function CrateService.gate(self: CrateService): Envelope.Envelope<any>?
	if self:isBusy() then
		self.stats.refused += 1
		return Envelope.fail(Envelope.Codes.INVALID_STATE, "crate_busy")
	end
	return nil
end

-- Starts a run for an accepted sale. Returns the payload broadcast to clients.
function CrateService.start(
	self: CrateService,
	roundId: string,
	chapter: string,
	featherCount: number,
	sellerUserId: number
): { [string]: any }
	local timeline = self:timeline(chapter)
	local total = self:totalSeconds(chapter)
	local crate = self._config.selling.crate
	self._runId += 1
	local runId = self._runId
	-- The gate closes for the sell cooldown only (owner: one second), not the crate's whole ride:
	-- a sale during the ride starts a fresh run and every client restarts the animation for it.
	local cooldown = crate.sellCooldownSeconds or total
	self._busyUntil = self._clock:monotonic() + math.min(total, cooldown)
	self.stats.runs += 1
	local payload = {
		runId = runId,
		chapter = chapter,
		featherCount = math.max(0, math.floor(featherCount)),
		sellerUserId = sellerUserId,
		timeline = timeline,
		totalSeconds = total,
	}
	self.runStarted:Fire(roundId, payload)
	-- Runs overlap: a fresh crate is parked `respawnSeconds` after each sale (the prompt comes back
	-- with it), and every sold crate finishes its own ride. A reset between them (round over)
	-- retires both timers.
	local generation = self._generation
	local respawn = math.min(total, crate.respawnSeconds or total)
	self._schedule(respawn, function()
		if self._generation == generation then
			self.crateRespawned:Fire(roundId, runId)
		end
	end)
	self._schedule(total, function()
		if self._generation == generation then
			self.runFinished:Fire(roundId, runId)
		end
	end)
	return payload
end

-- Round ended: the crate is free again immediately (clients reset on their own).
function CrateService.reset(self: CrateService)
	self._runId += 1
	self._generation += 1
	self._busyUntil = 0
end

return CrateService
