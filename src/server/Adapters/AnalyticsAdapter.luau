--!strict
-- Analytics sink adapter. Real: Roblox AnalyticsService custom events (pcall-guarded). Mock:
-- captures events for tests. The service above it enforces the enumerated event schema.

local AnalyticsAdapter = {}

export type Event = { name: string, userId: number?, fields: { [string]: any } }

export type Adapter = { send: (self: Adapter, event: Event) -> (), kind: string }

local Real = {}
Real.__index = Real

function AnalyticsAdapter.real(playersService: any): Adapter
	local self = setmetatable({ kind = "real", _players = playersService }, Real)
	return (self :: any) :: Adapter
end

function Real.send(self, event: Event)
	local player = event.userId and self._players:GetPlayerByUserId(event.userId)
	if not player then
		return
	end
	local AnalyticsService = game:GetService("AnalyticsService")
	pcall(function()
		AnalyticsService:LogCustomEvent(player, event.name, 1, event.fields)
	end)
end

local Mock = {}
Mock.__index = Mock

export type Mock = Adapter & { events: { Event }, countOf: (self: Mock, name: string) -> number, clear: (self: Mock) -> () }

function AnalyticsAdapter.mock(): Mock
	local self = setmetatable({ kind = "mock", events = {} }, Mock)
	return (self :: any) :: Mock
end

function Mock.send(self, event: Event)
	table.insert(self.events, event)
end

function Mock.countOf(self, name: string): number
	local n = 0
	for _, event in ipairs(self.events) do
		if event.name == name then
			n += 1
		end
	end
	return n
end

function Mock.clear(self)
	table.clear(self.events)
end

return AnalyticsAdapter
