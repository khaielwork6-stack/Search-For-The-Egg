--!nocheck
-- Headless harness: builds the Rojo test project into a place file, loads it with Lune's roblox
-- library, and executes ModuleScripts with a custom `require` so the exact same spec files run in
-- Studio and on the command line. Roblox-only services are stubbed just enough for pure modules.

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Harness = {}

local function guid()
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	return (
		string.gsub(template, "[xy]", function(c)
			local v = if c == "x" then math.random(0, 15) else math.random(8, 11)
			return string.format("%x", v)
		end)
	)
end

function Harness.build(projectFile: string, output: string): boolean
	local dir = string.match(output, "^(.*)[/\\]") or "."
	if not fs.isDir(dir) then
		fs.writeDir(dir)
	end
	local result = process.exec("rojo", { "build", projectFile, "-o", output })
	if not result.ok then
		print(result.stderr)
		return false
	end
	return true
end

function Harness.load(placeFile: string)
	local dm = roblox.deserializePlace(fs.readFile(placeFile))
	local ctx = {}
	ctx.game = dm
	ctx.isLune = true
	ctx.moduleCache = {}
	ctx.moduleLoads = 0

	local runService = {
		IsServer = function()
			return true
		end,
		IsClient = function()
			return false
		end,
		IsStudio = function()
			return true
		end,
		IsRunning = function()
			return false
		end,
		IsRunMode = function()
			return false
		end,
		IsEdit = function()
			return true
		end,
	}
	local httpService = {
		GenerateGUID = function(_, wrap)
			local id = guid()
			return if wrap == false then id else "{" .. id .. "}"
		end,
		JSONEncode = function(_, value)
			return serde.encode("json", value)
		end,
		JSONDecode = function(_, text)
			return serde.decode("json", text)
		end,
	}
	local serviceOverrides = {
		RunService = runService,
		HttpService = httpService,
	}

	local gameProxy = setmetatable({}, {
		__index = function(_, key)
			if key == "GetService" then
				return function(_, name)
					local override = serviceOverrides[name]
					if override then
						return override
					end
					local ok, service = pcall(function()
						return dm:GetService(name)
					end)
					if ok and service then
						return service
					end
					error("Harness: service not available headlessly: " .. tostring(name))
				end
			elseif key == "PlaceId" then
				return 0
			elseif key == "JobId" then
				return "lune-job"
			elseif key == "Name" then
				return dm.Name
			end
			local child = dm:FindFirstChild(key)
			if child then
				return child
			end
			return dm[key]
		end,
	})

	local globals = {
		game = gameProxy,
		workspace = dm:GetService("Workspace"),
		Instance = roblox.Instance,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Enum = roblox.Enum,
		NumberRange = roblox.NumberRange,
		task = task,
		tick = os.clock,
		elapsedTime = os.clock,
		settings = function()
			return {}
		end,
	}

	local function customRequire(target)
		if type(target) ~= "userdata" then
			error("Harness require expects an Instance, got " .. typeof(target))
		end
		local cached = ctx.moduleCache[target]
		if cached ~= nil then
			if cached == "__loading__" then
				error("Harness: cyclic require of " .. target:GetFullName())
			end
			return cached
		end
		if target.ClassName ~= "ModuleScript" then
			error("Harness: cannot require non-ModuleScript " .. target:GetFullName())
		end
		ctx.moduleCache[target] = "__loading__"
		-- luau.load copies the environment table, so build a flat table per module.
		local env = table.clone(globals)
		env.script = target
		env.require = customRequire
		local chunk = luau.load(target.Source, {
			debugName = target:GetFullName(),
			environment = env,
			injectGlobals = true,
		})
		local result = chunk()
		if result == nil then
			result = true
		end
		ctx.moduleCache[target] = result
		ctx.moduleLoads += 1
		return result
	end
	globals.require = customRequire
	ctx.require = customRequire
	ctx.globals = globals
	return ctx
end

-- Finds every ModuleScript whose name ends with ".spec" under `root` (recursively).
function Harness.discoverSpecs(root)
	local specs = {}
	local function walk(instance)
		for _, child in ipairs(instance:GetChildren()) do
			if child.ClassName == "ModuleScript" and string.match(child.Name, "%.spec$") then
				table.insert(specs, child)
			end
			walk(child)
		end
	end
	walk(root)
	table.sort(specs, function(a, b)
		return a.Name < b.Name
	end)
	return specs
end

return Harness
