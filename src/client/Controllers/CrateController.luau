--!strict
-- Replays a crate run on this client (owner requirement; ASSUMED A-SELL-02): the map's own collection
-- crate lifts onto the front belt, rides it into the processor, turns onto the side belt, rides out,
-- crosses to the earth pit, tips, falls out of sight, and resets to its parked pose. Every client
-- animates the same authored model from the same server timeline, so all players see one crate
-- travelling once per sale. Rollers spin and belt stripes scroll while a belt segment plays. The sold
-- feathers ride inside the crate as pooled clones. The server owns the sale and the busy gate; this
-- controller only moves the crate visually and puts it back exactly where it started.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local AssetManifest = require(Shared.Design.AssetManifest)
local Signal = require(Shared.Util.Signal)

local CrateController = {}
CrateController.__index = CrateController

export type CrateController = typeof(setmetatable(
	{} :: {
		_net: any,
		_audio: any,
		_vfx: any,
		_config: { [string]: any },
		_running: boolean,
		_runId: number?,
		_squash: number,
		_squashVelocity: number,
		_home: CFrame?,
		_feathers: { BasePart },
		_trove: Trove.Trove,
		runStarted: any,
		runFinished: any,
		stats: { runs: number, ignored: number },
	},
	CrateController
))

local TEMPLATE_SIZE = Vector3.new(0.54, 1.44, 0.13)

local function easeInOut(t: number): number
	return t * t * (3 - 2 * t)
end

local function easeIn(t: number): number
	return t * t
end

function CrateController.new(deps: { net: any, audio: any, vfx: any, config: { [string]: any } }): CrateController
	local self = setmetatable({
		_net = deps.net,
		_audio = deps.audio,
		_vfx = deps.vfx,
		_config = deps.config,
		_running = false,
		_runId = nil,
		_squash = 0,
		_squashVelocity = 0,
		_home = nil,
		_feathers = {},
		_trove = Trove.new(),
		runStarted = Signal.new(),
		runFinished = Signal.new(),
		stats = { runs = 0, ignored = 0 },
	}, CrateController)
	self._trove:add(deps.net:on("CrateRun", function(payload)
		self:play(payload)
	end))
	return self
end

function CrateController.crateModel(_self: CrateController): Model?
	local map = workspace:FindFirstChild(ChapterLayout.CHAPTER1_MAP_NAME)
	local geometry = ChapterLayout.chapter1.crate
	if not map or not geometry then
		return nil
	end
	local node: Instance? = map
	for _, segment in ipairs(geometry.modelPath) do
		node = node and node:FindFirstChild(segment)
	end
	return if node and node:IsA("Model") then node else nil
end

local function conveyorParts(): { rollers: { BasePart }, stripes: { { part: BasePart, start: CFrame } } }
	local rollers, stripes = {}, {}
	local map = workspace:FindFirstChild(ChapterLayout.CHAPTER1_MAP_NAME)
	local conveyors = map and map:FindFirstChild("Conveyors")
	if conveyors then
		for _, descendant in ipairs(conveyors:GetDescendants()) do
			if descendant:IsA("BasePart") then
				if descendant.Name == "EndRoller" then
					table.insert(rollers, descendant)
				elseif descendant.Name == "BeltSegment" then
					table.insert(stripes, { part = descendant, start = descendant.CFrame })
				end
			end
		end
	end
	return { rollers = rollers, stripes = stripes }
end

-- Sold feathers stacked inside the crate (capped; cosmetic).
-- A feather landing in the crate: the crate takes the weight and springs back. Applied on top of
-- whatever pose the timeline is driving, clamped, decaying on its own.
function CrateController.squash(self: CrateController, studs: number)
	self._squashVelocity = math.clamp(self._squashVelocity + studs * 22, -2.5, 2.5)
end

-- Reveals the sold feathers already sitting in the crate up to `fraction` of them, so a stream of
-- arrivals fills it rather than the whole load appearing at once.
function CrateController.showFeathers(self: CrateController, fraction: number)
	local n = #self._feathers
	local shown = math.clamp(math.ceil(n * fraction), 0, n)
	for index, part in ipairs(self._feathers) do
		part.Transparency = if index <= shown then 0 else 1
	end
