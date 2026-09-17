--!strict
-- Molly the Mole on the client. Owns everything the player sees of her and her machine: the
-- nameplate, the outline while her prompt is in reach, the idle (looking between the pile and the
-- map, goggles, notes, tapping tiles, the crank, a drill test, an ear to the table, greeting who
-- walks up), the survey panel - a top-down nest map of four big labelled areas, one pick, one
-- green SURVEY button with the crate's price, and the answer (STRONG, WEAK or NO SIGNAL) - the live
-- pick relayed to the party, the trade request, a short listening beat on the bench machine after
-- a committed trade, and the readings on the map tiles and the board from the round snapshot.
--
-- The rig arrives anchored; limbs are freed locally and the Motor6D C0s driven from here. Every
-- resource the panel takes (input, cursor, HUD) is returned by one trove.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Trove = require(Shared.Util.Trove)
local NestSurvey = require(Shared.Domain.NestSurvey)
local NpcPlate = require(script.Parent.Parent.UI.NpcPlate)
local SurveyPanel = require(script.Parent.Parent.UI.SurveyPanel)
local Confetti = require(script.Parent.Parent.UI.Components.Confetti)

local MollyController = {}
MollyController.__index = MollyController

MollyController.ARENA_NAME = "SFE_Chapter1"
MollyController.MODEL_NAME = "MollyTheMole"
MollyController.STATION_NAME = "SurveyStation"
MollyController.PROMPT_NAME = "SFE_MollySurvey"
MollyController.NPC_NAME = "Molly the Mole"

local LOOK_RANGE = 16
local TILE_RAISE = 0.22
local TILE_HOVER = 0.1
local STRAW = Color3.fromRGB(226, 196, 132)
local STRAW_LIT = Color3.fromRGB(255, 226, 150)
local STRAW_HOVER = Color3.fromRGB(240, 214, 150)
local NONE_TINT = Color3.fromRGB(170, 176, 190)
local WEAK_TINT = Color3.fromRGB(240, 190, 110)
local STRONG_TINT = Color3.fromRGB(255, 214, 96)
local BLUE_GREY = Color3.fromRGB(90, 110, 140)
local RED = Color3.fromRGB(196, 52, 44)
local INK = Color3.fromRGB(60, 44, 32)

local function tintFor(signal: string?): Color3
	if signal == "strong" then
		return STRONG_TINT
	elseif signal == "weak" then
		return WEAK_TINT
	end
	return NONE_TINT
end

local function inkFor(signal: string?): Color3
	return if signal == "none" then BLUE_GREY else RED
end

local RIG_PARTS = { "HumanoidRootPart", "Head", "UpperTorso", "RightUpperArm", "RightLowerArm", "LeftUpperArm", "LeftLowerArm" }
local RIG_MOTORS = {
	Neck = "Head",
	Waist = "UpperTorso",
	RightShoulder = "RightUpperArm",
	RightElbow = "RightLowerArm",
	LeftShoulder = "LeftUpperArm",
	LeftElbow = "LeftLowerArm",
}
local STATION_PARTS = {
	"Tile_backBarn",
	"Tile_frontFence",
	"DrillBridge",
	"DrillHead",
	"GaugeNeedle",
	"LampNone",
	"LampWeak",
	"LampStrong",
	"Gear1",
	"Lever",
	"SeismoNeedle",
	"SeismoPaper",
	"ResultBoard",
	"CratePlatform",
	"HopperFunnel",
	"Whistle",
	"CrankWheel",
	"MapPlinth",
}

type Pivoted = { part: BasePart, rest: CFrame, pivot: Vector3, axis: Vector3 }
type SpinGroup = { rest: CFrame, pieces: { { part: BasePart, rel: CFrame } } }
-- The open panel: the pick, the last relayed pick, and the answer once a scan has run.
type Selection = {
	trove: Trove.Trove,
	region: string?,
	sent: string?, -- the last relayed pick
	panel: any,
	canSurvey: boolean,
	scanning: boolean,
	result: any?, -- the reading this panel bought, shown until the panel closes
}

export type MollyController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_trove: Trove.Trove,
		_rig: Model?,
		_station: Model?,
		_bound: Trove.Trove?,
		_highlights: { Highlight },
		_motors: { [string]: { motor: Motor6D, base: CFrame } },
		_tiles: { [string]: { part: BasePart, restY: number, tufts: { { part: BasePart, rest: CFrame } }, lift: number, color: Color3 } },
		_mapCentre: Vector3,
		_pivots: { [string]: Pivoted },
		_gears: { SpinGroup },
		_crank: SpinGroup?,
		_drill: { head: Model, headRest: CFrame, bridge: BasePart, bridgeRest: CFrame, target: Vector3, descend: number, current: Vector3 }?,
		_gesture: { name: string, t: number, duration: number, region: string? }?,
		_nextGesture: number,
		_look: { yaw: number, pitch: number, until_: number }?,
		_yaw: number,
		_pitch: number,
		_hop: number,
		_selection: Selection?,
		_pending: boolean,
		_remoteSelection: string?,
		_lamps: { [string]: { part: BasePart, light: PointLight, level: number } },
		_ring: { bars: { BasePart }, sparks: { BasePart }, hub: BasePart, region: string?, restY: number }?,
		_gaugeLevel: number,
		_seismoLevel: number,
		_gearSpeed: number,
		_gearAngle: number,
		stats: {
			opens: number,
			refused: number,
			selections: number,
			cancels: number,
			surveys: number,
			scans: number,
			banners: number,
			boardUpdates: number,
			gestures: number,
		},
	},
	MollyController
))

function MollyController.new(deps: {
	net: any,
	round: any,
	modals: any,
	hud: any,
	input: any,
	audio: any,
	haptics: any,
	accessibility: any,
	quality: any,
	camera: any,
	config: { [string]: any },
	interaction: any,
}): MollyController
	local self = setmetatable({
		_deps = deps,
		_trove = Trove.new(),
		_rig = nil,
		_station = nil,
		_bound = nil,
		_highlights = {},
		_motors = {},
		_tiles = {},
		_mapCentre = Vector3.zero,
		_pivots = {},
		_gears = {},
		_crank = nil,
		_drill = nil,
		_gesture = nil,
		_nextGesture = os.clock() + 4,
		_look = nil,
		_yaw = 0,
		_pitch = 0,
		_hop = 0,
		_selection = nil,
		_pending = false,
		_remoteSelection = nil,
		_lamps = {},
		_ring = nil,
		_gaugeLevel = 0,
		_seismoLevel = 0,
		_gearSpeed = 0,
		_gearAngle = 0,
		stats = {
			opens = 0,
			refused = 0,
			selections = 0,
			cancels = 0,
			surveys = 0,
			scans = 0,
			banners = 0,
			boardUpdates = 0,
			gestures = 0,
		},
	}, MollyController)

	self._trove:add(deps.interaction.surveyRequested:Connect(function()
		self:interact()
	end))
	self._trove:add(deps.net:on("SurveyCompleted", function(payload)
		self:_onCompleted(payload)
	end))
	self._trove:add(deps.net:on("SurveySelection", function(payload)
		self:_onRemoteSelection(payload)
	end))
	self._trove:add(deps.round.snapshot:Connect(function()
		self:_applyResult()
	end))
	self._trove:add(deps.round.phaseChanged:Connect(function()
		if deps.round:phase() ~= "Searching" then
			self:_endSelection("phase")
		end
		self:_applyResult()
	end))
	local player = Players.LocalPlayer
	if player then
		self._trove:add(player.CharacterAdded:Connect(function()
			self:_endSelection("respawn")
		end))
	end
	self._trove:add(ProximityPromptService.PromptShown:Connect(function(prompt)
		if prompt.Name == MollyController.PROMPT_NAME then
			self:_setHighlighted(true)
			deps.audio:play(Tokens.sound.stationChime, { at = prompt.Parent :: any })
		end
	end))
	self._trove:add(ProximityPromptService.PromptHidden:Connect(function(prompt)
		if prompt.Name == MollyController.PROMPT_NAME then
			self:_setHighlighted(false)
		end
	end))
	self:_watchArena()
	return self
