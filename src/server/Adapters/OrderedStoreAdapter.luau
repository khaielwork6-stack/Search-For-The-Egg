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
	local self = setmetatable({ kind = "real", _storeName = storeName, _stores = {} }, Real)
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

function Real.setAsync(self, board: string, key: string, value: number): boolean
	local ok = pcall(function()
		store(self, board):SetAsync(key, math.floor(value))
	end)
	return ok
end

function Real.topAsync(self, board: string, ascending: boolean, count: number): (boolean, { Entry }?)
	local ok, entries = pcall(function()
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
