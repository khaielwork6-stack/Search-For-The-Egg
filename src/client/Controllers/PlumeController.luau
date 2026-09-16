--!strict
-- Professor Plume on the client. Owns everything the player sees of him: the nameplate, the outline
-- while his prompt is in reach, the idle (writing, examining, adjusting his glasses, looking at
-- whoever walks up), the clue board's words, his conversation card, the trade request, and the
-- analysis sequence after a successful trade (feathers fly from the carried bundle into the prism,
-- the machine runs, Plume stamps a card, the clue is read out, the party is told).
--
-- The rig arrives from the server fully anchored. This controller unanchors the limbs locally and
-- drives the Motor6D C0s itself, so the pose is a local matter and the server never moves a thing.
-- Everything the sequence takes (input, camera, the cursor) is handed back through one trove with
-- a watchdog behind it, so no path - respawn, round end, a lost tween - leaves the player stuck.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local AssetManifest = require(Shared.Design.AssetManifest)
local Trove = require(Shared.Util.Trove)
local NestClues = require(Shared.Domain.NestClues)
local NpcPlate = require(script.Parent.Parent.UI.NpcPlate)
local PlumeCard = require(script.Parent.Parent.UI.PlumeCard)
local FrameKit = require(script.Parent.Parent.UI.Components.Frame)
local Depth = require(script.Parent.Parent.UI.Components.Depth)
local Confetti = require(script.Parent.Parent.UI.Components.Confetti)

local PlumeController = {}
PlumeController.__index = PlumeController

PlumeController.ARENA_NAME = "SFE_Chapter1"
PlumeController.MODEL_NAME = "ProfessorPlume"
PlumeController.STATION_NAME = "PlumeStation"
PlumeController.PROMPT_NAME = "SFE_PlumeAnalyze"
PlumeController.NPC_NAME = "Professor Plume"

local LOOK_RANGE = 16
local FEATHER_STAGGER = 0.14
local FEATHER_FLIGHT = 0.62
local CARD_HOLD = 2.8
local BANNER_HOLD = 2.0
local WATCHDOG_GRACE = 4
local PARCHMENT = Color3.fromRGB(246, 232, 196)
local STAMP = Color3.fromRGB(196, 52, 44)
local PAGE_BLUE = Color3.fromRGB(40, 104, 172)

export type PlumeController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_trove: Trove.Trove,
		_rig: Model?,
		_station: Model?,
		_bound: Trove.Trove?,
		_highlights: { Highlight },
		_motors: { [string]: { motor: Motor6D, base: CFrame } },
		_gesture: { name: string, t: number, duration: number }?,
		_nextGesture: number,
		_look: { yaw: number, pitch: number, until_: number }?,
		_yaw: number,
		_pitch: number,
		_sequence: { trove: Trove.Trove, done: boolean }?,
		_modalOpen: boolean,
		_card: { trove: Trove.Trove, handle: any, selected: string? }?,
		_pendingAnalyze: boolean,
		_deferredUnlock: any?,
		stats: {
			opens: number,
			refused: number,
			analyses: number,
			sequences: number,
			banners: number,
			boardUpdates: number,
			restored: number,
			feathersFlown: number,
		},
	},
	PlumeController
))

function PlumeController.new(deps: {
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
	dialogue: any,
	interaction: any,
}): PlumeController
	local self = setmetatable({
		_deps = deps,
		_trove = Trove.new(),
		_rig = nil,
		_station = nil,
		_bound = nil,
		_highlights = {},
		_motors = {},
		_gesture = nil,
		_nextGesture = os.clock() + 6,
		_look = nil,
		_yaw = 0,
		_pitch = 0,
		_sequence = nil,
		_modalOpen = false,
		_card = nil,
		_pendingAnalyze = false,
		_deferredUnlock = nil,
		stats = { opens = 0, refused = 0, analyses = 0, sequences = 0, banners = 0, boardUpdates = 0, restored = 0, feathersFlown = 0 },
	}, PlumeController)

	-- The prompt routes here from the InteractionController, which already refuses while a
	-- conversation owns the screen.
	self._trove:add(deps.interaction.plumeRequested:Connect(function()
		self:interact()
	end))
	self._trove:add(deps.net:on("ClueUnlocked", function(payload)
		self:_onUnlocked(payload)
	end))
	self._trove:add(deps.round.snapshot:Connect(function()
		self:_applyBoard()
	end))
	self._trove:add(deps.round.phaseChanged:Connect(function()
		if self._sequence and deps.round:phase() ~= "Searching" then
			self:_finishSequence("phase")
		end
		self:_applyBoard()
	end))
	local player = Players.LocalPlayer
	if player then
		self._trove:add(player.CharacterAdded:Connect(function()
			if self._sequence then
				self:_finishSequence("respawn")
			end
		end))
	end
	self._trove:add(ProximityPromptService.PromptShown:Connect(function(prompt)
		if prompt.Name == PlumeController.PROMPT_NAME then
			self:_setHighlighted(true)
			deps.audio:play(Tokens.sound.stationChime, { at = prompt.Parent :: any })
		end
	end))
	self._trove:add(ProximityPromptService.PromptHidden:Connect(function(prompt)
		if prompt.Name == PlumeController.PROMPT_NAME then
			self:_setHighlighted(false)
		end
	end))
	self:_watchArena()
	return self