end

-- Finding the rig and the station, now or when they are built; binding waits for their parts.
function MollyController._watchArena(self: MollyController)
	local function tryBind(folder: Instance)
		local rig = folder:FindFirstChild(MollyController.MODEL_NAME)
		local station = folder:FindFirstChild(MollyController.STATION_NAME)
		if rig and rig:IsA("Model") and station and station:IsA("Model") then
			self:_bind(rig, station)
			return true
		end
		return false
	end
	local function watchFolder(folder: Instance)
		if tryBind(folder) then
			return
		end
		local conn: RBXScriptConnection
		conn = folder.ChildAdded:Connect(function()
			task.defer(function()
				if self._rig == nil and tryBind(folder) then
					conn:Disconnect()
				end
			end)
		end)
		self._trove:add(conn)
	end
	local arena = workspace:FindFirstChild(MollyController.ARENA_NAME)
	if arena then
		watchFolder(arena)
	end
	self._trove:add(workspace.ChildAdded:Connect(function(child)
		if child.Name == MollyController.ARENA_NAME then
			task.defer(watchFolder, child)
		end
	end))
end

function MollyController._bind(self: MollyController, rig: Model, station: Model)
	if self._bound then
		self._bound:destroy()
	end
	local bound = Trove.new()
	self._bound = bound
	self._rig = rig
	self._station = station
	local alive = true
	bound:add(function()
		alive = false
	end)
	task.spawn(function()
		for _, name in ipairs(RIG_PARTS) do
			rig:WaitForChild(name, 10)
		end
		for motorName, parentName in pairs(RIG_MOTORS) do
			local parent = rig:FindFirstChild(parentName)
			if parent then
				parent:WaitForChild(motorName, 10)
			end
		end
		for _, name in ipairs(STATION_PARTS) do
			station:WaitForChild(name, 10)
		end
		local board = station:FindFirstChild("ResultBoard")
		if board then
			board:WaitForChild("Gui", 5)
		end
		if alive and self._bound == bound then
			self:_bindReady(rig, station, bound)
		end
	end)
end

local function pivoted(part: BasePart, axis: Vector3): Pivoted
	local attachment = part:FindFirstChild("Pivot")
	local pivot = if attachment and attachment:IsA("Attachment") then attachment.WorldPosition else part.Position
	return { part = part, rest = part.CFrame, pivot = pivot, axis = axis }
end

local function applyPivot(p: Pivoted, angle: number)
	local rotation = CFrame.fromAxisAngle(p.axis, angle)
	p.part.CFrame = CFrame.new(p.pivot) * rotation * CFrame.new(-p.pivot) * p.rest
end

local function spinGroup(hub: BasePart, pieces: { BasePart }): SpinGroup
	local group = { rest = hub.CFrame, pieces = {} }
	table.insert(group.pieces, { part = hub, rel = CFrame.new() })
	for _, piece in ipairs(pieces) do
		table.insert(group.pieces, { part = piece, rel = hub.CFrame:ToObjectSpace(piece.CFrame) })
	end
	return group
end

local function applySpin(group: SpinGroup, angle: number)
	local turned = group.rest * CFrame.Angles(angle, 0, 0)
	for _, piece in ipairs(group.pieces) do
		piece.part.CFrame = turned * piece.rel
	end
end

function MollyController._bindReady(self: MollyController, rig: Model, station: Model, bound: Trove.Trove)
	self._highlights = {}
	local root = rig:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local _, size = rig:GetBoundingBox()
		local plate = NpcPlate.build(root, MollyController.NPC_NAME, "Underground surveyor", size.Y * 0.5 + 0.9, { onTop = true })
		bound:add(plate.destroy)
	end
	for _, model in ipairs({ rig, station }) do
		local highlight = Instance.new("Highlight")
		highlight.Name = "SFE_MollyOutline"
		highlight.FillTransparency = 1
		highlight.OutlineColor = Tokens.color.goldLight
		highlight.OutlineTransparency = 0
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Enabled = false
		highlight.Adornee = model
		highlight.Parent = model
		bound:add(highlight)
		table.insert(self._highlights, highlight)
	end
	-- Joints and locally freed limbs.
	self._motors = {}
	local function adopt(descendant: Instance)
		if descendant:IsA("Motor6D") then
			self._motors[descendant.Name] = { motor = descendant, base = descendant.C0 }
		elseif descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
			descendant.Anchored = false
		end
	end
	for _, descendant in ipairs(rig:GetDescendants()) do
		adopt(descendant)
	end
	bound:add(rig.DescendantAdded:Connect(adopt))
	-- The map.
	self._tiles = {}
	local centre = station:GetAttribute("SFE_MapCentre")
	self._mapCentre = if typeof(centre) == "Vector3" then centre else Vector3.zero
	for _, region in ipairs(NestSurvey.REGIONS) do
		local tile = station:FindFirstChild("Tile_" .. region)
		if tile and tile:IsA("BasePart") then
			local tufts = {}
			for _, child in ipairs(station:GetChildren()) do
				if child:IsA("BasePart") and child:GetAttribute("SFE_TuftOf") == region then
					table.insert(tufts, { part = child, rest = child.CFrame })
				end
			end
			self._tiles[region] = { part = tile, restY = tile.Position.Y, tufts = tufts, lift = 0, color = tile.Color }
		end
	end
	-- Pivoted pieces: gauge needle (about the gauge's normal), lever (about its hinge), seismo arm.
	self._pivots = {}
	local gauge = station:FindFirstChild("GaugeNeedle")
	if gauge and gauge:IsA("BasePart") then
		self._pivots.gauge = pivoted(gauge, gauge.CFrame.LookVector)
	end
	local lever = station:FindFirstChild("Lever")
	if lever and lever:IsA("BasePart") then
		local hinge = pivoted(lever, lever.CFrame.RightVector)
		self._pivots.lever = hinge
		local knob = station:FindFirstChild("LeverKnob")
		if knob and knob:IsA("BasePart") then
			self._pivots.leverKnob = { part = knob, rest = knob.CFrame, pivot = hinge.pivot, axis = hinge.axis }
		end
	end
	local seismoArm = station:FindFirstChild("SeismoNeedle")
	if seismoArm and seismoArm:IsA("BasePart") then
		self._pivots.seismo = pivoted(seismoArm, Vector3.yAxis)
	end
	-- Gears and their teeth, the crank and its arm.
	self._gears = {}
	for i = 1, 3 do
		local gear = station:FindFirstChild("Gear" .. i)
		if gear and gear:IsA("BasePart") then
			local teeth = {}
			for _, child in ipairs(station:GetChildren()) do
				if child:IsA("BasePart") and child:GetAttribute("SFE_GearOf") == i then
					table.insert(teeth, child)
				end
			end
			table.insert(self._gears, spinGroup(gear, teeth))
		end
	end
	local wheel = station:FindFirstChild("CrankWheel")
	if wheel and wheel:IsA("BasePart") then
		local crankParts = {}
		for _, child in ipairs(station:GetChildren()) do
			if child:IsA("BasePart") and child:GetAttribute("SFE_CrankPart") then
				table.insert(crankParts, child)
			end
		end
		self._crank = spinGroup(wheel, crankParts)
	end
	-- The drill: bridge along world Z, head along world X; rest over the map's centre.
	local head = station:FindFirstChild("DrillHead")
	local bridge = station:FindFirstChild("DrillBridge")
	if head and head:IsA("Model") and head.PrimaryPart and bridge and bridge:IsA("BasePart") then
		self._drill = {
			head = head,
			headRest = head:GetPivot(),
			bridge = bridge,
			bridgeRest = bridge.CFrame,
			target = head:GetPivot().Position,
			descend = 0,
			current = head:GetPivot().Position,
		}
	end
	-- The selection ring and its sparks.
	local ringModel = station:FindFirstChild("TileRing")
	if ringModel and ringModel:IsA("Model") and ringModel.PrimaryPart then
		local bars, sparks = {}, {}
		for _, child in ipairs(ringModel:GetChildren()) do
			if child:IsA("BasePart") and string.find(child.Name, "RingBar", 1, true) then
				table.insert(bars, child)
			elseif child:IsA("BasePart") and string.find(child.Name, "Spark", 1, true) then
				table.insert(sparks, child)
			end
		end
		table.sort(bars, function(a, b)
			return a.Name < b.Name
		end)
		self._ring = { bars = bars, sparks = sparks, hub = ringModel.PrimaryPart, region = nil, restY = ringModel.PrimaryPart.Position.Y }
	end
	-- Lamps.
	self._lamps = {}
	for _, spec in ipairs({ { "none", "LampNone" }, { "weak", "LampWeak" }, { "strong", "LampStrong" } }) do
		local lamp = station:FindFirstChild(spec[2])
		local light = lamp and lamp:FindFirstChild("Light")
		if lamp and lamp:IsA("BasePart") and light and light:IsA("PointLight") then
			self._lamps[spec[1]] = { part = lamp, light = light, level = 0 }
		end
	end
	-- The tick.
	local accumulator = 0
	local started = os.clock()
	bound:add(RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		local tier = self._deps.quality and self._deps.quality:tier() or "high"
		local interval = if tier == "low" then 1 / 15 else 1 / 30
		if accumulator < interval then
			return
		end
		local step = accumulator
		accumulator = 0
		self:_stepIdle(step, os.clock() - started)
		self:_stepMachine(step, os.clock() - started)
	end))
	bound:add(function()
		self._rig = nil
		self._station = nil
		self._motors = {}
		self._tiles = {}
		self._drill = nil
		self._gears = {}
		self._crank = nil
		self._pivots = {}
		self._lamps = {}
		self._ring = nil
	end)
	self:_applyResult()
