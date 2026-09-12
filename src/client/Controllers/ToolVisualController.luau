--!strict
-- World visuals for server tool events (`ToolEvent`): thrown Confetti Charges (arc in, fuse pulse,
-- burst), Feather Vac suction puffs, Scout Chick units (client-smoothed motion toward the server's
-- announced target at the server's speed), and overflow bundles (pickups with a count label).
-- Everything here is presentation: the server already decided every outcome. PLACEHOLDER art.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Signal = require(Shared.Util.Signal)
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)

local ToolVisualController = {}
ToolVisualController.__index = ToolVisualController

type Charge = { part: Part, explodeAt: number, mini: boolean, userId: number }
type Unit = { part: Part, target: Vector3?, speed: number, state: string, userId: number }
type Bundle = { part: Part, label: TextLabel, position: Vector3, count: number }

export type ToolVisualController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_folder: Folder,
		_charges: { [string]: Charge },
		_units: { [string]: Unit },
		_bundles: { [string]: Bundle },
		_bound: boolean,
		_trove: Trove.Trove,
		chargeExploded: any, -- (payload) for the local player's camera impulse
		vacState: any, -- (payload) local player's vac state
		chickState: any, -- (payload)
		stats: { charges: number, explosions: number, units: number, bundles: number, deposits: number },
	},
	ToolVisualController
))

local RENDER_NAME = "SFE_ToolVisuals"

local function placeholder(name: string, size: Vector3, color: Color3, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Shape = shape or Enum.PartType.Ball
	part:SetAttribute("SFE_Placeholder", "PHASE_6_ART")
	return part
end

function ToolVisualController.new(deps: {
	net: any,
	round: any,
	vfx: any,
	audio: any,
	accessibility: any,
	quality: any,
	config: { [string]: any },
}): ToolVisualController
	local folder = Instance.new("Folder")
	folder.Name = "SFE_ToolVisuals"
	folder.Parent = workspace
	local self = setmetatable({
		_deps = deps,
		_folder = folder,
		_charges = {},
		_units = {},
		_bundles = {},
		_bound = false,
		_trove = Trove.new(),
		chargeExploded = Signal.new(),
		vacState = Signal.new(),
		chickState = Signal.new(),
		stats = { charges = 0, explosions = 0, units = 0, bundles = 0, deposits = 0 },
	}, ToolVisualController)
	self._trove:add(folder)
	self._trove:add(deps.net:on("ToolEvent", function(payload)
		self:_onEvent(payload)
	end))
	self._trove:add(deps.round.snapshot:Connect(function(payload)
		-- Rejoin / late snapshot: rebuild live bundles and charges from the authoritative projection.
		if payload.bundles then
			for _, bundle in ipairs(payload.bundles) do
				self:_upsertBundle(bundle.bundleId, Vector3.new(bundle.x, bundle.y, bundle.z), bundle.standard + bundle.rainbow)
			end
		end
		if payload.charges then
			for _, charge in ipairs(payload.charges) do
				if not self._charges[charge.chargeId] then
					self:_spawnCharge(
						charge.chargeId,
						Vector3.new(charge.x, charge.y, charge.z),
						charge.fuseMs,
						charge.mini,
						charge.userId,
						true
					)
				end
			end
		end
	end))
	self._trove:add(deps.round.phaseChanged:Connect(function(phase)
		if phase ~= "Searching" then
			self:clear()
		end
		self:_setBound(phase == "Searching")
	end))
	return self
end

function ToolVisualController._setBound(self: ToolVisualController, bound: boolean)
	if bound == self._bound then
		return
	end
	self._bound = bound
	if bound then
		RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 3, function(dt)
			self:_step(dt)
		end)
	else
		RunService:UnbindFromRenderStep(RENDER_NAME)
	end
end

function ToolVisualController._step(self: ToolVisualController, dt: number)
	local now = os.clock()
	local motionScale = self._deps.accessibility:motionScale()
	for _, charge in pairs(self._charges) do
		-- Fuse pulse quickens toward detonation.
		local remaining = math.max(0, charge.explodeAt - now)
		local rate = if remaining < 0.6 then 18 else 6
		local pulse = 1 + 0.12 * motionScale * math.sin(now * rate)
		local base = if charge.mini then 0.9 else 1.4
		charge.part.Size = Vector3.new(base * pulse, base * pulse, base * pulse)
	end
	for _, unit in pairs(self._units) do
		if unit.target then
			local delta = unit.target - unit.part.Position
			local distance = delta.Magnitude
			local step = unit.speed * dt
			if distance <= step or distance < 0.05 then
				unit.part.CFrame = CFrame.new(unit.target)
				unit.target = nil
			else
				local next = unit.part.Position + delta.Unit * step
				unit.part.CFrame = CFrame.lookAt(next, next + Vector3.new(delta.X, 0, delta.Z))
			end
		end
		if unit.state == "Collecting" then
			-- Peck bob while collecting.
			local bob = math.abs(math.sin(now * 8)) * 0.25 * motionScale
			unit.part.CFrame = unit.part.CFrame * CFrame.new(0, bob - (unit.part:GetAttribute("SFE_Bob") or 0), 0)
			unit.part:SetAttribute("SFE_Bob", bob)
		end
	end
	for _, bundle in pairs(self._bundles) do
		local hover = math.sin(now * 2 + bundle.position.X) * 0.15 * motionScale
		bundle.part.CFrame = CFrame.new(bundle.position + Vector3.new(0, 0.9 + hover, 0)) * CFrame.Angles(0, now * 0.8, 0)
	end
