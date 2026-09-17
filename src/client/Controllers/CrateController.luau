--!strict
-- Replays crate runs on this client (owner requirement; ASSUMED A-SELL-02). The map's own collection
-- crate stays parked at the sale point; each accepted sale sends a travelling copy of it off along
-- the server's timeline (lift onto the front belt, ride it into the processor, turn onto the side
-- belt, ride out, cross to the earth pit, tip, fall out of sight) while the parked crate drops out
-- of view and pops back in `respawnSeconds` later with a bounce - so the next sale never waits for
-- the last crate's ride. Runs overlap freely: every sold crate finishes its own ride and cleans
-- itself up. Rollers spin and belt stripes scroll while any run is on a belt. The sold feathers ride
-- inside the travelling copy as pooled clones. The server owns the sale and the busy gate; this
-- controller only moves crates visually and always leaves the parked one exactly where it started.

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

type Run = {
	id: number,
	crate: Model,
	feathers: { BasePart },
	squash: number,
	squashVelocity: number,
	onBelt: boolean,
}

export type CrateController = typeof(setmetatable(
	{} :: {
		_net: any,
		_audio: any,
		_vfx: any,
		_config: { [string]: any },
		_runs: { Run },
		_home: CFrame?,
		_hidden: boolean,
		_respawnToken: number,
		_beltRuns: number,
		_conveyorBound: boolean,
		_trove: Trove.Trove,
		runStarted: any,
		runFinished: any,
		stats: { runs: number, ignored: number, respawns: number },
	},
	CrateController
))

local TEMPLATE_SIZE = Vector3.new(0.54, 1.44, 0.13)
local BASE_TRANSPARENCY = "SFE_BaseTransparency"

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
		_runs = {},
		_home = nil,
		_hidden = false,
		_respawnToken = 0,
		_beltRuns = 0,
		_conveyorBound = false,
		_trove = Trove.new(),
		runStarted = Signal.new(),
		runFinished = Signal.new(),
		stats = { runs = 0, ignored = 0, respawns = 0 },
	}, CrateController)
	self._trove:add(deps.net:on("CrateRun", function(payload)
		self:play(payload)
	end))
	return self
end

-- The parked crate: the map's authored model, never moved except by the respawn bounce.
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

-- Each part remembers the transparency it was authored with, so hiding and showing the parked crate
-- restores fasteners and glass exactly rather than forcing everything opaque.
local function setVisible(model: Model, visible: boolean)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name ~= "SoldFeather" then
			local base = descendant:GetAttribute(BASE_TRANSPARENCY)
			if typeof(base) ~= "number" then
				base = descendant.Transparency
				descendant:SetAttribute(BASE_TRANSPARENCY, base)
			end
			descendant.Transparency = if visible then base else 1
		end
	end
end