end

-- Where a feather flying to the crate should aim: just inside the top of the crate's current pose.
function CrateController.mouth(self: CrateController): Vector3?
	local crate = self:crateModel()
	if not crate then
		return nil
	end
	return (crate:GetPivot() * CFrame.new(0, 0.6, 0)).Position
end

function CrateController._fillCrate(self: CrateController, crate: Model, count: number)
	local template = AssetManifest.model("feather")
	local n = math.min(count, self._config.selling.crate.featherVisualMax)
	local pivot = crate:GetPivot()
	for i = 1, n do
		local part: BasePart
		if template and template:IsA("BasePart") then
			part = template:Clone() :: BasePart
		else
			part = Instance.new("Part")
			part.Material = Enum.Material.SmoothPlastic
		end
		part.Name = "SoldFeather"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Size = TEMPLATE_SIZE * 1.8
		part.Color = Color3.fromRGB(246, 236, 214)
		local h = (i * 0.618) % 1
		local g = (i * 0.382) % 1
		part.CFrame = pivot
			* CFrame.new((h - 0.5) * 6.5, -0.9 + (i / n) * 1.4, (g - 0.5) * 4.2)
			* CFrame.Angles(math.rad(80 + (h - 0.5) * 20), h * math.pi * 2, (g - 0.5) * 0.6)
		part.Transparency = 1 -- revealed as the stream from the bundle lands (showFeathers)
		part.Parent = crate
		table.insert(self._feathers, part)
	end
end

function CrateController._clearFeathers(self: CrateController)
	for _, part in ipairs(self._feathers) do
		part:Destroy()
	end
	table.clear(self._feathers)
end