end

-- Finds Plume and the station in the arena folder, now or when the server builds them.
function PlumeController._watchArena(self: PlumeController)
	local function tryBind(folder: Instance)
		local rig = folder:FindFirstChild(PlumeController.MODEL_NAME)
		local station = folder:FindFirstChild(PlumeController.STATION_NAME)
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
	local arena = workspace:FindFirstChild(PlumeController.ARENA_NAME)
	if arena then
		watchFolder(arena)
	end
	self._trove:add(workspace.ChildAdded:Connect(function(child)
		if child.Name == PlumeController.ARENA_NAME then
			task.defer(watchFolder, child)
		end
	end))
end

-- Replication delivers a Model before its children: the first look at Plume can find an empty rig.
-- Everything that reads his parts waits for the ones it needs, and parts that arrive after the
-- limbs were freed are freed as they land.
local RIG_PARTS = { "HumanoidRootPart", "Head", "UpperTorso", "RightUpperArm", "RightLowerArm", "LeftUpperArm", "LeftLowerArm" }
local RIG_MOTORS = {
	Neck = "Head",
	Waist = "UpperTorso",
	RightShoulder = "RightUpperArm",
	RightElbow = "RightLowerArm",
	LeftShoulder = "LeftUpperArm",
	LeftElbow = "LeftLowerArm",
}

function PlumeController._bind(self: PlumeController, rig: Model, station: Model)
	if self._bound then
		self._bound:destroy()
	end
	local bound = Trove.new()
	self._bound = bound
	self._rig = rig
	self._station = station
	self._highlights = {}
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
		station:WaitForChild("ClueBoard", 10)
		if alive and self._bound == bound then
			self:_bindReady(rig, station, bound)
		end
	end)
end

function PlumeController._bindReady(self: PlumeController, rig: Model, station: Model, bound: Trove.Trove)
	-- Nameplate over the hat.
	local root = rig:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local _, size = rig:GetBoundingBox()
		local plate = NpcPlate.build(root, PlumeController.NPC_NAME, "Nest forensics", size.Y * 0.5 + 0.9, { onTop = true })
		bound:add(plate.destroy)
	end
	-- Outlines for the prompt-in-range state.
	for _, model in ipairs({ rig, station }) do
		local highlight = Instance.new("Highlight")
		highlight.Name = "SFE_PlumeOutline"
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
	-- The idle: limbs free locally, joints driven from here. Anything that streams in later (a lens,
	-- a tuft) is freed on arrival, or it would hang in the air where the head used to be.
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
	end))
	bound:add(function()
		self._rig = nil
		self._station = nil
		self._motors = {}
	end)
	self:_applyBoard()
end

function PlumeController._setHighlighted(self: PlumeController, on: boolean)
	for _, highlight in ipairs(self._highlights) do
		highlight.Enabled = on
	end
end

