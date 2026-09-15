--!strict
-- The round intro cinematic.
--
-- Plays once per round, locally, while the server holds the round in its intro phase. Four shots
-- between named camera markers: the flyer on the sign, the player's own avatar walking in and taking
-- it, a beat reading it, then a sweep into the farm. When it ends - watched through, skipped, or
-- failed - the client reports ready, and the server starts the round once every present member has.
--
-- Three rules shape the code:
--
--  * It must never trap anyone. Every takeover is registered on one Trove before it is applied, the
--    whole run is wrapped, and `finish` is idempotent and reachable from an error, a skip, a respawn
--    or the phase moving on. A missing marker, model or sound degrades the shot; it never blocks.
--  * It must never be authoritative. Nothing here decides when the round starts; it reports.
--  * The avatar on camera is a local clone. The real character stays parked at the round spawn under
--    server control, hidden locally, so nothing a player sees can move anyone else's character.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContentProvider = game:GetService("ContentProvider")
local ProximityPromptService = game:GetService("ProximityPromptService")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Trove = require(Shared.Util.Trove)
local RoundIntro = require(Shared.Domain.RoundIntro)
local Signal = require(Shared.Util.Signal)
local IntroOverlay = require(script.Parent.Parent.UI.IntroOverlay)

local IntroCinematicController = {}
IntroCinematicController.__index = IntroCinematicController

export type Deps = {
	config: { [string]: any },
	round: any,
	net: any,
	input: any,
	modals: any,
	hud: any,
	audio: any,
	accessibility: any,
}

export type IntroCinematicController = typeof(setmetatable(
	{} :: {
		_deps: Deps,
		_trove: Trove.Trove,
		_session: any?,
		_playedRounds: { [string]: boolean },
		finished: Signal.Signal<string>,
		stats: { plays: number, skips: number, failures: number, missing: { string }, ticks: number, stage: string, lastT: number },
	},
	IntroCinematicController
))

-- Limb joints by the part they drive, so one table poses both rig kinds.
local LEG_PARTS = { ["Left Leg"] = -1, ["Right Leg"] = 1, LeftUpperLeg = -1, RightUpperLeg = 1 }
local ARM_PARTS = { ["Left Arm"] = -1, ["Right Arm"] = 1, LeftUpperArm = -1, RightUpperArm = 1 }
local HEAD_PARTS = { Head = true }
local RIGHT_HAND_PARTS = { ["Right Arm"] = true, RightHand = true }

local function smoothstep(t: number): number
	local x = math.clamp(t, 0, 1)
	return x * x * (3 - 2 * x)
end

function IntroCinematicController.new(deps: Deps): IntroCinematicController
	local self = setmetatable({
		_deps = deps,
		_trove = Trove.new(),
		_session = nil,
		_playedRounds = {},
		finished = Signal.new(),
		stats = { plays = 0, skips = 0, failures = 0, missing = {}, ticks = 0, stage = "idle", lastT = 0 },
	}, IntroCinematicController)
	return self
end

function IntroCinematicController._note(self: IntroCinematicController, what: string)
	-- Named so a fallback is diagnosable rather than mysterious.
	if not table.find(self.stats.missing, what) then
		table.insert(self.stats.missing, what)
	end
	warn("[SFE][Intro] missing dependency: " .. what)
end

-- The marker part if it is in the world, else the authored default, else nil.
function IntroCinematicController._marker(self: IntroCinematicController, name: string): (CFrame?, number?)
	local chapter = workspace:FindFirstChild("SFE_Chapter1")
	local set = chapter and chapter:FindFirstChild("SFE_IntroSet")
	local pin = set and set:FindFirstChild(name)
	if pin and pin:IsA("BasePart") then
		local fov = pin:GetAttribute("SFE_FieldOfView")
		return pin.CFrame, if type(fov) == "number" then fov else nil
	end
	local marker = self._deps.config.round.intro.markers[name]
	if not marker then
		self:_note("marker " .. name)
		return nil, nil
	end
	self:_note("marker part " .. name .. " (using the configured default)")
	local position = Vector3.new(marker.position[1], marker.position[2], marker.position[3])
	local lookAt = Vector3.new(marker.lookAt[1], marker.lookAt[2], marker.lookAt[3])
	return CFrame.lookAt(position, lookAt), marker.fieldOfView
