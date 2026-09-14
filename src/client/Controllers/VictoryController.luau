--!strict
-- Discovery and victory presentation (MASTER_SPEC 15 "Discovery/victory", STATE_MACHINES 7):
-- reveal = final-cover spiral + positional chime + glow + short camera framing (static cut under
-- reduced motion); claim = brief gameplay input lock, winner announcement; rewards/results modal
-- with separated party reward and finder bonus rows counting up only after RewardsCommitted.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local EconomyMath = require(Shared.EconomyMath)
local Button = require(script.Parent.Parent.UI.Components.Button)
local SafeArea = require(script.Parent.Parent.UI.SafeArea)

local VictoryController = {}
VictoryController.__index = VictoryController

export type VictoryController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_announcement: TextLabel?,
		_trove: Trove.Trove,
		stats: { reveals: number, victories: number, results: number },
	},
	VictoryController
))

function VictoryController.new(deps: {
	net: any,
	round: any,
	pile: any,
	modals: any,
	hud: any,
	input: any,
	audio: any,
	vfx: any,
	camera: any,
	haptics: any,
	accessibility: any,
	config: { [string]: any },
}): VictoryController
	local self = setmetatable(
		{ _deps = deps, _announcement = nil, _trove = Trove.new(), stats = { reveals = 0, victories = 0, results = 0 } },
		VictoryController
	)
	self._trove:add(deps.round.eggRevealed:Connect(function(payload)
		self:onRevealed(payload)
	end))
	self._trove:add(deps.round.victory:Connect(function(payload)
		self:onVictory(payload)
	end))
	self._trove:add(deps.round.results:Connect(function(payload)
		self:onResults(payload)
	end))
	return self
end

-- Reveal cue: spiral, chime, glow, camera framing (or static cut), party toast.
function VictoryController.onRevealed(self: VictoryController, payload: { [string]: any })
	local deps = self._deps
	self.stats.reveals += 1
	local position = Vector3.new(payload.x, payload.y, payload.z)
	deps.pile:revealSpiral(position, payload.coverCells or {})
	local eggPart = workspace:FindFirstChild("SFE_Chapter1") and workspace.SFE_Chapter1:FindFirstChild("SFE_Egg")
	deps.audio:play(Tokens.sound.eggChime, { at = eggPart })
	deps.haptics:pulse(0.7, 0.2)
	deps.hud.toasts:push("The Egg is uncovered!", "success")
	if eggPart then
		local highlight = Instance.new("Highlight")
		highlight.Name = "SFE_EggGlow"
		highlight.FillColor = Tokens.color.straw
		highlight.FillTransparency = 0.6
		highlight.OutlineColor = Tokens.color.cream
		highlight.Parent = eggPart
	end
	-- Camera framing: ease toward the Egg for cameraFocusSeconds, then return control.
	local camera = workspace.CurrentCamera
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if camera and root then
		local seconds = deps.config.round.discoverySequence.cameraFocusSeconds
		local from = camera.CFrame
		local target = CFrame.lookAt(root.Position + Vector3.new(0, 2, 0), position)
		camera.CameraType = Enum.CameraType.Scriptable
		if deps.accessibility:reducedMotion() then
			camera.CFrame = target
			task.delay(seconds * deps.config.polishBudgets.reducedMotionScale, function()
				camera.CameraType = Enum.CameraType.Custom
			end)
		else
			local tween = TweenService:Create(camera, TweenInfo.new(seconds * 0.5, Tokens.motion.easeInOut), { CFrame = target })
			tween:Play()
			tween.Completed:Once(function()
				task.wait(seconds * 0.5)
				camera.CameraType = Enum.CameraType.Custom
			end)
		end
		local _ = from
	end
end