end

function MollyController._setHighlighted(self: MollyController, on: boolean)
	for _, highlight in ipairs(self._highlights) do
		highlight.Enabled = on
	end
end

-- Puts the neon ring around a tile (nil hides it under the plinth).
function MollyController._setRing(self: MollyController, region: string?)
	local ring = self._ring
	if not ring then
		return
	end
	ring.region = region
	local tile = region and self._tiles[region]
	if not tile then
		for _, bar in ipairs(ring.bars) do
			bar.Transparency = 1
		end
		for _, spark in ipairs(ring.sparks) do
			spark.Transparency = 1
		end
		return
	end
	local half = tile.part.Size.X / 2 + 0.06
	local y = tile.part.Position.Y + tile.part.Size.Y / 2 + 0.03
	local c = tile.part.Position
	local spots = { Vector3.new(0, 0, half), Vector3.new(0, 0, -half), Vector3.new(half, 0, 0), Vector3.new(-half, 0, 0) }
	for i, bar in ipairs(ring.bars) do
		bar.CFrame = CFrame.new(c.X + spots[i].X, y, c.Z + spots[i].Z)
		bar.Transparency = 0.1
	end
	ring.hub.CFrame = CFrame.new(c.X, y, c.Z)
end

-- World position over a tile (at gantry height for the drill, at the tile for a look).
function MollyController._tilePosition(self: MollyController, region: string): Vector3?
	local tile = self._tiles[region]
	return tile and tile.part.Position or nil
end

-- ----------------------------------------------------------------------------------------------
-- Idle

local GESTURES = {
	{ name = "lookPile", weight = 3, duration = 2.6 },
	{ name = "lookMap", weight = 3, duration = 2.2 },
	{ name = "goggles", weight = 1.5, duration = 1.8 },
	{ name = "write", weight = 2, duration = 2.8 },
	{ name = "tap", weight = 2.5, duration = 2.0 },
	{ name = "crank", weight = 1.5, duration = 2.6 },
	{ name = "drill", weight = 1, duration = 2.2 },
	{ name = "ear", weight = 1, duration = 3.0 },
}

local function pickGesture(): { name: string, weight: number, duration: number }
	local total = 0
	for _, g in ipairs(GESTURES) do
		total += g.weight
	end
	local roll = math.random() * total
	for _, g in ipairs(GESTURES) do
		roll -= g.weight
		if roll <= 0 then
			return g
		end
	end
	return GESTURES[1]
end

-- Yaw/pitch (rig-local, the rig faces -Z) that puts the head on a world point.
local function lookAngles(root: BasePart, head: BasePart, target: Vector3): (number, number)
	local localDir = root.CFrame:VectorToObjectSpace(target - head.Position)
	local horizontal = math.sqrt(localDir.X * localDir.X + localDir.Z * localDir.Z)
	return math.clamp(math.atan2(-localDir.X, -localDir.Z), -1.1, 1.1), math.clamp(math.atan2(localDir.Y, horizontal), -0.75, 0.45)
end

