--!strict
-- Discovery and victory presentation (MASTER_SPEC 15 "Discovery/victory", STATE_MACHINES 7):
-- reveal = final-cover spiral + positional chime + glow + short camera framing (static cut under
-- reduced motion); claim = brief gameplay input lock, winner announcement; rewards/results modal
-- as a clean Round Complete recap (winner, reward, CONTINUE) counting up only after RewardsCommitted.
--
-- The notices themselves (THE EGG IS UNCOVERED!, Soryn has the Egg!, EGG RETURNED!) are the server's
-- announcements on the AnnouncementBanner; this controller only presents the moments around them:
--   reveal    music dip, a golden ripple across the nest, gold light rising from the Egg, a small FOV
--             punch, the existing spiral/glow/framing;
--   carry     a gold highlight and trail on the carrier for everyone, a gold edge glow for the carrier;
--   return    confetti for the party; the carrier's camera eases toward the hand-over, everyone else
--             sees a burst and a ripple there; the Round Complete card opens after this short beat
--             (never more than RETURN_BEAT_MAX seconds; the server flow is not delayed at all).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Tokens = require(Shared.Design.Tokens)
local Feedback = require(script.Parent.Parent.UI.Feedback)
local Motion = require(Shared.Design.Motion)
local Button = require(script.Parent.Parent.UI.Components.Button)
local Fit = require(script.Parent.Parent.UI.Components.Fit)
local Depth = require(script.Parent.Parent.UI.Components.Depth)
local Icons = require(script.Parent.Parent.UI.Components.Icons)
local Confetti = require(script.Parent.Parent.UI.Components.Confetti)
local SafeArea = require(script.Parent.Parent.UI.SafeArea)
local ChapterLayout = require(Shared.Domain.ChapterLayout)

local VictoryController = {}
VictoryController.__index = VictoryController

export type VictoryController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_trove: Trove.Trove,
		_carrierGlowRemove: (() -> ())?,
		_resultsNotBefore: number,
		_beatToken: number,
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
	celebration: any?,
}): VictoryController
	local self = setmetatable({
		_deps = deps,
		_carrierGlowRemove = nil,
		_resultsNotBefore = 0,
		_beatToken = 0,
		_trove = Trove.new(),
		stats = { reveals = 0, victories = 0, results = 0 },
	}, VictoryController)
	self._trove:add(deps.round.eggRevealed:Connect(function(payload)
		self:onRevealed(payload)
	end))
	self._trove:add(deps.net:on("EggCarried", function(payload)
		self:onCarried(payload)
	end))
	self._trove:add(deps.net:on("EggDropped", function(payload)
		self:onDropped(payload)
	end))
	self._trove:add(deps.round.victory:Connect(function(payload)
		self:onVictory(payload)
	end))
	self._trove:add(deps.round.results:Connect(function(payload)
		self:onResults(payload)
	end))
	self._trove:add(deps.round.phaseChanged:Connect(function(phase)
		if phase == "Returning" or phase == "Abandoned" or phase == "Cutscene" then
			self:_clearCarrierGlow()
		end
	end))
	return self
end

-- The return beat before the Round Complete card: long enough for the confetti and the camera ease
-- to read, never longer than RETURN_BEAT_MAX.
VictoryController.RETURN_BEAT_SECONDS = 1.3
VictoryController.RETURN_BEAT_MAX = 1.5

function VictoryController._clearCarrierGlow(self: VictoryController)
	if self._carrierGlowRemove then
		self._carrierGlowRemove()
		self._carrierGlowRemove = nil
	end
end

