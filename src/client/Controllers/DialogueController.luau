--!strict
-- NPC dialogue in the reference style: the camera eases in to frame the speaker, the rig gets an
-- outline, and a dark translucent box across the bottom types the line out. One press, tap or
-- Cancel closes it; the camera and controls come back exactly as they were.
--
-- Two rules keep a player from getting stuck in here, both learned from spamming the Farmer's prompt:
--
-- 1. **One conversation at a time.** `open` used to begin with "if a box is up, close it and start
--    again". Every press of E on the prompt therefore tore a session down and built another, and the
--    new one read its "put the camera back like this" baseline off a camera that the old one had left
--    Scriptable and was still tweening. So it saved Scriptable as the thing to restore, and restored
--    it - camera dead, mouse locked, no way out. `open` now refuses while a conversation is live.
--
-- 2. **The camera baseline outlives the session.** It is taken the first time this controller makes
--    the camera Scriptable and released only once the camera is genuinely handed back, so a reopen
--    during the return tween inherits the real gameplay camera rather than a frame of the animation.
--
-- The press that opens a box also cannot close it: the close inputs arm a moment later, or the E that
-- triggered the prompt would be read again here on the same press and shut the box instantly.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Trove = require(Shared.Util.Trove)

local DialogueController = {}
DialogueController.__index = DialogueController

export type DialogueController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_trove: any,
		_session: any?,
		_cameraBaseline: { type: Enum.CameraType, cframe: CFrame }?,
		_restoreTween: Tween?,
		stats: { opens: number, closes: number, refused: number, recovered: number },
	},
	DialogueController
))

local TYPE_SECONDS_PER_CHARACTER = 0.028
local MIN_SECONDS = 1.2
-- How long after the box appears before a press can dismiss it. Long enough that the press which
-- opened it is finished, short enough that nobody notices they have to wait.
local INPUT_ARM_SECONDS = 0.18
-- If the hand-back tween never reports finishing, the camera is given back anyway this long after.
local RESTORE_BACKSTOP_SECONDS = 1.5

function DialogueController.new(deps: {
	input: any,
	modals: any,
	hud: any,
	audio: any,
	accessibility: any,
	config: { [string]: any },
}): DialogueController
	local self = setmetatable({
		_deps = deps,
		_trove = Trove.new(),
		_session = nil,
		_cameraBaseline = nil,
		_restoreTween = nil,
		stats = { opens = 0, closes = 0, refused = 0, recovered = 0 },
	}, DialogueController)
	self._trove:add(deps.input.actionBegan:Connect(function(action)
		if self:_armed() and (action == "Cancel" or action == "Back") then
			self:close()
		end
	end))
	-- Gameplay actions are suspended while the box is up, so E / A / a click are read here directly.
	self._trove:add(UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not self:_armed() then
			return
		end
		if
			input.KeyCode == Enum.KeyCode.E
			or input.KeyCode == Enum.KeyCode.ButtonA
			or input.KeyCode == Enum.KeyCode.Space
			or input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			self:close()
		end
	end))
	-- A respawn must not leave the camera framing an NPC the player is no longer standing next to.
	self._trove:add(Players.LocalPlayer.CharacterAdded:Connect(function()
		if self._session then
			self:close()
		end
	end))
	return self
end

function DialogueController.isOpen(self: DialogueController): boolean
	return self._session ~= nil
end

-- True once the open press has passed and a close input should be taken seriously.
function DialogueController._armed(self: DialogueController): boolean
	local session = self._session
	return session ~= nil and os.clock() >= session.armedAt
end

