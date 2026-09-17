--!strict
-- Molly the Mole on the client. Owns everything the player sees of her and her machine: the
-- nameplate, the outline while her prompt is in reach, the idle (looking between the pile and the
-- map, goggles, notes, tapping tiles, the crank, a drill test, an ear to the table, greeting who
-- walks up), the map's selection (mouse hover and click, touch, gamepad and keyboard) for each of
-- the round's three narrowing surveys - a region, then a patch inside it on a zoomed map of nine
-- small tiles laid over the chosen region, then the pin with nothing to choose - the live pick
-- relayed to the party, the trade request, the full survey sequence after a committed trade, and
-- the readings on the map and the board from the round snapshot.
--
-- The rig arrives anchored; limbs are freed locally and the Motor6D C0s driven from here. Every
-- resource a mode takes (input, cursor, camera, props) is returned by one trove with a watchdog.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local AssetManifest = require(Shared.Design.AssetManifest)
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
local WATCHDOG_GRACE = 4
local STRAW = Color3.fromRGB(226, 196, 132)
local STRAW_LIT = Color3.fromRGB(255, 226, 150)
local STRAW_HOVER = Color3.fromRGB(240, 214, 150)
local STRAW_DIM = Color3.fromRGB(168, 150, 118) -- the eight regions not being subdivided
local NONE_TINT = Color3.fromRGB(170, 176, 190)
local WEAK_TINT = Color3.fromRGB(240, 190, 110)
local STRONG_TINT = Color3.fromRGB(255, 214, 96)
local NEAR_TINT = Color3.fromRGB(248, 222, 176)
local BLUE_GREY = Color3.fromRGB(90, 110, 140)
local RED = Color3.fromRGB(196, 52, 44)
local PAPER = Color3.fromRGB(246, 236, 212)
local INK = Color3.fromRGB(60, 44, 32)
local PIN_DROP_SECONDS = 0.3

local function tintFor(signal: string?): Color3
	if signal == "strong" or signal == "pin" then
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
	"Tile_A1",
	"Tile_C3",
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
	"SubTile_1",
	"SubTile_9",
	"PinMarker",
}