end

-- A copy of the local character to act in the shot. The real one never moves.
function IntroCinematicController._buildActor(self: IntroCinematicController, trove: Trove.Trove): Model?
	local player = Players.LocalPlayer
	local character = player.Character
	if not character or not character:FindFirstChild("HumanoidRootPart") then
		self:_note("local character")
		return nil
	end
	local wasArchivable = character.Archivable
	character.Archivable = true
	local ok, clone = pcall(function()
		return character:Clone()
	end)
	character.Archivable = wasArchivable
	if not ok or not clone then
		self:_note("character clone")
		return nil
	end
	local model = clone :: Model
	model.Name = "SFE_IntroActor"
	-- Strip anything that could act on its own or draw a label over the shot.
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BaseScript") or descendant:IsA("Sound") or descendant:IsA("BillboardGui") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.Anchored = true
			descendant.Massless = true
		end
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.NameDisplayDistance = 0
		humanoid.HealthDisplayDistance = 0
		humanoid.EvaluateStateMachine = false
	end
	model.Parent = workspace
	trove:add(model)
	return model
end

-- Hides the real character locally for the duration. Nothing is destroyed and nothing replicates.
function IntroCinematicController._hideRealCharacter(_self: IntroCinematicController, trove: Trove.Trove)
	local character = Players.LocalPlayer.Character
	if not character then
		return
	end
	local hidden: { BasePart } = {}
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = 1
			table.insert(hidden, descendant)
		end
	end
	trove:add(function()
		for _, basePart in ipairs(hidden) do
			if basePart.Parent then
				basePart.LocalTransparencyModifier = 0
			end
		end
	end)
end