local function latestRun(self: CrateController): Run?
	return self._runs[#self._runs]
end

-- A feather landing in the crate: the crate takes the weight and springs back. Applied on top of
-- whatever pose the timeline is driving, clamped, decaying on its own.
function CrateController.squash(self: CrateController, studs: number)
	local run = latestRun(self)
	if run then
		run.squashVelocity = math.clamp(run.squashVelocity + studs * 22, -2.5, 2.5)
	end
end

-- Reveals the sold feathers already sitting in the newest travelling crate up to `fraction` of them,
-- so a stream of arrivals fills it rather than the whole load appearing at once.
function CrateController.showFeathers(self: CrateController, fraction: number)
	local run = latestRun(self)
	if not run then
		return
	end
	local n = #run.feathers
	local shown = math.clamp(math.ceil(n * fraction), 0, n)
	for index, part in ipairs(run.feathers) do
		part.Transparency = if index <= shown then 0 else 1
	end
end

-- Where a feather flying to the crate should aim: just inside the top of the crate that is taking
-- this sale (the newest travelling copy while one is leaving, else the parked crate).
function CrateController.mouth(self: CrateController): Vector3?
	local run = latestRun(self)
	local crate = if run then run.crate else self:crateModel()
	if not crate then
		return nil
	end
	return (crate:GetPivot() * CFrame.new(0, 0.6, 0)).Position
end

function CrateController._fillCrate(self: CrateController, run: Run, count: number)
	local template = AssetManifest.model("feather")
	local n = math.min(count, self._config.selling.crate.featherVisualMax)
	local pivot = run.crate:GetPivot()
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
		part.Parent = run.crate
		table.insert(run.feathers, part)
	end
end

-- The conveyor runs while any crate is on a belt: one shared loop, never one per run.
function CrateController._bindConveyor(self: CrateController)
	if self._conveyorBound then
		return
	end
	self._conveyorBound = true
	local conveyor = conveyorParts()
	local spin = math.rad(self._config.selling.crate.rollerSpinDegreesPerSecond)
	local speed = self._config.selling.crate.beltStudsPerSecond
	task.spawn(function()
		while self._beltRuns > 0 do
			local dt = RunService.Heartbeat:Wait()
			for _, roller in ipairs(conveyor.rollers) do
				roller.CFrame = roller.CFrame * CFrame.Angles(spin * dt, 0, 0)
			end
			for _, stripe in ipairs(conveyor.stripes) do
				local axis = if math.abs(stripe.part.Size.X) > math.abs(stripe.part.Size.Z)
					then Vector3.new(0, 0, -1)
					else Vector3.new(-1, 0, 0)
				stripe.part.CFrame = stripe.part.CFrame + axis * (speed * dt)
				if (stripe.part.Position - stripe.start.Position).Magnitude > 3.5 then
					stripe.part.CFrame = stripe.start
				end
			end
		end
		for _, stripe in ipairs(conveyor.stripes) do
			stripe.part.CFrame = stripe.start
		end
		self._conveyorBound = false
	end)
end

-- The parked crate drops out of sight the moment a sale takes it, and a fresh one lands in its
-- place `respawnSeconds` later: a short drop from above with a squash on touchdown.
function CrateController._respawnLater(self: CrateController, parked: Model, home: CFrame)
	self._respawnToken += 1
	local token = self._respawnToken
	local seconds = self._config.selling.crate.respawnSeconds or 1.5
	task.delay(math.max(0, seconds - 0.3), function()
		if self._respawnToken ~= token or not parked.Parent then
			return
		end
		setVisible(parked, true)
		self._hidden = false
		self.stats.respawns += 1
		self._audio:play("sell.tick")
		local elapsed = 0
		local duration = 0.3
		while elapsed < duration and self._respawnToken == token do
			elapsed += RunService.Heartbeat:Wait()
			local t = math.clamp(elapsed / duration, 0, 1)
			-- Falls in, overshoots into a squash, settles.
			local drop = (1 - t) * (1 - t) * 2.4
			local squash = if t > 0.7 then math.sin((t - 0.7) / 0.3 * math.pi) * 0.18 else 0
			parked:PivotTo(home * CFrame.new(0, drop - squash, 0))
		end
		if self._respawnToken == token then
			parked:PivotTo(home)
			self._vfx:burst("dust", (home * CFrame.new(0, -0.8, 0)).Position, 0.25)
		end
	end)
end

-- Runs one sale's timeline on a Heartbeat thread over a travelling copy of the parked crate; each
-- segment interpolates the pivot from its own start pose so nothing snaps. The copy is destroyed
-- when its ride ends.
function CrateController.play(self: CrateController, payload: { [string]: any })
	local parked = self:crateModel()
	local geometry = ChapterLayout.chapter1.crate
	if not parked or not geometry then
		self.stats.ignored += 1
		return
	end
	local home = self._home or parked:GetPivot()
	self._home = home
	-- The copy is taken from a visible, parked crate whatever state the last sale left it in.
	self._respawnToken += 1
	setVisible(parked, true)
	parked:PivotTo(home)
	local travelling = parked:Clone()
	travelling.Name = "SFE_CrateRun_" .. tostring(payload.runId)
	for _, descendant in ipairs(travelling:GetDescendants()) do
		if descendant:IsA("ClickDetector") or descendant:IsA("ProximityPrompt") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Anchored = true
		end
	end
	travelling.Parent = parked.Parent
	local run: Run = {
		id = payload.runId,
		crate = travelling,
		feathers = {},
		squash = 0,
		squashVelocity = 0,
		onBelt = false,
	}
	table.insert(self._runs, run)
	self.stats.runs += 1
	self:_fillCrate(run, payload.featherCount or 0)
	if payload.sellerUserId ~= Players.LocalPlayer.UserId then
		self:showFeathers(1)
	end
	-- The parked crate is gone until the fresh one lands.
	setVisible(parked, false)
	self._hidden = true
	self:_respawnLater(parked, home)
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
	local function setOnBelt(onBelt: boolean)
		if run.onBelt == onBelt then
			return
		end
		run.onBelt = onBelt
		self._beltRuns += if onBelt then 1 else -1
		if onBelt then
			self:_bindConveyor()
		end
	end
	task.spawn(function()
		local from = home
		for _, segment in ipairs(payload.timeline) do
			if run.crate.Parent == nil then
				break
			end
			local name = segment.name
			if name == "reset" then
				-- The ride is over; the copy has fallen out of sight.
				break
			end
			local to = poses[name] or from
			local ease = if name == "fall"
				then easeIn
				elseif name == "frontBelt" or name == "sideBelt" then function(t)
					return t
				end
				else easeInOut
			setOnBelt(name == "frontBelt" or name == "sideBelt" or name == "machine" or name == "turn")
			local elapsed = 0
			local wasVisible = true
			while elapsed < segment.seconds and run.crate.Parent ~= nil do
				local dt = RunService.Heartbeat:Wait()
				elapsed += dt
				local t = math.clamp(elapsed / math.max(0.001, segment.seconds), 0, 1)
				local damping = 2 * math.sqrt(180)
				run.squashVelocity += (-180 * run.squash - damping * run.squashVelocity) * dt
				run.squash = math.clamp(run.squash + run.squashVelocity * dt, -0.25, 0.25)
				run.crate:PivotTo(from:Lerp(to, ease(t)) * CFrame.new(0, -run.squash, 0))
				if name == "fall" and t > 0.55 and wasVisible then
					-- Fully below the pit floor: vanish.
					wasVisible = false
					setVisible(run.crate, false)
					for _, feather in ipairs(run.feathers) do
						feather.Transparency = 1
					end
				end
			end
			if name == "tip" then
				self._vfx:burst("dust", Vector3.new(hole.X, hole.Y + 3, hole.Z), 0.5)
				self._audio:play("sell.burst")
			end
			from = to
		end
		setOnBelt(false)
		self:_finishRun(run)
	end)
end

function CrateController._finishRun(self: CrateController, run: Run)
	local index = table.find(self._runs, run)
	if not index then
		return
	end
	table.remove(self._runs, index)
	if run.crate.Parent then
		run.crate:Destroy()
	end
	table.clear(run.feathers)
	self.runFinished:Fire(run.id)
end

function CrateController.isRunning(self: CrateController): boolean
	return #self._runs > 0
end

function CrateController.destroy(self: CrateController)
	for _, run in ipairs(table.clone(self._runs)) do
		if run.onBelt then
			run.onBelt = false
			self._beltRuns -= 1
		end
		self:_finishRun(run)
	end
	self._beltRuns = 0
	self._respawnToken += 1
	local parked = self:crateModel()
	if parked then
		setVisible(parked, true)
		if self._home then
			parked:PivotTo(self._home)
		end
	end
	self.runStarted:Destroy()
	self.runFinished:Destroy()
	self._trove:destroy()
end

return CrateController