-- Frames `model` (its Head when it has one) and types `line`. `options.seconds` holds the box for
-- that long after the reveal before it closes itself (nil = wait for a press).
function DialogueController.open(
	self: DialogueController,
	model: Model,
	line: string,
	options: { seconds: number?, name: string? }?
): boolean
	-- The debounce. A second conversation cannot begin on top of a live one: the press is simply
	-- ignored, which is what stops a spammed prompt from cycling this controller through states it was
	-- never meant to be in.
	if self._session then
		self.stats.refused += 1
		return false
	end
	local opts = (options or {}) :: any
	local deps = self._deps
	local player = Players.LocalPlayer
	local camera = workspace.CurrentCamera
	if not (player and camera) then
		return false
	end
	local motion = deps.accessibility:motionSettings()
	local session = { trove = Trove.new(), model = model, armedAt = os.clock() + INPUT_ARM_SECONDS }
	self._session = session
	self.stats.opens += 1
	deps.audio:play(Tokens.sound.uiOpen)

	-- Controls: gameplay input pauses (Cancel / press still reach us), the cursor is free, HUD hides.
	deps.input:setSuspended(true)
	deps.modals:setExternalUnlock(true)
	local hudGui = deps.hud.gui
	local hudWasEnabled = hudGui.Enabled
	hudGui.Enabled = false
	session.trove:add(function()
		hudGui.Enabled = hudWasEnabled
		deps.modals:setExternalUnlock(false)
		deps.input:setSuspended(false)
	end)

	-- Outline the speaker.
	local highlight = Instance.new("Highlight")
	highlight.Name = "SFE_DialogueOutline"
	highlight.FillTransparency = 1
	highlight.OutlineColor = Tokens.color.featherWhite
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = model
	highlight.Parent = model
	session.trove:add(highlight)

	-- Camera: a close three-quarter shot from the front, slightly above the head.
	local head = model:FindFirstChild("Head")
	local pivot = model:GetPivot()
	local focus = if head and head:IsA("BasePart") then head.Position else pivot.Position + Vector3.new(0, 2, 0)
	local forward = pivot.LookVector
	local right = pivot.RightVector
	local eye = focus + forward * 6.5 + right * 2.2 + Vector3.new(0, 1.2, 0)
	local target = CFrame.lookAt(eye, focus + Vector3.new(0, -0.6, 0))
	-- A hand-back may still be running from the conversation before this one. Stop it, and keep the
	-- baseline it was restoring towards: that is the real gameplay camera. Reading the camera again
	-- here would capture a frame of that animation, and its CameraType is Scriptable because we are
	-- the ones holding it - which is how this used to restore Scriptable and strand the player.
	if self._restoreTween then
		self._restoreTween:Cancel()
		self._restoreTween = nil
	end
	if not self._cameraBaseline then
		self._cameraBaseline = { type = camera.CameraType, cframe = camera.CFrame }
	end
	local baseline = self._cameraBaseline :: { type: Enum.CameraType, cframe: CFrame }
	camera.CameraType = Enum.CameraType.Scriptable
	local seconds = if motion.reducedMotion then 0.05 else 0.4
	TweenService:Create(camera, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = target }):Play()
	session.trove:add(function()
		local back = TweenService:Create(
			camera,
			TweenInfo.new(if motion.reducedMotion then 0.05 else 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ CFrame = baseline.cframe }
		)
		self._restoreTween = back
		local function release()
			if self._restoreTween ~= back then
				return -- a newer conversation owns the camera; it will hand it back itself
			end
			self._restoreTween = nil
			if self._session then
				return
			end
			camera.CameraType = baseline.type
			self._cameraBaseline = nil
		end
		back.Completed:Once(release)
		back:Play()
		-- Completed does not fire on a cancelled tween, and a cancelled-then-abandoned hand-back would
		-- leave the camera Scriptable with nobody left to give it back. This is the floor under that.
		task.delay(RESTORE_BACKSTOP_SECONDS, function()
			if self._restoreTween == back or (self._cameraBaseline ~= nil and self._session == nil) then
				if self._session == nil and self._cameraBaseline ~= nil then
					self.stats.recovered += 1
					camera.CameraType = (self._cameraBaseline :: any).type
					self._cameraBaseline = nil
				end
				if self._restoreTween == back then
					self._restoreTween = nil
				end
			end
		end)
	end)

	-- Dialogue box across the bottom.
	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_Dialogue"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = Tokens.zIndex.modal - 1
	gui.Parent = player:WaitForChild("PlayerGui")
	session.trove:add(gui)
	local catcher = Instance.new("TextButton")
	catcher.Name = "Catcher"
	catcher.Text = ""
	catcher.BackgroundTransparency = 1
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.ZIndex = 1
	catcher.Parent = gui
	session.trove:add(catcher.Activated:Connect(function()
		if self:_armed() then
			self:close()
		end
	end))
	local box = Instance.new("Frame")
	box.Name = "Box"
	box.AnchorPoint = Vector2.new(0.5, 1)
	box.Position = UDim2.new(0.5, 0, 1, -Tokens.layout.safeAreaPaddingPx * 3)
	box.Size = UDim2.new(0.72, 0, 0, 96)
	box.BackgroundColor3 = Color3.fromRGB(22, 20, 18)
	box.BackgroundTransparency = 0.28
	box.BorderSizePixel = 0
	box.ZIndex = 2
	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
	boxCorner.Parent = box
	local boxStroke = Instance.new("UIStroke")
	boxStroke.Thickness = 2
	boxStroke.Color = Color3.fromRGB(70, 62, 54)
	boxStroke.Transparency = 0.2
	boxStroke.Parent = box
	local boxScale = Instance.new("UIScale")
	boxScale.Scale = 0.92
	boxScale.Parent = box
	box.Parent = gui
	local speaker = Instance.new("TextLabel")
	speaker.Name = "Speaker"
	speaker.BackgroundTransparency = 1
	speaker.AnchorPoint = Vector2.new(0, 1)
	speaker.Position = UDim2.fromOffset(Tokens.spacing.lg, 2)
	speaker.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 6)
	speaker.Font = Enum.Font.FredokaOne
	speaker.TextSize = Tokens.typography.caption.size + 2
	speaker.TextColor3 = Tokens.color.goldLight
	speaker.TextXAlignment = Enum.TextXAlignment.Left
	speaker.TextStrokeTransparency = 0.4
	speaker.Text = opts.name or (model.Name ~= "" and model.Name or "")
	speaker.ZIndex = 3
	speaker.Parent = box
	local text = Instance.new("TextLabel")
	text.Name = "Line"
	text.BackgroundTransparency = 1
	text.Size = UDim2.new(1, -Tokens.spacing.lg * 2, 1, 0)
	text.Position = UDim2.fromOffset(Tokens.spacing.lg, 0)
	text.Font = Enum.Font.SpecialElite
	text.TextSize = 34
	text.TextScaled = false
	text.TextWrapped = true
	text.TextColor3 = Tokens.color.featherWhite
	text.TextStrokeColor3 = Color3.new(0, 0, 0)
	text.TextStrokeTransparency = 0.15
	text.TextXAlignment = Enum.TextXAlignment.Center
	text.TextYAlignment = Enum.TextYAlignment.Center
	text.Text = line
	text.MaxVisibleGraphemes = 0
	text.ZIndex = 3
	text.Parent = box
	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.BackgroundTransparency = 1
	hint.AnchorPoint = Vector2.new(1, 1)
	hint.Position = UDim2.new(1, -Tokens.spacing.md, 1, -Tokens.spacing.xs)
	hint.Size = UDim2.new(0.5, 0, 0, Tokens.typography.caption.size + 4)
	hint.Font = Tokens.typography.caption.font
	hint.TextSize = Tokens.typography.caption.size
	hint.TextColor3 = Tokens.color.inkMuted
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.Text = if deps.input:mode() == "touch" then "Tap to continue" else "Press E or click to continue"
	hint.TextTransparency = 1
	hint.ZIndex = 3
	hint.Parent = box
	TweenService:Create(boxScale, TweenInfo.new(seconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	-- Typewriter reveal, one grapheme every few milliseconds with a soft tick.
	local total = utf8.len(line) or #line
	local revealSeconds = if motion.reducedMotion then 0 else total * TYPE_SECONDS_PER_CHARACTER
	local started = os.clock()
	local lastShown = 0
	local connection
	connection = RunService.Heartbeat:Connect(function()
		if self._session ~= session then
			return
		end
		local t = if revealSeconds <= 0 then 1 else math.clamp((os.clock() - started) / revealSeconds, 0, 1)
		local shown = math.floor(total * t + 0.5)
		if shown ~= lastShown then
			text.MaxVisibleGraphemes = shown
			if shown > lastShown and shown % 3 == 0 then
				deps.audio:play(Tokens.sound.rewardTick, { pitchVariance = 0.2 })
			end
			lastShown = shown
		end
		if t >= 1 then
			text.MaxVisibleGraphemes = -1
			TweenService:Create(hint, TweenInfo.new(0.25), { TextTransparency = 0.2 }):Play()
			connection:Disconnect()
			if opts.seconds then
				task.delay(math.max(MIN_SECONDS, opts.seconds), function()
					if self._session == session then
						self:close()
					end
				end)
			end
		end
	end)
	session.trove:add(connection)
	return true
end

function DialogueController.close(self: DialogueController)
	local session = self._session
	if not session then
		return
	end
	self._session = nil
	self.stats.closes += 1
	session.trove:destroy()
	self._deps.audio:play(Tokens.sound.uiClose)
end

function DialogueController.destroy(self: DialogueController)
	self:close()
	self._trove:destroy()
end

return DialogueController
