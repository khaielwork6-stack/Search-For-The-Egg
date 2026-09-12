--!strict
-- Lifetime bag: tracks connections, instances, functions, and nested troves so controllers and
-- components clean up everything on unload. Accepts anything with Disconnect/Destroy or a function.

local Trove = {}
Trove.__index = Trove

export type Trove = typeof(setmetatable({} :: { _items: { any }, _destroyed: boolean }, Trove))

function Trove.new(): Trove
	return setmetatable({ _items = {}, _destroyed = false }, Trove)
end

function Trove.add<T>(self: Trove, item: T): T
	assert(not self._destroyed, "Trove already destroyed")
	table.insert(self._items, item)
	return item
end

function Trove.extend(self: Trove): Trove
	return self:add(Trove.new())
end

local function cleanupItem(item: any)
	local kind = typeof(item)
	if kind == "function" then
		item()
	elseif kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		item:Destroy()
	elseif kind == "table" then
		if type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.Disconnect) == "function" then
			item:Disconnect()
		elseif type(item.destroy) == "function" then
			item:destroy()
		end
	elseif kind == "thread" then
		pcall(task.cancel, item)
	end
end

function Trove.remove(self: Trove, item: any): boolean
	local index = table.find(self._items, item)
	if not index then
		return false
	end
	table.remove(self._items, index)
	cleanupItem(item)
	return true
end

function Trove.clean(self: Trove)
	local items = self._items
	self._items = {}
	for i = #items, 1, -1 do
		cleanupItem(items[i])
	end
end

function Trove.count(self: Trove): number
	return #self._items
end

function Trove.destroy(self: Trove)
	if self._destroyed then
		return
	end
	self:clean()
	self._destroyed = true
end

Trove.Destroy = Trove.destroy

return Trove
