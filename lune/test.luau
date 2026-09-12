--!nocheck
-- Headless test command: `lune run lune/test`
-- Builds test.project.json, loads the place, runs every *.spec ModuleScript under
-- ServerStorage.Tests through the shared Spec runner, prints counts, and exits non-zero on failure.

local process = require("@lune/process")
local Harness = require("./harness")

local PROJECT = "test.project.json"
local OUTPUT = "build/test.rbxl"

local filter = process.args[1]

print("[test] building " .. PROJECT .. " -> " .. OUTPUT)
if not Harness.build(PROJECT, OUTPUT) then
	print("[test] rojo build failed")
	process.exit(2)
end

local ctx = Harness.load(OUTPUT)
local game = ctx.game
local Spec = ctx.require(game:GetService("ReplicatedStorage").Shared.Testing.Spec)
local testsRoot = game:GetService("ServerStorage"):FindFirstChild("Tests")
if not testsRoot then
	print("[test] ServerStorage.Tests missing from build")
	process.exit(2)
end

local suites = {}
for _, module in ipairs(Harness.discoverSpecs(testsRoot)) do
	if filter and not string.find(module.Name, filter, 1, true) then
		continue
	end
	table.insert(suites, {
		name = module.Name,
		specFn = function(...)
			local specFn = ctx.require(module)
			return specFn(...)
		end,
	})
end

print(string.format("[test] discovered %d spec module(s)", #suites))
local result = Spec.run(suites, {
	log = print,
	ctx = { game = game, isLune = true, require = ctx.require },
})

print(string.format("[test] modules loaded: %d", ctx.moduleLoads))
if result.failed > 0 then
	print(string.format("[test] FAILED: %d failed of %d", result.failed, result.total))
	process.exit(1)
end
print(string.format("[test] OK: %d passed, %d skipped, %d total", result.passed, result.skipped, result.total))
process.exit(0)