-- Poses the actor for time `t`: walk cycle along the path, then reach, take, read and turn.
local function poseActor(model: Model, intro: { [string]: any }, t: number, parchment: BasePart?)
	local actor = intro.actor
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local from = Vector3.new(actor.startPosition[1], actor.startPosition[2], actor.startPosition[3])
	local to = Vector3.new(actor.standPosition[1], actor.standPosition[2], actor.standPosition[3])
	local alpha = RoundIntro.actorAlpha(actor, t)
	local position = from:Lerp(to, alpha)
	-- Facing: along the walk while moving, then square to the sign, then round to the farm.
	local sign = Vector3.new(intro.sign.position[1], position.Y, intro.sign.position[3])
	local walkFacing = if (to - from).Magnitude > 0.01 then (to - from).Unit else Vector3.new(0, 0, -1)
	local signFacing = if (sign - position).Magnitude > 0.01 then (sign - position).Unit else walkFacing
	local farm = Vector3.new(intro.markers.IntroFarmReveal.lookAt[1], position.Y, intro.markers.IntroFarmReveal.lookAt[3])
	local farmFacing = if (farm - position).Magnitude > 0.01 then (farm - position).Unit else signFacing
	local facing = walkFacing
	if alpha >= 0.999 then
		facing = signFacing
	end
	if t >= actor.turnAt then
		local turn = smoothstep((t - actor.turnAt) / math.max(0.01, actor.turnSeconds))
		facing = signFacing:Lerp(farmFacing, turn)
		if facing.Magnitude > 0.01 then
			facing = facing.Unit
		else
			facing = signFacing
		end
	end
	-- Roblox rigs stand with the root about 3 studs above the feet on R15 and 3 on R6; the clone keeps
	-- its own offset, so lift by half the root's height plus the leg reach it was built with.
	local lift = root.Size.Y / 2 + 1.5
	root.CFrame = CFrame.lookAt(position + Vector3.new(0, lift, 0), position + Vector3.new(0, lift, 0) + facing)

	local moving = t >= actor.walkAt and alpha < 0.999
	local phase = t * actor.stepsPerSecond * math.pi * 2
	local swing = if moving then math.sin(phase) * math.rad(34) else 0
	local reach = 0
	if t >= actor.reachAt then
		-- Reach up to the board, hold, then bring the paper down to read it.
		local up = smoothstep((t - actor.reachAt) / 0.7)
		local down = smoothstep((t - actor.readAt) / 0.8)
		reach = math.rad(78) * up - math.rad(46) * down
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Motor6D") and descendant.Part1 then
			local name = descendant.Part1.Name
			local legSide = LEG_PARTS[name]
			local armSide = ARM_PARTS[name]
			if legSide then
				descendant.Transform = CFrame.Angles(swing * legSide, 0, 0)
			elseif armSide then
				local isRight = armSide > 0
				local value = -swing * armSide
				if isRight and reach ~= 0 then
					value = -reach
				end
				descendant.Transform = CFrame.Angles(value, 0, 0)
			elseif HEAD_PARTS[name] then
				-- Look down at the paper while reading.
				local read = if t >= actor.readAt then smoothstep((t - actor.readAt) / 0.6) else 0
				local liftBack = if t >= actor.turnAt then smoothstep((t - actor.turnAt) / 0.6) else 0
				descendant.Transform = CFrame.Angles(math.rad(26) * read * (1 - liftBack), 0, 0)
			end
		end
	end

	if parchment then
		local hand: BasePart? = nil
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") and RIGHT_HAND_PARTS[descendant.Name] then
				hand = descendant
				break
			end
		end
		if hand then
			-- Held clear of the limb so nothing intersects, tilted up towards the face while reading.
			local read = if t >= actor.readAt then smoothstep((t - actor.readAt) / 0.6) else 0
			local held = (hand :: BasePart).CFrame
				* CFrame.new(0, -(hand :: BasePart).Size.Y / 2 - 0.9, -0.35)
				* CFrame.Angles(math.rad(-60 - 28 * read), 0, 0)
			parchment.CFrame = held
		end
	end
end

function IntroCinematicController.isPlaying(self: IntroCinematicController): boolean
	return self._session ~= nil
end

-- Ends the run exactly once, restores everything, and reports ready.
function IntroCinematicController.finish(self: IntroCinematicController, reason: string)
	local session = self._session
	if not session or session.finishing then
		return
	end
	session.finishing = true
	local deps = self._deps
	local intro = deps.config.round.intro
	local overlay = session.overlay
	-- Hold black over the hand-back so the restore is never seen.
	if overlay then
		overlay.setFade(1, if reason == "skip" then 0.18 else intro.fadeOutSeconds)
		overlay.setSubtitle(nil)
		overlay.setSkipEnabled(false)
	end
	task.delay(if reason == "skip" then 0.2 else intro.fadeOutSeconds, function()
		-- Restore the world before the black lifts.
		pcall(function()
			session.trove:destroy()
		end)
		self._session = nil
		if overlay then
			overlay.setLetterbox(false, 0.25)
			overlay.showObjective(intro.objectiveLabel, intro.objectiveSeconds)
			overlay.setFade(0, 0.35)
			-- The round music starts with the round, not under the cinematic.
			pcall(function()
				deps.audio:setState("Search")
			end)
			task.delay(intro.objectiveSeconds + 1.2, function()
				overlay.destroy()
			end)
		end
		self.finished:Fire(reason)
	end)
	-- Report immediately, not after the fade: the server should not wait on our animation.
	self:_reportReady()
end

