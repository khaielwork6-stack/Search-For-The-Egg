--!strict
-- Professor Plume on the client. Owns everything the player sees of him: the nameplate, the outline
-- while his prompt is in reach, the idle (writing, examining, adjusting his glasses, looking at
-- whoever walks up), the analysis board's rows, his card, and the analysis request. The clue the
-- server returns is shown on the card and said over his head; nothing is placed in the world.
--
-- The rig arrives from the server fully anchored. This controller unanchors the limbs locally and
-- drives the Motor6D C0s itself, so the pose is a local matter and the server never moves a thing.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Feedback = require(script.Parent.Parent.UI.Feedback)
local Trove = require(Shared.Util.Trove)
local PlumeClue = require(Shared.Domain.PlumeClue)
local NpcPlate = require(script.Parent.Parent.UI.NpcPlate)
local PlumeCard = require(script.Parent.Parent.UI.PlumeCard)

local PlumeController = {}
PlumeController.__index = PlumeController

PlumeController.ARENA_NAME = "SFE_Chapter1"
PlumeController.MODEL_NAME = "ProfessorPlume"
PlumeController.STATION_NAME = "PlumeStation"
PlumeController.PROMPT_NAME = "SFE_PlumeAnalyse"
PlumeController.NPC_NAME = "Professor Plume"

local LOOK_RANGE = 16

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
		_modalOpen: boolean,
		_card: { trove: Trove.Trove, handle: any }?,
		_pending: boolean,
		stats: {
			opens: number,
			refused: number,
			analyses: number,
			boardUpdates: number,
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
		_modalOpen = false,
		_card = nil,
		_pending = false,
		stats = { opens = 0, refused = 0, analyses = 0, boardUpdates = 0 },
	}, PlumeController)

	-- The prompt routes here from the InteractionController, which already refuses while a
	-- conversation owns the screen.
	self._trove:add(deps.interaction.plumeRequested:Connect(function()
		self:interact()
	end))
	self._trove:add(deps.round.snapshot:Connect(function()
		self:_applyBoard()
	end))
	self._trove:add(deps.round.playerChanged:Connect(function()
		self:_applyBoard()
	end))
	self._trove:add(deps.round.phaseChanged:Connect(function()
		self:_applyBoard()
	end))
	local player = Players.LocalPlayer
	if player then
		self._trove:add(player.CharacterAdded:Connect(function()
			self:_closeCard()
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
-- the board; the left hand holds the clipboard at his chest and the right hangs at his side; every
-- so often the right hand comes up to the glasses, or he looks down and taps the clipboard.
-- Nothing reaches across the bench. Reduced motion keeps only the slow head-turn.
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

-- This player's side of the analysis: the price, the carried Rainbow Feathers, the clue once
-- known, and why the button is off when it is.
function PlumeController._analysisState(self: PlumeController): PlumeCard.State
	local deps = self._deps
	local player = deps.round.player
	local phase = deps.round:phase()
	local clue = player and player.plumeClue or nil
	local carried = player and player.carriedRainbow or 0
	local reason = PlumeClue.refusal(deps.config, {
		eggOut = phase == "EggRevealed",
		searching = phase == "Searching",
		used = clue ~= nil,
		carriedRainbow = carried,
	})
	if reason == nil and self._pending then
		reason = "pending"
	end
	return {
		carriedRainbow = carried,
		cost = PlumeClue.cost(deps.config),
		clue = if clue then { title = tostring(clue.title), text = tostring(clue.text) } else nil,
		canAnalyse = reason == nil,
		reason = reason,
	}
end

-- The parchment board shows this player's price and whether the round's analysis is spent. Written
-- locally, so each player reads their own row.
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
	local state = self:_analysisState()
	local rows = {
		Cost = string.format("%d RAINBOW", state.cost),
		Status = if not live then "-" elseif state.clue then "USED" else "READY",
	}
	for rowName, text in pairs(rows) do
		local row = gui:FindFirstChild(rowName)
		local value = row and row:FindFirstChild("Value")
		if value and value:IsA("TextLabel") then
			if value.Text ~= text then
				self.stats.boardUpdates += 1
			end
			value.Text = text
			value.TextColor3 = if live then Color3.fromRGB(70, 46, 28) else Color3.fromRGB(150, 130, 100)
		end
	end
end

function PlumeController.isBusy(self: PlumeController): boolean
	return self._modalOpen or self._pending
end

-- Plume's short lines go over his head, never into a panel.
function PlumeController._say(self: PlumeController, line: string)
	local rig = self._rig
	local root = rig and rig:FindFirstChild("HumanoidRootPart")
	if root then
		NpcPlate.sayOn(root, line, 3.2)
	end
end

-- The prompt press. One card at a time.
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
			self:_say(PlumeClue.LINES.found)
		end
		self.stats.refused += 1
		return false
	end
	local state = self:_analysisState()
	self.stats.opens += 1
	deps.audio:play(Tokens.sound.uiOpen)
	self:_say(if state.clue then state.clue.text else PlumeClue.lineFor(deps.config, state.reason))
	return self:_openCard()
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
			onAnalyse = function()
				self:analyse()
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
			session.handle.setState(self:_analysisState())
		end
	end))
	session.trove:add(deps.round.snapshot:Connect(function()
		if session.handle then
			session.handle.setState(self:_analysisState())
		end
	end))
	handle.setState(self:_analysisState())
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

