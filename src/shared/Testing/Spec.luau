--!strict
-- Minimal TestEZ-compatible spec runner (describe / it / expect) that runs identically inside
-- Roblox Studio and inside the headless Lune harness. Spec modules return
-- `function(describe, it, expect, ctx)` and register cases synchronously.
-- The pack allows a minimal runner when no healthy framework already exists in the repository.

local Spec = {}

export type Expectation = {
	toBe: (expected: any) -> (),
	toEqual: (expected: any) -> (),
	toBeTruthy: () -> (),
	toBeFalsy: () -> (),
	toBeNil: () -> (),
	toBeCloseTo: (expected: number, tolerance: number?) -> (),
	toBeGreaterThan: (expected: number) -> (),
	toBeGreaterThanOrEqual: (expected: number) -> (),
	toBeLessThan: (expected: number) -> (),
	toBeLessThanOrEqual: (expected: number) -> (),
	toThrow: (pattern: string?) -> (),
	toContain: (needle: any) -> (),
	toHaveLength: (n: number) -> (),
	toBeType: (typeName: string) -> (),
	never: Expectation,
}

export type Result = {
	passed: number,
	failed: number,
	skipped: number,
	total: number,
	failures: { { name: string, message: string } },
	durationSeconds: number,
}

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in pairs(a) do
		if not deepEqual(value, b[key]) then
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

local function describeValue(value: any, depth: number?): string
	local kind = type(value)
	local level = depth or 0
	if kind == "string" then
		return string.format("%q", value)
	elseif kind == "table" then
		if level >= 2 then
			return "{...}"
		end
		local parts = {}
		local n = 0
		for key, child in pairs(value) do
			n += 1
			if n > 8 then
				table.insert(parts, "...")
				break
			end
			table.insert(parts, tostring(key) .. "=" .. describeValue(child, level + 1))
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(value)
end

local function makeExpect(value: any, negate: boolean): Expectation
	local self = {} :: any

	local function check(condition: boolean, message: string)
		if negate then
			condition = not condition
		end
		if not condition then
			error((negate and "NOT " or "") .. message, 3)
		end
	end

	function self.toBe(expected)
		check(value == expected, "expected " .. describeValue(value) .. " to be " .. describeValue(expected))
	end
	function self.toEqual(expected)
		check(deepEqual(value, expected), "expected " .. describeValue(value) .. " to deep-equal " .. describeValue(expected))
	end
	function self.toBeTruthy()
		check(value and true or false, "expected " .. describeValue(value) .. " to be truthy")
	end
	function self.toBeFalsy()
		check(not value, "expected " .. describeValue(value) .. " to be falsy")
	end
	function self.toBeNil()
		check(value == nil, "expected " .. describeValue(value) .. " to be nil")
	end
	function self.toBeCloseTo(expected, tolerance)
		local tol = tolerance or 1e-9
		check(
			type(value) == "number" and math.abs(value - expected) <= tol,
			"expected " .. describeValue(value) .. " to be within " .. tostring(tol) .. " of " .. tostring(expected)
		)
	end
	function self.toBeGreaterThan(expected)
		check(type(value) == "number" and value > expected, "expected " .. tostring(value) .. " > " .. tostring(expected))
	end
	function self.toBeGreaterThanOrEqual(expected)
		check(type(value) == "number" and value >= expected, "expected " .. tostring(value) .. " >= " .. tostring(expected))
	end
	function self.toBeLessThan(expected)
		check(type(value) == "number" and value < expected, "expected " .. tostring(value) .. " < " .. tostring(expected))
	end
	function self.toBeLessThanOrEqual(expected)
		check(type(value) == "number" and value <= expected, "expected " .. tostring(value) .. " <= " .. tostring(expected))
	end
	function self.toThrow(pattern)
		assert(type(value) == "function", "toThrow expects a function")
		local ok, err = pcall(value)
		local matched = not ok
		if matched and pattern then
			matched = string.find(tostring(err), pattern, 1, true) ~= nil
		end
		check(
			matched,
			"expected function to throw"
				.. (pattern and (" matching " .. string.format("%q", pattern)) or "")
				.. (ok and " but it returned" or (" but got: " .. tostring(err)))
		)
	end
	function self.toContain(needle)
		local found = false
		if type(value) == "table" then
			for _, item in pairs(value) do
				if deepEqual(item, needle) then
					found = true
					break
				end
			end
		elseif type(value) == "string" then
			found = string.find(value, tostring(needle), 1, true) ~= nil
		end
		check(found, "expected " .. describeValue(value) .. " to contain " .. describeValue(needle))
	end
	function self.toHaveLength(n)
		local len = if type(value) == "table" or type(value) == "string" then #value else -1
		check(len == n, "expected length " .. tostring(n) .. " but got " .. tostring(len))
	end
	function self.toBeType(typeName)
		check(typeof(value) == typeName, "expected type " .. typeName .. " but got " .. typeof(value))
	end

	if not negate then
		self.never = makeExpect(value, true)
	end
	return self :: Expectation