function MollyController._stepIdle(self: MollyController, dt: number, t: number)
	local rig = self._rig
	if not rig then
		return
	end
	local motors = self._motors
	local neck, waist = motors.Neck, motors.Waist
	local rShoulder, rElbow = motors.RightShoulder, motors.RightElbow
	local lShoulder, lElbow = motors.LeftShoulder, motors.LeftElbow
	if not (neck and waist and rShoulder and rElbow and lShoulder and lElbow) then
		return
	end
	local reduced = self._deps.accessibility:motionSettings().reducedMotion
	local root = rig:FindFirstChild("HumanoidRootPart") :: BasePart?
	local head = rig:FindFirstChild("Head") :: BasePart?
	if not (root and head) then
		return
	end
	-- Where she looks: an explicit target (a hovered tile, the machine) wins; then a player who has
	-- walked up; then the current gesture; then a slow drift between the map and the mound.
	local targetYaw, targetPitch = math.sin(t * 0.3) * 0.25 + 0.1, -0.35
	local look = self._look
	local nearestHead: BasePart? = nil
	if look and os.clock() < look.until_ then
		targetYaw, targetPitch = look.yaw, look.pitch
	else
		self._look = nil
		local nearestDistance = LOOK_RANGE
		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			local pHead = character and character:FindFirstChild("Head")
			if pHead and pHead:IsA("BasePart") then
				local distance = (pHead.Position - head.Position).Magnitude
				if distance < nearestDistance then
					nearestHead, nearestDistance = pHead, distance
				end
			end
		end
		if nearestHead and not self._selection then
			targetYaw, targetPitch = lookAngles(root, head, nearestHead.Position)
		end
	end
	-- Gestures.
	local gesture = self._gesture
	if not gesture and not self._selection and os.clock() >= self._nextGesture then
		local pick = pickGesture()
		gesture = { name = pick.name, t = 0, duration = pick.duration, region = NestSurvey.REGIONS[math.random(1, #NestSurvey.REGIONS)] }
		self._gesture = gesture
		self.stats.gestures += 1
	end
	-- Rest: both paws forward and down onto the bench top in front of her, elbows soft, a slow lean
	-- with the breath. On this rig a positive shoulder pitch swings the arm forward.
	local settle = math.sin(t * 1.3) * 0.02
	local rPitch, rRoll, rElbowPitch = 0.95 + settle, 0.1, 0.08
	local lPitch, lRoll, lElbowPitch = 0.95 + settle, -0.1, 0.08
	local waistPitch, waistYaw, waistY = 0, 0, 0
	local crankSpin = nil
	if gesture then
		gesture.t += dt
		local phase = math.clamp(gesture.t / gesture.duration, 0, 1)
		local blend = math.sin(phase * math.pi)
		local name = gesture.name
		if name == "lookPile" then
			local layoutTarget = self._mapCentre + Vector3.new(0, 2, 0)
			local nest = workspace:FindFirstChild(MollyController.ARENA_NAME)
			local pile = nest and nest:FindFirstChild("PileBody")
			local target = if pile then pile:GetPivot().Position + Vector3.new(0, 6, 0) else layoutTarget - (root.CFrame.LookVector * -30)
			if not look then
				targetYaw, targetPitch = lookAngles(root, head, target)
			end
		elseif name == "lookMap" then
			if not look then
				targetYaw, targetPitch = lookAngles(root, head, self._mapCentre)
			end
		elseif name == "goggles" then
			lPitch = -0.5 - 1.9 * blend
			lElbowPitch = -0.55 - 0.9 * blend
			lRoll = -0.12 - 0.2 * blend
			if not look then
				targetPitch = -0.1 * blend
			end
		elseif name == "write" then
			rPitch = -1.0 + math.sin(t * 7) * 0.04 * blend
			rElbowPitch = -1.15 + math.sin(t * 9) * 0.06 * blend
			rRoll = 0.25
			if not look then
				targetYaw, targetPitch = 0.35, -0.6
			end
		elseif name == "tap" then
			local tilePos = self:_tilePosition(gesture.region or NestSurvey.REGIONS[1])
			if tilePos and not look then
				targetYaw, targetPitch = lookAngles(root, head, tilePos)
			end
			rPitch = -0.55 - 0.95 * blend
			rElbowPitch = -0.6 + 0.2 * blend
			rRoll = 0.1 + 0.35 * blend
			local tile = self._tiles[gesture.region or ""]
			if tile and phase > 0.4 and phase < 0.7 and not self._selection then
				tile.lift = math.max(tile.lift, TILE_HOVER * math.sin((phase - 0.4) / 0.3 * math.pi))
			end
		elseif name == "crank" then
			rPitch = -0.9 + math.sin(gesture.t * 5) * 0.25
			rElbowPitch = -0.8 + math.cos(gesture.t * 5) * 0.25
			rRoll = 0.4
			waistYaw = 0.35
			crankSpin = gesture.t * 5
			if not look then
				targetYaw, targetPitch = 0.9, -0.3
			end
		elseif name == "drill" then
			lPitch = -1.2 * blend
			lElbowPitch = -0.4 * blend
			if self._drill and not self._selection then
				self._drill.descend = 0.28 * blend
			end
			if not look then
				local drillPos = self._drill and self._drill.current or self._mapCentre
				targetYaw, targetPitch = lookAngles(root, head, drillPos)
			end
		elseif name == "headshake" then
			-- Disappointed: a slow shake, shoulders down.
			if not look then
				targetYaw, targetPitch = math.sin(gesture.t * 9) * 0.35, -0.3
			end
			rPitch, lPitch = -0.3, -0.3
			waistPitch = 0.12 * blend
		elseif name == "cheer" then
			-- Excited: both arms up, a little bounce carried by the hop.
			rPitch = -0.55 - 2.4 * blend
			lPitch = -0.5 - 2.4 * blend
			rRoll, lRoll = 0.3, -0.3
			rElbowPitch, lElbowPitch = -0.3, -0.3
			if not look then
				targetYaw, targetPitch = 0, 0.25 * blend
			end
		elseif name == "ear" then
			waistPitch = 0.55 * blend
			waistY = -0.12 * blend
			if not look then
				targetYaw, targetPitch = 0.6, 0.35 * blend - 0.5 * (1 - blend)
			end
			rPitch = -0.9 * blend
			rElbowPitch = -0.7 * blend
		end
		if phase >= 1 then
			self._gesture = nil
			self._nextGesture = os.clock() + 3.5 + math.random() * 5
		end
	end
	if reduced then
		-- Reduced motion: the slow head turn only, and the gesture timer keeps ticking.
		local ease = math.min(1, dt * 3)
		self._yaw += (targetYaw - self._yaw) * ease
		self._pitch += (targetPitch - self._pitch) * ease
		neck.motor.C0 = neck.base * CFrame.fromEulerAnglesYXZ(self._pitch, self._yaw, 0)
		return
	end
	local ease = math.min(1, dt * 6)
	self._yaw += (targetYaw - self._yaw) * ease
	self._pitch += (targetPitch - self._pitch) * ease
	neck.motor.C0 = neck.base * CFrame.fromEulerAnglesYXZ(self._pitch, self._yaw, 0)
	-- The hop decays on its own (set by the strong-signal reaction).
	self._hop = math.max(0, self._hop - dt * 2.2)
	local hopY = math.sin(math.min(1, self._hop) * math.pi) * 0.45
	local breathe = math.sin(t * 1.7) * 0.02
	waist.motor.C0 = waist.base
		* CFrame.new(0, breathe + waistY + hopY, 0)
		* CFrame.fromEulerAnglesYXZ(waistPitch + math.sin(t * 1.7) * 0.01, waistYaw, 0)
	rShoulder.motor.C0 = rShoulder.base * CFrame.Angles(rPitch, 0, rRoll)
	rElbow.motor.C0 = rElbow.base * CFrame.Angles(rElbowPitch, 0, 0)
	lShoulder.motor.C0 = lShoulder.base * CFrame.Angles(lPitch, 0, lRoll)
	lElbow.motor.C0 = lElbow.base * CFrame.Angles(lElbowPitch, 0, 0)
	if crankSpin and self._crank then
		applySpin(self._crank, crankSpin)
	end
end

-- ----------------------------------------------------------------------------------------------
-- Machine: tiles, drill, gears, gauge, lamps, seismograph. Levels are set by the panel; this
-- moves the parts towards them every tick.

function MollyController._stepMachine(self: MollyController, dt: number, t: number)
	local station = self._station
	if not station then
		return
	end
	local reduced = self._deps.accessibility:motionSettings().reducedMotion
	-- Tiles: rise towards their lift and fall back.
	for _, tile in pairs(self._tiles) do
		local currentY = tile.part.Position.Y
		local wantY = tile.restY + tile.lift
		local y = if reduced then wantY else currentY + (wantY - currentY) * math.min(1, dt * 10)
		if math.abs(y - currentY) > 1e-4 then
			local dy = y - currentY
			tile.part.CFrame = tile.part.CFrame + Vector3.new(0, dy, 0)
			for _, tuft in ipairs(tile.tufts) do
				tuft.part.CFrame = tuft.rest + Vector3.new(0, y - tile.restY, 0)
			end
		end
		if not self._selection and tile.lift > 0 and tile.lift < TILE_RAISE then
			tile.lift = math.max(0, tile.lift - dt * 0.4) -- an idle tap settles back
		end
	end
	-- Drill: bridge follows the target's Z, head follows X and Z, and dips by `descend`.
	local drill = self._drill
	if drill then
		local target = drill.target
		local current = drill.current
		local next = if reduced then target else current:Lerp(target, math.min(1, dt * 5))
		drill.current = next
		local restY = drill.headRest.Position.Y
		local headCF = CFrame.new(next.X, restY - drill.descend, next.Z) * (drill.headRest - drill.headRest.Position)
		drill.head:PivotTo(headCF)
		local bridgeRest = drill.bridgeRest
		drill.bridge.CFrame = CFrame.new(bridgeRest.Position.X, bridgeRest.Position.Y, next.Z) * (bridgeRest - bridgeRest.Position)
	end
	-- Gears turn at the current speed.
	if self._gearSpeed > 0.01 and not reduced then
		self._gearAngle += dt * self._gearSpeed
		for i, gear in ipairs(self._gears) do
			applySpin(gear, self._gearAngle * (if i == 2 then -1.4 else 1) * (if i == 3 then -0.8 else 1))
		end
	end
	-- Gauge needle: 0 -> pointing down-left, 1 -> up-right; a little tremble while searching.
	local gauge = self._pivots.gauge
	if gauge then
		local tremble = if self._selection and self._selection.scanning and not reduced then math.sin(t * 23) * 0.04 else 0
		applyPivot(gauge, -math.rad(120) * math.clamp(self._gaugeLevel + tremble, 0, 1) + math.rad(60))
	end
	-- Seismograph arm and trace.
	local seismo = self._pivots.seismo
	if seismo then
		local swing = if reduced then 0 else math.sin(t * 19) * 0.35 * self._seismoLevel
		applyPivot(seismo, swing)
	end
	local paper = station:FindFirstChild("SeismoPaper")
	local trace = paper and paper:FindFirstChild("Gui") and (paper :: any).Gui:FindFirstChild("Trace")
	if trace and self._seismoLevel >= 0 then
		local level = self._seismoLevel
		-- Scroll: each bar takes the height of the one before; the first takes the live reading.
		for i = 40, 2, -1 do
			local bar = trace:FindFirstChild("Bar" .. i)
			local previous = trace:FindFirstChild("Bar" .. (i - 1))
			if bar and previous and bar:IsA("Frame") and previous:IsA("Frame") then
				bar.Size = previous.Size
			end
		end
		local first = trace:FindFirstChild("Bar1")
		if first and first:IsA("Frame") then
			local h = if level <= 0.001 then 2 else 2 + (math.abs(math.sin(t * 31)) * 0.6 + math.random() * 0.4) * 40 * level
			first.Size = UDim2.new(first.Size.X.Scale, 0, 0, math.floor(h))
		end
	end
	-- The ring breathes and its sparks circle the chosen tile.
	local ring = self._ring
	if ring and ring.region then
		local tile = self._tiles[ring.region]
		if tile then
			local pulse = if reduced then 0.15 else 0.15 + 0.25 * (0.5 + 0.5 * math.sin(t * 5))
			local y = tile.part.Position.Y + tile.part.Size.Y / 2 + 0.03
			for _, bar in ipairs(ring.bars) do
				bar.Transparency = pulse
				bar.CFrame = CFrame.new(bar.Position.X, y, bar.Position.Z)
			end
			for i, spark in ipairs(ring.sparks) do
				local a = t * 2.2 + i * math.pi / 2
				local r = tile.part.Size.X / 2 + 0.3
				spark.CFrame = CFrame.new(
					tile.part.Position.X + math.cos(a) * r,
					y + 0.25 + math.sin(t * 6 + i) * 0.06,
					tile.part.Position.Z + math.sin(a) * r
				) * CFrame.Angles(0, -a, 0)
				spark.Transparency = if reduced then 0.3 else 0.2 + 0.4 * (0.5 + 0.5 * math.sin(t * 7 + i))
			end
		end
	end
	-- Lamps glow to their level.
	for _, lamp in pairs(self._lamps) do
		local target = lamp.level
		lamp.part.Transparency = 0.55 - 0.5 * target
		lamp.light.Brightness = 2.4 * target
	end
end

-- ----------------------------------------------------------------------------------------------
-- The result, from the round snapshot: tiles, ring, board, lamps at rest.

-- The round's survey as the snapshot projects it, or the fresh shape before any scan.
function MollyController._surveyInfo(self: MollyController): { [string]: any }
	local round = self._deps.round.round
	local survey = round and round.phase ~= "Returning" and round.survey or nil
	if survey and survey.readings then
		return survey
	end
	return NestSurvey.project(self._deps.config, nil)
end

-- One line of the board's list: "1. BACK BARN: WEAK SIGNAL".
local function readingLine(index: number, reading: any): string
	return string.format("%d. %s: %s", index, tostring(reading.name or NestSurvey.name(tostring(reading.region))), tostring(reading.title))
end

function MollyController._applyResult(self: MollyController)
	local station = self._station
	if not station then
		return
	end
	local survey = self:_surveyInfo()
	local readings = survey.readings or {}
	local latestByRegion = NestSurvey.latestByRegion(readings)
	local latest = readings[#readings]
	-- Tiles, ring and lamps at rest, unless a panel is driving them.
	if not self._selection then
		for region, tile in pairs(self._tiles) do
			local reading = latestByRegion[region]
			tile.lift = 0
			tile.part.Color = if reading then tintFor(reading.signal) else tile.color
		end
		self:_setRing(if latest then latest.region else nil)
		for key, lamp in pairs(self._lamps) do
			lamp.level = if latest and latest.signal == key then 0.6 else 0
		end
		self._gaugeLevel = if not latest then 0.05 elseif latest.signal == "strong" then 0.95 elseif latest.signal == "weak" then 0.35 else 0
		self._seismoLevel = 0
	end
	-- The board.
	local board = station:FindFirstChild("ResultBoard")
	local gui = board and board:FindFirstChild("Gui")
	if not gui then
		return
	end
	local status = gui:FindFirstChild("Status")
	local grid = gui:FindFirstChild("Grid")
	local statusText = if not latest
		then "NOT YET RUN"
		elseif survey.nextCost then string.format("%d OF %d SURVEYS - NEXT %d FEATHERS", survey.count, survey.max, survey.nextCost)
		else string.format("ALL %d SURVEYS USED", survey.max)
	if status and status:IsA("TextLabel") then
		if status.Text ~= statusText then
			self.stats.boardUpdates += 1
		end
		status.Text = statusText
		status.TextColor3 = if latest then INK else Color3.fromRGB(140, 120, 100)
	end
	for index = 1, 3 do
		local line = gui:FindFirstChild("Reading" .. index)
		local reading = readings[index]
		if line and line:IsA("TextLabel") then
			line.Visible = reading ~= nil
			if reading then
				line.Text = readingLine(index, reading)
				line.TextColor3 = inkFor(reading.signal)
			end
		end
	end
	if grid then
		for _, region in ipairs(NestSurvey.REGIONS) do
			local cell = grid:FindFirstChild("Cell_" .. region)
			if cell and cell:IsA("Frame") then
				local reading = latestByRegion[region]
				local mark = cell:FindFirstChild("Mark")
				local edge = cell:FindFirstChild("Edge")
				cell.BackgroundColor3 = if reading then tintFor(reading.signal) else STRAW
				if mark and mark:IsA("TextLabel") then
					mark.Visible = reading ~= nil
					mark.Text = if reading then tostring(reading.short) else ""
					mark.TextColor3 = inkFor(reading and reading.signal)
				end
				if edge and edge:IsA("UIStroke") then
					edge.Thickness = if reading then 4 else 2
					edge.Color = if reading then inkFor(reading.signal) else INK
					edge.Transparency = if reading then 0 else 0.4
				end
				for i = 1, 2 do
					local cross = cell:FindFirstChild("Cross" .. i)
					if cross and cross:IsA("Frame") then
						cross.Visible = reading ~= nil and reading.signal == "none"
					end
				end
			end
		end
	end
end

-- ----------------------------------------------------------------------------------------------
-- Interaction and the panel

function MollyController.isBusy(self: MollyController): boolean
	return self._selection ~= nil or self._pending
end

local function sayOn(rig: Model?, line: string)
	local root = rig and rig:FindFirstChild("HumanoidRootPart")
	if root then
		NpcPlate.sayOn(root, line, 3.2)
	end
end

-- The prompt press. Opens the map when a scan is possible; otherwise Molly answers over her head.
function MollyController.interact(self: MollyController): boolean
	local deps = self._deps
	if self:isBusy() then
		self.stats.refused += 1
		return false
	end
	-- Another screen (a conversation, the Book, the other NPC) has the HUD down: it owns the player.
	if deps.hud.gui.Enabled == false then
		self.stats.refused += 1
		return false
	end
	local phase = deps.round:phase()
	local player = deps.round.player
	local info = self:_surveyInfo()
	local exposed = phase == "EggRevealed"
	local active = phase == "Searching"
	local used = (info.usesLeft or 0) <= 0
	local line = NestSurvey.lineFor(deps.config, {
		active = active,
		exposed = exposed,
		count = info.count or 0,
		carriedStandard = player and player.carriedStandard or 0,
	})
	self.stats.opens += 1
	if not active or exposed or used then
		deps.audio:play(Tokens.sound.uiTap)
		sayOn(self._rig, line)
		self.stats.refused += 1
		return false
	end
	deps.audio:play(Tokens.sound.uiOpen)
	sayOn(self._rig, line)
	return self:_beginSelection()
end

-- What the panel shows: the pick, the price, and - once this panel's scan is done - the answer.
function MollyController._panelState(self: MollyController): SurveyPanel.State
	local deps = self._deps
	local selection = self._selection
	local player = deps.round.player
	local carried = player and player.carriedStandard or 0
	local info = self:_surveyInfo()
	local cost = info.nextCost or 0
	local max = info.max or NestSurvey.maxSurveys(deps.config)
	local readings = {}
	for region, reading in pairs(NestSurvey.latestByRegion(info.readings or {})) do
		readings[region] = { signal = tostring(reading.signal), short = tostring(reading.short) }
	end
	local region = selection and selection.region
	local base = {
		carried = carried,
		cost = cost,
		usesLeft = info.usesLeft,
		usesMax = max,
		selected = region,
		readings = readings,
		back = true,
	}
	if selection and selection.scanning then
		base.title = "LISTENING..."
		base.caption = if region then NestSurvey.name(region) else nil
		base.mapEnabled = false
		base.primary = nil
		base.primaryEnabled = false
		base.back = false
		base.tone = "plain"
		selection.canSurvey = false
		return base :: any
	end
	local result = selection and selection.result
	if result then
		local strong = result.signal == "strong"
		base.title = if strong then tostring(result.title) .. "!" else tostring(result.title)
		base.caption = string.format("%s - %s", tostring(result.name), tostring(result.text))
		base.mapEnabled = false
		base.primary = "DONE"
		base.primaryEnabled = true
		base.tone = if result.signal == "none" then "bad" else "good"
		if selection then
			selection.canSurvey = false
		end
		return base :: any
	end
	local affordable = info.nextCost ~= nil and carried >= cost
	local canSurvey = affordable and region ~= nil and deps.round:phase() == "Searching"
	if selection then
		selection.canSurvey = canSurvey
	end
	local step = (info.count or 0) + 1
	local stepLine = string.format("SURVEY %d OF %d", math.min(step, max), max)
	if info.nextCost == nil then
		base.title = "NO SURVEYS LEFT"
		base.caption = "Molly's drill is done for this round."
	elseif not affordable then
		base.title = if region then NestSurvey.name(region) else "PICK AN AREA"
		base.caption = string.format("%s - BRING %d NORMAL FEATHERS", stepLine, cost)
	elseif region then
		base.title = NestSurvey.name(region)
		base.caption = stepLine .. " - STRONG, WEAK OR NO SIGNAL"
	else
		base.title = "PICK AN AREA"
		base.caption = stepLine .. " - TAP ONE OF THE FOUR AREAS"
	end
	base.mapEnabled = info.nextCost ~= nil
	base.primary = if region then string.format("SURVEY %s - %d", NestSurvey.name(region), cost) else "PICK AN AREA"
	base.primaryEnabled = canSurvey
	base.tone = "plain"
	return base :: any
end

function MollyController._refreshPanel(self: MollyController)
	local selection = self._selection
	if selection and selection.panel then
		selection.panel.setState(self:_panelState())
	end
end

-- Opens the panel, frees the cursor, and reads the player's pick until they survey or leave.
function MollyController._beginSelection(self: MollyController): boolean
	local deps = self._deps
	local station, rig = self._station, self._rig
	local player = Players.LocalPlayer
	if not (station and rig and player) then
		return false
	end
	local selection: Selection = {
		trove = Trove.new(),
		region = nil,
		sent = nil,
		panel = nil,
		canSurvey = false,
		scanning = false,
		result = nil,
	}
	self._selection = selection
	deps.input:setSuspended(true)
	deps.modals:setExternalUnlock(true)
	local hudGui = deps.hud.gui
	local hudWasEnabled = hudGui.Enabled
	hudGui.Enabled = false -- the map is the screen; nothing else competes with it
	selection.trove:add(function()
		hudGui.Enabled = hudWasEnabled
		deps.modals:setExternalUnlock(false)
		deps.input:setSuspended(deps.modals:isBlocking())
	end)
	local panel = SurveyPanel.create(
		player:WaitForChild("PlayerGui"),
		{ audio = deps.audio, accessibility = deps.accessibility, config = deps.config },
		{
			onSelect = function(region)
				self:select(region)
			end,
			onPrimary = function()
				self:_confirmSurvey()
			end,
			onBack = function()
				self:_endSelection("cancel")
			end,
		}
	)
	selection.panel = panel
	selection.trove:add(panel.destroy)
	selection.trove:add(deps.round.playerChanged:Connect(function()
		if self._selection == selection then
			self:_refreshPanel()
		end
	end))
	-- Keyboard and gamepad: step over the 2x2, confirm, back out.
	selection.trove:add(UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local key = input.KeyCode
		if key == Enum.KeyCode.Up or key == Enum.KeyCode.W or key == Enum.KeyCode.DPadUp then
			self:navigate(-1, 0)
		elseif key == Enum.KeyCode.Down or key == Enum.KeyCode.S or key == Enum.KeyCode.DPadDown then
			self:navigate(1, 0)
		elseif key == Enum.KeyCode.Left or key == Enum.KeyCode.A or key == Enum.KeyCode.DPadLeft then
			self:navigate(0, -1)
		elseif key == Enum.KeyCode.Right or key == Enum.KeyCode.D or key == Enum.KeyCode.DPadRight then
			self:navigate(0, 1)
		elseif key == Enum.KeyCode.Return or key == Enum.KeyCode.ButtonA then
			self:_confirmSurvey()
		elseif key == Enum.KeyCode.Escape or key == Enum.KeyCode.ButtonB then
			self:_endSelection("cancel")
		end
	end))
	-- Molly watches the map while a player picks; everything she moved goes back on close.
	self._look = { yaw = 0.3, pitch = -0.6, until_ = math.huge }
	selection.trove:add(function()
		self._look = nil
		self._remoteSelection = nil
		if self._drill then
			self._drill.target = self._drill.headRest.Position
			self._drill.descend = 0
		end
		self._gearSpeed = 0
	end)
	if deps.input:mode() == "gamepad" then
		self:select(NestSurvey.REGIONS[1])
	end
	self:_refreshSelectionVisuals()
	return true
end

-- The pick itself, from any input path. The live pick is relayed to the party once per change.
function MollyController.select(self: MollyController, region: string?): boolean
	local selection = self._selection
	if not selection or selection.scanning or selection.result then
		return false
	end
	if not NestSurvey.isRegion(region) then
		return false
	end
	if selection.region ~= region then
		selection.region = region
		self.stats.selections += 1
		self._deps.audio:play(Tokens.sound.uiSelect)
		self._deps.haptics:pulse(0.15, 0.04)
	end
	self:_refreshSelectionVisuals()
	if selection.sent ~= region then
		selection.sent = region
		local token = self._deps.round:sessionToken()
		if token then
			task.spawn(function()
				self._deps.net:request("SurveySelect", { sessionToken = token, region = region })
			end)
		end
	end
	return true
end

function MollyController.navigate(self: MollyController, dRow: number, dCol: number): boolean
	local selection = self._selection
	if not selection then
		return false
	end
	return self:select(NestSurvey.step(selection.region or NestSurvey.REGIONS[1], dRow, dCol))
end

-- The bench follows the pick: the tile rises and lights, the ring and the drill move over it, and
-- Molly looks at it.
function MollyController._refreshSelectionVisuals(self: MollyController)
	local selection = self._selection
	if not selection then
		return
	end
	local survey = self:_surveyInfo()
	local latestByRegion = NestSurvey.latestByRegion(survey.readings or {})
	for region, tile in pairs(self._tiles) do
		local reading = latestByRegion[region]
		if region == selection.region then
			tile.lift = TILE_RAISE
			tile.part.Color = if selection.result then tintFor(selection.result.signal) else STRAW_LIT
		else
			tile.lift = 0
			tile.part.Color = if reading then tintFor(reading.signal) else tile.color
		end
	end
	self:_setRing(selection.region)
	local focusPos = if selection.region then self:_tilePosition(selection.region) else nil
	if focusPos then
		local pos = focusPos :: Vector3
		if self._drill then
			self._drill.target = Vector3.new(pos.X, self._drill.headRest.Position.Y, pos.Z)
		end
		local rig = self._rig
		local root = rig and rig:FindFirstChild("HumanoidRootPart")
		local head = rig and rig:FindFirstChild("Head")
		if root and root:IsA("BasePart") and head and head:IsA("BasePart") then
			local yaw, pitch = lookAngles(root, head, pos)
			self._look = { yaw = yaw, pitch = pitch, until_ = math.huge }
		end
	end
	self:_refreshPanel()
end

function MollyController._endSelection(self: MollyController, reason: string)
	local selection = self._selection
	if not selection then
		return
	end
	self._selection = nil
	if reason == "cancel" then
		self.stats.cancels += 1
	end
	local token = self._deps.round:sessionToken()
	if token and selection.sent and not selection.result then
		task.spawn(function()
			self._deps.net:request("SurveySelect", { sessionToken = token })
		end)
	end
	selection.trove:destroy()
	self:_applyResult()
end

-- The green button: SURVEY while picking, DONE once the answer is shown.
function MollyController._confirmSurvey(self: MollyController)
	local deps = self._deps
	local selection = self._selection
	if not selection or selection.scanning then
		return
	end
	if selection.result then
		self:_endSelection("done")
		return
	end
	if not selection.canSurvey or self._pending then
		deps.audio:play(Tokens.sound.uiError)
		return
	end
	self:survey(selection.region)
end

-- The request. Returns the envelope; a success runs the listening beat inside the open panel.
function MollyController.survey(self: MollyController, region: string?): any
	local deps = self._deps
	local token = deps.round:sessionToken()
	if not token then
		return { ok = false, code = "invalid_state", message = "no_session" }
	end
	if self._pending or (self._selection and self._selection.scanning) then
		self.stats.refused += 1
		return { ok = false, code = "invalid_state", message = "busy" }
	end
	self._pending = true
	local result = deps.net:request("SurveyRequest", { sessionToken = token, region = region })
	self._pending = false
	if not result.ok then
		deps.audio:play(Tokens.sound.uiError)
		local message = result.message
		if message == "limit" then
			sayOn(self._rig, NestSurvey.LINES.used)
			self:_endSelection("used")
		elseif message == "egg_found" then
			sayOn(self._rig, NestSurvey.LINES.exposed)
			self:_endSelection("egg")
		else
			local info = self:_surveyInfo()
			deps.hud.toasts:push(
				if message == "insufficient"
					then string.format("You need %d normal feathers for the next survey crate", info.nextCost or 0)
					elseif result.code == "out_of_range" then "Stand at Molly's bench"
					elseif result.code == "rate_limited" then "One moment..."
					else "Survey unavailable",
				"warning"
			)
			self:_refreshPanel()
		end
		return result
	end
	self.stats.surveys += 1
	deps.haptics:pulse(0.4, 0.12)
	local data = result.data
	if deps.round.round and data then
		deps.round.round.survey = data.survey
	end
	if data and data.player then
		deps.round.player = data.player
		deps.round.playerChanged:Fire(data.player)
	end
	self:_playScan(data)
	return result
end

-- The listening beat: the drill drops onto the chosen tile, the gears spin and the seismograph
-- scribbles for `survey.sequenceSeconds`, then the lamp for the answer lights and Molly reacts.
-- The panel shows LISTENING... and then the answer; nothing here can outlive the panel.
function MollyController._playScan(self: MollyController, data: any)
	local deps = self._deps
	local selection = self._selection
	local reading = if data and type(data.reading) == "table" then data.reading else data
	if not selection or not reading then
		self:_announce(reading)
		return
	end
	self.stats.scans += 1
	selection.scanning = true
	self:_refreshSelectionVisuals()
	local reduced = deps.accessibility:motionSettings().reducedMotion
	local seconds = if reduced then 0.4 else (deps.config.survey.sequenceSeconds or 2)
	local started = os.clock()
	deps.audio:play(Tokens.sound.uiConfirm)
	local hum = deps.audio:play(Tokens.sound.vacMotor, { at = self._station and self._station:FindFirstChild("MachineHousing") :: any })
	selection.trove:add(function()
		if hum then
			hum:Stop()
		end
	end)
	self._gesture = { name = "crank", t = 0, duration = seconds }
	selection.trove:add(RunService.Heartbeat:Connect(function()
		if not selection.scanning then
			return
		end
		local u = math.clamp((os.clock() - started) / math.max(0.01, seconds), 0, 1)
		self._gearSpeed = 7 * math.min(1, u * 3)
		if self._drill then
			self._drill.descend = math.sin(u * math.pi) * 0.9
		end
		self._seismoLevel = 0.35 + math.random() * 0.25
		self._gaugeLevel = 0.3 + math.sin(os.clock() * 9) * 0.25
		for _, lamp in pairs(self._lamps) do
			lamp.level = 0.25 + math.sin(os.clock() * 6 + lamp.part.Position.X) * 0.2
		end
	end))
	task.delay(seconds, function()
		if self._selection ~= selection then
			return
		end
		selection.scanning = false
		selection.result = reading
		if hum then
			hum:Stop()
			hum = nil
		end
		self._gearSpeed = 1.5
		self._seismoLevel = 0
		if self._drill then
			self._drill.descend = 0
		end
		local signal = tostring(reading.signal)
		for key, lamp in pairs(self._lamps) do
			lamp.level = if key == signal then 1 else 0
		end
		if signal == "strong" then
			self._gaugeLevel = 1
			self._hop = 1.2
			self._gesture = { name = "cheer", t = 0, duration = 1.4 }
			deps.audio:play(Tokens.sound.eggChime)
			deps.haptics:pulse(0.8, 0.2)
		elseif signal == "weak" then
			self._gaugeLevel = 0.4
			self._gesture = { name = "ear", t = 0.4, duration = 2.4 }
			deps.audio:play(Tokens.sound.stationChime)
		else
			self._gaugeLevel = 0
			self._gesture = { name = "headshake", t = 0, duration = 1.2 }
			deps.audio:play(Tokens.sound.uiCancel)
		end
		sayOn(self._rig, tostring(reading.text))
		self:_refreshSelectionVisuals()
		self:_applyResult()
		self:_banner(reading)
	end)
end

-- The party's banner and toast for a reading (the payer reads the answer on the panel as well).
function MollyController._banner(self: MollyController, reading: any)
	local deps = self._deps
	local stage = deps.hud.stage
	if not stage or not reading then
		return
	end
	self.stats.banners += 1
	local motion = deps.accessibility:motionSettings()
	local signal = tostring(reading.signal)
	local words = (NestSurvey.WORDS :: any)[signal] or NestSurvey.WORDS.none
	local label = Instance.new("TextLabel")
	label.Name = "SFE_SurveyBanner"
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.fromScale(0.5, 0.16)
	label.Size = UDim2.new(0.9, 0, 0, 64)
	label.BackgroundTransparency = 1
	label.Font = Tokens.typography.display.font
	label.TextSize = Tokens.typography.display.size - 2
	label.TextColor3 = if signal == "none" then Color3.fromRGB(200, 214, 236) else Tokens.color.goldLight
	label.TextStrokeTransparency = 0.2
	label.TextStrokeColor3 = Tokens.color.outline
	label.Text = string.format("MOLLY SURVEYED %s: %s", tostring(reading.name or NestSurvey.name(tostring(reading.region))), words.title)
	label.TextTransparency = 1
	label.ZIndex = Tokens.zIndex.toast + 2
	label.Parent = stage
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(780, 64)
	constraint.Parent = label
	local scale = Instance.new("UIScale")
	scale.Scale = 0.8
	scale.Parent = label
	TweenService:Create(label, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeOut), { TextTransparency = 0 }):Play()
	TweenService:Create(scale, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeBack), { Scale = 1 }):Play()
	if signal == "strong" then
		Confetti.burst(stage, {
			origin = UDim2.fromScale(0.5, 0.2),
			count = 16,
			spread = 180,
			motion = motion,
			tier = deps.quality and deps.quality:tier() or nil,
			zIndex = Tokens.zIndex.toast + 3,
		})
	end
	deps.hud.toasts:push(words.text, if signal == "none" then "info" else "success", 4)
	task.delay(2.0, function()
		if label.Parent then
			local out = TweenService:Create(
				label,
				TweenInfo.new(Motion.duration("quick", motion)),
				{ TextTransparency = 1, TextStrokeTransparency = 1 }
			)
			out:Play()
			out.Completed:Once(function()
				label:Destroy()
			end)
		end
	end)
	self._trove:add(label)
end

function MollyController._announce(self: MollyController, reading: any)
	self:_banner(reading)
	self:_applyResult()
end

function MollyController._onCompleted(self: MollyController, payload: any)
	local me = Players.LocalPlayer and Players.LocalPlayer.UserId
	local round = self._deps.round.round
	if round and payload.survey and round.roundId == payload.roundId then
		round.survey = payload.survey
	end
	self._remoteSelection = nil
	local selection = self._selection
	if payload.byUserId == me and (self._pending or (selection and (selection.scanning or selection.result))) then
		return -- the payer's own panel reads it out
	end
	-- Another member paid: the price moved on, so an open panel here shows the new state.
	if selection and not selection.scanning and not selection.result then
		local info = self:_surveyInfo()
		if info.nextCost then
			sayOn(
				self._rig,
				string.format(
					"%s paid for that one. The next crate is %d feathers.",
					tostring(payload.byName or "A forager"),
					info.nextCost
				)
			)
		else
			sayOn(self._rig, NestSurvey.LINES.used)
		end
		self:_refreshSelectionVisuals()
	end
	self._deps.audio:play(Tokens.sound.stationChime)
	self:_announce(payload)
end

-- Another member's live pick: the tile and the drill follow it for anyone not picking themselves.
function MollyController._onRemoteSelection(self: MollyController, payload: any)
	local round = self._deps.round.round
	if not round or round.roundId ~= payload.roundId then
		return
	end
	local info = self:_surveyInfo()
	if (info.usesLeft or 0) <= 0 then
		return
	end
	local region = if NestSurvey.isRegion(payload.region) then payload.region else nil
	self._remoteSelection = region
	if self._selection then
		return
	end
	if not region then
		self:_applyResult() -- the pick was cleared: back to the readings on the map
		return
	end
	for r, tile in pairs(self._tiles) do
		local chosen = r == region
		tile.lift = if chosen then TILE_RAISE else 0
		if chosen then
			tile.part.Color = STRAW_HOVER
		end
	end
	if self._drill then
		local pos = self:_tilePosition(region :: string)
		self._drill.target = if pos then Vector3.new(pos.X, self._drill.headRest.Position.Y, pos.Z) else self._drill.headRest.Position
	end
end

function MollyController.cancel(self: MollyController)
	self:_endSelection("cancel")
end

function MollyController.status(self: MollyController): { [string]: any }
	local camera = workspace.CurrentCamera
	local station = self._station
	local board = station and station:FindFirstChild("ResultBoard")
	local gui = board and board:FindFirstChild("Gui")
	local status = gui and gui:FindFirstChild("Status")
	local highlighted = false
	for _, highlight in ipairs(self._highlights) do
		highlighted = highlighted or highlight.Enabled
	end
	local raised = {}
	local tiles = 0
	for region, tile in pairs(self._tiles) do
		tiles += 1
		if tile.lift > 0.05 then
			table.insert(raised, region)
		end
	end
	table.sort(raised)
	local motors = 0
	for _ in pairs(self._motors) do
		motors += 1
	end
	local selection = self._selection
	local lamps = {}
	for key, lamp in pairs(self._lamps) do
		lamps[key] = math.floor(lamp.level * 100) / 100
	end
	return {
		rig = self._rig ~= nil,
		station = self._station ~= nil,
		motors = motors,
		tiles = tiles,
		highlighted = highlighted,
		busy = self:isBusy(),
		selecting = selection ~= nil,
		selected = selection and selection.region or nil,
		canSurvey = selection and selection.canSurvey or false,
		scanning = selection and selection.scanning or false,
		result = selection and selection.result and selection.result.title or nil,
		usesLeft = self:_surveyInfo().usesLeft,
		raisedTiles = raised,
		drillDescend = self._drill and self._drill.descend or 0,
		gearSpeed = self._gearSpeed,
		gauge = self._gaugeLevel,
		lamps = lamps,
		boardStatus = if status and status:IsA("TextLabel") then status.Text else nil,
		gesture = self._gesture and self._gesture.name or nil,
		remoteSelection = self._remoteSelection,
		cameraType = tostring(camera and camera.CameraType),
		stats = table.clone(self.stats),
	}
end

function MollyController.destroy(self: MollyController)
	self:_endSelection("destroy")
	if self._bound then
		self._bound:destroy()
		self._bound = nil
	end
	self._trove:destroy()
end

return MollyController