type Pivoted = { part: BasePart, rest: CFrame, pivot: Vector3, axis: Vector3 }
type SpinGroup = { rest: CFrame, pieces: { { part: BasePart, rel: CFrame } } }
-- The zoomed map: which region the nine patch tiles sit on, and which patch is chosen / hovered /
-- already read (with its signal). nil region parks the patches under the plinth.
type SubGrid = { region: string?, chosen: number?, hovered: number?, signal: string? }
-- The pin on the map: the region tile it stands on and where inside it (0..1 along x and z).
type PinAt = { region: string, fx: number, fz: number }
type Selection = {
	trove: Trove.Trove,
	tier: string, -- "region" | "subcell" | "pin"
	baseRegion: string?, -- tiers 2 and 3: the region the first reading measured
	region: string?,
	sub: number?,
	hovered: string?,
	hoveredSub: number?,
	sent: string?, -- the last relayed pick, as "B2" / "B2-5"
	panel: any,
	canSurvey: boolean,
	baseline: any?,
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
		_subTiles: { [number]: { part: BasePart, label: TextLabel?, color: Color3 } },
		_subGrid: SubGrid,
		_pin: { model: Model, post: BasePart, head: BasePart, light: PointLight?, parkCF: CFrame }?,
		_pinAt: PinAt?,
		_pinDropAt: number,
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
		_sequence: { trove: Trove.Trove, done: boolean, committed: boolean, data: any, panel: any? }?,
		_pending: boolean,
		_remoteSelection: { region: string?, sub: number? }?,
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
			sequences: number,
			skips: number,
			banners: number,
			boardUpdates: number,
			restored: number,
			feathersFlown: number,
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
		_subTiles = {},
		_subGrid = { region = nil, chosen = nil, hovered = nil, signal = nil },
		_pin = nil,
		_pinAt = nil,
		_pinDropAt = 0,
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
		_sequence = nil,
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
			sequences = 0,
			skips = 0,
			banners = 0,
			boardUpdates = 0,
			restored = 0,
			feathersFlown = 0,
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
			if self._sequence then
				self:_finishSequence("phase")
			end
		end
		self:_applyResult()
	end))
	local player = Players.LocalPlayer
	if player then
		self._trove:add(player.CharacterAdded:Connect(function()
			self:_endSelection("respawn")
			if self._sequence then
				self:_finishSequence("respawn")
			end
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
	-- The zoomed map's nine patch tiles and the pin, parked under the plinth until used.
	self._subTiles = {}
	for _, sub in ipairs(NestSurvey.SUBS) do
		local subTile = station:FindFirstChild("SubTile_" .. sub)
		if subTile and subTile:IsA("BasePart") then
			local gui = subTile:FindFirstChild("Gui")
			local sheet = gui and gui:FindFirstChild("Sheet")
			local id = sheet and sheet:FindFirstChild("Id")
			self._subTiles[sub] = { part = subTile, label = if id and id:IsA("TextLabel") then id else nil, color = subTile.Color }
		end
	end
	self._subGrid = { region = nil, chosen = nil, hovered = nil, signal = nil }
	self._pin = nil
	self._pinAt = nil
	local pinModel = station:FindFirstChild("PinMarker")
	local pinPost = pinModel and pinModel:FindFirstChild("Post")
	local pinHead = pinModel and pinModel:FindFirstChild("Head")
	if pinModel and pinModel:IsA("Model") and pinPost and pinPost:IsA("BasePart") and pinHead and pinHead:IsA("BasePart") then
		local light = pinHead:FindFirstChild("Light")
		self._pin = {
			model = pinModel,
			post = pinPost,
			head = pinHead,
			light = if light and light:IsA("PointLight") then light else nil,
			parkCF = pinPost.CFrame,
		}
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
	-- The drill: bridge along world Z, head along world X; rest over B2.
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
		self._subTiles = {}
		self._subGrid = { region = nil, chosen = nil, hovered = nil, signal = nil }
		self._pin = nil
		self._pinAt = nil
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

-- Where a patch tile sits on a region tile: thirds of the tile, at the tile's current height.
function MollyController._subTilePosition(self: MollyController, region: string, sub: number): Vector3?
	local tile = self._tiles[region]
	if not tile then
		return nil
	end
	local row, col = NestSurvey.subRowCol(sub)
	local pitch = tile.part.Size.X / 3
	local p = tile.part.Position
	return Vector3.new(p.X + (col - 2) * pitch, p.Y + tile.part.Size.Y / 2 + 0.06, p.Z + (row - 2) * pitch)
end

-- Where the pin stands: a fraction across a region tile, above the patch tiles.
function MollyController._pinPosition(self: MollyController, at: PinAt): Vector3?
	local tile = self._tiles[at.region]
	if not tile then
		return nil
	end
	local p = tile.part.Position
	return Vector3.new(p.X + (at.fx - 0.5) * tile.part.Size.X, p.Y + tile.part.Size.Y / 2 + 0.1, p.Z + (at.fz - 0.5) * tile.part.Size.Z)
end

-- The round's survey as the snapshot projects it, or the fresh shape before any scan.
function MollyController._surveyInfo(self: MollyController): { [string]: any }
	local round = self._deps.round.round
	local survey = round and round.phase ~= "Returning" and round.survey or nil
	if survey and survey.readings then
		return survey
	end
	return NestSurvey.project(self._deps.config, nil)
end

-- Lays the patch tiles over a region (or parks them). `chosen` is tinted by `signal` when given.
function MollyController._setSubGrid(self: MollyController, grid: SubGrid)
	self._subGrid = grid
	self:_placeSubTiles()
end

function MollyController._placeSubTiles(self: MollyController)
	local grid = self._subGrid
	local region = grid.region
	local tile = region and self._tiles[region]
	for sub, entry in pairs(self._subTiles) do
		if not (region and tile) then
			entry.part.Transparency = 1
			entry.part.CFrame = CFrame.new(self._mapCentre + Vector3.new(0, -1.2, 0))
			if entry.label then
				entry.label.TextTransparency = 1
			end
			continue
		end
		local pos = self:_subTilePosition(region :: string, sub)
		if pos then
			entry.part.CFrame = CFrame.new(pos + Vector3.new(0, if sub == grid.hovered then 0.03 else 0, 0))
		end
		entry.part.Transparency = 0
		if entry.label then
			entry.label.TextTransparency = 0
		end
		if sub == grid.chosen then
			entry.part.Color = if grid.signal then tintFor(grid.signal) else STRAW_LIT
		elseif sub == grid.hovered then
			entry.part.Color = STRAW_HOVER
		else
			entry.part.Color = entry.color
		end
	end
end

-- Stands the pin on the map (or parks it). The drop animation runs from `_pinDropAt`.
function MollyController._placePin(self: MollyController, now: number)
	local pin = self._pin
	if not pin then
		return
	end
	local at = self._pinAt
	local pos = at and self:_pinPosition(at)
	if not pos then
		pin.post.CFrame = pin.parkCF
		pin.head.CFrame = pin.parkCF + Vector3.new(0, 0.3, 0)
		pin.post.Transparency = 1
		pin.head.Transparency = 1
		if pin.light then
			pin.light.Brightness = 0
		end
		return
	end
	local reduced = self._deps.accessibility:motionSettings().reducedMotion
	local drop = if reduced then 0 else math.max(0, 1 - (now - self._pinDropAt) / PIN_DROP_SECONDS)
	local lift = drop * drop * 1.2
	local base = (pos :: Vector3) + Vector3.new(0, lift, 0)
	pin.post.CFrame = CFrame.new(base + Vector3.new(0, pin.post.Size.Y / 2, 0))
	pin.head.CFrame = CFrame.new(base + Vector3.new(0, pin.post.Size.Y + pin.head.Size.Y / 2 - 0.04, 0))
	pin.post.Transparency = 0
	pin.head.Transparency = 0
	if pin.light then
		pin.light.Brightness = if reduced then 1.2 else 1.2 + 0.8 * (0.5 + 0.5 * math.sin(now * 4))
	end
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
		if nearestHead and not self._selection and not self._sequence then
			targetYaw, targetPitch = lookAngles(root, head, nearestHead.Position)
		end
	end
	-- Gestures.
	local gesture = self._gesture
	if not gesture and not self._sequence and os.clock() >= self._nextGesture then
		local pick = pickGesture()
		gesture = { name = pick.name, t = 0, duration = pick.duration, region = NestSurvey.REGIONS[math.random(1, 9)] }
		self._gesture = gesture
		self.stats.gestures += 1
	end
	local rPitch, rRoll, rElbowPitch = -0.55, 0.12, -0.6 -- hands resting on the bench edge
	local lPitch, lRoll, lElbowPitch = -0.5, -0.12, -0.55
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
			local tilePos = self:_tilePosition(gesture.region or "B2")
			if tilePos and not look then
				targetYaw, targetPitch = lookAngles(root, head, tilePos)
			end
			rPitch = -0.55 - 0.95 * blend
			rElbowPitch = -0.6 + 0.2 * blend
			rRoll = 0.1 + 0.35 * blend
			local tile = self._tiles[gesture.region or ""]
			if tile and phase > 0.4 and phase < 0.7 and not self._selection and not self._sequence then
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
			if self._drill and not self._selection and not self._sequence then
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
-- Machine: tiles, drill, gears, gauge, lamps, seismograph. Levels are set by the modes; this
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
		if not self._selection and not self._sequence and tile.lift > 0 and tile.lift < TILE_RAISE then
			tile.lift = math.max(0, tile.lift - dt * 0.4) -- an idle tap settles back
		end
	end
	-- The patch tiles ride their region tile; the pin stands on its cell.
	if self._subGrid.region then
		self:_placeSubTiles()
	end
	if self._pinAt then
		self:_placePin(os.clock())
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
		local tremble = if self._sequence and not reduced then math.sin(t * 23) * 0.04 else 0
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
-- The result, from the round snapshot: tiles, stamp, board, lamps at rest.

-- The pin's place on a region tile, from the pin reading's cell.
function MollyController._pinAtFor(self: MollyController, reading: any): PinAt?
	if not (reading and reading.tier == 3 and type(reading.cellX) == "number" and type(reading.cellZ) == "number") then
		return nil
	end
	local pile = self._deps.config.pile
	local fx, fz = NestSurvey.fractionInRegion(pile.gridWidth, pile.gridDepth, reading.cellX, reading.cellZ)
	return { region = reading.region, fx = fx, fz = fz }
end

-- One line of the board's list: "1. REGION B2: WEAK SIGNAL", "3. PINNED AT B2-5".
local function readingLine(reading: any): string
	if reading.tier == 3 then
		return string.format("%d. PINNED AT %s", reading.tier, tostring(reading.id))
	elseif reading.tier == 2 then
		return string.format("%d. PATCH %s: %s", reading.tier, tostring(reading.id), tostring(reading.title))
	end
	return string.format("%d. REGION %s: %s", reading.tier, tostring(reading.id or reading.region), tostring(reading.title))
end

function MollyController._applyResult(self: MollyController)
	local station = self._station
	if not station then
		return
	end
	local survey = self:_surveyInfo()
	local readings = survey.readings or {}
	local first, second, third = readings[1], readings[2], readings[3]
	local latest = readings[#readings]
	-- Tiles, patches, pin, stamps.
	if not self._sequence then
		for region, tile in pairs(self._tiles) do
			local chosen = first and first.region == region
			tile.lift = if chosen then TILE_RAISE else 0
			tile.part.Color = if chosen then tintFor(first.signal) elseif second then STRAW_DIM else tile.color
		end
		self:_setSubGrid(
			if second
				then { region = first.region, chosen = second.sub, hovered = nil, signal = second.signal }
				else { region = nil, chosen = nil, hovered = nil, signal = nil }
		)
		local pinAt = self:_pinAtFor(third)
		if pinAt and not self._pinAt then
			self._pinDropAt = os.clock() -- a late joiner still sees it drop once
		end
		self._pinAt = pinAt
		self:_placePin(os.clock())
		for tier = 1, 3 do
			local reading = readings[tier]
			local existing = station:FindFirstChild("SFE_SurveyStamp" .. tier)
			if reading and not existing then
				self:_placeStamp(reading)
			elseif not reading and existing then
				existing:Destroy()
			end
		end
		self:_setRing(if first then first.region else nil)
		local lampKey = if latest then (if latest.signal == "pin" then "strong" else latest.signal) else nil
		for key, lamp in pairs(self._lamps) do
			lamp.level = if lampKey == key then 0.6 else 0
		end
		self._gaugeLevel = if latest then (if lampKey == "strong" then 0.95 elseif lampKey == "weak" then 0.35 else 0) else 0.05
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
	local statusText = if not first
		then "NOT YET RUN"
		elseif survey.nextCost then string.format("%d OF %d SURVEYS - NEXT %d FEATHERS", survey.count, survey.max, survey.nextCost)
		else string.format("ALL %d SURVEYS USED", survey.max)
	if status and status:IsA("TextLabel") then
		if status.Text ~= statusText then
			self.stats.boardUpdates += 1
		end
		status.Text = statusText
		status.TextColor3 = if first then INK else Color3.fromRGB(140, 120, 100)
	end
	for tier = 1, 3 do
		local line = gui:FindFirstChild("Reading" .. tier)
		local reading = readings[tier]
		if line and line:IsA("TextLabel") then
			line.Visible = reading ~= nil
			if reading then
				line.Text = readingLine(reading)
				line.TextColor3 = inkFor(reading.signal)
			end
		end
	end
	if grid then
		local adjacent = if first and first.signal == "weak" then NestSurvey.adjacent(first.region) else {}
		local nearSubs = if second and second.signal == "weak" then NestSurvey.adjacentSubs(second.sub) else {}
		local pinAt = self:_pinAtFor(third)
		for _, region in ipairs(NestSurvey.REGIONS) do
			local cell = grid:FindFirstChild("Cell_" .. region)
			if cell and cell:IsA("Frame") then
				local mark = cell:FindFirstChild("Mark")
				local edge = cell:FindFirstChild("Edge")
				local isChosen = first ~= nil and first.region == region
				local isNear = table.find(adjacent, region) ~= nil
				cell.BackgroundColor3 = if isChosen then tintFor(first.signal) elseif isNear then NEAR_TINT else STRAW
				if mark and mark:IsA("TextLabel") then
					mark.Visible = (isChosen or isNear) and not (isChosen and second)
					mark.Text = if isChosen then first.short :: string elseif isNear then "?" else ""
					mark.TextColor3 = if isChosen then inkFor(first.signal) else RED
				end
				if edge and edge:IsA("UIStroke") then
					edge.Thickness = if isChosen then 5 elseif isNear then 3 else 2
					edge.Color = if isChosen then inkFor(first.signal) elseif isNear then WEAK_TINT else INK
					edge.Transparency = if isChosen or isNear then 0 else 0.4
				end
				for i = 1, 2 do
					local cross = cell:FindFirstChild("Cross" .. i)
					if cross and cross:IsA("Frame") then
						cross.Visible = isChosen and first.signal == "none" and not second
					end
				end
				-- The second reading's patches live inside the first reading's cell.
				local showSubs = isChosen and second ~= nil
				for _, sub in ipairs(NestSurvey.SUBS) do
					local patch = cell:FindFirstChild("Sub_" .. sub)
					if patch and patch:IsA("Frame") then
						patch.Visible = showSubs
						if showSubs then
							local isSub = second.sub == sub
							local isNearSub = table.find(nearSubs, sub) ~= nil
							patch.BackgroundColor3 = if isSub then tintFor(second.signal) elseif isNearSub then NEAR_TINT else STRAW
							patch.BackgroundTransparency = if isSub then 0 elseif isNearSub then 0.2 else 0.35
							local patchEdge = patch:FindFirstChild("Edge")
							if patchEdge and patchEdge:IsA("UIStroke") then
								patchEdge.Thickness = if isSub then 3 else 1
								patchEdge.Color = if isSub then inkFor(second.signal) else INK
								patchEdge.Transparency = if isSub then 0 else 0.5
							end
						end
					end
				end
				local pinDot = cell:FindFirstChild("Pin")
				if pinDot and pinDot:IsA("Frame") then
					local showPin = pinAt ~= nil and pinAt.region == region
					pinDot.Visible = showPin
					if showPin then
						pinDot.Position = UDim2.fromScale((pinAt :: PinAt).fx, (pinAt :: PinAt).fz)
					end
				end
			end
		end
	end
end

-- The permanent card for a reading: a big one on the region tile, a small one beside the patch,
-- a tag beside the pin. Named by tier so the list survives a resync and clears with the round.
function MollyController._placeStamp(self: MollyController, reading: any): BasePart?
	local station = self._station
	local tile = self._tiles[reading.region]
	if not (station and tile) then
		return nil
	end
	local tier = reading.tier
	local topY = tile.part.Position.Y + tile.part.Size.Y / 2 + (TILE_RAISE - tile.lift)
	local at: Vector3
	local size: Vector3
	local textSize: number
	if tier == 1 then
		at = Vector3.new(tile.part.Position.X, topY + 0.12, tile.part.Position.Z)
		size = Vector3.new(1.0, 0.04, 0.6)
		textSize = 34
	elseif tier == 2 then
		local pos = self:_subTilePosition(reading.region, reading.sub or 5) or tile.part.Position
		at = Vector3.new(pos.X, topY + 0.2, pos.Z)
		size = Vector3.new(0.42, 0.02, 0.24)
		textSize = 18
	else
		local pinAt = self:_pinAtFor(reading)
		local pos = if pinAt then self:_pinPosition(pinAt) else nil
		local base = pos or tile.part.Position
		at = Vector3.new(base.X + 0.22, topY + 0.24, base.Z + 0.14)
		size = Vector3.new(0.36, 0.02, 0.2)
		textSize = 18
	end
	local card = Instance.new("Part")
	card.Name = "SFE_SurveyStamp" .. tier
	card.Anchored = true
	card.CanCollide = false
	card.CanQuery = false
	card.CanTouch = false
	card.Size = size
	card.Color = PAPER
	card.Material = Enum.Material.SmoothPlastic
	card.CFrame = CFrame.new(at) * CFrame.Angles(0, math.rad(-8 + tier * 3), 0)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 120
	gui.Parent = card
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 1)
	text.Font = Enum.Font.FredokaOne
	text.TextSize = textSize
	text.TextColor3 = inkFor(reading.signal)
	text.Text = ((NestSurvey.WORDS :: any)[reading.signal] or NestSurvey.WORDS.none).short
	text.Rotation = -6
	text.Parent = gui
	card.Parent = station
	return card
end

-- ----------------------------------------------------------------------------------------------
-- Interaction and region selection

function MollyController.isBusy(self: MollyController): boolean
	return self._selection ~= nil or self._sequence ~= nil or self._pending
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
	local carried = player and player.carriedStandard or 0
	local info = self:_surveyInfo()
	local used = (info.usesLeft or 0) <= 0
	local exposed = phase == "EggRevealed"
	local active = phase == "Searching"
	local first = info.readings and info.readings[1]
	local line = NestSurvey.lineFor(deps.config, {
		active = active,
		exposed = exposed,
		count = info.count or 0,
		carriedStandard = carried,
		region = first and first.region or nil,
	})
	self.stats.opens += 1
	if not active or exposed or used then
		deps.audio:play(Tokens.sound.uiTap)
		sayOn(self._rig, line)
		self.stats.refused += 1
		return false
	end
	deps.audio:play(Tokens.sound.uiOpen)
	return self:_beginSelection(line)
end

function MollyController._selectionState(self: MollyController): SurveyPanel.State
	local deps = self._deps
	local selection = self._selection
	local player = deps.round.player
	local carried = player and player.carriedStandard or 0
	local info = self:_surveyInfo()
	local tier = selection and selection.tier or info.nextTier or "region"
	local cost = info.nextCost or 0
	local step = (info.count or 0) + 1
	local max = info.max or NestSurvey.maxSurveys(deps.config)
	-- The target: a region, a patch of the base region, or nothing for the pin.
	local target: string? = nil
	if tier == "region" then
		target = selection and selection.region or nil
	elseif tier == "subcell" then
		local base = selection and selection.baseRegion
		local sub = selection and selection.sub
		target = if base and sub then NestSurvey.id(base, sub) else nil
	end
	local affordable = info.nextCost ~= nil and carried >= cost
	local canSurvey = affordable and deps.round:phase() == "Searching" and (tier == "pin" or target ~= nil)
	if selection then
		selection.canSurvey = canSurvey
	end
	local mode = deps.input:mode()
	local words = (NestSurvey.TIER_WORDS :: any)[tier] or NestSurvey.TIER_WORDS.region
	local stepLine = string.format("SURVEY %d OF %d - %d FEATHERS", step, max, cost)
	local hint = if mode == "gamepad" then "D-PAD TO CHOOSE" elseif mode == "touch" then "TAP A TILE" else "CLICK A TILE"
	local caption = if not affordable
		then string.format("BRING %d NORMAL FEATHERS  -  %s", cost, stepLine)
		elseif tier == "pin" then stepLine .. "  -  NO CHOICE: MOLLY PINS THE NEST"
		elseif target then stepLine .. "  -  " .. NestSurvey.describe(
			(selection and selection.baseRegion) or (target :: string),
			selection and selection.sub
		)
		else stepLine .. "  -  " .. hint
	local title: string
	local primary: string
	if tier == "pin" then
		title = words.pick
		primary = string.format("%s - %d FEATHERS", words.scan, cost)
	elseif target then
		title = string.format("%s %s?", words.scan, target)
		primary = string.format("%s %s - %d FEATHERS", words.scan, target, cost)
	else
		title = string.format(words.pick, selection and selection.baseRegion or "")
		primary = "PICK " .. string.upper(words.hint)
	end
	return {
		title = title,
		caption = caption,
		carried = carried,
		cost = cost,
		usesLeft = info.usesLeft,
		usesMax = max,
		primary = primary,
		primaryEnabled = canSurvey,
		back = true,
		skip = false,
		tone = "plain",
	}
end

-- Frames the map, frees the cursor, and reads the player's pick until they survey or cancel.
function MollyController._beginSelection(self: MollyController, _line: string): boolean
	local deps = self._deps
	local station, rig = self._station, self._rig
	local camera = workspace.CurrentCamera
	local player = Players.LocalPlayer
	if not (station and rig and camera and player) then
		return false
	end
	local info = self:_surveyInfo()
	local tier = info.nextTier
	if not tier then
		return false
	end
	local first = info.readings and info.readings[1]
	local selection: Selection = {
		trove = Trove.new(),
		tier = tier,
		baseRegion = if tier ~= "region" and first then first.region else nil,
		region = nil,
		sub = nil,
		hovered = nil,
		hoveredSub = nil,
		sent = nil,
		panel = nil,
		canSurvey = false,
		baseline = nil,
	}
	if tier ~= "region" and not selection.baseRegion then
		return false -- a snapshot without the first reading cannot be zoomed
	end
	self._selection = selection
	local motion = deps.accessibility:motionSettings()
	local reduced = motion.reducedMotion
	deps.input:setSuspended(true)
	deps.modals:setExternalUnlock(true)
	local hudGui = deps.hud.gui
	local hudWasEnabled = hudGui.Enabled
	hudGui.Enabled = false -- the map is the screen; nothing else competes with it
	selection.trove:add(function()
		if not self._sequence then
			hudGui.Enabled = hudWasEnabled
		end
		deps.modals:setExternalUnlock(false)
		deps.input:setSuspended(deps.modals:isBlocking())
	end)
	-- Camera: from the players' side, a little high, with Molly and the machine on the left of the
	-- map, the way the bench is meant to be read.
	local anchor = station.PrimaryPart or station:FindFirstChild("MollyAnchor")
	local base = if anchor and anchor:IsA("BasePart") then anchor.CFrame else rig:GetPivot()
	local mapCentre = self._mapCentre
	local focus = mapCentre + base.RightVector * 1.3 + Vector3.new(0, 1.0, 0)
	local eye = focus + base.LookVector * 9.4 + Vector3.new(0, 4.6, 0)
	if tier == "subcell" then
		-- Zoomed: the chosen region fills the view, its nine patches readable, the rest dimmed.
		local basePos = self:_tilePosition(selection.baseRegion :: string) or mapCentre
		focus = basePos + Vector3.new(0, 0.2, 0)
		eye = focus + base.LookVector * 3.2 + Vector3.new(0, 2.7, 0)
	end
	local baseline = { type = camera.CameraType, cframe = camera.CFrame }
	camera.CameraType = Enum.CameraType.Scriptable
	TweenService:Create(camera, TweenInfo.new(if reduced then 0.05 else 0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = CFrame.lookAt(eye, focus),
	}):Play()
	selection.trove:add(function()
		-- Only hand the camera back if the sequence is not taking over from here.
		if self._sequence then
			return
		end
		self:_restoreCamera(baseline)
	end)
	selection.baseline = baseline
	-- Panel.
	local panel = SurveyPanel.create(
		player:WaitForChild("PlayerGui"),
		{ audio = deps.audio, accessibility = deps.accessibility, config = deps.config },
		{
			onPrimary = function()
				self:_confirmSurvey()
			end,
			onBack = function()
				self:_endSelection("cancel")
			end,
			onSkip = function() end,
		}
	)
	selection.panel = panel
	selection.trove:add(panel.destroy)
	panel.setState(self:_selectionState())
	selection.trove:add(deps.round.playerChanged:Connect(function()
		if self._selection == selection then
			panel.setState(self:_selectionState())
		end
	end))
	-- Pointing: the tile (or patch tile, when zoomed) under the cursor or the last touch; clicks
	-- pick it. Returns a region for tier 1, a patch number for tier 2, nothing for the pin.
	local tileParts = {}
	if tier == "region" then
		for _, tile in pairs(self._tiles) do
			table.insert(tileParts, tile.part)
		end
	elseif tier == "subcell" then
		for _, entry in pairs(self._subTiles) do
			table.insert(tileParts, entry.part)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = tileParts
	local function tileAt(screen: Vector2): (string?, number?)
		if #tileParts == 0 then
			return nil, nil
		end
		local ray = camera:ViewportPointToRay(screen.X, screen.Y)
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 60, params)
		if not hit then
			return nil, nil
		end
		local region = hit.Instance:GetAttribute("SFE_Region")
		local sub = hit.Instance:GetAttribute("SFE_Sub")
		return if type(region) == "string" then region else nil, if type(sub) == "number" then sub else nil
	end
	-- Hover only counts while the pointer is actually moving: a D-pad or keyboard pick must not be
	-- overruled by whatever tile happens to sit under a parked cursor.
	local lastPointer = UserInputService:GetMouseLocation()
	local pointerMovedAt = 0
	selection.trove:add(RunService.RenderStepped:Connect(function()
		if deps.input:mode() ~= "mouse" then
			return
		end
		local location = UserInputService:GetMouseLocation()
		if (location - lastPointer).Magnitude > 1 then
			lastPointer = location
			pointerMovedAt = os.clock()
		end
		local region: string?, sub: number? = nil, nil
		if os.clock() - pointerMovedAt < 1.5 then
			region, sub = tileAt(location)
		end
		if region ~= selection.hovered or sub ~= selection.hoveredSub then
			selection.hovered = region
			selection.hoveredSub = sub
			self:_refreshSelectionVisuals()
		end
	end))
	selection.trove:add(UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			local region, sub = tileAt(UserInputService:GetMouseLocation())
			if region or sub then
				self:select(region, sub)
			end
		elseif input.UserInputType == Enum.UserInputType.Touch then
			local region, sub = tileAt(Vector2.new(input.Position.X, input.Position.Y))
			if region or sub then
				self:select(region, sub)
			end
		elseif input.UserInputType == Enum.UserInputType.Keyboard then
			local key = input.KeyCode
			if key == Enum.KeyCode.Up or key == Enum.KeyCode.W then
				self:navigate(-1, 0)
			elseif key == Enum.KeyCode.Down or key == Enum.KeyCode.S then
				self:navigate(1, 0)
			elseif key == Enum.KeyCode.Left or key == Enum.KeyCode.A then
				self:navigate(0, -1)
			elseif key == Enum.KeyCode.Right or key == Enum.KeyCode.D then
				self:navigate(0, 1)
			elseif key == Enum.KeyCode.Return then
				self:_confirmSurvey()
			elseif key == Enum.KeyCode.Escape then
				self:_endSelection("cancel")
			end
		elseif input.UserInputType == Enum.UserInputType.Gamepad1 then
			local key = input.KeyCode
			if key == Enum.KeyCode.DPadUp then
				self:navigate(-1, 0)
			elseif key == Enum.KeyCode.DPadDown then
				self:navigate(1, 0)
			elseif key == Enum.KeyCode.DPadLeft then
				self:navigate(0, -1)
			elseif key == Enum.KeyCode.DPadRight then
				self:navigate(0, 1)
			elseif key == Enum.KeyCode.ButtonA then
				self:_confirmSurvey()
			elseif key == Enum.KeyCode.ButtonB then
				self:_endSelection("cancel")
			end
		end
	end))
	-- Thumbstick steps, one per flick.
	local stickArmed = true
	selection.trove:add(UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Gamepad1 or input.KeyCode ~= Enum.KeyCode.Thumbstick1 then
			return
		end
		local p = input.Position
		if p.Magnitude < 0.35 then
			stickArmed = true
			return
		end
		if not stickArmed then
			return
		end
		stickArmed = false
		if math.abs(p.X) > math.abs(p.Y) then
			self:navigate(0, if p.X > 0 then 1 else -1)
		else
			self:navigate(if p.Y > 0 then -1 else 1, 0)
		end
	end))
	-- Molly says her piece over her head and watches the map while a player picks.
	local carriedNow = deps.round.player and deps.round.player.carriedStandard or 0
	sayOn(
		rig,
		NestSurvey.lineFor(deps.config, {
			active = true,
			exposed = false,
			count = info.count or 0,
			carriedStandard = carriedNow,
			region = selection.baseRegion,
		})
	)
	self._look = { yaw = 0.3, pitch = -0.6, until_ = math.huge }
	selection.trove:add(function()
		self._look = nil
		self._remoteSelection = nil
		for _, tile in pairs(self._tiles) do
			tile.part.Color = tile.color
		end
		self:_applyResult()
		if self._drill and not self._sequence then
			self._drill.target = self._drill.headRest.Position
			self._drill.descend = 0
		end
	end)
	if deps.input:mode() ~= "mouse" then
		if tier == "region" then
			self:select("B2")
		elseif tier == "subcell" then
			self:select(nil, 5)
		end
	end
	self:_refreshSelectionVisuals()
	return true