-- One idle step. Head follows the nearest player in range, otherwise drifts between the notes and
-- the board; the right hand writes; every so often a hand comes up to the glasses or the head
-- drops to the magnifier. Reduced motion keeps only the slow head-turn.
function PlumeController._stepIdle(self: PlumeController, dt: number, t: number)
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
	-- Look target.
	local targetYaw, targetPitch = math.sin(t * 0.35) * 0.3 + 0.15, -0.28
	local look = self._look
	if look and os.clock() < look.until_ then
		targetYaw, targetPitch = look.yaw, look.pitch
	else
		self._look = nil
		local nearest, nearestDistance = nil, LOOK_RANGE
		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			local pHead = character and character:FindFirstChild("Head")
			if pHead and pHead:IsA("BasePart") then
				local distance = (pHead.Position - head.Position).Magnitude
				if distance < nearestDistance then
					nearest, nearestDistance = pHead, distance
				end
			end
		end
		if nearest then
			local localDir = root.CFrame:VectorToObjectSpace(nearest.Position - head.Position)
			local horizontal = math.sqrt(localDir.X * localDir.X + localDir.Z * localDir.Z)
			-- The rig faces -Z: yaw is measured from that.
			targetYaw = math.clamp(math.atan2(-localDir.X, -localDir.Z), -0.95, 0.95)
			targetPitch = math.clamp(math.atan2(localDir.Y, horizontal), -0.45, 0.4)
		end
	end
	local ease = math.min(1, dt * (if reduced then 3 else 6))
	self._yaw += (targetYaw - self._yaw) * ease
	self._pitch += (targetPitch - self._pitch) * ease
	neck.motor.C0 = neck.base * CFrame.fromEulerAnglesYXZ(self._pitch, self._yaw, 0)
	if reduced then
		return
	end
	-- Breathing.
	waist.motor.C0 = waist.base * CFrame.new(0, math.sin(t * 1.5) * 0.025, 0) * CFrame.Angles(math.sin(t * 1.5) * 0.012, 0, 0)
	-- Gestures.
	local gesture = self._gesture
	if not gesture and os.clock() >= self._nextGesture then
		local pick = if math.random() < 0.55 then "glasses" else "examine"
		gesture = { name = pick, t = 0, duration = if pick == "glasses" then 1.9 else 2.6 }
		self._gesture = gesture
	end
	local writePitch = -1.02 + math.sin(t * 2.1) * 0.05
	local writeRoll = 0.14 + math.sin(t * 5.7) * 0.02
	local elbowPitch = -0.95 + math.sin(t * 6.3) * 0.07
	local leftPitch, leftElbow = 0.05, -0.12
	if gesture then
		gesture.t += dt
		local phase = gesture.t / gesture.duration
		local blend = math.sin(math.clamp(phase, 0, 1) * math.pi) -- rises, holds, falls
		if gesture.name == "glasses" then
			-- Left hand up to the frames; the head tips a touch with it.
			leftPitch = -2.35 * blend
			leftElbow = -1.35 * blend
			self._look = { yaw = self._yaw, pitch = -0.1 * blend, until_ = os.clock() + dt * 2 }
		else
			-- Head down to the magnifier; the right hand lifts it.
			self._look = { yaw = 0.45, pitch = -0.6, until_ = os.clock() + dt * 2 }
			writePitch = -1.02 - 0.5 * blend
			elbowPitch = -0.95 - 0.35 * blend
		end
		if phase >= 1 then
			self._gesture = nil
			self._nextGesture = os.clock() + 7 + math.random() * 8
		end
	end
	rShoulder.motor.C0 = rShoulder.base * CFrame.Angles(writePitch, 0, writeRoll)
	rElbow.motor.C0 = rElbow.base * CFrame.Angles(elbowPitch, 0, 0)
	lShoulder.motor.C0 = lShoulder.base * CFrame.Angles(leftPitch, 0, -0.1)
	lElbow.motor.C0 = lElbow.base * CFrame.Angles(leftElbow, 0, 0)
end

-- The parchment board shows this party's clues. Written locally from the round snapshot, so
-- every member sees the same words and a server with two parties never crosses them.
function PlumeController._applyBoard(self: PlumeController)
	local station = self._station
	if not station then
		return
	end
	local board = station:FindFirstChild("ClueBoard")
	local gui = board and board:FindFirstChild("Gui")
	if not gui then
		return
	end
	local round = self._deps.round.round
	local clues = if round and round.phase ~= "Returning" then round.clues else nil
	local unlocked = clues and clues.unlocked or {}
	for _, category in ipairs(NestClues.CATEGORIES) do
		local rowName = if category == "direction" then "Direction" else "Depth"
		local row = gui:FindFirstChild(rowName)
		local value = row and row:FindFirstChild("Value")
		local stamp = row and row:FindFirstChild("Stamp")
		if value and value:IsA("TextLabel") and stamp and stamp:IsA("TextLabel") then
			local entry = unlocked[category]
			local text = if entry then tostring(entry.title) else "UNKNOWN"
			if value.Text ~= text then
				self.stats.boardUpdates += 1
			end
			value.Text = text
			value.TextColor3 = if entry then Color3.fromRGB(70, 46, 28) else Color3.fromRGB(150, 130, 100)
			stamp.Visible = entry ~= nil
		end
	end
end

function PlumeController.isBusy(self: PlumeController): boolean
	return self._sequence ~= nil or self._modalOpen or self._pendingAnalyze
end

-- Plume's short lines go over his head, never into a panel.
local function say(rig: Model?, line: string)
	local root = rig and rig:FindFirstChild("HumanoidRootPart")
	if root then
		NpcPlate.sayOn(root, line, 3.2)
	end
end

