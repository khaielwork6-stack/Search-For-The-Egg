--!strict
-- Minimal synchronous signal with connection handles. No Roblox instance dependency so it
-- runs identically in Studio and in the headless Lune test harness.

local Signal = {}
Signal.__index = Signal

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	Destroy: (self: Signal<T...>) -> (),
	ConnectionCount: (self: Signal<T...>) -> number,
}

function Signal.new<T...>(): Signal<T...>
	local self = setmetatable({ _handlers = {} :: { any }, _destroyed = false }, Signal)
	return (self :: any) :: Signal<T...>
end

function Signal:Connect(fn)
	assert(type(fn) == "function", "Signal:Connect expects a function")
	local handlers = self._handlers
	local connection = { Connected = true }
	function connection.Disconnect(conn)
		if not conn.Connected then
			return
		end
		conn.Connected = false
		local index = table.find(handlers, conn)
		if index then
			table.remove(handlers, index)
		end
	end
	connection._fn = fn
	table.insert(handlers, connection)
	return connection
end

function Signal:Once(fn)
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

function Signal:Fire(...)
	if self._destroyed then
		return
	end
	local snapshot = table.clone(self._handlers)
	for _, connection in ipairs(snapshot) do
		if connection.Connected then
			local ok, err = pcall(connection._fn, ...)
			if not ok then
				warn("[Signal] handler error: " .. tostring(err))
			end
		end
	end
end

function Signal:ConnectionCount(): number
	return #self._handlers
end

function Signal:Destroy()
	self._destroyed = true
	for _, connection in ipairs(self._handlers) do
		connection.Connected = false
	end
	table.clear(self._handlers)
end

return Signal
