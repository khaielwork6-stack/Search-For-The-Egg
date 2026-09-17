--!strict
-- Studio diagnostics for join-time cost: named stage timings (os.clock deltas) and a Heartbeat
-- recorder of long frames, each tagged with the stage that was running. Read through the probe
-- channels (client `call perfReport`, server `perfReport`). Cheap enough to leave running: one
-- Heartbeat connection and a bounded list.

local RunService = game:GetService("RunService")

local PerfTrace = {}

export type Spike = { at: number, ms: number, stage: string }

local started = os.clock()
local stage = "boot"
local stages: { { name: string, ms: number } } = {}
local stageStarted = started
local spikes: { Spike } = {}
local frames = 0
local worst = 0
local over50 = 0
local over100 = 0
local connection: RBXScriptConnection? = nil
local MAX_SPIKES = 60
local events: { { at: number, name: string } } = {}

function PerfTrace.event(name: string)
	if #events < 40 then
		table.insert(events, { at = math.floor((os.clock() - started) * 100) / 100, name = name })
	end
end

function PerfTrace.mark(name: string)
	local now = os.clock()
	table.insert(stages, { name = stage, ms = math.floor((now - stageStarted) * 10000) / 10 })
	stage = name
	stageStarted = now
end

function PerfTrace.label(name: string)
	stage = name
end

function PerfTrace.startRecorder()
	if connection then
		return
	end
	connection = RunService.Heartbeat:Connect(function(dt)
		frames += 1
		local ms = dt * 1000
		if ms > worst then
			worst = ms
		end
		if ms > 50 then
			over50 += 1
			if ms > 100 then
				over100 += 1
			end
			if #spikes >= MAX_SPIKES then
				table.remove(spikes, 1)
			end
			table.insert(spikes, { at = math.floor((os.clock() - started) * 10) / 10, ms = math.floor(ms), stage = stage })
		end
	end)
end

function PerfTrace.reset()
	spikes = {}
	frames = 0
	worst = 0
	over50 = 0
	over100 = 0
	started = os.clock()
end

function PerfTrace.report(): { [string]: any }
	return {
		uptime = math.floor((os.clock() - started) * 10) / 10,
		frames = frames,
		worstMs = math.floor(worst),
		over50 = over50,
		over100 = over100,
		stages = stages,
		spikes = spikes,
		events = events,
	}
end

return PerfTrace