-- The prompt press. One card at a time; while the machine runs, nothing.
function PlumeController.interact(self: PlumeController): boolean
	local deps = self._deps
	if self:isBusy() then
		self.stats.refused += 1
		return false
	end
	local rig = self._rig
	local phase = deps.round:phase()
	if phase ~= "Searching" then
		if phase == "EggRevealed" then
			say(rig, NestClues.LINES.found)
		end
		self.stats.refused += 1
		return false
	end
	local round = deps.round.round
	local clues = round and round.clues
	local count = clues and clues.count or 0
	local carried = deps.round.player and deps.round.player.carriedRainbow or 0
	self.stats.opens += 1
	deps.audio:play(Tokens.sound.uiOpen)
	say(rig, NestClues.lineFor(deps.config, count, carried, false))
	return self:_openCard()
end

function PlumeController._cardState(self: PlumeController): PlumeCard.State
	local deps = self._deps
	local card = self._card
	local round = deps.round.round
	local clues = round and round.clues
	local count = clues and clues.count or 0
	local unlocked = clues and clues.unlocked or {}
	local cost = NestClues.nextCost(deps.config, count)
	local carried = deps.round.player and deps.round.player.carriedRainbow or 0
	local selected = card and card.selected or nil
	if selected and unlocked[selected] then
		selected = nil
	end
	if not selected then
		for _, category in ipairs(NestClues.CATEGORIES) do
			if not unlocked[category] then
				selected = category
				break
			end
		end
	end
	if card then
		card.selected = selected
	end
	return {
		carried = carried,
		cost = cost,
		unlocked = unlocked,
		selected = selected,
		canGet = cost ~= nil and selected ~= nil and carried >= cost and deps.round:phase() == "Searching",
	}
end

-- The card owns the screen while it is up: cursor free, gameplay input paused, HUD down.
function PlumeController._openCard(self: PlumeController): boolean
	local deps = self._deps
	local player = Players.LocalPlayer
	if not player or self._card then
		return false
	end
	local session = { trove = Trove.new(), handle = nil, selected = nil }
	self._card = session
	self._modalOpen = true
	deps.input:setSuspended(true)
	deps.modals:setExternalUnlock(true)
	local hudGui = deps.hud.gui
	local hudWasEnabled = hudGui.Enabled
	hudGui.Enabled = false
	session.trove:add(function()
		hudGui.Enabled = hudWasEnabled
		deps.modals:setExternalUnlock(false)
		deps.input:setSuspended(deps.modals:isBlocking())
		self._modalOpen = false
		if self._card == session then
			self._card = nil
		end
	end)
	local handle = PlumeCard.create(
		player:WaitForChild("PlayerGui"),
		{ audio = deps.audio, accessibility = deps.accessibility, config = deps.config },
		{
			onGetClue = function(category)
				self:analyze(category)
			end,
			onSelect = function(category)
				local state = self:_cardState()
				if state.unlocked[category] then
					return
				end
				deps.audio:play(Tokens.sound.uiSelect)
				session.selected = category
				if session.handle then
					session.handle.setState(self:_cardState())
				end
			end,
			onClose = function()
				self:_closeCard()
			end,
		}
	)
	session.handle = handle
	session.trove:add(handle.destroy)
	session.trove:add(deps.round.playerChanged:Connect(function()
		if session.handle then
			session.handle.setState(self:_cardState())
		end
	end))
	session.trove:add(deps.round.snapshot:Connect(function()
		if session.handle then
			session.handle.setState(self:_cardState())
		end
	end))
	handle.setState(self:_cardState())
	return true
end

function PlumeController._closeCard(self: PlumeController)
	local session = self._card
	if not session then
		return
	end
	self._card = nil
	session.trove:destroy()
end

-- The trade request. Returns the envelope; a success starts the sequence once the card closes.
function PlumeController.analyze(self: PlumeController, category: string): any
	local deps = self._deps
	local token = deps.round:sessionToken()
	if not token then
		return { ok = false, code = "invalid_state", message = "no_session" }
	end
	if self._sequence or self._pendingAnalyze then
		self.stats.refused += 1
		return { ok = false, code = "invalid_state", message = "busy" }
	end
	self._pendingAnalyze = true
	local result = deps.net:request("ClueAnalyze", { sessionToken = token, category = category })
	if not result.ok then
		self._pendingAnalyze = false
		deps.audio:play(Tokens.sound.uiError)
		local message = result.message
		local rig = self._rig
		if message == "egg_found" then
			say(rig, NestClues.LINES.found)
		else
			deps.hud.toasts:push(
				if message == "insufficient"
					then "Not enough Rainbow Feathers"
					elseif message == "already_analyzed" then "That clue is already on the board"
					elseif message == "limit" then "Plume has told you everything he can"
					elseif result.code == "out_of_range" then "Stand at Plume's bench"
					else "Analysis unavailable",
				"warning"
			)
		end
		return result
	end
	self.stats.analyses += 1
	deps.haptics:pulse(0.4, 0.12)
	local data = result.data
	-- The response carries the round's clue table; the Book, the board and the card read it from
	-- the round state, so it lands there now rather than with the next snapshot.
	if deps.round.round and data and data.clues then
		deps.round.round.clues = data.clues
	end
	-- The response carries the payer's projection with the feathers already gone; the HUD binds to
	-- playerChanged, so the bundle thins now, before the first feather has left it.
	if data and data.player then
		deps.round.player = data.player
		deps.round.playerChanged:Fire(data.player)
	end
	-- The card gives way to the sequence; nothing else may own the screen while the machine runs.
	self:_closeCard()
	-- `_pendingAnalyze` holds until the sequence has taken over, so the party event that lands in
	-- the frame between the response and the deferred start is kept for the sequence to read out.
	task.defer(function()
		self:_runSequence(data)
		self._pendingAnalyze = false
	end)
	return result
