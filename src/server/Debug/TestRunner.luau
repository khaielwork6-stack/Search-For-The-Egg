--!strict
-- In-Studio test runner: discovers every *.spec ModuleScript under ServerStorage.Tests and runs it
-- through the shared Spec runner (the same modules the headless Lune harness executes).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Spec = require(ReplicatedStorage.Shared.Testing.Spec)

local TestRunner = {}

function TestRunner.discover(root: Instance): { ModuleScript }
	local specs = {}
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ModuleScript") and string.match(descendant.Name, "%.spec$") then
			table.insert(specs, descendant)
		end
	end
	table.sort(specs, function(a, b)
		return a.Name < b.Name
	end)
	return specs
end

function TestRunner.run(filter: string?): Spec.Result
	local root = ServerStorage:FindFirstChild("Tests")
	assert(root, "ServerStorage.Tests is missing (check the Rojo project mapping)")
	local suites = {}
	for _, module in ipairs(TestRunner.discover(root)) do
		if filter and not string.find(module.Name, filter, 1, true) then
			continue
		end
		table.insert(suites, {
			name = module.Name,
			specFn = function(...)
				return (require(module) :: any)(...)
			end,
		})
	end
	print(string.format("[SFE][Tests] discovered %d spec module(s)", #suites))
	local result = Spec.run(suites, { log = print, ctx = { game = game, isLune = false, require = require } })
	workspace:SetAttribute("SFE_TestsPassed", result.failed == 0)
	workspace:SetAttribute("SFE_TestsTotal", result.total)
	return result
end

return TestRunner
