--!strict
-- Typed, immutable configuration facade.
--   Server: loads the raw SYSTEM_CONFIG ModuleScript (Rojo maps the build pack JSON into
--           ServerStorage.SFE.SystemConfig), validates it, freezes it.
--   Client: decodes the sanitized projection the server publishes at boot.
-- Services read tunables through this module only; they never restate literals.

local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local DeepFreeze = require(script.Parent.Util.DeepFreeze)
local Validator = require(script.Validator)
local Projection = require(script.Projection)

local Config = {}

export type Report = Validator.Report

Config.RUNTIME_FOLDER_NAME = "SFE_Runtime"
Config.CLIENT_CONFIG_VALUE_NAME = "ClientConfig"

local cached: { [string]: any }? = nil

-- Builds a frozen config from a raw table. Throws when validation fails so a broken config can
-- never silently reach services.
function Config.fromRaw(raw: { [string]: any }, options: { validate: boolean? }?): { [string]: any }
	local opts = (options or {}) :: any
	if opts.validate ~= false then
		local report = Validator.validate(raw)
		if not report.ok then
			error("SYSTEM_CONFIG invalid:\n  - " .. table.concat(report.errors, "\n  - "))
		end
	end
	return DeepFreeze.freeze(raw)
end

function Config.validate(raw: { [string]: any }): Report
	return Validator.validate(raw)
end

function Config.toClientProjection(raw: { [string]: any }): { [string]: any }
	return Projection.toClient(raw)
end

local function loadServerRaw(): { [string]: any }
	local ServerStorage = game:GetService("ServerStorage")
	local folder = ServerStorage:FindFirstChild("SFE")
	local module = folder and folder:FindFirstChild("SystemConfig")
	if not module then
		error("ServerStorage.SFE.SystemConfig is missing; check the Rojo project mapping for SYSTEM_CONFIG.json")
	end
	return require(module) :: any
end

local function loadClientRaw(): { [string]: any }
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local runtime = ReplicatedStorage:WaitForChild(Config.RUNTIME_FOLDER_NAME, 30)
	if not runtime then
		error("SFE_Runtime folder never replicated; server bootstrap did not publish config")
	end
	local value = runtime:WaitForChild(Config.CLIENT_CONFIG_VALUE_NAME, 30) :: StringValue?
	if not value then
		error("ClientConfig never replicated")
	end
	return HttpService:JSONDecode(value.Value)
end

-- Returns the process-wide frozen config. On the server the full config; on the client the
-- projection. Tests use Config.fromRaw with fixtures instead.
function Config.get(): { [string]: any }
	if cached then
		return cached
	end
	if RunService:IsServer() then
		cached = Config.fromRaw(loadServerRaw())
	else
		cached = Config.fromRaw(loadClientRaw(), { validate = false })
	end
	return cached :: any
end

-- Server only: publishes the sanitized projection for clients. Idempotent.
function Config.publishClientProjection(runtimeFolder: Instance): StringValue
	assert(RunService:IsServer(), "publishClientProjection is server-only")
	local raw = loadServerRaw()
	local projection = Projection.toClient(raw)
	assert(not Projection.leaksServerData(projection), "projection leaked server-only keys")
	local existing = runtimeFolder:FindFirstChild(Config.CLIENT_CONFIG_VALUE_NAME) :: StringValue?
	local value = existing or Instance.new("StringValue")
	value.Name = Config.CLIENT_CONFIG_VALUE_NAME
	value.Value = HttpService:JSONEncode(projection)
	value.Parent = runtimeFolder
	return value
end

-- Typed accessors -----------------------------------------------------------------------------

function Config.bagLevel(cfg: { [string]: any }, level: number): { [string]: any }?
	return cfg.bags.levels[level]
end

function Config.handPath(cfg: { [string]: any }, pathName: string): { { [string]: any } }?
	return cfg.handUpgrades[pathName]
end

function Config.tool(cfg: { [string]: any }, toolId: string): { [string]: any }?
	return cfg.tools[toolId]
end

function Config.toolPath(cfg: { [string]: any }, toolId: string, pathName: string): { { [string]: any } }?
	local tool = cfg.toolUpgrades[toolId]
	return tool and tool[pathName]
end

function Config.chapter(cfg: { [string]: any }, chapterKey: string): { [string]: any }?
	return cfg.chapters[chapterKey]
end

function Config.difficulty(cfg: { [string]: any }, difficultyId: string): { [string]: any }?
	return cfg.difficulty[difficultyId]
end

function Config.class(cfg: { [string]: any }, classId: string): { [string]: any }?
	for _, entry in ipairs(cfg.classes.weights) do
		if entry.id == classId then
			return entry
		end
	end
	return nil
end

function Config.classWeights(cfg: { [string]: any }): { { id: string, weight: number } }
	local out = {}
	for _, entry in ipairs(cfg.classes.weights) do
		table.insert(out, { id = entry.id, weight = entry.weight })
	end
	return out
end

function Config.featureEnabled(cfg: { [string]: any }, flag: string): boolean
	return cfg.featureFlags[flag] == true
end

function Config.reset()
	cached = nil
end

return Config