end

-- A rainbow feather for the flight, the same template the bundle and the pile use.
local function makeFlyingFeather(index: number): BasePart
	local template = AssetManifest.model("feather")
	local part: BasePart
	if template and template:IsA("BasePart") then
		part = template:Clone() :: BasePart
	else
		part = Instance.new("Part")
	end
	part.Name = "SFE_PlumeFeather" .. index
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromHSV((index * 0.17) % 1, 0.35, 1)
	part.Size = Vector3.new(0.5, 1.3, 0.12)
	local motes = Instance.new("ParticleEmitter")
	motes.Rate = 8
	motes.Lifetime = NumberRange.new(0.4, 0.8)
	motes.Speed = NumberRange.new(0.2, 0.5)
	motes.Size = NumberSequence.new(0.12, 0)
	motes.Transparency = NumberSequence.new(0.2, 1)
	motes.LightEmission = 0.9
	motes.Color = ColorSequence.new(Color3.fromRGB(255, 240, 255))
	motes.Parent = part
	return part
end

local function bezier(a: Vector3, b: Vector3, c: Vector3, t: number): Vector3
	local u = 1 - t
	return a * (u * u) + b * (2 * u * t) + c * (t * t)
end

-- The analysis sequence for the payer. Every resource it takes is returned by `session.trove`.
function PlumeController._runSequence(self: PlumeController, data: any)
	local deps = self._deps
	local rig, station = self._rig, self._station
	local camera = workspace.CurrentCamera
	local player = Players.LocalPlayer
	if not (rig and station and camera and player) then
		-- No world to stage it in: the clue still lands (the board and the Book read the snapshot).
		self:_announce(data)
		return
	end
	if self._sequence then
		self:_finishSequence("restart")
	end
	local session = { trove = Trove.new(), done = false }
	self._sequence = session
	self.stats.sequences += 1
	local motion = deps.accessibility:motionSettings()
	local reduced = motion.reducedMotion
	local cfg = deps.config
	local analyzeSeconds = if reduced then math.min(0.8, cfg.clues.analyzeSeconds) else cfg.clues.analyzeSeconds

	-- Controls and cursor.
	deps.input:setSuspended(true)
	deps.modals:setExternalUnlock(true)
	session.trove:add(function()
		deps.modals:setExternalUnlock(false)
		deps.input:setSuspended(deps.modals:isBlocking())
	end)

	-- Camera: a three-quarter shot of Plume and the bench from the players' side.
	local anchor = station.PrimaryPart or station:FindFirstChild("PlumeAnchor")
	local base = if anchor and anchor:IsA("BasePart") then anchor.CFrame else rig:GetPivot()
	local focus = base.Position + Vector3.new(0, 0.2, 0)
	local eye = (base * CFrame.new(4.6, 3.4, -8.8)).Position
	local baseline = { type = camera.CameraType, cframe = camera.CFrame }
	camera.CameraType = Enum.CameraType.Scriptable
	local inSeconds = if reduced then 0.05 else 0.5
	TweenService
		:Create(camera, TweenInfo.new(inSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = CFrame.lookAt(eye, focus) })
		:Play()
	session.trove:add(function()
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
		task.delay(1.2, release) -- Completed never fires on a cancelled tween; this is the floor
	end)

	-- The machine.
	local chamber = station:FindFirstChild("PrismChamber") :: BasePart?
	local core = chamber and chamber:FindFirstChild("PrismCore") :: Attachment?
	local intake = chamber and chamber:FindFirstChild("Intake") :: Attachment?
	local light = chamber and chamber:FindFirstChild("PrismLight") :: PointLight?
	local ring = station:FindFirstChild("Refractor") :: BasePart?
	local prismA = station:FindFirstChild("PrismHalfA") :: BasePart?
	local prismB = station:FindFirstChild("PrismHalfB") :: BasePart?
	local target = if core then core.WorldPosition else base.Position + Vector3.new(0, 4, 0)
	local mouth = if intake then intake.WorldPosition else target
	local ringBase = ring and ring.CFrame
	local lightBase = light and light.Brightness or 0
	local prismColor = prismA and prismA.Color
	session.trove:add(function()
		if ring and ringBase then
			ring.CFrame = ringBase
		end
		if light then
			light.Brightness = lightBase
			light.Color = Color3.fromRGB(236, 208, 255)
		end
		if prismA and prismColor then
			prismA.Color = prismColor
		end
		if prismB and prismColor then
			prismB.Color = prismColor
		end
	end)

	-- Feathers: one at a time from the carried bundle into the intake. The bag itself already
	-- shows the new count (the response carried the player projection), so these are the ones
	-- that left it.
	local count = math.max(1, tonumber(data and data.cost) or 1)
	local origin = deps.hud:carriedStackWorldPoint()
	if not origin then
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		origin = if root and root:IsA("BasePart") then root.Position + Vector3.new(0, 1.5, 0) else base.Position + Vector3.new(0, 3, -3)
	end
	local origin2 = origin :: Vector3
	local flightSeconds = if reduced then 0.2 else FEATHER_FLIGHT
	local stagger = if reduced then 0.05 else FEATHER_STAGGER
	local flying = 0
	for index = 1, count do
		task.delay((index - 1) * stagger, function()
			if session.done then
				return
			end
			local feather = makeFlyingFeather(index)
			feather.Parent = workspace
			session.trove:add(feather)
			flying += 1
			self.stats.feathersFlown += 1
			deps.audio:play(Tokens.sound.collectRainbow, { pitchVariance = 0.08 })
			local startAt = os.clock()
			local control = (origin2 + mouth) / 2 + Vector3.new(0, 2.5, 0)
			local conn: RBXScriptConnection
			conn = RunService.RenderStepped:Connect(function()
				local t = math.min(1, (os.clock() - startAt) / flightSeconds)
				local eased = 1 - (1 - t) * (1 - t)
				local position = bezier(origin2, control, if t < 0.85 then mouth else target, eased)
				feather.CFrame = CFrame.new(position) * CFrame.Angles(t * 9, t * 5, 0)
				feather.Size = Vector3.new(0.5, 1.3, 0.12) * (1 - 0.6 * math.max(0, t - 0.8) / 0.2)
				if t >= 1 then
					conn:Disconnect()
					feather:Destroy()
					flying -= 1
					if light then
						light.Brightness = math.min(3, light.Brightness + 0.5)
					end
				end
			end)
			session.trove:add(conn)
		end)
	end
	local featherPhase = (count - 1) * stagger + flightSeconds + 0.1

	-- Machine spin after the last feather is in.
	local spinStart = os.clock() + featherPhase
	local spinEnd = spinStart + analyzeSeconds
	local hum: Sound? = nil
	task.delay(featherPhase, function()
		if session.done then
			return
		end
		hum = deps.audio:play(Tokens.sound.stationHum, { at = chamber :: any })
		deps.haptics:pulse(0.25, 0.15)
		-- Plume watches the chamber while it works.
		self._look = { yaw = -0.5, pitch = -0.35, until_ = spinEnd + 0.6 }
	end)
	session.trove:add(RunService.RenderStepped:Connect(function()
		local now = os.clock()
		if now < spinStart then
			return
		end
		local u = math.min(1, (now - spinStart) / math.max(0.01, analyzeSeconds))
		local speed = math.sin(u * math.pi) * 14 -- winds up and down
		if ring and ringBase then
			ring.CFrame = ringBase * CFrame.Angles((now - spinStart) * speed, 0, 0)
		end
		local hue = (now * 0.6) % 1
		local rainbow = Color3.fromHSV(hue, 0.55, 1)
		if light then
			light.Brightness = 0.35 + 2.4 * math.sin(u * math.pi)
			light.Color = rainbow
		end
		if prismA and prismB then
			prismA.Color = rainbow
			prismB.Color = Color3.fromHSV((hue + 0.33) % 1, 0.55, 1)
		end
	end))
	session.trove:add(function()
		if hum then
			hum:Stop()
		end
	end)

	-- Plume examines the reading, then stamps a card on the bench.
	local stampAt = featherPhase + analyzeSeconds
	task.delay(stampAt, function()
		if session.done then
			return
		end
		self._look = { yaw = 0.25, pitch = -0.55, until_ = os.clock() + 1.4 }
		self._gesture = { name = "examine", t = 0.9, duration = 2.6 }
		deps.audio:play(Tokens.sound.introPaper)
		task.delay(0.45, function()
			if session.done then
				return
			end
			-- The card lands on the bench with a stamp on it.
			local benchTop = station:FindFirstChild("BenchTop") :: BasePart?
			if benchTop then
				local card = Instance.new("Part")
				card.Name = "SFE_ClueCard"
				card.Anchored = true
				card.CanCollide = false
				card.CanQuery = false
				card.Size = Vector3.new(1.0, 0.03, 1.3)
				card.Color = PARCHMENT
				card.Material = Enum.Material.Fabric
				card.CFrame = benchTop.CFrame * CFrame.new(-0.2, benchTop.Size.Y / 2 + 0.6, -0.6) * CFrame.Angles(0, math.rad(6), 0)
				card.Parent = workspace
				session.trove:add(card)
				local stamp = Instance.new("Part")
				stamp.Anchored = true
				stamp.CanCollide = false
				stamp.CanQuery = false
				stamp.Size = Vector3.new(0.6, 0.02, 0.28)
				stamp.Color = STAMP
				stamp.Material = Enum.Material.SmoothPlastic
				stamp.CFrame = card.CFrame * CFrame.new(0.05, 0.03, 0.25) * CFrame.Angles(0, math.rad(-10), 0)
				stamp.Parent = card
				TweenService:Create(card, TweenInfo.new(if reduced then 0.05 else 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
					CFrame = card.CFrame * CFrame.new(0, -0.58, 0),
				}):Play()
			end
			deps.audio:play(Tokens.sound.uiConfirm)
			deps.camera:impulse(0.08)
			deps.haptics:pulse(0.5, 0.08)
		end)
	end)

	-- The clue card on screen, then the party-wide banner, then everything is handed back.
	local revealAt = stampAt + 0.75
	task.delay(revealAt, function()
		if session.done then
			return
		end
		self:_showCard(session, data)
	end)
	local bannerAt = revealAt + CARD_HOLD
	task.delay(bannerAt, function()
		if session.done then
			return
		end
		self:_banner(data)
	end)
	task.delay(bannerAt + 0.6, function()
		self:_finishSequence("complete")
	end)
	-- The watchdog: whatever else happens, the player gets the screen back.
	task.delay(bannerAt + 0.6 + WATCHDOG_GRACE, function()
		if self._sequence == session then
			self:_finishSequence("watchdog")
		end
	end)