end

-- The pick itself, from any input path: a region for the first survey, a patch of the base region
-- for the second. The pin takes no pick. The live pick is relayed to the party once per change.
function MollyController.select(self: MollyController, region: string?, sub: number?): boolean
	local selection = self._selection
	if not selection then
		return false
	end
	local changed = false
	if selection.tier == "region" then
		if not NestSurvey.isRegion(region) then
			return false
		end
		changed = selection.region ~= region
		selection.region = region
	elseif selection.tier == "subcell" then
		if not NestSurvey.isSub(sub) then
			return false
		end
		changed = selection.sub ~= sub
		selection.sub = sub
		selection.region = selection.baseRegion
	else
		return false
	end
	if changed then
		self.stats.selections += 1
		self._deps.audio:play(Tokens.sound.uiSelect)
		self._deps.haptics:pulse(0.15, 0.04)
	end
	self:_refreshSelectionVisuals()
	local id = NestSurvey.id(selection.region :: string, selection.sub)
	if selection.sent ~= id then
		selection.sent = id
		local token = self._deps.round:sessionToken()
		local sendRegion, sendSub = selection.region, selection.sub
		if token then
			task.spawn(function()
				self._deps.net:request("SurveySelect", { sessionToken = token, region = sendRegion, sub = sendSub })
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
	if selection.tier == "region" then
		return self:select(NestSurvey.step(selection.region or "B2", dRow, dCol))
	elseif selection.tier == "subcell" then
		return self:select(nil, NestSurvey.stepSub(selection.sub or 5, dRow, dCol))
	end
	return false
end

-- Tiles, patches, drill and Molly's gaze follow the hover and the pick.
function MollyController._refreshSelectionVisuals(self: MollyController)
	local selection = self._selection
	if not selection then
		return
	end
	local focusPos: Vector3? = nil
	if selection.tier == "region" then
		for region, tile in pairs(self._tiles) do
			if region == selection.region then
				tile.lift = TILE_RAISE
				tile.part.Color = STRAW_LIT
			elseif region == selection.hovered then
				tile.lift = TILE_HOVER
				tile.part.Color = STRAW_HOVER
			else
				tile.lift = 0
				tile.part.Color = tile.color
			end
		end
		self:_setSubGrid({ region = nil, chosen = nil, hovered = nil, signal = nil })
		self:_setRing(selection.region)
		local focus = selection.hovered or selection.region
		focusPos = if focus then self:_tilePosition(focus) else nil
	else
		-- Zoomed (tier 2) or pinning (tier 3): the base region stays up and lit, the other eight
		-- sit dimmed, and the nine patches lie on the base tile.
		local base = selection.baseRegion :: string
		for region, tile in pairs(self._tiles) do
			tile.lift = if region == base then TILE_RAISE else 0
			tile.part.Color = if region == base then STRAW_LIT else STRAW_DIM
		end
		local info = self:_surveyInfo()
		local second = info.readings and info.readings[2]
		if selection.tier == "subcell" then
			self:_setSubGrid({ region = base, chosen = selection.sub, hovered = selection.hoveredSub, signal = nil })
			local focusSub = selection.hoveredSub or selection.sub
			focusPos = if focusSub then self:_subTilePosition(base, focusSub) else self:_tilePosition(base)
		else
			self:_setSubGrid({ region = base, chosen = second and second.sub, hovered = nil, signal = second and second.signal })
			focusPos = self:_tilePosition(base)
		end
		self:_setRing(base)
	end
	if focusPos then
		local pos = focusPos :: Vector3
		if self._drill then
			self._drill.target = Vector3.new(pos.X, self._drill.headRest.Position.Y, pos.Z)
			self._drill.descend = 0
		end
		local rig = self._rig
		local root = rig and rig:FindFirstChild("HumanoidRootPart")
		local head = rig and rig:FindFirstChild("Head")
		if root and root:IsA("BasePart") and head and head:IsA("BasePart") then
			local yaw, pitch = lookAngles(root, head, pos)
			self._look = { yaw = yaw, pitch = pitch, until_ = math.huge }
		end
	end
	if selection.panel then
		selection.panel.setState(self:_selectionState())
	end
end

function MollyController._endSelection(self: MollyController, reason: string)
	local selection = self._selection
	if not selection then
		return
	end
	self._selection = nil
	if reason == "cancel" then
		self.stats.cancels += 1
		local token = self._deps.round:sessionToken()
		if token and selection.sent then
			task.spawn(function()
				self._deps.net:request("SurveySelect", { sessionToken = token })
			end)
		end
	end
	selection.trove:destroy()
end

function MollyController._restoreCamera(self: MollyController, baseline: { type: Enum.CameraType, cframe: CFrame })
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local reduced = self._deps.accessibility:motionSettings().reducedMotion
	local back = TweenService:Create(
		camera,
		TweenInfo.new(if reduced then 0.05 else 0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{ CFrame = baseline.cframe }
	)
	local released = false
	local function release()
		if released then
			return
		end
		released = true
		camera.CameraType = baseline.type
		self.stats.restored += 1
	end
	back.Completed:Once(release)
	back:Play()
	task.delay(1.2, release)
end

-- The SCAN / PIN button is the decision; the sign already said how many surveys are left.
function MollyController._confirmSurvey(self: MollyController)
	local deps = self._deps
	local selection = self._selection
	if not selection or not selection.canSurvey or self._pending then
		deps.audio:play(Tokens.sound.uiError)
		return
	end
	if selection.tier == "pin" then
		self:survey(nil, nil)
	elseif selection.tier == "subcell" then
		self:survey(selection.baseRegion, selection.sub)
	else
		self:survey(selection.region, nil)
	end
end

-- The request. Returns the envelope; a success hands the screen from the selection to the sequence.
function MollyController.survey(self: MollyController, region: string?, sub: number?): any
	local deps = self._deps
	local token = deps.round:sessionToken()
	if not token then
		return { ok = false, code = "invalid_state", message = "no_session" }
	end
	if self._sequence or self._pending then
		self.stats.refused += 1
		return { ok = false, code = "invalid_state", message = "busy" }
	end
	self._pending = true
	local result = deps.net:request("SurveyRequest", { sessionToken = token, region = region, sub = sub })
	if not result.ok then
		self._pending = false
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
			local first = info.readings and info.readings[1]
			deps.hud.toasts:push(
				if message == "insufficient"
					then string.format("You need %d normal feathers for the next survey crate", info.nextCost or 0)
					elseif message == "wrong_region" then string.format(
						"Pick a patch inside %s",
						tostring(first and first.region or "the surveyed region")
					)
					elseif result.code == "out_of_range" then "Stand at Molly's bench"
					elseif result.code == "rate_limited" then "One moment..."
					else "Survey unavailable",
				"warning"
			)
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
	task.defer(function()
		self:_runSequence(data)
		self._pending = false
	end)
	return result
end

-- ----------------------------------------------------------------------------------------------
-- The sequence

local function makeFeather(index: number): BasePart
	local template = AssetManifest.model("feather")
	local part: BasePart
	if template and template:IsA("BasePart") then
		part = template:Clone() :: BasePart
	else
		part = Instance.new("Part")
	end
	part.Name = "SFE_SurveyFeather" .. index
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = Color3.fromRGB(246, 236, 212):Lerp(Color3.fromRGB(226, 196, 132), (index % 4) / 4)
	part.Size = Vector3.new(0.4, 1.0, 0.1)
	return part
end

local function bezier(a: Vector3, b: Vector3, c: Vector3, t: number): Vector3
	local u = 1 - t
	return a * (u * u) + b * (2 * u * t) + c * (t * t)
end

-- A survey crate: planks, iron bands, a hinged lid, full of feathers.
local function makeCrate(): (Model, BasePart, BasePart)
	local crate = Instance.new("Model")
	crate.Name = "SFE_SurveyCrate"
	local function box(name: string, size: Vector3, offset: CFrame, color: Color3, material: Enum.Material): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Size = size
		p.CFrame = offset
		p.Color = color
		p.Material = material
		p.Parent = crate
		return p
	end
	local body = box("Body", Vector3.new(1.8, 1.2, 1.8), CFrame.new(0, 0.6, 0), Color3.fromRGB(150, 112, 66), Enum.Material.WoodPlanks)
	box("BandA", Vector3.new(1.86, 0.14, 1.86), CFrame.new(0, 0.25, 0), Color3.fromRGB(70, 72, 78), Enum.Material.Metal)
	box("BandB", Vector3.new(1.86, 0.14, 1.86), CFrame.new(0, 0.95, 0), Color3.fromRGB(70, 72, 78), Enum.Material.Metal)
	local fill = box("Fill", Vector3.new(1.6, 0.3, 1.6), CFrame.new(0, 1.15, 0), Color3.fromRGB(246, 236, 212), Enum.Material.Sand)
	fill.Name = "Fill"
	local lid = box("Lid", Vector3.new(1.86, 0.12, 1.86), CFrame.new(0, 1.26, 0), Color3.fromRGB(104, 74, 42), Enum.Material.WoodPlanks)
	crate.PrimaryPart = body
	return crate, body, lid
end

function MollyController._runSequence(self: MollyController, data: any)
	local deps = self._deps
	local rig, station = self._rig, self._station
	local camera = workspace.CurrentCamera
	local player = Players.LocalPlayer
	local region = tostring(data and data.region or "B2")
	local signal = tostring(data and data.signal or "none")
	local tier = tonumber(data and data.tier) or 1
	local sub: number? = if data and NestSurvey.isSub(data.sub) then data.sub else nil
	local id = tostring(data and data.id or NestSurvey.id(region, sub))
	local strength = if signal == "pin" then "strong" else signal -- the lamps read the pin as strong
	local reading = if data and type(data.reading) == "table" then data.reading else data
	if not (rig and station and camera and player) then
		self:_endSelection("sequence")
		self:_announce(data)
		return
	end
	local selection = self._selection
	local baseline = selection and (selection :: any).baseline or { type = camera.CameraType, cframe = camera.CFrame }
	local session = { trove = Trove.new(), done = false, committed = true, data = data, panel = nil }
	self._sequence = session
	self.stats.sequences += 1
	-- The selection hands over: its trove sees `_sequence` set and leaves the camera to us.
	self:_endSelection("sequence")
	local motion = deps.accessibility:motionSettings()
	local reduced = motion.reducedMotion
	local scale = math.max(0.5, (deps.config.survey.sequenceSeconds or 5) / 5)
	local function at(seconds: number): number
		return seconds * (if reduced then 0.55 else scale)
	end

	deps.input:setSuspended(true)
	deps.modals:setExternalUnlock(true)
	local hudGui = deps.hud.gui
	hudGui.Enabled = false
	session.trove:add(function()
		hudGui.Enabled = true
		deps.modals:setExternalUnlock(false)
		deps.input:setSuspended(deps.modals:isBlocking())
		self:_restoreCamera(baseline)
	end)
	-- Camera: the whole bench from the players' side, a little high, machine on the left.
	local anchor = station.PrimaryPart or station:FindFirstChild("MollyAnchor")
	local base = if anchor and anchor:IsA("BasePart") then anchor.CFrame else rig:GetPivot()
	local focus = base.Position + Vector3.new(0, 0.6, 0)
	local eye = (base * CFrame.new(1.2, 3.8, -10.2)).Position
	camera.CameraType = Enum.CameraType.Scriptable
	TweenService:Create(
		camera,
		TweenInfo.new(if reduced then 0.05 else 0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = CFrame.lookAt(eye, focus) }
	):Play()
	-- Panel with Molly's line and a skip (the trade is already committed).
	local panel = SurveyPanel.create(
		player:WaitForChild("PlayerGui"),
		{ audio = deps.audio, accessibility = deps.accessibility, config = deps.config },
		{
			onPrimary = function() end,
			onBack = function() end,
			onSkip = function()
				self.stats.skips += 1
				self:_finishSequence("skip")
			end,
		}
	)
	session.panel = panel
	session.trove:add(panel.destroy)
	local playerState = deps.round.player
	local infoNow = self:_surveyInfo()
	local paid = tonumber(data and data.cost) or 0
	panel.setState({
		title = if tier == 3 then "PINNING THE NEST..." else "SCANNING " .. id .. "...",
		caption = if tier == 3 then "MOLLY DROPS THE PIN ON THE EGG'S CELL" else NestSurvey.describe(region, sub),
		carried = playerState and playerState.carriedStandard or 0,
		cost = paid,
		usesLeft = infoNow.usesLeft,
		usesMax = infoNow.max,
		primary = nil,
		primaryEnabled = false,
		back = false,
		skip = true,
		tone = "plain",
	})
	session.trove:add(UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.Escape then
			self.stats.skips += 1
			self:_finishSequence("skip")
		end
	end))

	-- Props and levels we set here are undone by _applyResult at the end.
	local tile = self._tiles[region]
	local drill = self._drill
	-- Where the drill goes: the region tile, the patch tile, or the pin's exact spot.
	local pinAt = if tier == 3 then self:_pinAtFor(reading) else nil
	local targetPos: Vector3? = if tier == 1
		then self:_tilePosition(region)
		elseif tier == 2 then self:_subTilePosition(region, sub or 5)
		elseif pinAt then self:_pinPosition(pinAt)
		else self:_tilePosition(region)
	local second = infoNow.readings and infoNow.readings[2]
	local platform = station:FindFirstChild("CratePlatform")
	local spot = platform and platform:FindFirstChild("CrateSpot")
	local spotPos = if spot and spot:IsA("Attachment") then spot.WorldPosition else base.Position + base.RightVector * 5.6
	local funnel = station:FindFirstChild("HopperFunnel")
	local mouth = funnel and funnel:FindFirstChild("Mouth")
	local mouthPos = if mouth and mouth:IsA("Attachment") then mouth.WorldPosition else base.Position + Vector3.new(0, 5, 0)
	local whistle = station:FindFirstChild("Whistle")
	local steam = whistle and whistle:FindFirstChild("Steam")
	local function after(seconds: number, fn: () -> ())
		task.delay(seconds, function()
			if not session.done then
				fn()
			end
		end)
	end

	-- 1. The crate slides in from the player and lands on the platform.
	local crate, body, lid = makeCrate()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local from = if root and root:IsA("BasePart") then root.Position + Vector3.new(0, 0.5, 0) else spotPos + base.LookVector * -4
	crate:PivotTo(CFrame.new(from) * CFrame.Angles(0, math.rad(20), 0))
	crate.Parent = workspace
	session.trove:add(crate)
	local crateStart = os.clock()
	local slideSeconds = at(0.7)
	session.trove:add(RunService.RenderStepped:Connect(function()
		local u = math.min(1, (os.clock() - crateStart) / slideSeconds)
		if u < 1 then
			local eased = 1 - (1 - u) * (1 - u)
			local pos = bezier(from, (from + spotPos) / 2 + Vector3.new(0, 2.2, 0), spotPos - Vector3.new(0, 0.9, 0), eased)
			crate:PivotTo(CFrame.new(pos) * CFrame.Angles(0, math.rad(20 * (1 - eased)), 0))
		end
	end))
	deps.audio:play(Tokens.sound.throw)
	after(slideSeconds, function()
		crate:PivotTo(CFrame.new(spotPos - Vector3.new(0, 0.9, 0)))
		deps.audio:play(Tokens.sound.rewardLand)
		deps.haptics:pulse(0.3, 0.06)
	end)
	-- 2. Lid opens; feathers flow into the hopper.
	after(at(0.85), function()
		local hinge = lid.Position + Vector3.new(0, 0, 0.93)
		local lidTween = TweenService:Create(lid, TweenInfo.new(at(0.3), Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(hinge) * CFrame.Angles(math.rad(-110), 0, 0) * CFrame.new(0, 0, -0.93),
		})
		lidTween:Play()
		deps.audio:play(Tokens.sound.introPaper)
	end)
	local featherCount = if reduced then 6 else 14
	for i = 1, featherCount do
		after(at(1.1) + (i - 1) * at(0.06), function()
			local feather = makeFeather(i)
			feather.Parent = workspace
			session.trove:add(feather)
			self.stats.feathersFlown += 1
			local start = os.clock()
			local origin = body.Position + Vector3.new((i % 3 - 1) * 0.4, 0.9, (i % 2) * 0.3 - 0.15)
			local control = (origin + mouthPos) / 2 + Vector3.new(0, 2.6, 0)
			local flight = at(0.5)
			local conn: RBXScriptConnection
			conn = RunService.RenderStepped:Connect(function()
				local u = math.min(1, (os.clock() - start) / flight)
				local eased = 1 - (1 - u) * (1 - u)
				feather.CFrame = CFrame.new(bezier(origin, control, mouthPos, eased)) * CFrame.Angles(u * 6, u * 4, 0)
				if u >= 1 then
					conn:Disconnect()
					feather:Destroy()
				end
			end)
			session.trove:add(conn)
			if i % 4 == 1 then
				deps.audio:play(Tokens.sound.collectRelease, { pitchVariance = 0.1 })
			end
		end)
	end
	after(at(1.2), function()
		local fill = crate:FindFirstChild("Fill")
		if fill and fill:IsA("BasePart") then
			TweenService
				:Create(fill, TweenInfo.new(at(0.9)), { Size = Vector3.new(1.6, 0.05, 1.6), CFrame = fill.CFrame - Vector3.new(0, 0.3, 0) })
				:Play()
		end
	end)
	-- 3. The selected tile rises and lights; a zoomed survey shows its patches, the rest dimmed.
	after(at(1.0), function()
		for r, t in pairs(self._tiles) do
			t.lift = if r == region then TILE_RAISE + 0.08 else 0
			t.part.Color = if r == region then STRAW_LIT elseif tier > 1 then STRAW_DIM else t.color
		end
		if tier == 2 then
			self:_setSubGrid({ region = region, chosen = sub, hovered = nil, signal = nil })
		elseif tier == 3 then
			self:_setSubGrid({ region = region, chosen = second and second.sub, hovered = nil, signal = second and second.signal })
		else
			self:_setSubGrid({ region = nil, chosen = nil, hovered = nil, signal = nil })
		end
		self:_setRing(region)
	end)
	-- 4. Molly pulls the goggles down and hauls the lever; gears wind up.
	after(at(1.3), function()
		self._gesture = { name = "goggles", t = 0, duration = at(0.9) }
		self._look = { yaw = -0.7, pitch = -0.3, until_ = os.clock() + at(2) }
	end)
	after(at(1.9), function()
		local lever = self._pivots.lever
		local knob = self._pivots.leverKnob
		if lever then
			local start = os.clock()
			local conn: RBXScriptConnection
			conn = RunService.RenderStepped:Connect(function()
				local u = math.min(1, (os.clock() - start) / at(0.4))
				local angle = math.rad(56) * (1 - (1 - u) * (1 - u))
				applyPivot(lever, angle)
				if knob then
					applyPivot(knob, angle)
				end
				if u >= 1 then
					conn:Disconnect()
				end
			end)
			session.trove:add(conn)
		end
		deps.audio:play(Tokens.sound.uiConfirm)
		deps.haptics:pulse(0.35, 0.08)
		local motors = self._motors
		if motors.RightShoulder then
			self._gesture = { name = "crank", t = 0, duration = at(1.0) }
		end
	end)
	local hum: Sound? = nil
	after(at(2.1), function()
		hum = deps.audio:play(Tokens.sound.vacMotor, { at = station:FindFirstChild("MachineHousing") :: any })
		local start = os.clock()
		local conn: RBXScriptConnection
		conn = RunService.RenderStepped:Connect(function()
			local u = math.min(1, (os.clock() - start) / at(0.8))
			self._gearSpeed = 7 * u
			if u >= 1 then
				conn:Disconnect()
			end
		end)
		session.trove:add(conn)
	end)
	session.trove:add(function()
		if hum then
			hum:Stop()
		end
		self._gearSpeed = 0
	end)
	-- 5. The drill moves over the tile and descends; the table shakes; the machine searches.
	after(at(2.3), function()
		if drill and targetPos then
			drill.target = Vector3.new(targetPos.X, drill.headRest.Position.Y, targetPos.Z)
		end
	end)
	local searching = false
	after(at(2.9), function()
		searching = true
		deps.audio:play(Tokens.sound.rakeImpact)
		deps.camera:impulse(0.06)
		deps.haptics:pulse(0.5, 0.12)
		self._look = { yaw = 0.35, pitch = -0.7, until_ = os.clock() + at(2.2) }
	end)
	local searchStart = at(2.9)
	local searchEnd = at(4.3)
	local shakeBase: { [BasePart]: CFrame } = {}
	local plinth = station:FindFirstChild("MapPlinth")
	if plinth and plinth:IsA("BasePart") then
		shakeBase[plinth] = plinth.CFrame
	end
	session.trove:add(RunService.RenderStepped:Connect(function()
		if not searching then
			return
		end
		local now = os.clock() - crateStart
		local u = math.clamp((now - searchStart) / math.max(0.01, searchEnd - searchStart), 0, 1)
		if drill then
			drill.descend = math.sin(math.min(1, u * 1.2) * math.pi) * 0.9
		end
		if u < 1 then
			self._seismoLevel = 0.35 + math.random() * 0.25
			self._gaugeLevel = 0.3 + math.sin(now * 9) * 0.25 + math.random() * 0.1
			for _, lamp in pairs(self._lamps) do
				lamp.level = 0.25 + math.sin(now * 6 + lamp.part.Position.X) * 0.2
			end
			if not reduced then
				for p, rest in pairs(shakeBase) do
					p.CFrame = rest + Vector3.new((math.random() - 0.5) * 0.03, (math.random() - 0.5) * 0.02, (math.random() - 0.5) * 0.03)
				end
			end
		else
			for p, rest in pairs(shakeBase) do
				p.CFrame = rest
			end
		end
	end))
	session.trove:add(function()
		for p, rest in pairs(shakeBase) do
			p.CFrame = rest
		end
	end)
	-- 6. The reading.
	after(searchEnd, function()
		searching = false
		if drill then
			drill.descend = 0
		end
		self._gearSpeed = 2
		local words = (NestSurvey.WORDS :: any)[signal] or NestSurvey.WORDS.none
		for key, lamp in pairs(self._lamps) do
			lamp.level = if key == strength then 1 else 0
		end
		if strength == "none" then
			self._gaugeLevel = 0
			self._seismoLevel = 0
			self._gesture = { name = "headshake", t = 0, duration = at(1.2) }
			self._look = { yaw = 0.3, pitch = -0.4, until_ = os.clock() + at(1.4) }
			deps.audio:play(Tokens.sound.uiCancel)
		elseif strength == "weak" then
			self._gaugeLevel = 0.4
			self._seismoLevel = 0.18
			self._gesture = { name = "ear", t = 0.4, duration = at(2.4) }
			deps.audio:play(Tokens.sound.stationChime)
		else
			self._gaugeLevel = 1
			self._seismoLevel = 0.9
			self._hop = 1.2
			self._gesture = { name = "cheer", t = 0, duration = at(1.4) }
			if steam and steam:IsA("ParticleEmitter") and not reduced then
				steam.Enabled = true
				task.delay(at(0.9), function()
					steam.Enabled = false
				end)
			end
			deps.audio:play(Tokens.sound.fuseHiss, { at = whistle :: any })
			deps.audio:play(Tokens.sound.eggChime)
			deps.haptics:pulse(0.8, 0.2)
			deps.camera:impulse(0.05)
		end
		if tier == 1 and tile then
			tile.part.Color = tintFor(signal)
		elseif tier == 2 then
			self:_setSubGrid({ region = region, chosen = sub, hovered = nil, signal = signal })
		elseif tier == 3 and pinAt then
			-- The pin drops on the exact cell.
			self._pinAt = pinAt
			self._pinDropAt = os.clock()
			self:_placePin(os.clock())
		end
		local afterInfo = self:_surveyInfo()
		if session.panel then
			session.panel.setState({
				title = (if strength == "strong" then words.title .. "!" else words.title),
				caption = id .. "  -  " .. words.text,
				carried = deps.round.player and deps.round.player.carriedStandard or 0,
				cost = afterInfo.nextCost or paid,
				usesLeft = afterInfo.usesLeft,
				usesMax = afterInfo.max,
				primary = nil,
				primaryEnabled = false,
				back = false,
				skip = true,
				tone = if strength == "none" then "bad" else "good",
			})
		end
		sayOn(rig, words.text)
	end)
	-- 7. The stamp lands on the map and the board is written.
	after(searchEnd + at(0.6), function()
		local existing = station:FindFirstChild("SFE_SurveyStamp" .. tier)
		if existing then
			existing:Destroy()
		end
		local card = self:_placeStamp(reading)
		if card then
			local restCF = card.CFrame
			card.CFrame = restCF + Vector3.new(0, 1.4, 0)
			TweenService:Create(card, TweenInfo.new(at(0.18), Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = restCF }):Play()
		end
		deps.audio:play(Tokens.sound.rewardLand)
		deps.haptics:pulse(0.4, 0.06)
		self:_applyBoardOnly()
	end)
	-- 8. The party hears; then everything is handed back. About five and a half seconds in all.
	local finishAt = searchEnd + at(1.1)
	after(finishAt, function()
		self:_banner(data)
	end)
	task.delay(finishAt + 0.2, function()
		self:_finishSequence("complete")
	end)
	task.delay(finishAt + 0.2 + WATCHDOG_GRACE, function()
		if self._sequence == session then
			self:_finishSequence("watchdog")
		end
	end)
end

-- The board alone (the tiles are owned by the sequence until it ends).
function MollyController._applyBoardOnly(self: MollyController)
	local sequence = self._sequence
	self._sequence = nil
	self:_applyResult()
	self._sequence = sequence
	-- _applyResult reset the lamps/gauge/tiles to the rest display for a finished survey, which is
	-- exactly the state the sequence is converging on; the pulse below keeps the lamps alive.
	local latest = self:_surveyInfo().latest
	if latest then
		local lamp = self._lamps[if latest.signal == "pin" then "strong" else latest.signal]
		if lamp then
			lamp.level = 1
		end
	end
end

function MollyController._banner(self: MollyController, data: any)
	local deps = self._deps
	local stage = deps.hud.stage
	if not stage then
		return
	end
	self.stats.banners += 1
	local motion = deps.accessibility:motionSettings()
	local words = (NestSurvey.WORDS :: any)[tostring(data and data.signal or "none")] or NestSurvey.WORDS.none
	local label = Instance.new("TextLabel")
	label.Name = "SFE_SurveyBanner"
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.fromScale(0.5, 0.16)
	label.Size = UDim2.new(0.9, 0, 0, 64)
	label.BackgroundTransparency = 1
	label.Font = Tokens.typography.display.font
	label.TextSize = Tokens.typography.display.size - 2
	label.TextColor3 = if data and data.signal == "none" then Color3.fromRGB(200, 214, 236) else Tokens.color.goldLight
	label.TextStrokeTransparency = 0.2
	label.TextStrokeColor3 = Tokens.color.outline
	local id = tostring(data and (data.id or data.region) or "?")
	label.Text = if data and data.signal == "pin"
		then string.format("MOLLY PINNED THE NEST AT %s", id)
		else string.format("MOLLY SURVEYED %s: %s", id, words.title)
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
	if data and (data.signal == "strong" or data.signal == "pin") then
		Confetti.burst(stage, {
			origin = UDim2.fromScale(0.5, 0.2),
			count = 16,
			spread = 180,
			motion = motion,
			tier = deps.quality and deps.quality:tier() or nil,
			zIndex = Tokens.zIndex.toast + 3,
		})
	end
	deps.hud.toasts:push(words.text, if data and data.signal == "none" then "info" else "success", 4)
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

function MollyController._announce(self: MollyController, data: any)
	self:_banner(data)
	self:_applyResult()
end

function MollyController._onCompleted(self: MollyController, payload: any)
	local me = Players.LocalPlayer and Players.LocalPlayer.UserId
	local round = self._deps.round.round
	if round and payload.survey and round.roundId == payload.roundId then
		round.survey = payload.survey
	end
	self._remoteSelection = nil
	if payload.byUserId == me and (self._pending or self._sequence) then
		return -- the payer's own sequence reads it out
	end
	-- Another member paid: their pick is no longer a preview and the next survey is a different
	-- tier, so any map open here closes and shows the reading instead.
	if self._selection then
		self:_endSelection("surveyed")
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
	end
	self._deps.audio:play(Tokens.sound.stationChime)
	self:_announce(payload)
end

-- Another member's live pick: the tile (and patch, when zoomed) and the drill follow it for anyone
-- not picking themselves.
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
	local sub = if NestSurvey.isSub(payload.sub) then payload.sub else nil
	self._remoteSelection = if region then { region = region, sub = sub } else nil
	if self._selection or self._sequence then
		return
	end
	if not region then
		self:_applyResult() -- the pick was cleared: back to the readings on the map
		return
	end
	for r, tile in pairs(self._tiles) do
		local chosen = r == region
		tile.lift = if chosen then TILE_RAISE else 0
		tile.part.Color = if chosen then STRAW_HOVER elseif sub then STRAW_DIM else tile.color
	end
	if sub then
		local second = info.readings and info.readings[2]
		self:_setSubGrid({ region = region, chosen = second and second.sub, hovered = sub, signal = second and second.signal })
	end
	if self._drill then
		local pos = if sub then self:_subTilePosition(region :: string, sub :: number) else self:_tilePosition(region :: string)
		self._drill.target = if pos then Vector3.new(pos.X, self._drill.headRest.Position.Y, pos.Z) else self._drill.headRest.Position
	end
end

function MollyController._finishSequence(self: MollyController, reason: string)
	local session = self._sequence
	if not session then
		return
	end
	session.done = true
	self._sequence = nil
	self._look = nil
	self._gesture = nil
	session.trove:destroy()
	self:_applyResult()
	if self._drill then
		self._drill.target = self._drill.headRest.Position
		self._drill.descend = 0
	end
	local _ = reason
end

function MollyController.cancel(self: MollyController)
	self:_endSelection("cancel")
end

function MollyController.skip(self: MollyController)
	if self._sequence then
		self.stats.skips += 1
		self:_finishSequence("skip")
	end
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
	for region, tile in pairs(self._tiles) do
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
	return {
		rig = self._rig ~= nil,
		station = self._station ~= nil,
		motors = motors,
		tiles = (function()
			local n = 0
			for _ in pairs(self._tiles) do
				n += 1
			end
			return n
		end)(),
		highlighted = highlighted,
		busy = self:isBusy(),
		selecting = selection ~= nil,
		tier = selection and selection.tier or nil,
		baseRegion = selection and selection.baseRegion or nil,
		selected = selection and selection.region or nil,
		selectedSub = selection and selection.sub or nil,
		hovered = selection and selection.hovered or nil,
		hoveredSub = selection and selection.hoveredSub or nil,
		canSurvey = selection and selection.canSurvey or false,
		subGrid = self._subGrid.region,
		pin = self._pinAt ~= nil,
		usesLeft = self:_surveyInfo().usesLeft,
		sequence = self._sequence ~= nil,
		raisedTiles = raised,
		drillDescend = self._drill and self._drill.descend or 0,
		drillTarget = self._drill and tostring(self._drill.current) or nil,
		gearSpeed = self._gearSpeed,
		gauge = self._gaugeLevel,
		lamps = (function()
			local out = {}
			for key, lamp in pairs(self._lamps) do
				out[key] = math.floor(lamp.level * 100) / 100
			end
			return out
		end)(),
		boardStatus = if status and status:IsA("TextLabel") then status.Text else nil,
		stamp = station and station:FindFirstChild("SFE_SurveyStamp1") ~= nil or false,
		stamps = (function()
			local n = 0
			for tier = 1, 3 do
				if station and station:FindFirstChild("SFE_SurveyStamp" .. tier) then
					n += 1
				end
			end
			return n
		end)(),
		gesture = self._gesture and self._gesture.name or nil,
		remoteSelection = self._remoteSelection and NestSurvey.id(self._remoteSelection.region or "?", self._remoteSelection.sub) or nil,
		cameraType = tostring(camera and camera.CameraType),
		stats = table.clone(self.stats),
	}
end

function MollyController.destroy(self: MollyController)
	self:_endSelection("destroy")
	self:_finishSequence("destroy")
	if self._bound then
		self._bound:destroy()
		self._bound = nil
	end
	self._trove:destroy()
end

return MollyController
