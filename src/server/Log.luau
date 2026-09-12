--!strict
-- Structured server logger. Messages are enumerated codes plus numeric/enumerated fields; free
-- text and personal data never enter logs (MASTER_SPEC 18/19, DATASTORE_SCHEMA 13).

local Log = {}
Log.__index = Log

export type Level = "debug" | "info" | "warn" | "error"

export type Log = typeof(setmetatable({} :: { scope: string, minLevel: number, sink: ((string) -> ())? }, Log))

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }

local function formatFields(fields: { [string]: any }?): string
	if not fields then
		return ""
	end
	local keys = {}
	for key in pairs(fields) do
		table.insert(keys, key)
	end
	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do
		local value = fields[key]
		local kind = type(value)
		if kind == "number" or kind == "boolean" then
			table.insert(parts, key .. "=" .. tostring(value))
		elseif kind == "string" then
			-- Enumerated identifiers only; anything long is truncated to protect against free text.
			table.insert(parts, key .. "=" .. string.sub(value, 1, 48))
		else
			table.insert(parts, key .. "=<" .. kind .. ">")
		end
	end
	return " {" .. table.concat(parts, " ") .. "}"
end

function Log.new(scope: string, minLevel: Level?): Log
	return setmetatable({ scope = scope, minLevel = LEVELS[minLevel or "info"], sink = nil }, Log)
end

function Log.emit(self: Log, level: Level, code: string, fields: { [string]: any }?)
	if LEVELS[level] < self.minLevel then
		return
	end
	local line = string.format("[SFE][%s][%s] %s%s", self.scope, level, code, formatFields(fields))
	if self.sink then
		self.sink(line)
	elseif level == "warn" or level == "error" then
		warn(line)
	else
		print(line)
	end
end

function Log.debug(self: Log, code: string, fields: { [string]: any }?)
	self:emit("debug", code, fields)
end
function Log.info(self: Log, code: string, fields: { [string]: any }?)
	self:emit("info", code, fields)
end
function Log.warn(self: Log, code: string, fields: { [string]: any }?)
	self:emit("warn", code, fields)
end
function Log.error(self: Log, code: string, fields: { [string]: any }?)
	self:emit("error", code, fields)
end

-- Test double that captures lines.
function Log.capture(scope: string): (Log, { string })
	local lines = {}
	local log = Log.new(scope, "debug")
	log.sink = function(line)
		table.insert(lines, line)
	end
	return log, lines
end

return Log