function IntroCinematicController._reportReady(self: IntroCinematicController)
	local deps = self._deps
	task.spawn(function()
		local ok, result = pcall(function()
			local token = deps.round:sessionToken()
			if not token then
				return nil
			end
			return deps.net:request("RoundIntroReady", { sessionToken = token })
		end)
		if not ok then
			warn("[SFE][Intro] ready report failed: " .. tostring(result))
			return
		end
		-- Others may still be watching; the overlay says so until the phase moves on.
		local session = self._session
		local data = type(result) == "table" and (result :: any).data or nil
		if session and session.overlay and data and data.ready and data.present and data.ready < data.present then
			session.overlay.setWaiting(true)
		end
	end)
end

function IntroCinematicController.skip(self: IntroCinematicController)
	local session = self._session
	if not session or session.finishing then
		return
	end
	if not self._deps.config.round.intro.allowSkip then
		return
	end
	self.stats.skips += 1
	self:finish("skip")
end

function IntroCinematicController.play(self: IntroCinematicController, roundId: string)
	if self._session or self._playedRounds[roundId] then
		return
	end
	local deps = self._deps
	local intro = deps.config.round.intro
	if not intro.playEveryRound then
		self:_reportReady()
		return
	end
	self._playedRounds[roundId] = true
	self.stats.plays += 1

	local session: any = { trove = Trove.new(), finishing = false, overlay = nil }
	self._session = session

	local ok, err = pcall(function()
		self:_run(session)
	end)
	if not ok then
		self.stats.failures += 1
		warn("[SFE][Intro] failed, falling back: " .. tostring(err))
		self:finish("error")
	end
end

function IntroCinematicController._takeOver(self: IntroCinematicController, session: any)
	local deps = self._deps
	local trove = session.trove

	deps.input:setSuspended(true)
	deps.modals:setExternalUnlock(true)
	local hudGui = deps.hud.gui
	local hudWasEnabled = hudGui.Enabled
	hudGui.Enabled = false
	trove:add(function()
		hudGui.Enabled = hudWasEnabled
		deps.modals:setExternalUnlock(false)
		deps.input:setSuspended(false)
	end)

	-- World prompts are BillboardGuis in the workspace, so hiding the HUD does not touch them.
	local promptsWereEnabled = ProximityPromptService.Enabled
	ProximityPromptService.Enabled = false
	trove:add(function()
		ProximityPromptService.Enabled = promptsWereEnabled
	end)

	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
	end)
	trove:add(function()
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, true)
			-- Tab belongs to the upgrade book, so the player list stays off as it was at boot.
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
		end)
	end)

	local camera = workspace.CurrentCamera
	local previousType, previousCFrame, previousFov = camera.CameraType, camera.CFrame, camera.FieldOfView
	camera.CameraType = Enum.CameraType.Scriptable
	trove:add(function()
		camera.CFrame = previousCFrame
		camera.FieldOfView = previousFov
		camera.CameraType = previousType
	end)

	self:_hideRealCharacter(trove)
end

