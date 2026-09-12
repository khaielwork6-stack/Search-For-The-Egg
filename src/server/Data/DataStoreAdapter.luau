--!strict
-- Real DataStoreService adapter. Same interface as MockDataStore: getAsync/updateAsync returning
-- (ok, valueOrError). DataStoreService is resolved lazily so the module loads headlessly.

local DataStoreAdapter = {}
DataStoreAdapter.__index = DataStoreAdapter

export type DataStoreAdapter = typeof(setmetatable({} :: { name: string, _store: any }, DataStoreAdapter))

function DataStoreAdapter.new(name: string): DataStoreAdapter
	return setmetatable({ name = name, _store = nil }, DataStoreAdapter)
end

local function getStore(self: DataStoreAdapter): any
	if not self._store then
		local DataStoreService = game:GetService("DataStoreService")
		self._store = DataStoreService:GetDataStore(self.name)
	end
	return self._store
end

function DataStoreAdapter.getAsync(self: DataStoreAdapter, key: string): (boolean, any)
	local ok, result = pcall(function()
		return getStore(self):GetAsync(key)
	end)
	return ok, result
end

function DataStoreAdapter.updateAsync(self: DataStoreAdapter, key: string, transform: (any) -> any): (boolean, any)
	local ok, result = pcall(function()
		return getStore(self):UpdateAsync(key, transform)
	end)
	return ok, result
end

-- True when DataStore access is expected to work (published place or Studio with API access).
function DataStoreAdapter.isAvailable(): boolean
	local ok, result = pcall(function()
		local DataStoreService = game:GetService("DataStoreService")
		local store = DataStoreService:GetDataStore("SFE_Probe")
		return store ~= nil
	end)
	return ok and result == true
end

return DataStoreAdapter
