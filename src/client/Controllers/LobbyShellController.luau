--!strict
-- Client-side ambient life for the Phase 1 lobby shell. Reads SFE_Ambient attributes the server
-- placed on shell parts and registers actors with the AmbientScheduler: drifting pooled feather
-- strands, portal shimmer, cloth sway, pedestal bob/spin, and dust motes through the VFX pool.
-- Everything is cleaned up through one trove; the scheduler owns the only Heartbeat connection.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Tokens = require(Shared.Design.Tokens)

local LobbyShellController = {}
LobbyShellController.__index = LobbyShellController

export type LobbyShellController = typeof(setmetatable(
	{} :: { _deps: any, _trove: Trove.Trove, _strands: { Part }, _actors: { any }, started: boolean },
	LobbyShellController
))

local STRANDS_PER_ANCHOR_BY_TIER = { low = 6, medium = 12, high = 20 }

function LobbyShellController.new(deps: any): LobbyShellController
	return setmetatable({ _deps = deps, _trove = Trove.new(), _strands = {}, _actors = {}, started = false }, LobbyShellController)
end

local function makeStrand(parent: Instance): Part
	local strand = Instance.new("Part")
	strand.Name = "FeatherStrand"
	strand.Anchored = true
	strand.CanCollide = false
	strand.CanQuery = false
	strand.CanTouch = false
	strand.CastShadow = false
	strand.Material = Enum.Material.SmoothPlastic
	strand.Color = Tokens.color.cream
	strand.Size = Vector3.new(0.12, 0.5, 0.9)
	strand:SetAttribute("SFE_Placeholder", "PHASE_6_VFX")
	strand.Parent = parent
	return strand
end

function LobbyShellController.start(self: LobbyShellController)
	if self.started then
		return
	end
	self.started = true
	local deps = self._deps
	local shell = workspace:WaitForChild("SFE_LobbyShell", 30)
	if not shell then
		warn("[SFE][Lobby] shell folder missing; ambient life skipped")
		return
	end
	-- The folder replicates before its children; wait for the server-declared child count.
	local expected = tonumber(shell:GetAttribute("SFE_ChildCount")) or 0
	local deadline = os.clock() + 10
	while #shell:GetChildren() < expected and os.clock() < deadline do
		task.wait(0.05)
	end
	local container = Instance.new("Folder")
	container.Name = "SFE_LobbyAmbient"
	container.Parent = workspace
	self._trove:add(container)

	local tier = deps.quality:tier()
	local strandsPerAnchor = STRANDS_PER_ANCHOR_BY_TIER[tier] or 12

	for _, part in ipairs(shell:GetChildren()) do
		if not part:IsA("BasePart") then
			continue
		end
		local kind = part:GetAttribute("SFE_Ambient")
		if kind == "featherDrift" then
			local origin = part.Position
			for i = 1, strandsPerAnchor do
				local strand = makeStrand(container)
				table.insert(self._strands, strand)
				local seed = i * 0.37
				local actor = deps.ambient:register({
					id = part.Name .. ":" .. i,
					position = function()
						return origin
					end,
					interval = 1 / 20,
					update = function(_dt: number, t: number)
						local phase = t * 0.35 + seed * 7
						local radius = 4 + (seed * 10) % 6
						local x = origin.X + math.cos(phase) * radius
						local z = origin.Z + math.sin(phase * 0.8) * radius
						local y = origin.Y - ((t * 0.9 + seed * 13) % 14)
						strand.CFrame = CFrame.new(x, y, z) * CFrame.Angles(math.sin(phase * 2) * 0.6, phase, math.cos(phase * 1.3) * 0.4)
					end,
				})
				table.insert(self._actors, actor)
			end
		elseif kind == "portalShimmer" then
			local base = part.Transparency
			table.insert(
				self._actors,
				deps.ambient:register({
					id = part.Name,
					position = function()
						return part.Position
					end,
					interval = 1 / 15,
					update = function(_dt: number, t: number)
						part.Transparency = base + math.sin(t * 1.6) * 0.12
					end,
				})
			)
		elseif kind == "clothSway" then
			local baseCFrame = part.CFrame
			table.insert(
				self._actors,
				deps.ambient:register({
					id = part.Name,
					position = function()
						return part.Position
					end,
					interval = 1 / 15,
					update = function(_dt: number, t: number)
						part.CFrame = baseCFrame * CFrame.Angles(0, 0, math.sin(t * 0.7) * 0.02)
					end,
				})
			)
		elseif kind == "bob" or kind == "spin" then
			local baseCFrame = part.CFrame
			table.insert(
				self._actors,
				deps.ambient:register({
					id = part.Name,
					position = function()
						return part.Position
					end,
					interval = 1 / 20,
					update = function(_dt: number, t: number)
						if kind == "bob" then
							part.CFrame = baseCFrame * CFrame.new(0, math.sin(t * 1.2) * 0.4, 0) * CFrame.Angles(0, t * 0.3, 0)
						else
							part.CFrame = baseCFrame * CFrame.Angles(0, t * 0.8, 0)
						end
					end,
				})
			)
		elseif kind == "dustMote" then
			table.insert(
				self._actors,
				deps.ambient:register({
					id = part.Name .. ":dust",
					position = function()
						return part.Position
					end,
					interval = 2.5,
					update = function(_dt: number, _t: number, rng: any)
						local offset = Vector3.new((rng:next() - 0.5) * 8, 2 + rng:next() * 3, (rng:next() - 0.5) * 8)
						deps.vfx:burst("dust", part.Position + offset, 1.2)
					end,
				})
			)
		end
	end
	deps.ambient:start()
	print(string.format("[SFE][Lobby] ambient actors=%d strands=%d tier=%s", #self._actors, #self._strands, tier))
end

function LobbyShellController.stop(self: LobbyShellController)
	for _, actor in ipairs(self._actors) do
		self._deps.ambient:unregister(actor)
	end
	table.clear(self._actors)
	for _, strand in ipairs(self._strands) do
		strand:Destroy()
	end
	table.clear(self._strands)
	self._trove:clean()
	self.started = false
end

function LobbyShellController.strandCount(self: LobbyShellController): number
	return #self._strands
end

function LobbyShellController.destroy(self: LobbyShellController)
	self:stop()
	self._trove:destroy()
end

return LobbyShellController