-- Winner announcement with gameplay input lock for inputLockSeconds.
function VictoryController.onVictory(self: VictoryController, payload: { [string]: any })
	local deps = self._deps
	self.stats.victories += 1
	deps.input:setSuspended(true)
	deps.audio:play(Tokens.sound.victoryStem)
	deps.haptics:pulse(1, 0.25)
	deps.camera:impulse(0.2)
	deps.vfx:burst(
		"sparkle",
		(workspace.CurrentCamera and workspace.CurrentCamera.CFrame.Position or Vector3.zero) + Vector3.new(0, 1, -4),
		deps.config.round.discoverySequence.confettiSeconds
	)
	local isMe = payload.finderUserId == Players.LocalPlayer.UserId
	local text = if isMe then "You found the Egg!" else (tostring(payload.finderName) .. " found the Egg!")
	local label = Instance.new("TextLabel")
	label.Name = "Announcement"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.4)
	label.Size = UDim2.new(0.8, 0, 0, 80)
	label.BackgroundTransparency = 1
	label.Font = Tokens.typography.display.font
	label.TextSize = Tokens.typography.display.size
	label.TextColor3 = Tokens.color.cream
	label.TextStrokeTransparency = 0.3
	label.TextStrokeColor3 = Tokens.color.emberDeep
	label.Text = text
	label.TextTransparency = 1
	label.ZIndex = Tokens.zIndex.toast
	label.Parent = deps.hud.stage
	local scale = Instance.new("UIScale")
	scale.Scale = 0.8
	scale.Parent = label
	local motion = deps.accessibility:motionSettings()
	TweenService:Create(label, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeOut), { TextTransparency = 0 }):Play()
	TweenService:Create(scale, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeBack), { Scale = 1 }):Play()
	self._announcement = label
	task.delay(deps.config.round.discoverySequence.inputLockSeconds, function()
		deps.input:setSuspended(deps.modals:isBlocking())
	end)
	task.delay(deps.config.round.discoverySequence.winnerAnnouncementSeconds, function()
		if label.Parent then
			TweenService:Create(label, TweenInfo.new(Motion.duration("quick", motion)), { TextTransparency = 1 }):Play()
		end
	end)
end