end

-- The parchment card with the stamped band.
function PlumeController._showCard(self: PlumeController, session: { trove: Trove.Trove, done: boolean }, data: any)
	local deps = self._deps
	local stage = deps.hud.stage
	if not stage then
		return
	end
	local motion = deps.accessibility:motionSettings()
	local z = Tokens.zIndex.toast + 3
	local card = Instance.new("Frame")
	card.Name = "SFE_ClueCard"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.42)
	card.Size = UDim2.fromOffset(380, 172)
	card.ZIndex = z
	Depth.panel(card, PARCHMENT, { radius = Tokens.radius.md })
	local scale = Instance.new("UIScale")
	scale.Scale = 0.7
	scale.Parent = card
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Tokens.spacing.md)
	pad.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
	pad.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	pad.PaddingBottom = UDim.new(0, Tokens.spacing.md)
	pad.Parent = card
	local label = FrameKit.text(card, "Category", tostring(NestClues.LABELS[data.category] or "CLUE"), "caption", {
		zIndex = z + 1,
		color = Tokens.color.inkMuted,
	})
	label.Position = UDim2.fromOffset(0, 0)
	local title = FrameKit.text(card, "Title", tostring(data.title), "display", { zIndex = z + 1, color = PAGE_BLUE })
	title.Position = UDim2.fromOffset(0, Tokens.typography.caption.size + Tokens.spacing.xs)
	title.Size = UDim2.new(1, 0, 0, Tokens.typography.display.size + 4)
	title.TextSize = Tokens.typography.display.size - 4
	local text = FrameKit.text(card, "Text", tostring(data.text), "body", { zIndex = z + 1, color = Tokens.color.inkStrong, wrap = true })
	text.Position =
		UDim2.fromOffset(0, Tokens.typography.caption.size + Tokens.spacing.xs + Tokens.typography.display.size + Tokens.spacing.sm)
	text.Size = UDim2.new(1, 0, 0, Tokens.typography.body.size * 3)
	text.TextYAlignment = Enum.TextYAlignment.Top
	local stamp = FrameKit.badge(card, "Stamp", "ANALYZED", STAMP, z + 2)
	stamp.AnchorPoint = Vector2.new(1, 0)
	stamp.Position = UDim2.fromScale(1, 0)
	stamp.Rotation = -8
	local stampScale = Instance.new("UIScale")
	stampScale.Scale = 2.2
	stampScale.Parent = stamp
	stamp.Visible = false
	card.Parent = stage
	session.trove:add(card)
	TweenService:Create(scale, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeBack), { Scale = 1 }):Play()
	task.delay(if motion.reducedMotion then 0.05 else 0.35, function()
		if session.done or not stamp.Parent then
			return
		end
		stamp.Visible = true
		deps.audio:play(Tokens.sound.rewardLand)
		TweenService:Create(stampScale, TweenInfo.new(Motion.duration("quick", motion), Tokens.motion.easeBack), { Scale = 1 }):Play()
	end)
