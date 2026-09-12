--!strict
-- Recursively freezes a table graph so configuration and projections are immutable.
-- Cycles are tolerated; already-frozen tables are skipped.

local DeepFreeze = {}

local function freeze(value: any, seen: { [any]: boolean }): any
	if type(value) ~= "table" or seen[value] then
		return value
	end
	seen[value] = true
	for _, child in pairs(value) do
		if type(child) == "table" then
			freeze(child, seen)
		end
	end
	if not table.isfrozen(value) then
		table.freeze(value)
	end
	return value
end

function DeepFreeze.freeze<T>(value: T): T
	return freeze(value, {})
end

local function isDeepFrozen(value: any, seen: { [any]: boolean }): boolean
	if type(value) ~= "table" or seen[value] then
		return true
	end
	seen[value] = true
	if not table.isfrozen(value) then
		return false
	end
	for _, child in pairs(value) do
		if type(child) == "table" and not isDeepFrozen(child, seen) then
			return false
		end
	end
	return true
end

function DeepFreeze.isDeepFrozen(value: any): boolean
	return isDeepFrozen(value, {})
end

return DeepFreeze
