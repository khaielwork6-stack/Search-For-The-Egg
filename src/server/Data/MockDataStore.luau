--!strict
-- In-memory DataStore test double implementing the same adapter interface as DataStoreAdapter.
-- Supports failure injection (next N calls fail), call counting, and inspection of stored records.
-- Values are deep-copied on the way in and out so tests cannot share references with the "cloud".

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)

local MockDataStore = {}
MockDataStore.__index = MockDataStore

export type MockDataStore = typeof(setmetatable(
	{} :: {
		name: string,
		_records: { [string]: any },
		_failNext: number,
		_failMatcher: ((op: string, key: string) -> boolean)?,
		calls: { get: number, update: number, failed: number },
	},
	MockDataStore
))

function MockDataStore.new(name: string): MockDataStore
	return setmetatable({
		name = name,
		_records = {},
		_failNext = 0,
		_failMatcher = nil,
		calls = { get = 0, update = 0, failed = 0 },
	}, MockDataStore)
end

-- Makes the next `count` operations fail (simulating DataStore outages / throttling).
function MockDataStore.failNext(self: MockDataStore, count: number, matcher: ((op: string, key: string) -> boolean)?)
	self._failNext = count
	self._failMatcher = matcher
end

local function shouldFail(self: MockDataStore, op: string, key: string): boolean
	if self._failNext <= 0 then
		return false
	end
	if self._failMatcher and not self._failMatcher(op, key) then
		return false
	end
	self._failNext -= 1
	self.calls.failed += 1
	return true
end

function MockDataStore.getAsync(self: MockDataStore, key: string): (boolean, any)
	self.calls.get += 1
	if shouldFail(self, "get", key) then
		return false, "mock_failure"
	end
	return true, TableUtil.deepCopy(self._records[key])
end

-- transform(old) -> new | nil. Returning nil aborts the write (like Roblox UpdateAsync).
function MockDataStore.updateAsync(self: MockDataStore, key: string, transform: (any) -> any): (boolean, any)
	self.calls.update += 1
	if shouldFail(self, "update", key) then
		return false, "mock_failure"
	end
	local current = TableUtil.deepCopy(self._records[key])
	local ok, result = pcall(transform, current)
	if not ok then
		return false, "transform_error: " .. tostring(result)
	end
	if result == nil then
		return true, TableUtil.deepCopy(self._records[key])
	end
	self._records[key] = TableUtil.deepCopy(result)
	return true, TableUtil.deepCopy(result)
end

-- Test helpers -------------------------------------------------------------------------------

function MockDataStore.peek(self: MockDataStore, key: string): any
	return TableUtil.deepCopy(self._records[key])
end

function MockDataStore.seed(self: MockDataStore, key: string, value: any)
	self._records[key] = TableUtil.deepCopy(value)
end

function MockDataStore.keyCount(self: MockDataStore): number
	return TableUtil.count(self._records)
end

return MockDataStore