-- Results modal: rows count up from zero to the committed values; Replay / Lobby actions.
function VictoryController.onResults(self: VictoryController, payload: { [string]: any })
	local deps = self._deps
	self.stats.results += 1
	if self._announcement then
		self._announcement:Destroy()
		self._announcement = nil
	end
	local minimumTap = SafeArea.minimumTapTarget(deps.modals.gui, deps.config)
	deps.modals:open("results", deps.modals.Priority.Results, true, function(container, api)
		local cleanups: { any } = {}
		local isFinder = payload.isFinder == true
		local function line(order: number, text: string, color: Color3?, size: number?): TextLabel
			local label = Instance.new("TextLabel")
			label.LayoutOrder = order
			label.Size = UDim2.new(1, 0, 0, (size or Tokens.typography.body.size) + Tokens.spacing.sm)
			label.BackgroundTransparency = 1
			label.Font = Tokens.typography.body.font
			label.TextSize = size or Tokens.typography.body.size
			label.TextColor3 = color or Tokens.color.inkStrong
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.Text = text
			label.Parent = container
			return label
		end
		local time = payload.elapsedMs or 0
		local totalSeconds = math.floor(time / 1000)
		line(
			1,
			string.format(
				"%s  -  %s  -  %s",
				if isFinder then "You found the Egg" else (tostring(payload.finderName) .. " found the Egg"),
				"Sunlit Henhouse",
				tostring(payload.difficulty)
			),
			Tokens.color.inkMuted
		)
		line(
			2,
			string.format(
				"Time %02d:%02d.%02d%s",
				math.floor(totalSeconds / 60),
				totalSeconds % 60,
				math.floor((time % 1000) / 10),
				if payload.newBest then "   NEW BEST" else ""
			),
			if payload.newBest then Tokens.color.leafDeep else nil,
			Tokens.typography.heading.size
		)
		local contribution = payload.contribution or {}
		line(
			3,
			string.format(
				"Your contribution: %d feathers, %d patches cleared, %s cash",
				contribution.feathersCollected or 0,
				contribution.cellsRemoved or 0,
				EconomyMath.formatCents(payload.roundCashCents or 0)
			),
			Tokens.color.inkMuted
		)
		local rewards = payload.rewards or {}
		local partyRow = line(4, "Party reward: 0 Gems", Tokens.color.gemDeep, Tokens.typography.heading.size)
		local bonusRow = if (rewards.finderBonusGems or 0) > 0
			then line(5, "Finder bonus: 0 Gems", Tokens.color.ember, Tokens.typography.heading.size)
			else nil
		if payload.unlocked and #payload.unlocked > 0 then
			local names = {}
			for _, key in ipairs(payload.unlocked) do
				table.insert(
					names,
					if key == "chapter1:hard" then "Sunlit Henhouse - Hard" elseif key == "chapter2:normal" then "Moonlit Cellar" else key
				)
			end
			line(6, "Unlocked: " .. table.concat(names, ", "), Tokens.color.skyDeep)
		end
		-- Count-ups only after the server committed (RewardsCommitted precedes ResultsProjection).
		local motion = deps.accessibility:motionSettings()
		local duration = Motion.duration("slow", motion) * 3
		local started = os.clock()
		local thread = task.spawn(function()
			while true do
				local t = math.clamp((os.clock() - started) / duration, 0, 1)
				local eased = 1 - (1 - t) ^ 3
				partyRow.Text = string.format(
					"Party reward: %d Gems%s",
					math.floor((rewards.gems or 0) * eased + 0.5),
					if (rewards.eventTokens or 0) > 0
						then string.format("  +%d Tokens", math.floor(rewards.eventTokens * eased + 0.5))
						else ""
				)
				if bonusRow then
					bonusRow.Text = string.format("Finder bonus: %d Gems", math.floor((rewards.finderBonusGems or 0) * eased + 0.5))
				end
				if t >= 1 then
					break
				end
				deps.audio:play(Tokens.sound.rewardTick)
				task.wait(0.06)
			end
		end)
		table.insert(cleanups, function()
			task.cancel(thread)
		end)
		local function act(action: string)
			local result = deps.net:request("ResultsAction", { action = action })
			if result.ok then
				api.close()
			elseif result.code == "rate_limited" then
				deps.hud.toasts:push("Take a breath...", "info")
			end
		end
		local replay, replayCleanup = Button.create(container, {
			text = "Search again",
			variant = "primary",
			minimumTapTarget = minimumTap,
			motion = motion,
			size = UDim2.new(1, 0, 0, minimumTap),
			onActivated = function()
				act("replay")
			end,
		})
		replay.LayoutOrder = 10
		table.insert(cleanups, replayCleanup)
		local lobby, lobbyCleanup = Button.create(container, {
			text = "Back to the lobby",
			variant = "secondary",
			minimumTapTarget = minimumTap,
			motion = motion,
			size = UDim2.new(1, 0, 0, minimumTap),
			onActivated = function()
				act("lobby")
			end,
		})
		lobby.LayoutOrder = 11
		table.insert(cleanups, lobbyCleanup)
		-- Auto-close when the server returns the party (phase Returning).
		table.insert(
			cleanups,
			deps.round.phaseChanged:Connect(function(phase)
				if phase == "Returning" or phase == "Abandoned" then
					api.close()
				end
			end)
		)
		return function()
			for _, cleanup in ipairs(cleanups) do
				if type(cleanup) == "function" then
					cleanup()
				elseif type(cleanup) == "table" and cleanup.Disconnect then
					cleanup:Disconnect()
				end
			end
		end
	end, "Round complete")
end

function VictoryController.destroy(self: VictoryController)
	if self._announcement then
		self._announcement:Destroy()
	end
	self._trove:destroy()
end

return VictoryController