end

function ToolVisualController._spawnCharge(
	self: ToolVisualController,
	id: string,
	landing: Vector3,
	fuseMs: number,
	mini: boolean,
	userId: number,
	silent: boolean?
)
	local size = if mini then 0.9 else 1.4
	local part = placeholder("SFE_Charge", Vector3.new(size, size, size), if mini then Tokens.color.sky else Tokens.color.ember)
	part.Parent = self._folder
	local motion = self._deps.accessibility:motionSettings()
	local rest = landing + Vector3.new(0, size / 2, 0)
	if silent or motion.reducedMotion then
		part.CFrame = CFrame.new(rest)
	else
		-- Arc in from above the thrower's side of the nest.
		part.CFrame = CFrame.new(rest + Vector3.new(0, 9, 0))
		TweenService:Create(part, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = CFrame.new(rest) }):Play()
	end
	self._charges[id] = { part = part, explodeAt = os.clock() + fuseMs / 1000, mini = mini, userId = userId }
	self.stats.charges += 1
	if not silent then
		self._deps.audio:play(Tokens.sound.collectTug, { pitchVariance = 0.15 })
	end
end

function ToolVisualController._explodeCharge(self: ToolVisualController, payload: { [string]: any })
	local charge = self._charges[payload.chargeId]
	if charge then
		charge.part:Destroy()
		self._charges[payload.chargeId] = nil
	end
	local position = Vector3.new(payload.x, payload.y + 1, payload.z)
	self.stats.explosions += 1
	self._deps.vfx:burst("sparkle", position, 0.6)
	self._deps.vfx:burst("featherPuff", position, 0.8)
	if payload.rainbow and payload.rainbow > 0 then
		self._deps.vfx:burst("sparkle", position + Vector3.new(0, 1.5, 0), 1.2)
	end
	self._deps.audio:play(Tokens.sound.sellBurst, { pitchVariance = 0.2 })
	self.chargeExploded:Fire(payload)
end

function ToolVisualController._upsertUnit(self: ToolVisualController, payload: { [string]: any })
	local unit = self._units[payload.unitId]
	if payload.removed then
		if unit then
			unit.part:Destroy()
			self._units[payload.unitId] = nil
		end
		self.chickState:Fire(payload)
		return
	end
	if not unit then
		local part = placeholder("SFE_ScoutChick", Vector3.new(1.2, 1.1, 1.4), Tokens.color.straw, Enum.PartType.Block)
		part.Material = Enum.Material.Fabric
		local beak = placeholder("Beak", Vector3.new(0.3, 0.25, 0.4), Tokens.color.ember, Enum.PartType.Block)
		beak.CFrame = CFrame.new(0, 0.1, -0.8)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = part
		weld.Part1 = beak
		weld.Parent = part
		beak.Parent = part
		part.CFrame = CFrame.new(payload.x, payload.y + 0.6, payload.z)
		beak.CFrame = part.CFrame * CFrame.new(0, 0.1, -0.8)
		part.Parent = self._folder
		unit = { part = part, target = nil, speed = payload.speed or 10, state = payload.state, userId = payload.userId }
		self._units[payload.unitId] = unit
		self.stats.units += 1
	end
	unit.state = payload.state
	if payload.speed then
		unit.speed = payload.speed
	end
	-- Snap correction if the client drifted more than a couple of studs, else keep smoothing.
	local serverPosition = Vector3.new(payload.x, payload.y + 0.6, payload.z)
	if (unit.part.Position - serverPosition).Magnitude > 3 then
		unit.part.CFrame = CFrame.new(serverPosition)
	end
	if payload.targetX then
		unit.target = Vector3.new(payload.targetX, payload.targetY + 0.6, payload.targetZ)
	elseif payload.state == "Collecting" or payload.state == "Depositing" then
		unit.target = nil
	end
	if payload.cents then
		self.stats.deposits += 1
		self._deps.vfx:burst("sparkle", serverPosition, 0.5)
		self._deps.audio:play(Tokens.sound.sellTick, { pitchVariance = 0.1 })
	end
	self.chickState:Fire(payload)
