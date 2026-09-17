--!strict
-- One-shot-per-window gate keyed by an arbitrary string. The first `tryPass(key)` passes and opens a
-- window of `windowSeconds`; every further pass for that key inside the window is refused, and the
-- refusal does NOT extend the window, so a player who keeps mashing still hears the denial again
-- once the window has run out.
--
-- Used for three things that must never spam:
--   * client denial feedback (key = reason, 5 s)              - UI/Feedback
--   * notification de-dupe (key = message text, 1.5 s)         - UI/Components/Toast
--   * server denial pushes (key = userId .. ":" .. reason, 5 s) - init.server `sendDenial`
-- Pure (the clock is injected), so it is tested under lune.

local CooldownGate = {}
CooldownGate.__index = CooldownGate

export type CooldownGate = typeof(setmetatable(
	{} :: { _window: number, _clock: () -> number, _openedAt: { [string]: number } },
	CooldownGate
))

function CooldownGate.new(windowSeconds: number, clock: () -> number): CooldownGate
	assert(type(windowSeconds) == "number" and windowSeconds >= 0, "CooldownGate window must be >= 0")
	return setmetatable({ _window = windowSeconds, _clock = clock, _openedAt = {} }, CooldownGate)
end

-- A message's de-dupe key: identical text is one notification whatever tone or caller it came from,
-- so case and runs of whitespace do not make two.
function CooldownGate.textKey(text: string): string
	local collapsed = string.gsub(text, "%s+", " ")
	local trimmed = string.match(collapsed, "^ ?(.-) ?$") or collapsed
	return string.lower(trimmed)
end

-- True (and the window opens) when `key` has not passed within the window.
function CooldownGate.tryPass(self: CooldownGate, key: string): boolean
	local now = self._clock()
	local opened = self._openedAt[key]
	if opened ~= nil and now - opened < self._window then
		return false
	end
	self._openedAt[key] = now
	return true
end

-- True when `key` would pass right now (does not open a window).
function CooldownGate.isOpen(self: CooldownGate, key: string): boolean
	local opened = self._openedAt[key]
	return opened == nil or self._clock() - opened >= self._window
end

function CooldownGate.setWindow(self: CooldownGate, windowSeconds: number)
	assert(type(windowSeconds) == "number" and windowSeconds >= 0, "CooldownGate window must be >= 0")
	self._window = windowSeconds
end

function CooldownGate.window(self: CooldownGate): number
	return self._window
end

-- Forgets one key, or every key when none is given.
function CooldownGate.reset(self: CooldownGate, key: string?)
	if key == nil then
		table.clear(self._openedAt)
	else
		self._openedAt[key] = nil
	end
end

-- Forgets every key starting with `prefix` (a player leaving: "123:").
function CooldownGate.clearPrefix(self: CooldownGate, prefix: string)
	for key in pairs(self._openedAt) do
		if string.sub(key, 1, #prefix) == prefix then
			self._openedAt[key] = nil
		end
	end
end

-- Drops keys whose window has closed, so a long session does not accumulate one entry per message.
function CooldownGate.sweep(self: CooldownGate)
	local now = self._clock()
	for key, opened in pairs(self._openedAt) do
		if now - opened >= self._window then
			self._openedAt[key] = nil
		end
	end
end

function CooldownGate.size(self: CooldownGate): number
	local count = 0
	for _ in pairs(self._openedAt) do
		count += 1
	end
	return count
end

return CooldownGate