-- Reveal cue: spiral, chime, glow, ripple, rising light, camera framing (or static cut).
function VictoryController.onRevealed(self: VictoryController, payload: { [string]: any })
	local deps = self._deps
	self.stats.reveals += 1
	local position = Vector3.new(payload.x, payload.y, payload.z)
	deps.pile:revealSpiral(position, payload.coverCells or {})
	local eggPart = workspace:FindFirstChild("SFE_Chapter1") and workspace.SFE_Chapter1:FindFirstChild("SFE_Egg")
	deps.audio:play(Tokens.sound.eggChime, { at = eggPart })
	deps.haptics:pulse(0.7, 0.2)
	-- The objective moves on with the phase (it kept reading "Gather 25 feathers" under the reveal).
	deps.hud:setObjective("Grab the Egg!", "It's glowing gold in the nest - hold Interact on it")
	-- The notice is the server's announcement (one notice for the reveal, not a toast as well).
	local celebration = deps.celebration
	if celebration then
		local pile = deps.round.pile
		local nestRadius = if pile and pile.width and pile.cellSize then pile.width * pile.cellSize * 0.55 else 16
		celebration:musicDip(2.2, 0.65)
		celebration:goldenRipple(position, math.max(10, nestRadius))
		celebration:burst(position + Vector3.new(0, 1, 0), "gold", 1.3)
		celebration:cameraPunch(0.45, 0.5)
	end
	if eggPart then
		local highlight = Instance.new("Highlight")
		highlight.Name = "SFE_EggGlow"
		highlight.FillColor = Tokens.color.straw
		highlight.FillTransparency = 0.7
		highlight.OutlineColor = Tokens.color.goldLight
		highlight.Parent = eggPart
		self:_burst(position)
		self:_idle(eggPart :: BasePart)
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
			-- A short push in on the Egg, then the field of view eases back with the hand-off.
			local fov = camera.FieldOfView
			TweenService
				:Create(camera, TweenInfo.new(seconds * 0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { FieldOfView = fov - 12 })
				:Play()
			tween.Completed:Once(function()
				task.wait(seconds * 0.5)
				TweenService:Create(camera, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { FieldOfView = fov })
					:Play()
				camera.CameraType = Enum.CameraType.Custom
			end)
		end
		local _ = from
	end
end

-- The reveal flash: a gold sphere of light that swells from the Egg and fades in under half a second.
function VictoryController._burst(self: VictoryController, position: Vector3)
	if self._deps.accessibility:reducedMotion() then
		return
	end
	local flash = Instance.new("Part")
	flash.Name = "SFE_EggBurst"
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(1, 1, 1)
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 226, 150)
	flash.Transparency = 0.15
	flash.CFrame = CFrame.new(position + Vector3.new(0, 1, 0))
	flash.Parent = workspace
	local tween = TweenService:Create(
		flash,
		TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(16, 16, 16), Transparency = 1 }
	)
	tween:Play()
	tween.Completed:Once(function()
		flash:Destroy()
	end)
	self._deps.vfx:burst("sparkle", position + Vector3.new(0, 1.5, 0), 2)
end

-- While the Egg waits to be claimed it bobs and turns slowly; the loop ends the moment the server
-- picks it up (unanchored for the carry weld) or removes it.
function VictoryController._idle(self: VictoryController, egg: BasePart)
	if self._deps.accessibility:reducedMotion() then
		return
	end
	local base = egg.CFrame
	local started = os.clock()
	task.spawn(function()
		while egg.Parent and egg.Anchored do
			local t = os.clock() - started
			egg.CFrame = base * CFrame.new(0, math.sin(t * 1.6) * 0.16 + 0.1, 0) * CFrame.Angles(0, t * 0.55, 0)
			RunService.Heartbeat:Wait()
		end
	end)
end

-- Someone picked the Egg up: the carrier glows for everyone and the banner says where it goes.
function VictoryController.onCarried(self: VictoryController, payload: { [string]: any })
	local deps = self._deps
	local isMe = payload.carrierUserId == Players.LocalPlayer.UserId
	if isMe then
		deps.hud:setObjective("Bring the Egg to the Farmer", "He is waiting between the barn and the nest")
	else
		-- "<Name> has the Egg!" is the announcement; the objective says what to do about it, so the
		-- same words are not on screen twice.
		deps.hud:setObjective("Follow " .. tostring(payload.carrierName), "They are taking the Egg to the Farmer")
	end
	deps.audio:play(Tokens.sound.eggChime)
	self:_clearCarrierGlow()
	local carrier = Players:GetPlayerByUserId(payload.carrierUserId)
	local character = carrier and carrier.Character
	local celebration = deps.celebration
	if character and celebration then
		self._carrierGlowRemove = celebration:carrierGlow(character)
	elseif character then
		local highlight = Instance.new("Highlight")
		highlight.Name = "SFE_CarrierGlow"
		highlight.FillColor = Tokens.color.goldLight
		highlight.FillTransparency = 0.75
		highlight.OutlineColor = Tokens.color.gold
		highlight.Parent = character
		self._carrierGlowRemove = function()
			highlight:Destroy()
		end
	end
	if isMe and celebration then
		celebration:screenFlash("gold")
	end
end

function VictoryController.onDropped(self: VictoryController, _payload: { [string]: any })
	local deps = self._deps
	self:_clearCarrierGlow()
	-- One notice: the objective banner says it was dropped and what to do (it used to be a toast too).
	deps.hud:setObjective("The Egg was dropped!", "Hold Interact on the Egg before anyone else")
end

