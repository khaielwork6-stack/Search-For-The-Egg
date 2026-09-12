--!strict
-- Tiny schema combinator library used by NetSchema to validate every remote payload.
-- Rejects NaN/infinity, wrong types, unknown keys (strict objects), oversized strings/arrays,
-- and unknown enum values. Validation is pure and never throws for bad input.

local Schema = {}

export type Result = { ok: boolean, reason: string? }
export type Validator = { kind: string, check: (value: any, path: string) -> Result, [string]: any }

local function ok(): Result
	return { ok = true }
end

local function bad(path: string, reason: string): Result
	return { ok = false, reason = path .. ": " .. reason }
end

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Schema.number(options: { min: number?, max: number?, integer: boolean? }?): Validator
	local opts = (options or {}) :: any
	return {
		kind = "number",
		check = function(value, path)
			if not isFinite(value) then
				return bad(path, "expected finite number")
			end
			if opts.integer and value % 1 ~= 0 then
				return bad(path, "expected integer")
			end
			if opts.min and value < opts.min then
				return bad(path, "below minimum " .. tostring(opts.min))
			end
			if opts.max and value > opts.max then
				return bad(path, "above maximum " .. tostring(opts.max))
			end
			return ok()
		end,
	}
end

function Schema.string(options: { max: number?, min: number?, pattern: string? }?): Validator
	local opts = (options or {}) :: any
	local maxLen = opts.max or 128
	return {
		kind = "string",
		check = function(value, path)
			if type(value) ~= "string" then
				return bad(path, "expected string")
			end
			if #value > maxLen then
				return bad(path, "string too long (" .. #value .. " > " .. maxLen .. ")")
			end
			if opts.min and #value < opts.min then
				return bad(path, "string too short")
			end
			if opts.pattern and not string.match(value, opts.pattern) then
				return bad(path, "string does not match pattern")
			end
			return ok()
		end,
	}
end

-- Identifier: short, [A-Za-z0-9_-] only. Used for every config-keyed id (chapter, tool, class...).
function Schema.id(max: number?): Validator
	return Schema.string({ max = max or 48, min = 1, pattern = "^[%w_%-]+$" })
end

function Schema.boolean(): Validator
	return {
		kind = "boolean",
		check = function(value, path)
			if type(value) ~= "boolean" then
				return bad(path, "expected boolean")
			end
			return ok()
		end,
	}
end

function Schema.enum(values: { string }): Validator
	local lookup: { [string]: boolean } = {}
	for _, v in ipairs(values) do
		lookup[v] = true
	end
	return {
		kind = "enum",
		values = values,
		check = function(value, path)
			if type(value) ~= "string" or not lookup[value] then
				return bad(path, "not an allowed value")
			end
			return ok()
		end,
	}
end

function Schema.literal(expected: any): Validator
	return {
		kind = "literal",
		check = function(value, path)
			if value ~= expected then
				return bad(path, "expected literal " .. tostring(expected))
			end
			return ok()
		end,
	}
end

function Schema.optional(inner: Validator): Validator
	return {
		kind = "optional",
		inner = inner,
		check = function(value, path)
			if value == nil then
				return ok()
			end
			return inner.check(value, path)
		end,
	}
end

function Schema.array(item: Validator, options: { max: number?, min: number? }?): Validator
	local opts = (options or {}) :: any
	local maxLen = opts.max or 64
	return {
		kind = "array",
		check = function(value, path)
			if type(value) ~= "table" then
				return bad(path, "expected array")
			end
			local count = 0
			for key in pairs(value) do
				count += 1
				if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count + maxLen then
					return bad(path, "non-array key")
				end
			end
			if count ~= #value then
				return bad(path, "sparse array")
			end
			if count > maxLen then
				return bad(path, "array too long")
			end
			if opts.min and count < opts.min then
				return bad(path, "array too short")
			end
			for index, child in ipairs(value) do
				local result = item.check(child, path .. "[" .. index .. "]")
				if not result.ok then
					return result
				end
			end
			return ok()
		end,
	}
end

-- Strict object: every key must be declared; missing required keys fail.
function Schema.object(fields: { [string]: Validator }): Validator
	return {
		kind = "object",
		fields = fields,
		check = function(value, path)
			if type(value) ~= "table" then
				return bad(path, "expected object")
			end
			for key in pairs(value) do
				if type(key) ~= "string" or fields[key] == nil then
					return bad(path, "unknown key " .. tostring(key))
				end
			end
			for key, validator in pairs(fields) do
				local result = validator.check(value[key], path .. "." .. key)
				if not result.ok then
					return result
				end
			end
			return ok()
		end,
	}
end

-- Vector3 (Roblox datatype) with finite, bounded components.
function Schema.vector3(maxMagnitude: number?): Validator
	local limit = maxMagnitude or 5000
	return {
		kind = "vector3",
		check = function(value, path)
			if typeof(value) ~= "Vector3" then
				return bad(path, "expected Vector3")
			end
			local v = value :: any
			if not (isFinite(v.X) and isFinite(v.Y) and isFinite(v.Z)) then
				return bad(path, "non-finite vector component")
			end
			if v.Magnitude > limit then
				return bad(path, "vector magnitude too large")
			end
			return ok()
		end,
	}
end

-- Empty payload (no fields). Accepts nil or an empty table.
function Schema.none(): Validator
	return {
		kind = "none",
		check = function(value, path)
			if value == nil then
				return ok()
			end
			if type(value) ~= "table" or next(value) ~= nil then
				return bad(path, "expected no payload")
			end
			return ok()
		end,
	}
end

function Schema.validate(validator: Validator, value: any): Result
	return validator.check(value, "payload")
end

-- Estimates payload size (bytes-ish) and depth to reject oversized or deeply nested tables before
-- schema validation. Returns size, depth, and whether limits were exceeded.
function Schema.measure(value: any, maxBytes: number, maxDepth: number): (number, number, boolean)
	local size = 0
	local maxSeen = 0
	local exceeded = false
	local function walk(v: any, depth: number)
		if exceeded then
			return
		end
		if depth > maxSeen then
			maxSeen = depth
		end
		if depth > maxDepth then
			exceeded = true
			return
		end
		local kind = type(v)
		if kind == "string" then
			size += #v + 1
		elseif kind == "number" then
			size += 8
		elseif kind == "boolean" then
			size += 1
		elseif kind == "table" then
			size += 8
			for key, child in pairs(v) do
				walk(key, depth + 1)
				walk(child, depth + 1)
				if size > maxBytes then
					exceeded = true
					return
				end
			end
		else
			size += 16
		end
		if size > maxBytes then
			exceeded = true
		end
	end
	walk(value, 0)
	return size, maxSeen, exceeded
end

return Schema