function IntroCinematicController._run(self: IntroCinematicController, session: any)
	self.stats.stage = "run"
	local deps = self._deps
	local intro = deps.config.round.intro
	local motion = deps.accessibility:motionSettings()
	local trove = session.trove

	-- Preload what the shot needs. A failure here is not fatal: the intro plays with whatever loaded.
	task.spawn(function()
		local chapter = workspace:FindFirstChild("SFE_Chapter1")
		local set = chapter and chapter:FindFirstChild("SFE_IntroSet")
		local targets: { Instance } = {}
		if set then
			table.insert(targets, set)
		end
		if Players.LocalPlayer.Character then
			table.insert(targets, Players.LocalPlayer.Character :: Instance)
		end
		if #targets > 0 then
			local okPreload, preloadErr = pcall(function()
				ContentProvider:PreloadAsync(targets)
			end)
			if not okPreload then
				warn("[SFE][Intro] preload failed, continuing: " .. tostring(preloadErr))
			end
		end
	end)

	local overlay = IntroOverlay.create(Players.LocalPlayer:WaitForChild("PlayerGui"), {
		config = deps.config,
		motion = motion,
		allowSkip = intro.allowSkip,
		onSkip = function()
			self:skip()
		end,
	})
	self.stats.stage = "overlay"
	session.overlay = overlay
	trove:add(function()
		-- The overlay outlives the takeover by design (it holds the black through the restore), so
		-- only tear it down here if the run is being abandoned rather than finished.
		if self._session == session and not session.finishing then
			overlay.destroy()
		end
	end)

	self:_takeOver(session)
	self.stats.stage = "takeover"
	overlay.setLetterbox(true, intro.letterboxSeconds)
	overlay.setFade(1, 0)
	overlay.setFade(0, intro.fadeInSeconds)

	-- Skip on click, tap, Space, Enter or controller B.
	if intro.allowSkip then
		trove:add(UserInputService.InputBegan:Connect(function(input, processed)
			if processed or not self._session then
				return
			end
			if
				input.KeyCode == Enum.KeyCode.Space
				or input.KeyCode == Enum.KeyCode.Return
				or input.KeyCode == Enum.KeyCode.KeypadEnter
				or input.KeyCode == Enum.KeyCode.ButtonB
			then
				self:skip()
			end
		end))
	end

	-- The flyer, and a copy of it for the actor's hand.
	local chapter = workspace:FindFirstChild("SFE_Chapter1")
	local set = chapter and chapter:FindFirstChild("SFE_IntroSet")
	local sign = set and set:FindFirstChild("SFE_IntroSign")
	local boardParchment = sign and sign:FindFirstChild("IntroParchment") :: BasePart?
	local heldParchment: BasePart? = nil
	if boardParchment then
		-- Rewrite the prize for the chapter and difficulty this round is actually on. Purely local: a
		-- client-side text change never replicates, so two parties sharing a server cannot disagree
		-- about what the flyer says, and the number still comes from the same shared calculation the
		-- payout uses rather than from anything written on the board.
		local snapshot = deps.round.round
		if snapshot and snapshot.chapter then
			local flyer = boardParchment:FindFirstChild("Flyer")
			local paper = flyer and flyer:FindFirstChild("Paper")
			local rewardLabel = paper and paper:FindFirstChild("Reward")
			if rewardLabel and rewardLabel:IsA("TextLabel") then
				rewardLabel.Text = intro.poster.rewardPrefix
					.. RoundIntro.rewardText(deps.config, snapshot.chapter, snapshot.difficulty or "normal")
			else
				self:_note("flyer reward label")
			end
		end
		local held = boardParchment:Clone()
		held.Name = "SFE_IntroHeldParchment"
		held.Anchored = true
		held.CanCollide = false
		held.CanQuery = false
		held.Transparency = 1
		held.Parent = workspace
		heldParchment = held
		trove:add(held)
	else
		self:_note("sign parchment")
	end

	local actor = self:_buildActor(trove)
	self.stats.stage = "actor"

	-- Layered bed for the shot. Every one of these but the tick is a silent placeholder until the
	-- owner supplies an id, so a missing sound costs nothing and changes no code.
	local ambienceAnchor = (actor and actor:FindFirstChild("HumanoidRootPart")) :: BasePart?
	if ambienceAnchor then
		local ambience = deps.audio:loop(Tokens.sound.introAmbience, ambienceAnchor)
		local wind = deps.audio:loop(Tokens.sound.introWind, ambienceAnchor)
		trove:add(function()
			if ambience then
				deps.audio:stopLoop(ambience)
			end
			if wind then
				deps.audio:stopLoop(wind)
			end
		end)
	end
	local lastStep = -1
	local paperPlayed, stingPlayed = false, false

	local shots = intro.shots
	local duration = RoundIntro.duration(deps.config)
	local started = os.clock()
	local lastTyped = ""
	self.stats.stage = "binding"
	local frame = "SFE_RoundIntroCamera"
	RunService:BindToRenderStep(frame, Enum.RenderPriority.Camera.Value + 6, function()
		if not self._session or session.finishing then
			return
		end
		local t = os.clock() - started
		self.stats.ticks += 1
		self.stats.lastT = t
		local camera = workspace.CurrentCamera
		local shot, progress = RoundIntro.shotAt(shots, t)
		if shot then
			local index = table.find(shots, shot) or 1
			local toCF, toFov = self:_marker(shot.marker)
			if toCF then
				local fromCF, fromFov = toCF, toFov
				if index > 1 then
					local previous = shots[index - 1]
					local prevCF, prevFov = self:_marker(previous.marker)
					if prevCF then
						fromCF, fromFov = prevCF, prevFov or toFov
					end
				end
				-- Every shot settles exactly on its marker; `push` only decides how far back it starts,
				-- so tuning a marker moves the shot predictably.
				local backOff = (shot.push or 0) * 3
				if backOff > 0 then
					fromCF = fromCF * CFrame.new(0, 0, backOff)
				end
				local eased = smoothstep(progress)
				camera.CFrame = fromCF:Lerp(toCF, eased)
				camera.FieldOfView = (fromFov or 70) + ((toFov or 70) - (fromFov or 70)) * eased
			end
		end
		if actor then
			pcall(poseActor, actor, intro, t, heldParchment)
			-- One footstep per half stride while the walk is running.
			local alpha = RoundIntro.actorAlpha(intro.actor, t)
			if t >= intro.actor.walkAt and alpha < 0.999 then
				local step = math.floor(t * intro.actor.stepsPerSecond * 2)
				if step ~= lastStep then
					lastStep = step
					deps.audio:play(Tokens.sound.introFootstep)
				end
			end
		end
		if not paperPlayed and t >= intro.actor.takeAt then
			paperPlayed = true
			deps.audio:play(Tokens.sound.introPaper)
		end
		if not stingPlayed and t >= intro.actor.turnAt then
			stingPlayed = true
			deps.audio:play(Tokens.sound.introSting)
		end
		-- The flyer leaves the board and appears in the hand at the same instant.
		if heldParchment and boardParchment then
			local taken = t >= intro.actor.takeAt
			heldParchment.Transparency = if taken then 0 else 1
			boardParchment.LocalTransparencyModifier = if taken then 1 else 0
		end
		local text, typedFraction = RoundIntro.subtitleAt(intro.beats, t, intro.subtitleCharactersPerSecond)
		if text then
			local typed = RoundIntro.typedText(text, typedFraction)
			if typed ~= lastTyped then
				if #typed > #lastTyped then
					deps.audio:play(Tokens.sound.introType)
				end
				lastTyped = typed
				overlay.setSubtitle(typed)
			end
		else
			overlay.setSubtitle(nil)
		end
		if t >= duration then
			self:finish("played")
		end
	end)
	self.stats.stage = "bound"
	trove:add(function()
		RunService:UnbindFromRenderStep(frame)
		if boardParchment and boardParchment.Parent then
			boardParchment.LocalTransparencyModifier = 0
		end
	end)
end

-- Phase drives everything: the intro starts on the intro phase and is torn down the moment the round
-- leaves it, so a server that times out while a client is mid-shot never leaves that client behind.
function IntroCinematicController.bindRound(self: IntroCinematicController)
	local deps = self._deps
	self._trove:add(deps.round.phaseChanged:Connect(function(phase: string)
		if phase == "Cutscene" then
			local snapshot = deps.round.round
			local roundId = (snapshot and snapshot.roundId) or "round"
			self:play(roundId)
		elseif self._session then
			self:finish("phase")
		end
	end))
	-- A respawn mid-intro must not leave a hidden character or a scripted camera behind.
	self._trove:add(Players.LocalPlayer.CharacterAdded:Connect(function()
		if self._session then
			self:finish("respawn")
		end
	end))
end

function IntroCinematicController.destroy(self: IntroCinematicController)
	if self._session then
		pcall(function()
			self._session.trove:destroy()
		end)
		if self._session.overlay then
			self._session.overlay.destroy()
		end
		self._session = nil
	end
	self._trove:destroy()
end

return IntroCinematicController
