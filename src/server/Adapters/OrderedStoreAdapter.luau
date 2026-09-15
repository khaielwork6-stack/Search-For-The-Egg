--!strict
-- Ordered-store adapter for leaderboards (DATASTORE_SCHEMA 2: SFE_GlobalStats_v1, sharded by board).
-- Real: one OrderedDataStore per board. Mock: in-memory tables for tests and Studio. Values are
-- integers; the service above bounds write frequency.

local OrderedStoreAdapter = {}

export type Entry = { key: string, value: number }

export type Adapter = {
	setAsync: (self: Adapter, board: string, key: string, value: number) -> boolean,
	topAsync: (self: Adapter, board: string, ascending: boolean, count: number) -> (boolean, { Entry }?),
	kind: string,
}

-- Real ---------------------------------------------------------------------------------------

local Real = {}
Real.__index = Real

function OrderedStoreAdapter.real(storeName: string): Adapter
	local self = setmetatable({ kind = "real", _storeName = storeName, _stores = {}, _ascending = {} }, Real)
	return (self :: any) :: Adapter
end

local function store(self: any, board: string): any
	local existing = self._stores[board]
	if existing then
		return existing
	end
	local DataStoreService = game:GetService("DataStoreService")
	local ordered = DataStoreService:GetOrderedDataStore(self._storeName, board)
	self._stores[board] = ordered
	return ordered
end

-- Data store calls fail for reasons that pass: a throttle, a brief outage, a request-budget dip. One
-- pcall and a shrug lost the write silently. These retry a small number of times with a widening
-- pause, which is the shape Roblox's own guidance asks for, and give up rather than blocking a tick.
local MAX_ATTEMPTS = 3
local BASE_BACKOFF_SECONDS = 0.6

local function withRetry<T>(work: () -> T): (boolean, T?)
	local lastError: any = nil
	for attempt = 1, MAX_ATTEMPTS do
		local ok, result = pcall(work)
		if ok then
			return true, result
		end
		lastError = result
		if attempt < MAX_ATTEMPTS then
			-- 0.6 s, then 1.2 s: long enough to clear a throttle, short enough that the caller's own
			-- tick is never held up for a noticeable time.
			task.wait(BASE_BACKOFF_SECONDS * attempt)
		end
	end
	warn("[SFE][Leaderboard] data store call failed after " .. MAX_ATTEMPTS .. " attempts: " .. tostring(lastError))
	return false, nil
end

function Real.setAsync(self, board: string, key: string, value: number): boolean
	-- UpdateAsync rather than SetAsync: two servers finishing a round at the same moment would
	-- otherwise race, and the loser's score could overwrite a better one. The transform keeps
	-- whichever value is better for this board's direction.
	local ascending = self._ascending[board] == true
	local ok = withRetry(function()
		store(self, board):UpdateAsync(key, function(previous)
			local incoming = math.floor(value)
			if type(previous) ~= "number" then
				return incoming
			end
			if ascending then
				return math.min(previous, incoming)
			end
			return math.max(previous, incoming)
		end)
	end)
	return ok
end

-- The caller tells the adapter which way a board sorts, so the merge above can keep the better value.
function Real.setDirection(self, board: string, ascending: boolean)
	self._ascending[board] = ascending
end

function Real.topAsync(self, board: string, ascending: boolean, count: number): (boolean, { Entry }?)
	local ok, entries = withRetry(function()
		local pages = store(self, board):GetSortedAsync(ascending, math.clamp(count, 1, 100))
		local page = pages:GetCurrentPage()
		local out = {}
		for _, item in ipairs(page) do
			table.insert(out, { key = item.key, value = item.value })
		end
		return out
	end)
	if ok then
		return true, entries
	end
	return false, nil
end

-- Mock ---------------------------------------------------------------------------------------

local Mock = {}
Mock.__index = Mock

export type Mock = Adapter & {
	writes: number,
	reads: number,
	failNext: (self: Mock, count: number) -> (),
	peek: (self: Mock, board: string, key: string) -> number?,
}

function OrderedStoreAdapter.mock(): Mock
	local self = setmetatable({ kind = "mock", _boards = {}, writes = 0, reads = 0, _fail = 0 }, Mock)
	return (self :: any) :: Mock
end

function Mock.setAsync(self, board: string, key: string, value: number): boolean
	if self._fail > 0 then
		self._fail -= 1
		return false
	end
	self.writes += 1
	self._boards[board] = self._boards[board] or {}
	self._boards[board][key] = math.floor(value)
	return true
end

function Mock.topAsync(self, board: string, ascending: boolean, count: number): (boolean, { Entry }?)
	if self._fail > 0 then
		self._fail -= 1
		return false, nil
	end
	self.reads += 1
	local out: { Entry } = {}
	for key, value in pairs(self._boards[board] or {}) do
		table.insert(out, { key = key, value = value })
	end
	table.sort(out, function(a, b)
		if a.value == b.value then
			return a.key < b.key
		end
		return if ascending then a.value < b.value else a.value > b.value
	end)
	while #out > count do
		table.remove(out)
	end
	return true, out
end

function Mock.failNext(self, count: number)
	self._fail = count
end

function Mock.peek(self, board: string, key: string): number?
	local entries = self._boards[board]
	return entries and entries[key] or nil
end

return OrderedStoreAdapter