end

function ToolVisualController._upsertBundle(self: ToolVisualController, id: string, position: Vector3, count: number)
	local bundle = self._bundles[id]
	if not bundle then
		local part = placeholder("SFE_Bundle", Vector3.new(1.3, 1.3, 1.3), Tokens.color.cream)
		part.Material = Enum.Material.Fabric
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(80, 24)
		gui.StudsOffset = Vector3.new(0, 1.4, 0)
		gui.AlwaysOnTop = true
		gui.MaxDistance = 60
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Tokens.typography.numeral.font
		label.TextSize = Tokens.typography.numeral.size
		label.TextColor3 = Tokens.color.cream
		label.TextStrokeTransparency = 0.3
		label.Parent = gui
		gui.Parent = part
		part.Parent = self._folder
		bundle = { part = part, label = label, position = position, count = count }
		self._bundles[id] = bundle
		self.stats.bundles += 1
		self._deps.vfx:burst("featherPuff", position + Vector3.new(0, 1, 0), 0.4)
	end
	bundle.count = count
	bundle.label.Text = string.format("+%d", count)
end

function ToolVisualController._removeBundle(self: ToolVisualController, id: string, gathered: boolean)
	local bundle = self._bundles[id]
	if not bundle then
		return
	end
	if gathered then
		self._deps.vfx:burst("sparkle", bundle.position + Vector3.new(0, 1, 0), 0.4)
	end
	bundle.part:Destroy()
	self._bundles[id] = nil
end

function ToolVisualController._onEvent(self: ToolVisualController, payload: { [string]: any })
	local kind = payload.kind
	if kind == "charge_thrown" then
		self:_spawnCharge(
			payload.chargeId,
			Vector3.new(payload.x, payload.y, payload.z),
			payload.fuseMs,
			payload.mini == true,
			payload.userId
		)
	elseif kind == "charge_exploded" then
		self:_explodeCharge(payload)
	elseif kind == "vac_state" then
		if payload.state == "running" and payload.aimX then
			self._deps.vfx:burst("dust", Vector3.new(payload.aimX, 2, payload.aimZ), 1.5)
		end
		self.vacState:Fire(payload)
	elseif kind == "chick_state" then
		self:_upsertUnit(payload)
	elseif kind == "bundle_dropped" then
		self:_upsertBundle(payload.bundleId, Vector3.new(payload.x, payload.y, payload.z), payload.standard + payload.rainbow)
	elseif kind == "bundle_changed" then
		local bundle = self._bundles[payload.bundleId]
		if bundle then
			self:_upsertBundle(payload.bundleId, bundle.position, payload.standard + payload.rainbow)
		end
	elseif kind == "bundle_removed" then
		self:_removeBundle(payload.bundleId, payload.byUserId ~= nil)
	end
end

-- Nearest live bundle within `radius` of `position` (for the auto-gather walk-over).
function ToolVisualController.nearestBundle(self: ToolVisualController, position: Vector3, radius: number): (string?, number?)
	local bestId, bestDistance = nil, radius
	for id, bundle in pairs(self._bundles) do
		local flat = Vector3.new(bundle.position.X - position.X, 0, bundle.position.Z - position.Z).Magnitude
		if flat <= bestDistance then
			bestId, bestDistance = id, flat
		end
	end
	return bestId, bestDistance
end

function ToolVisualController.clear(self: ToolVisualController)
	for id, charge in pairs(self._charges) do
		charge.part:Destroy()
		self._charges[id] = nil
	end
	for id, unit in pairs(self._units) do
		unit.part:Destroy()
		self._units[id] = nil
	end
	for id, bundle in pairs(self._bundles) do
		bundle.part:Destroy()
		self._bundles[id] = nil
	end
end

function ToolVisualController.counts(self: ToolVisualController): { charges: number, units: number, bundles: number }
	local charges, units, bundles = 0, 0, 0
	for _ in pairs(self._charges) do
		charges += 1
	end
	for _ in pairs(self._units) do
		units += 1
	end
	for _ in pairs(self._bundles) do
		bundles += 1
	end
	return { charges = charges, units = units, bundles = bundles }
end

function ToolVisualController.instanceCount(self: ToolVisualController): number
	return #self._folder:GetDescendants()
end

function ToolVisualController.destroy(self: ToolVisualController)
	self:_setBound(false)
	self:clear()
	self._trove:destroy()
	self.chargeExploded:Destroy()
	self.vacState:Destroy()
	self.chickState:Destroy()
end

ToolVisualController.Motion = Motion
ToolVisualController.LocalPlayer = Players.LocalPlayer

return ToolVisualController