-- Runs the whole timeline on a Heartbeat thread; each segment interpolates the pivot from its own
-- start pose so nothing snaps. Returns when the crate is back home.
function CrateController.play(self: CrateController, payload: { [string]: any })
	local crate = self:crateModel()
	local geometry = ChapterLayout.chapter1.crate
	if not crate or not geometry then
		self.stats.ignored += 1
		return
	end
	if self._running then
		-- A second run can only arrive after the server gate expired; finish the old one instantly.
		self._runId = nil
		self:_finish(crate)
	end
	self._running = true
	self._runId = payload.runId
	self.stats.runs += 1
	local home = self._home or crate:GetPivot()
	self._home = home
	self:_clearFeathers()
	self:_fillCrate(crate, payload.featherCount or 0)
	if payload.sellerUserId ~= Players.LocalPlayer.UserId then
		self:showFeathers(1)
	end
	self.runStarted:Fire(payload)
	self._audio:play("sell.arc")
	local layout = ChapterLayout.chapter1
	local beltY = geometry.beltTopY + geometry.crateBottomOffset
	local hole = layout.blackHole
	local function at(v: Vector3, y: number): Vector3
		return Vector3.new(v.X, y, v.Z)
	end
	-- Key poses (pivot CFrames) in order; segments interpolate between consecutive poses.
	local poses: { [string]: CFrame } = {
		lift = CFrame.new(at(geometry.frontBeltStart, beltY)),
		frontBelt = CFrame.new(at(geometry.machineEntry, beltY)),
		machine = CFrame.new(at(geometry.machineTurn, beltY)),
		turn = CFrame.new(at(geometry.sideBeltStart, beltY)) * CFrame.Angles(0, math.rad(90), 0),
		sideBelt = CFrame.new(at(geometry.sideBeltEnd, beltY)) * CFrame.Angles(0, math.rad(90), 0),
		toPit = CFrame.new(at(geometry.pitRim, beltY - 1.2)) * CFrame.Angles(0, math.rad(90), 0),
		tip = CFrame.new(Vector3.new(hole.X + 1.5, hole.Y + 7, hole.Z))
			* CFrame.Angles(0, math.rad(90), 0)
			* CFrame.Angles(math.rad(-70), 0, 0),
		fall = CFrame.new(Vector3.new(hole.X, hole.Y - self._config.selling.crate.fallDepthStuds, hole.Z))
			* CFrame.Angles(0, math.rad(90), 0)
			* CFrame.Angles(math.rad(-110), 0, 0),
	}
	local runId = payload.runId
	local conveyor = conveyorParts()
	local spin = math.rad(self._config.selling.crate.rollerSpinDegreesPerSecond)
	task.spawn(function()
		local from = home
		for _, segment in ipairs(payload.timeline) do
			if self._runId ~= runId then
				return
			end
			local name = segment.name
			if name == "reset" then
				self._squash = 0
				self._squashVelocity = 0
				crate:PivotTo(home)
				for _, part in ipairs(self._feathers) do
					part.Transparency = 0
				end
				self:_clearFeathers()
				for _, descendant in ipairs(crate:GetDescendants()) do
					if descendant:IsA("BasePart") then
						descendant.Transparency = if descendant.Name == "Fastener" then descendant.Transparency else 0
					end
				end
				local elapsed = 0
				while elapsed < segment.seconds and self._runId == runId do
					elapsed += RunService.Heartbeat:Wait()
				end
				break
			end
			local to = poses[name] or from
			local ease = if name == "fall"
				then easeIn
				elseif name == "frontBelt" or name == "sideBelt" then function(t)
					return t
				end
				else easeInOut
			local onBelt = name == "frontBelt" or name == "sideBelt" or name == "machine" or name == "turn"
			local elapsed = 0
			local wasVisible = true
			while elapsed < segment.seconds and self._runId == runId do
				local dt = RunService.Heartbeat:Wait()
				elapsed += dt
				local t = math.clamp(elapsed / math.max(0.001, segment.seconds), 0, 1)
				local damping = 2 * math.sqrt(180)
				self._squashVelocity += (-180 * self._squash - damping * self._squashVelocity) * dt
				self._squash = math.clamp(self._squash + self._squashVelocity * dt, -0.25, 0.25)
				crate:PivotTo(from:Lerp(to, ease(t)) * CFrame.new(0, -self._squash, 0))
				if onBelt then
					for _, roller in ipairs(conveyor.rollers) do
						roller.CFrame = roller.CFrame * CFrame.Angles(spin * dt, 0, 0)
					end
					for _, stripe in ipairs(conveyor.stripes) do
						local axis = if math.abs(stripe.part.Size.X) > math.abs(stripe.part.Size.Z)
							then Vector3.new(0, 0, -1)
							else Vector3.new(-1, 0, 0)
						stripe.part.CFrame = stripe.part.CFrame + axis * (self._config.selling.crate.beltStudsPerSecond * dt)
						if (stripe.part.Position - stripe.start.Position).Magnitude > 3.5 then
							stripe.part.CFrame = stripe.start
						end
					end
				end
				if name == "fall" and t > 0.55 and wasVisible then
					-- Fully below the pit floor: vanish.
					wasVisible = false
					for _, descendant in ipairs(crate:GetDescendants()) do
						if descendant:IsA("BasePart") then
							descendant.Transparency = 1
						end
					end
				end
			end
			if name == "tip" then
				self._vfx:burst("dust", Vector3.new(hole.X, hole.Y + 3, hole.Z), 0.5)
				self._audio:play("sell.burst")
			end
			from = to
		end
		for _, stripe in ipairs(conveyor.stripes) do
			stripe.part.CFrame = stripe.start
		end
		if self._runId == runId then
			self:_finish(crate)
		end
	end)
end

function CrateController._finish(self: CrateController, crate: Model)
	if self._home then
		crate:PivotTo(self._home)
	end
	for _, descendant in ipairs(crate:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name ~= "SoldFeather" then
			descendant.Transparency = 0
		end
	end
	self:_clearFeathers()
	self._running = false
	self.runFinished:Fire()
end

function CrateController.isRunning(self: CrateController): boolean
	return self._running
end

function CrateController.destroy(self: CrateController)
	self._runId = nil
	local crate = self:crateModel()
	if crate then
		self:_finish(crate)
	end
	self.runStarted:Destroy()
	self.runFinished:Destroy()
	self._trove:destroy()
end

return CrateController
