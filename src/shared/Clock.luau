--!strict
-- Injected clock. Services never call os.time/os.clock directly; they receive a Clock so tests
-- can advance time deterministically and cooldowns use monotonic server deadlines.

local Clock = {}
Clock.__index = Clock

export type Clock = {
	now: (self: Clock) -> number, -- wall-clock seconds (unix)
	nowMs: (self: Clock) -> number, -- wall-clock integer milliseconds
	monotonic: (self: Clock) -> number, -- monotonic seconds for cooldowns/deadlines
	advance: (self: Clock, seconds: number) -> (), -- fake clocks only
	set: (self: Clock, unixSeconds: number) -> (), -- fake clocks only
	isFake: boolean,
}

function Clock.real(): Clock
	local self = setmetatable({ isFake = false }, Clock)
	function self.now(_)
		return os.time()
	end
	function self.nowMs(_)
		return os.time() * 1000
	end
	function self.monotonic(_)
		return os.clock()
	end
	function self.advance()
		error("Clock.real cannot be advanced")
	end
	function self.set()
		error("Clock.real cannot be set")
	end
	return (self :: any) :: Clock
end

function Clock.fake(startUnixSeconds: number?): Clock
	local wall = startUnixSeconds or 1800000000
	local mono = 0
	local self = setmetatable({ isFake = true }, Clock)
	function self.now(_)
		return wall
	end
	function self.nowMs(_)
		return math.floor(wall * 1000 + 0.5)
	end
	function self.monotonic(_)
		return mono
	end
	function self.advance(_, seconds: number)
		assert(seconds >= 0, "cannot advance negative time")
		wall += seconds
		mono += seconds
	end
	function self.set(_, unixSeconds: number)
		wall = unixSeconds
	end
	return (self :: any) :: Clock
end

return Clock