end

type Case = { name: string, fn: (...any) -> ...any, skip: boolean }

-- Collects cases from a spec module function.
local function collect(specFn: any, ctx: any): { Case }
	local cases: { Case } = {}
	local prefix: { string } = {}

	local function describe(name: string, body: () -> ())
		table.insert(prefix, name)
		local ok, err = pcall(body)
		table.remove(prefix)
		if not ok then
			table.insert(cases, {
				name = table.concat(prefix, " > ") .. " > " .. name .. " (describe body)",
				fn = function()
					error(err)
				end,
				skip = false,
			})
		end
	end

	local function it(name: string, fn: () -> ())
		local full = table.concat(prefix, " > ")
		table.insert(cases, { name = (full ~= "" and (full .. " > ") or "") .. name, fn = fn, skip = false })
	end

	local function expect(value: any): Expectation
		return makeExpect(value, false)
	end

	local api = {
		describe = describe,
		it = it,
		expect = expect,
		xit = function(name: string)
			local full = table.concat(prefix, " > ")
			table.insert(cases, { name = full .. " > " .. name, fn = function() end, skip = true })
		end,
	}
	specFn(describe, it, expect, ctx, api)
	return cases
end

export type Suite = { name: string, specFn: any }

-- Runs every suite and returns aggregated results. `log` receives human-readable lines.
function Spec.run(suites: { Suite }, options: { log: ((string) -> ())?, ctx: any?, clock: (() -> number)? }?): Result
	local opts = (options or {}) :: any
	local log = opts.log or print
	local now = opts.clock or os.clock
	local started = now()
	local result: Result = { passed = 0, failed = 0, skipped = 0, total = 0, failures = {}, durationSeconds = 0 }

	for _, suite in ipairs(suites) do
		local okCollect, cases = pcall(collect, suite.specFn, opts.ctx)
		if not okCollect then
			result.failed += 1
			result.total += 1
			table.insert(result.failures, { name = suite.name .. " (load)", message = tostring(cases) })
			log("  FAIL " .. suite.name .. " (load): " .. tostring(cases))
			continue
		end
		local suitePassed, suiteFailed = 0, 0
		for _, case in ipairs(cases :: { Case }) do
			result.total += 1
			if case.skip then
				result.skipped += 1
				continue
			end
			local ok, err = pcall(case.fn)
			if ok then
				result.passed += 1
				suitePassed += 1
			else
				result.failed += 1
				suiteFailed += 1
				table.insert(result.failures, { name = suite.name .. " :: " .. case.name, message = tostring(err) })
				log("  FAIL " .. suite.name .. " :: " .. case.name)
				log("       " .. tostring(err))
			end
		end
		log(string.format("%s %s (%d passed, %d failed)", suiteFailed == 0 and "PASS" or "FAIL", suite.name, suitePassed, suiteFailed))
	end

	result.durationSeconds = now() - started
	log(
		string.format(
			"Tests: %d passed, %d failed, %d skipped, %d total (%.2fs)",
			result.passed,
			result.failed,
			result.skipped,
			result.total,
			result.durationSeconds
		)
	)
	return result
end

Spec.deepEqual = deepEqual

return Spec