end

-- The party-wide line across the top of the screen.
function PlumeController._banner(self: PlumeController, data: any)
	local deps = self._deps
	local stage = deps.hud.stage
	if not stage then
		return
	end
	self.stats.banners += 1
	local motion = deps.accessibility:motionSettings()
	local label = Instance.new("TextLabel")
	label.Name = "SFE_ClueBanner"
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.fromScale(0.5, 0.16)
	label.Size = UDim2.new(0.9, 0, 0, 64)
	label.BackgroundTransparency = 1
	label.Font = Tokens.typography.display.font
	label.TextSize = Tokens.typography.display.size - 2
	label.TextScaled = false
	label.TextColor3 = Tokens.color.goldLight
	label.TextStrokeTransparency = 0.2
	label.TextStrokeColor3 = Tokens.color.outline
	label.Text = "PROFESSOR PLUME DISCOVERED A CLUE!"
	label.TextTransparency = 1
	label.ZIndex = Tokens.zIndex.toast + 2
	label.Parent = stage
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(760, 64)
	constraint.Parent = label
	local scale = Instance.new("UIScale")
	scale.Scale = 0.8
	scale.Parent = label
	TweenService:Create(label, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeOut), { TextTransparency = 0 }):Play()
	TweenService:Create(scale, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeBack), { Scale = 1 }):Play()
	Confetti.burst(stage, {
		origin = UDim2.fromScale(0.5, 0.2),
		count = 18,
		spread = 200,
		motion = motion,
		tier = deps.quality and deps.quality:tier() or nil,
		zIndex = Tokens.zIndex.toast + 3,
	})
	deps.audio:play(Tokens.sound.eggChime)
	if data and data.text then
		deps.hud.toasts:push(tostring(data.text), "success", 4)
	end
	task.delay(BANNER_HOLD, function()
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

-- What a member who did not pay sees; and what the payer sees if the stage is missing.
function PlumeController._announce(self: PlumeController, data: any)
	self:_banner(data)
	self:_applyBoard()
end

function PlumeController._onUnlocked(self: PlumeController, payload: any)
	local me = Players.LocalPlayer and Players.LocalPlayer.UserId
	local round = self._deps.round.round
	if round and payload.clues and round.roundId == payload.roundId then
		round.clues = payload.clues
	end
	-- The payer's own sequence reads the clue out at its end; the event arrives before the
	-- response does, so it is held rather than shown twice.
	if payload.byUserId == me and (self._pendingAnalyze or self._sequence) then
		self._deferredUnlock = payload
		return
	end
	self._deps.audio:play(Tokens.sound.stationChime)
	self:_announce(payload)
end

function PlumeController._finishSequence(self: PlumeController, reason: string)
	local session = self._sequence
	if not session then
		return
	end
	session.done = true
	self._sequence = nil
	self._deferredUnlock = nil
	self._look = nil
	session.trove:destroy()
	self:_applyBoard()
	local _ = reason
end

-- Dismisses whatever Plume has up: the card, or the sequence.
function PlumeController.skip(self: PlumeController)
	self:_closeCard()
	self:_finishSequence("skip")
end

function PlumeController.status(self: PlumeController): { [string]: any }
	local camera = workspace.CurrentCamera
	local station = self._station
	local board = station and station:FindFirstChild("ClueBoard")
	local gui = board and board:FindFirstChild("Gui")
	local function rowText(name: string): string?
		local row = gui and gui:FindFirstChild(name)
		local value = row and row:FindFirstChild("Value")
		return if value and value:IsA("TextLabel") then value.Text else nil
	end
	local highlighted = false
	for _, highlight in ipairs(self._highlights) do
		highlighted = highlighted or highlight.Enabled
	end
	return {
		rig = self._rig ~= nil,
		station = self._station ~= nil,
		motors = (function()
			local n = 0
			for _ in pairs(self._motors) do
				n += 1
			end
			return n
		end)(),
		highlighted = highlighted,
		busy = self:isBusy(),
		sequence = self._sequence ~= nil,
		modalOpen = self._modalOpen,
		boardDirection = rowText("Direction"),
		boardDepth = rowText("Depth"),
		cameraType = tostring(camera and camera.CameraType),
		stats = table.clone(self.stats),
	}
end

function PlumeController.destroy(self: PlumeController)
	self:_closeCard()
	self:_finishSequence("destroy")
	if self._bound then
		self._bound:destroy()
		self._bound = nil
	end
	self._trove:destroy()
end

return PlumeController
