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

-- True when DataStore access actually works (published place, or Studio with "Enable Studio Access to
-- API Services" on). GetDataStore alone succeeds in any published place even when API access is off
-- and every read/write then throws, which used to send a Studio player down the real-store path and
-- kick them after five failed loads; the probe therefore performs a real read.
function DataStoreAdapter.isAvailable(): boolean
	local ok = pcall(function()
		local DataStoreService = game:GetService("DataStoreService")
		local store = DataStoreService:GetDataStore("SFE_Probe")
		store:GetAsync("probe")
	end)
	return ok
end

return DataStoreAdapter