-- The Egg is home: input lock for inputLockSeconds, the victory stem, and the return beat. The
-- "EGG RETURNED!" notice is the server's announcement; there is no local banner any more.
function VictoryController.onVictory(self: VictoryController, payload: { [string]: any })
	local deps = self._deps
	self.stats.victories += 1
	self:_clearCarrierGlow()
	deps.input:setSuspended(true)
	deps.audio:play(Tokens.sound.victoryStem)
	deps.haptics:pulse(1, 0.25)
	local isMe = payload.finderUserId == Players.LocalPlayer.UserId
	local text = if isMe then "You found the Egg!" else (tostring(payload.finderName) .. " found the Egg!")
	deps.hud:setObjective(text, "Rewards on the way")
	self._resultsNotBefore = os.clock() + VictoryController.RETURN_BEAT_SECONDS
	self._beatToken += 1
	local token = self._beatToken
	task.delay(deps.config.round.discoverySequence.inputLockSeconds, function()
		deps.input:setSuspended(deps.modals:isBlocking())
	end)

	local celebration = deps.celebration
	if not celebration then
		deps.camera:impulse(0.2)
		Confetti.burst(deps.hud.stage, {
			origin = UDim2.fromScale(0.5, 0.4),
			count = 40,
			spread = 260,
			motion = deps.accessibility:motionSettings(),
			tier = deps.quality and deps.quality:tier() or nil,
			zIndex = Tokens.zIndex.toast + 2,
		})
		return
	end
	-- Where the Egg was handed over: the Farmer, or (a chapter without one) where it was claimed.
	local layout = payload.chapter and (ChapterLayout :: any)[payload.chapter]
	local point: Vector3? = if layout and layout.farmer then layout.farmer else deps.round.eggPosition
	celebration:confetti(UDim2.fromScale(0.5, 0.3), 48)
	if point then
		celebration:burst(point + Vector3.new(0, 2, 0), "gold", 1.4)
		celebration:goldenRipple(point, 12)
	end
	if isMe then
		celebration:screenFlash("gold")
		self:_returnCamera(point, token)
	end
end

-- The carrier's slow beat: the camera eases toward the carrier and the hand-over point for ~0.6 s and
-- hands control back when the card opens. Reduced motion keeps the player's camera where it is.
function VictoryController._returnCamera(self: VictoryController, point: Vector3?, token: number)
	local deps = self._deps
	if deps.accessibility:reducedMotion() then
		return
	end
	local camera = workspace.CurrentCamera
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not camera or not root or not root:IsA("BasePart") then
		return
	end
	local focus = if point then root.Position:Lerp(point, 0.5) + Vector3.new(0, 2.5, 0) else root.Position + Vector3.new(0, 2.5, 0)
	local from = camera.CFrame
	local away = from.Position - focus
	local flat = Vector3.new(away.X, 0, away.Z)
	local direction = if flat.Magnitude > 0.1 then flat.Unit else -root.CFrame.LookVector
	local target = CFrame.lookAt(focus + direction * 11 + Vector3.new(0, 4.5, 0), focus)
	camera.CameraType = Enum.CameraType.Scriptable
	TweenService:Create(camera, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { CFrame = target }):Play()
	task.delay(VictoryController.RETURN_BEAT_MAX, function()
		if self._beatToken == token and camera.CameraType == Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Custom
		end
	end)
end

-- The results arrive right behind the victory (the commit is synchronous); the card waits out what is
-- left of the return beat, capped, and never opens after the party has been sent home.
function VictoryController.onResults(self: VictoryController, payload: { [string]: any })
	local deps = self._deps
	self.stats.results += 1
	local waitSeconds = math.clamp(self._resultsNotBefore - os.clock(), 0, VictoryController.RETURN_BEAT_MAX)
	if waitSeconds <= 0.03 then
		self:_openResults(payload)
		return
	end
	task.delay(waitSeconds, function()
		local phase = deps.round:phase()
		if phase == nil or phase == "Returning" or phase == "Abandoned" then
			return
		end
		self:_openResults(payload)
	end)
end

