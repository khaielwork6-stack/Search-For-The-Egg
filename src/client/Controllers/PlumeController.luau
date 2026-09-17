--!strict
-- Professor Plume on the client. Owns everything the player sees of him: the nameplate, the outline
-- while his prompt is in reach, the idle (writing, examining, adjusting his glasses, looking at
-- whoever walks up), the loan board's rows, his conversation card, the loan request, and the
-- hand-over beat after a successful loan (Plume reaches out, the rod flies from his hand into the
-- player's, the viewmodel rises to meet it, the party is told).
--
-- The rig arrives from the server fully anchored. This controller unanchors the limbs locally and
-- drives the Motor6D C0s itself, so the pose is a local matter and the server never moves a thing.
-- Everything the hand-over takes is handed back through one trove with a watchdog behind it, so no
-- path - respawn, round end, a lost tween - leaves anything behind.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Feedback = require(script.Parent.Parent.UI.Feedback)
local Trove = require(Shared.Util.Trove)
local EggSense = require(Shared.Domain.EggSense)
local NpcPlate = require(script.Parent.Parent.UI.NpcPlate)
local PlumeCard = require(script.Parent.Parent.UI.PlumeCard)

local PlumeController = {}
PlumeController.__index = PlumeController

PlumeController.ARENA_NAME = "SFE_Chapter1"
PlumeController.MODEL_NAME = "ProfessorPlume"
PlumeController.STATION_NAME = "PlumeStation"
PlumeController.PROMPT_NAME = "SFE_PlumeBorrow"
PlumeController.NPC_NAME = "Professor Plume"

local LOOK_RANGE = 16
local SAY_RANGE = 26
local HAND_OVER_SECONDS = 0.55
local WATCHDOG_GRACE = 3
local ROD_WOOD = Color3.fromRGB(122, 82, 46)

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
		_card: { trove: Trove.Trove, handle: any }?,
		_pendingLend: boolean,
		stats: {
			opens: number,
			refused: number,
			loans: number,
			handOvers: number,
			notices: number,
			boardUpdates: number,
			restored: number,
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
	tools: any?,
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
		_pendingLend = false,
		stats = { opens = 0, refused = 0, loans = 0, handOvers = 0, notices = 0, boardUpdates = 0, restored = 0 },
	}, PlumeController)

	-- The prompt routes here from the InteractionController, which already refuses while a
	-- conversation owns the screen.
	self._trove:add(deps.interaction.plumeRequested:Connect(function()
		self:interact()
	end))
	self._trove:add(deps.net:on("PlumeLent", function(payload)
		self:_onLent(payload)
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
	if deps.tools and deps.tools.rodChanged then
		self._trove:add(deps.tools.rodChanged:Connect(function(active)
			self:_applyBoard()
			if not active and deps.round:phase() == "Searching" and self:_playerNear(SAY_RANGE) then
				self:_say(EggSense.LINES.expired)
			end
		end))
	end
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

-- True when the local character is within `range` studs of Plume.
function PlumeController._playerNear(self: PlumeController, range: number): boolean
	local rig = self._rig
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	local root = rig and rig:FindFirstChild("HumanoidRootPart")
	local mine = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart") and mine and mine:IsA("BasePart")) then
		return false
	end
	return (root.Position - mine.Position).Magnitude <= range
end

-- One idle step. Head follows the nearest player in range, otherwise drifts between the notes and
-- the board; the left hand holds the clipboard at his chest and the right hangs at his side; every
-- so often the right hand comes up to the glasses, or he looks down and taps the clipboard;
-- during a hand-over the right arm reaches out with the rod. Nothing else reaches across the
-- bench. Reduced motion keeps only the slow head-turn.
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
		local pick = if math.random() < 0.5 then "glasses" else "note"
		gesture = { name = pick, t = 0, duration = if pick == "glasses" then 1.9 else 2.4 }
		self._gesture = gesture
	end
	-- Rest: right arm down at his side with a slow sway; left forearm across the chest, clipboard up.
	-- On this rig a positive shoulder pitch swings the arm forward and a positive elbow folds it in.
	local rightPitch = -0.06 + math.sin(t * 1.5) * 0.02
	local rightRoll = 0.14 + math.sin(t * 0.9) * 0.02
	local rightElbow = 0.18
	local leftPitch, leftYaw, leftRoll, leftElbow = 0.9 + math.sin(t * 1.5) * 0.02, 0.15, 0.1, 1.15
	if gesture then
		gesture.t += dt
		local phase = gesture.t / gesture.duration
		local blend = math.sin(math.clamp(phase, 0, 1) * math.pi) -- rises, holds, falls
		if gesture.name == "glasses" then
			-- Right hand up to the frames; the head tips a touch with it.
			rightPitch = -0.06 + 2.2 * blend
			rightElbow = 0.18 + 1.2 * blend
			rightRoll = 0.14 - 0.2 * blend
			self._look = { yaw = self._yaw, pitch = -0.1 * blend, until_ = os.clock() + dt * 2 }
		elseif gesture.name == "handOver" then
			-- The right arm comes up and out toward the player, elbow straight, holding the rod.
			rightPitch = -0.06 + 1.45 * blend
			rightElbow = 0.18 * (1 - blend)
			rightRoll = 0.14 - 0.3 * blend
		else
			-- Eyes down to the clipboard; the right hand comes over and taps a note on it.
			self._look = { yaw = 0.25, pitch = -0.55, until_ = os.clock() + dt * 2 }
			rightPitch = -0.06 + 1.0 * blend + math.sin(t * 9) * 0.04 * blend
			rightElbow = 0.18 + 1.25 * blend
			rightRoll = 0.14 - 0.4 * blend
		end
		if phase >= 1 then
			self._gesture = nil
			self._nextGesture = os.clock() + 7 + math.random() * 8
		end
	end
	rShoulder.motor.C0 = rShoulder.base * CFrame.Angles(rightPitch, 0, rightRoll)
	rElbow.motor.C0 = rElbow.base * CFrame.Angles(rightElbow, 0, 0)
	lShoulder.motor.C0 = lShoulder.base * CFrame.Angles(leftPitch, leftYaw, leftRoll)
	lElbow.motor.C0 = lElbow.base * CFrame.Angles(leftElbow, 0, 0)
end

-- What the round snapshot says about the party's loans, and whether this player holds the rod.
function PlumeController._loanState(self: PlumeController): { count: number, usesLeft: number, cost: number?, active: boolean }
	local deps = self._deps
	local round = deps.round.round
	local plume = round and round.plume
	local count = plume and plume.count or 0
	local cost = EggSense.nextCost(deps.config, count)
	local active = false
	if deps.tools and deps.tools.rodState then
		active = deps.tools:rodState().active == true
	end
	if not active and plume and type(plume.active) == "table" then
		local me = Players.LocalPlayer and Players.LocalPlayer.UserId
		for _, entry in ipairs(plume.active) do
			if entry.userId == me and (entry.remainingMs or 0) > 0 then
				active = true
			end
		end
	end
	return { count = count, usesLeft = math.max(0, EggSense.maxUses(deps.config) - count), cost = cost, active = active }
end

-- The parchment board shows this party's loans. Written locally from the round snapshot, so every
-- member sees the same numbers and a server with two parties never crosses them.
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
	local live = round ~= nil and round.phase ~= "Returning"
	local loans = self:_loanState()
	local anyActive = false
	local plume = round and round.plume
	if live and plume and type(plume.active) == "table" then
		anyActive = #plume.active > 0
	end
	local rows = {
		Loans = if live then string.format("%d OF %d", loans.usesLeft, EggSense.maxUses(self._deps.config)) else "-",
		Cost = if not live then "-" elseif loans.cost then string.format("%d FEATHERS", loans.cost) else "NONE LEFT",
	}
	for rowName, text in pairs(rows) do
		local row = gui:FindFirstChild(rowName)
		local value = row and row:FindFirstChild("Value")
		local stamp = row and row:FindFirstChild("Stamp")
		if value and value:IsA("TextLabel") then
			if value.Text ~= text then
				self.stats.boardUpdates += 1
			end
			value.Text = text
			value.TextColor3 = if live then Color3.fromRGB(70, 46, 28) else Color3.fromRGB(150, 130, 100)
		end
		if stamp and stamp:IsA("TextLabel") then
			stamp.Visible = rowName == "Loans" and anyActive
		end
	end
end

function PlumeController.isBusy(self: PlumeController): boolean
	return self._sequence ~= nil or self._modalOpen or self._pendingLend
end

-- Plume's short lines go over his head, never into a panel.
function PlumeController._say(self: PlumeController, line: string)
	local rig = self._rig
	local root = rig and rig:FindFirstChild("HumanoidRootPart")
	if root then
		NpcPlate.sayOn(root, line, 3.2)
	end
end

-- The prompt press. One card at a time; while the rod is being handed over, nothing.
function PlumeController.interact(self: PlumeController): boolean
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
	if phase ~= "Searching" then
		if phase == "EggRevealed" then
			self:_say(EggSense.LINES.found)
		end
		self.stats.refused += 1
		return false
	end
	local loans = self:_loanState()
	local carried = deps.round.player and deps.round.player.carriedStandard or 0
	self.stats.opens += 1
	deps.audio:play(Tokens.sound.uiOpen)
	self:_say(EggSense.lineFor(deps.config, loans.count, carried, false, loans.active))
	return self:_openCard()
end

function PlumeController._cardState(self: PlumeController): PlumeCard.State
	local deps = self._deps
	local loans = self:_loanState()
	local carried = deps.round.player and deps.round.player.carriedStandard or 0
	local searching = deps.round:phase() == "Searching"
	local reason: string? = nil
	if not searching then
		reason = "phase"
	elseif loans.active then
		reason = "active"
	elseif loans.cost == nil then
		reason = "limit"
	elseif carried < loans.cost then
		reason = "insufficient"
	end
	return {
		carried = carried,
		cost = loans.cost,
		usesLeft = loans.usesLeft,
		maxUses = EggSense.maxUses(deps.config),
		activeSeconds = deps.config.plume.rod.activeSeconds,
		active = loans.active,
		canBorrow = reason == nil,
		reason = reason,
	}
end

-- The card owns the screen while it is up: cursor free, gameplay input paused, HUD down.
function PlumeController._openCard(self: PlumeController): boolean
	local deps = self._deps
	local player = Players.LocalPlayer
	if not player or self._card then
		return false
	end
	local session = { trove = Trove.new(), handle = nil }
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
			onBorrow = function()
				self:borrow()
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

-- The loan request. Returns the envelope; a success closes the card and plays the hand-over.
function PlumeController.borrow(self: PlumeController): any
	local deps = self._deps
	local token = deps.round:sessionToken()
	if not token then
		return { ok = false, code = "invalid_state", message = "no_session" }
	end
	if self._sequence or self._pendingLend then
		self.stats.refused += 1
		return { ok = false, code = "invalid_state", message = "busy" }
	end
	self._pendingLend = true
	local result = deps.net:request("PlumeLend", { sessionToken = token })
	if not result.ok then
		self._pendingLend = false
		local message = result.message
		-- One refusal, one voice: Plume says the reasons he has a line for (the toast that repeated
		-- "Not enough feathers" under his own line is gone); the rest are toasts. Both pass the gate.
		local shown = Feedback.deny(
			"plume:" .. tostring(message or result.code),
			if message == "egg_found"
					or message == "limit"
					or message == "active"
					or message == "insufficient"
				then nil
				elseif result.code == "out_of_range" then "Stand at Plume's bench"
				else "The rod is not available"
		)
		if not shown then
			return result
		end
		if message == "egg_found" then
			self:_say(EggSense.LINES.found)
		elseif message == "limit" then
			self:_say(EggSense.LINES.limit)
		elseif message == "active" then
			self:_say(EggSense.LINES.active)
		elseif message == "insufficient" then
			self:_say(EggSense.LINES.insufficient)
		end
		return result
	end
	self.stats.loans += 1
	deps.haptics:pulse(0.4, 0.12)
	local data = result.data
	-- The response carries the round's loan book; the Book, the board and the card read it from the
	-- round state, so it lands there now rather than with the next snapshot.
	if deps.round.round and data and data.plume then
		deps.round.round.plume = data.plume
	end
	-- The response carries the borrower's projection with the feathers already gone and the rod in
	-- hand; the HUD binds to playerChanged, so the bundle thins now.
	if data and data.player then
		deps.round.player = data.player
		deps.round.playerChanged:Fire(data.player)
	end
	self:_closeCard()
	self:_say(EggSense.LINES.lend)
	task.defer(function()
		self:_handOver(data)
		self._pendingLend = false
	end)
	return result
end

-- A small rod for the flight from Plume's hand to the camera: the same silhouette as the viewmodel.
local function makeFlyingRod(): Model
	local model = Instance.new("Model")
	model.Name = "SFE_PlumeRod"
	local function piece(name: string, size: Vector3, offset: CFrame, color: Color3, material: Enum.Material): Part
		local part = Instance.new("Part")
		part.Name = name
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Size = size
		part.CFrame = offset
		part.Color = color
		part.Material = material
		part.Parent = model
		return part
	end
	local shaft = piece(
		"Shaft",
		Vector3.new(0.9, 0.09, 0.09),
		CFrame.new(0, 0.45, 0) * CFrame.Angles(0, 0, math.rad(90)),
		ROD_WOOD,
		Enum.Material.Wood
	)
	shaft.Shape = Enum.PartType.Cylinder
	model.PrimaryPart = shaft
	for _, side in ipairs({ -1, 1 }) do
		local prong = piece(
			"Prong",
			Vector3.new(0.42, 0.07, 0.07),
			CFrame.new(0, 0.9, 0) * CFrame.Angles(0, 0, side * math.rad(26)) * CFrame.new(0, 0.21, 0) * CFrame.Angles(0, 0, math.rad(90)),
			ROD_WOOD,
			Enum.Material.Wood
		)
		prong.Shape = Enum.PartType.Cylinder
	end
	local crystal =
		piece("Crystal", Vector3.new(0.24, 0.24, 0.24), CFrame.new(0, 1.22, 0), Color3.fromRGB(120, 190, 255), Enum.Material.Neon)
	crystal.Shape = Enum.PartType.Ball
	local light = Instance.new("PointLight")
	light.Color = crystal.Color
	light.Brightness = 1.2
	light.Range = 5
	light.Parent = crystal
	return model
end

local function bezier(a: Vector3, b: Vector3, c: Vector3, t: number): Vector3
	local u = 1 - t
	return a * (u * u) + b * (2 * u * t) + c * (t * t)
end

-- The hand-over for the borrower. Plume reaches out; the rod leaves his hand and flies into the
-- camera, where the viewmodel is already rising to meet it. Every resource it takes is returned by
-- `session.trove`; the watchdog guarantees that.
function PlumeController._handOver(self: PlumeController, _data: any)
	local deps = self._deps
	local rig = self._rig
	local camera = workspace.CurrentCamera
	if not (rig and camera) then
		return
	end
	if self._sequence then
		self:_finishSequence("restart")
	end
	local session = { trove = Trove.new(), done = false }
	self._sequence = session
	self.stats.handOvers += 1
	local reduced = deps.accessibility:motionSettings().reducedMotion
	local seconds = if reduced then 0.15 else HAND_OVER_SECONDS
	-- Plume looks at the player and reaches out with the rod.
	self._gesture = { name = "handOver", t = 0, duration = if reduced then 0.4 else 1.3 }
	local hand = rig:FindFirstChild("RightHand") or rig:FindFirstChild("RightLowerArm")
	local from = if hand and hand:IsA("BasePart")
		then hand.Position + Vector3.new(0, 0.3, 0)
		else rig:GetPivot().Position + Vector3.new(0, 2, 0)
	local rod = makeFlyingRod()
	rod:PivotTo(CFrame.new(from))
	rod.Parent = workspace
	session.trove:add(rod)
	deps.audio:play(Tokens.sound.uiConfirm)
	deps.audio:play(Tokens.sound.rodLock)
	local startAt = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		if session.done then
			return
		end
		local t = math.min(1, (os.clock() - startAt) / seconds)
		local eased = 1 - (1 - t) * (1 - t)
		-- The destination tracks the camera so a turning player still catches it low right.
		local to = (camera.CFrame * CFrame.new(0.42, -0.62, -0.7)).Position
		local control = (from + to) / 2 + Vector3.new(0, 1.2, 0)
		local position = bezier(from, control, to, eased)
		rod:PivotTo(CFrame.new(position) * CFrame.Angles(0, t * 4, t * 2))
		if t >= 1 then
			conn:Disconnect()
			rod:Destroy()
			deps.haptics:pulse(0.35, 0.08)
			self:_finishSequence("complete")
		end
	end)
	session.trove:add(conn)
	-- The watchdog: whatever else happens, nothing of the hand-over is left in the world.
	task.delay(seconds + WATCHDOG_GRACE, function()
		if self._sequence == session then
			self:_finishSequence("watchdog")
		end
	end)
end

-- What a member who did not borrow sees.
function PlumeController._onLent(self: PlumeController, payload: any)
	local me = Players.LocalPlayer and Players.LocalPlayer.UserId
	local round = self._deps.round.round
	if round and payload.plume and round.roundId == payload.roundId then
		round.plume = payload.plume
	end
	self:_applyBoard()
	if payload.byUserId == me then
		return
	end
	self.stats.notices += 1
	self._deps.audio:play(Tokens.sound.stationChime)
	self._deps.hud.toasts:push(string.format("%s borrowed the Egg Sense Rod", tostring(payload.byName or "A forager")), "info")
end

function PlumeController._finishSequence(self: PlumeController, reason: string)
	local session = self._sequence
	if not session then
		return
	end
	session.done = true
	self._sequence = nil
	session.trove:destroy()
	self.stats.restored += 1
	self:_applyBoard()
	local _ = reason
end

-- Dismisses whatever Plume has up: the card, or the hand-over.
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
	local loans = self:_loanState()
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
		boardLoans = rowText("Loans"),
		boardCost = rowText("Cost"),
		usesLeft = loans.usesLeft,
		nextCost = loans.cost,
		rodActive = loans.active,
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
