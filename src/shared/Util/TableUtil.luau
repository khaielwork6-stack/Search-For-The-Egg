--!strict
-- Small pure table helpers shared by server, client, and tests.

local TableUtil = {}

function TableUtil.deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in pairs(value :: any) do
		copy[key] = TableUtil.deepCopy(child)
	end
	return (copy :: any) :: T
end

function TableUtil.deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in pairs(a) do
		if not TableUtil.deepEqual(value, b[key]) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

function TableUtil.count(value: { [any]: any }): number
	local n = 0
	for _ in pairs(value) do
		n += 1
	end
	return n
end

function TableUtil.keys(value: { [any]: any }): { any }
	local out = {}
	for key in pairs(value) do
		table.insert(out, key)
	end
	return out
end

function TableUtil.shallowMerge(base: { [any]: any }, overrides: { [any]: any }): { [any]: any }
	local out = table.clone(base)
	for key, value in pairs(overrides) do
		out[key] = value
	end
	return out
end

-- Returns a shallow copy with `key` set to `value` (structural sharing for reducers).
function TableUtil.with(base: { [any]: any }, key: any, value: any): { [any]: any }
	local out = table.clone(base)
	out[key] = value
	return out
end

function TableUtil.contains(list: { any }, needle: any): boolean
	return table.find(list, needle) ~= nil
end

function TableUtil.isArray(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local n = 0
	for key in pairs(value) do
		if type(key) ~= "number" then
			return false
		end
		n += 1
	end
	return n == #value
end

return TableUtil