-- Round Complete recap (owner, 17 Sep 2026: "a clean, premium recap showing only the winner, reward
-- and primary continue action"). One compact dark-kit card: the ROUND COMPLETE title, the winner's
-- headshot and name (or "No winner"), the reward this player banked (Gems with the finder bonus
-- included, and Tokens when any), and one green CONTINUE that sends the same ResultsAction the old
-- primary "Search again" button sent. The reward counts up only after RewardsCommitted (which
-- precedes ResultsProjection), and the card closes itself when the server returns the party.
function VictoryController._openResults(self: VictoryController, payload: { [string]: any })
	local deps = self._deps
	local minimumTap = SafeArea.minimumTapTarget(deps.modals.gui, deps.config)
	deps.modals:open("results", deps.modals.Priority.Results, true, function(container, api)
		local cleanups: { any } = {}
		local alive = true
		local motion = deps.accessibility:motionSettings()
		local z = container.ZIndex + 1

		-- A Scale builder: one root frame, no list, no scrolling.
		container.AutomaticCanvasSize = Enum.AutomaticSize.None
		container.CanvasSize = UDim2.fromScale(0, 0)
		container.ScrollingEnabled = false
		container.ScrollBarThickness = 0
		local listLayout = container:FindFirstChildOfClass("UIListLayout")
		if listLayout then
			listLayout:Destroy()
		end
		local listPadding = container:FindFirstChildOfClass("UIPadding")
		if listPadding then
			listPadding:Destroy()
		end
		-- The single action is CONTINUE; the corner X would be a second, silent one.
		api.shell.closeButton.Visible = false
		local root = Fit.frame(container, "Recap", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), z)

		-- Winner: a round headshot in a gold ring, a small caption and the name.
		local finderId = tonumber(payload.finderUserId)
		local hasWinner = finderId ~= nil and finderId > 0
		local isFinder = payload.isFinder == true
		local ring = Instance.new("Frame")
		ring.Name = "Avatar"
		ring.AnchorPoint = Vector2.new(0.5, 0.5)
		ring.Position = UDim2.fromScale(0.5, 0.25)
		ring.Size = UDim2.fromScale(0, 0.36)
		ring.BackgroundColor3 = Tokens.color.panelDeep
		ring.BorderSizePixel = 0
		ring.ZIndex = z + 1
		Fit.aspect(ring, 1, Enum.DominantAxis.Height)
		Fit.corner(ring, 0.5)
		Depth.keyline(ring, Tokens.depth.keyline, if hasWinner then Tokens.color.gold else Tokens.color.outline)
		ring.Parent = root
		local headshot = Instance.new("ImageLabel")
		headshot.Name = "Headshot"
		headshot.AnchorPoint = Vector2.new(0.5, 0.5)
		headshot.Position = UDim2.fromScale(0.5, 0.5)
		headshot.Size = UDim2.fromScale(0.92, 0.92)
		headshot.BackgroundTransparency = 1
		headshot.ZIndex = z + 2
		Fit.corner(headshot, 0.5)
		headshot.Parent = ring
		if hasWinner then
			task.spawn(function()
				local ok, image = pcall(function()
					return Players:GetUserThumbnailAsync(finderId :: number, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size180x180)
				end)
				if ok and alive and headshot.Parent then
					headshot.Image = image
				end
			end)
		else
			Fit.text(ring, "Nobody", "?", {
				font = Tokens.typography.display.font,
				color = Tokens.color.inkMuted,
				max = 90,
				outline = 3,
				outlineColor = Tokens.color.outline,
				zIndex = z + 2,
				size = UDim2.fromScale(0.6, 0.6),
				position = UDim2.fromScale(0.5, 0.5),
				anchor = Vector2.new(0.5, 0.5),
			})
		end
		Fit.text(root, "Caption", if not hasWinner then "THE EGG WAS NOT FOUND" elseif isFinder then "YOU FOUND THE EGG" else "WINNER", {
			font = Tokens.typography.label.font,
			color = if hasWinner then Tokens.color.gold else Tokens.color.inkMuted,
			max = 26,
			outline = 2,
			outlineColor = Tokens.color.outline,
			zIndex = z + 1,
			size = UDim2.fromScale(0.8, 0.07),
			position = UDim2.fromScale(0.5, 0.465),
			anchor = Vector2.new(0.5, 0),
		})
		local winnerName = if not hasWinner
			then "No winner"
			elseif isFinder then Players.LocalPlayer.DisplayName
			else tostring(payload.finderName or "A forager")
		local nameLabel = Fit.text(root, "Winner", winnerName, {
			font = Tokens.typography.display.font,
			color = Tokens.color.featherWhite,
			max = 54,
			outline = 3,
			outlineColor = Tokens.color.outline,
			zIndex = z + 1,
			size = UDim2.fromScale(0.86, 0.12),
			position = UDim2.fromScale(0.5, 0.54),
			anchor = Vector2.new(0.5, 0),
			wrap = false,
		})
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd

		-- Reward: one slate pill with the gem and the amount this player banked.
		local rewards = payload.rewards or {}
		local gems = (rewards.gems or 0) + (rewards.finderBonusGems or 0)
		local tokens = rewards.eventTokens or 0
		local rewardPill = Instance.new("Frame")
		rewardPill.Name = "Reward"
		rewardPill.AnchorPoint = Vector2.new(0.5, 0)
		rewardPill.Position = UDim2.fromScale(0.5, 0.69)
		rewardPill.Size = UDim2.fromScale(0.6, 0.11)
		rewardPill.BorderSizePixel = 0
		rewardPill.ZIndex = z + 1
		Depth.panel(rewardPill, Tokens.color.surface)
		Fit.corner(rewardPill, 0.5)
		rewardPill.Parent = root
		local gemArt = Fit.image(rewardPill, "hud.gem", {
			size = UDim2.fromScale(0, 0.74),
			position = UDim2.fromScale(0.14, 0.5),
			zIndex = z + 2,
			name = "Gem",
		})
		if gemArt then
			Fit.aspect(gemArt, 1, Enum.DominantAxis.Height)
		else
			local glyph = Icons.gem(rewardPill, 10, { zIndex = z + 2 })
			glyph.AnchorPoint = Vector2.new(0.5, 0.5)
			glyph.Position = UDim2.fromScale(0.14, 0.5)
			glyph.Size = UDim2.fromScale(0, 0.7)
			Fit.aspect(glyph, 1, Enum.DominantAxis.Height)
		end
		local amount = Fit.text(rewardPill, "Amount", "+0 Gems", {
			font = Tokens.typography.numeral.font,
			color = Tokens.color.featherWhite,
			max = 40,
			outline = 2.4,
			outlineColor = Tokens.color.outline,
			zIndex = z + 2,
			size = UDim2.fromScale(0.68, 0.66),
			position = UDim2.fromScale(0.27, 0.17),
			wrap = false,
		})
		local function rewardText(fraction: number): string
			local text = string.format("+%d Gems", math.floor(gems * fraction + 0.5))
			if tokens > 0 then
				text ..= string.format("  +%d Tokens", math.floor(tokens * fraction + 0.5))
			end
			return text
		end
		if gems <= 0 and tokens <= 0 then
			amount.Text = "No reward this time"
		elseif motion.reducedMotion then
			amount.Text = rewardText(1)
		else
			local duration = Motion.duration("slow", motion) * 2.5
			local started = os.clock()
			local thread = task.spawn(function()
				while alive do
					local t = math.clamp((os.clock() - started) / duration, 0, 1)
					amount.Text = rewardText(1 - (1 - t) ^ 3)
					if t >= 1 then
						break
					end
					deps.audio:play(Tokens.sound.rewardTick)
					task.wait(0.08)
				end
			end)
			table.insert(cleanups, function()
				if coroutine.status(thread) ~= "dead" then
					task.cancel(thread)
				end
			end)
		end

		-- The one action.
		local continueHandle = Button.build(root, {
			text = "CONTINUE",
			variant = "success",
			minimumTapTarget = minimumTap,
			motion = motion,
			size = UDim2.fromScale(0.56, 0.13),
			zIndex = z + 1,
			sound = function()
				deps.audio:play(Tokens.sound.uiConfirm)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = function()
				local result = deps.net:request("ResultsAction", { action = "replay" })
				if result.ok then
					api.close()
				elseif result.code == "rate_limited" then
					Feedback.deny("results:rate_limited", "Take a breath...", { tone = "info", silent = true })
				end
			end,
		})
		continueHandle.button.Name = "Continue"
		continueHandle.button.AnchorPoint = Vector2.new(0.5, 1)
		continueHandle.button.Position = UDim2.fromScale(0.5, 0.98)
		Fit.buttonText(continueHandle, 34)
		table.insert(cleanups, continueHandle.destroy)
		api.setInitialFocus(continueHandle.button)

		if hasWinner then
			Confetti.burst(root, {
				origin = UDim2.fromScale(0.5, 0.25),
				count = 26,
				spread = 200,
				motion = motion,
				tier = deps.quality and deps.quality:tier() or nil,
				zIndex = z + 8,
			})
		end
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
			alive = false
			for _, cleanup in ipairs(cleanups) do
				if type(cleanup) == "function" then
					cleanup()
				elseif typeof(cleanup) == "RBXScriptConnection" then
					cleanup:Disconnect()
				end
			end
		end
	end, "Round complete", { compact = true, icon = "header.results" })
end

function VictoryController.destroy(self: VictoryController)
	self._beatToken += 1
	self:_clearCarrierGlow()
	self._trove:destroy()
end

return VictoryController