-- Rewrites the card, when it is up, from the current state.
function PlumeController._refreshCard(self: PlumeController)
	local session = self._card
	if session and session.handle then
		session.handle.setState(self:_analysisState())
	end
end

-- The analysis request. Returns the envelope; a success shows the clue on the card and over
-- Plume's head. The server decides everything; this only shows the answer.
function PlumeController.analyse(self: PlumeController): any
	local deps = self._deps
	local token = deps.round:sessionToken()
	if not token then
		return { ok = false, code = "invalid_state", message = "no_session" }
	end
	if self._pending then
		self.stats.refused += 1
		return { ok = false, code = "invalid_state", message = "busy" }
	end
	self._pending = true
	self:_refreshCard()
	local result = deps.net:request("PlumeAnalyse", { sessionToken = token })
	self._pending = false
	if not result.ok then
		local message = result.message
		-- One refusal, one voice: Plume speaks the reasons he has a line for, the rest are toasts. Every
		-- refusal passes the denial gate, so a held key shows and sounds once per window.
		local spoken = message == "egg_found" or message == "phase" or message == "used" or message == "insufficient"
		local shown = Feedback.deny(
			"plume:" .. tostring(message or result.code),
			if spoken
				then nil
				elseif result.code == "out_of_range" then "Stand at Plume's bench"
				elseif result.code == "rate_limited" then "One moment..."
				else "The analyzer is not available",
			if result.code == "rate_limited" then { tone = "info", silent = true } else nil
		)
		if shown and spoken then
			self:_say(PlumeClue.lineFor(deps.config, message))
		end
		self:_refreshCard()
		return result
	end
	self.stats.analyses += 1
	deps.haptics:pulse(0.4, 0.12)
	deps.audio:play(Tokens.sound.stationChime)
	local data = result.data
	-- The response carries this player's projection with the Rainbow Feathers gone and the clue on
	-- it; the HUD and the card bind to playerChanged, so both update now.
	if data and data.player then
		deps.round.player = data.player
		deps.round.playerChanged:Fire(data.player)
	end
	local clue = data and data.clue
	if clue then
		self:_say(tostring(clue.text))
	end
	self:_refreshCard()
	self:_applyBoard()
	return result
end

-- Dismisses the card.
function PlumeController.skip(self: PlumeController)
	self:_closeCard()
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
	local state = self:_analysisState()
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
		modalOpen = self._modalOpen,
		boardCost = rowText("Cost"),
		boardStatus = rowText("Status"),
		cost = state.cost,
		canAnalyse = state.canAnalyse,
		reason = state.reason,
		clue = state.clue,
		cameraType = tostring(camera and camera.CameraType),
		stats = table.clone(self.stats),
	}
end

function PlumeController.destroy(self: PlumeController)
	self:_closeCard()
	if self._bound then
		self._bound:destroy()
		self._bound = nil
	end
	self._trove:destroy()
end

return PlumeController
