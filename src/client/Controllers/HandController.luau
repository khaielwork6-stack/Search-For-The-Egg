--!strict
-- First-person Hand tool: a viewmodel hand parented to the camera, Primary-action collection with
-- the four-layer feedback envelope (anticipation windup -> authoritative contact -> reward stream /
-- puff / haptic / bag squash -> eased recovery), local cooldown gating from the server's cooldownMs,
-- and touch/gamepad support through InputController. The server decides every yield.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Signal = require(Shared.Util.Signal)
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)

local HandController = {}
HandController.__index = HandController

export type HandController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_hand: Part?,
		_offset: CFrame,
		_swing: number,
		_nextAllowedAt: number,
		_bound: boolean,
		_enabled: boolean,
		collected: any,
		rejected: any,
		_trove: Trove.Trove,
		stats: { sent: number, accepted: number, rejected: number },
	},
	HandController
))

local HAND_OFFSET = CFrame.new(0.95, -0.75, -1.7) * CFrame.Angles(math.rad(-20), math.rad(10), 0)
local RENDER_NAME = "SFE_HandViewmodel"

function HandController.new(deps: {
	net: any,
	round: any,
	input: any,
	pile: any,
	vfx: any,
	audio: any,
	haptics: any,
	camera: any,
	accessibility: any,
	config: { [string]: any },
}): HandController
	local self = setmetatable({
		_deps = deps,
		_hand = nil,
		_offset = HAND_OFFSET,
		_swing = 0,
		_nextAllowedAt = 0,
		_bound = false,
		_enabled = false,
		collected = Signal.new(),
		rejected = Signal.new(),
		_trove = Trove.new(),
		stats = { sent = 0, accepted = 0, rejected = 0 },
	}, HandController)

	self._trove:add(deps.round.phaseChanged:Connect(function(phase)
		local active = phase == "Searching" or phase == "EggRevealed" or phase == "Countdown" or phase == "Cutscene"
		self:setEnabled(active)
	end))
	self._trove:add(deps.input.actionBegan:Connect(function(action)
		if action == "Primary" then
			self:tryCollect()
		end
	end))
	return self
end

local function makeHand(): Part
	local hand = Instance.new("Part")
	hand.Name = "SFE_Hand"
	hand.Anchored = true
	hand.CanCollide = false
	hand.CanQuery = false
	hand.CanTouch = false
	hand.CastShadow = false
	hand.Size = Vector3.new(0.7, 0.35, 1.1)
	hand.Color = Color3.fromRGB(226, 191, 108)
	hand.Material = Enum.Material.SmoothPlastic
	hand:SetAttribute("SFE_Placeholder", "PHASE_6_ART")
	local corner = Instance.new("SpecialMesh")
	corner.MeshType = Enum.MeshType.Sphere
	corner.Scale = Vector3.new(1, 0.7, 1.4)
	corner.Parent = hand
	return hand
end

function HandController.setEnabled(self: HandController, enabled: boolean)
	if enabled == self._enabled then
		return
	end
	self._enabled = enabled
	if enabled then
		self._hand = makeHand()
		self._hand.Parent = workspace.CurrentCamera
		if not self._bound then
			self._bound = true
			RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 2, function(dt)
				self:_render(dt)
			end)
		end
	else
		if self._bound then
			self._bound = false
			RunService:UnbindFromRenderStep(RENDER_NAME)
		end
		if self._hand then
			self._hand:Destroy()
			self._hand = nil
		end
	end
end

function HandController._render(self: HandController, dt: number)
	local camera = workspace.CurrentCamera
	local hand = self._hand
	if not camera or not hand then
		return
	end
	self._swing = math.max(0, self._swing - dt * 4)
	local swing = self._swing * self._deps.accessibility:motionScale()
	local bob = math.sin(os.clock() * 2) * 0.015
	hand.CFrame = camera.CFrame * self._offset * CFrame.new(0, bob - swing * 0.25, -swing * 0.9) * CFrame.Angles(-swing * 0.8, 0, 0)
end

function HandController.canCollect(self: HandController): boolean
	return self._enabled and os.clock() >= self._nextAllowedAt and self._deps.round:phase() == "Searching"
end

-- Sends one collect request aimed from the camera through the screen centre.
-- `aimTarget` (Studio automation only) overrides the camera look direction with a world point.
function HandController.tryCollect(self: HandController, aimTarget: Vector3?): boolean
	if not self:canCollect() then
		return false
	end
	local camera = workspace.CurrentCamera
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local token = self._deps.round:sessionToken()
	if not camera or not root or not token then
		return false
	end
	-- Anticipation: windup swing before the server answers.
	self._swing = 1
	self._deps.audio:play(Tokens.sound.collectTug, { pitchVariance = 0.08 })
	local origin = root.Position + Vector3.new(0, 1.5, 0)
	local direction = if aimTarget then (aimTarget - origin).Unit else camera.CFrame.LookVector
	self.stats.sent += 1
	local result =
		self._deps.net:request("CollectAction", { sessionToken = token, origin = origin, direction = direction, toolId = "hand" })
	if result.ok and result.data then
		local data = result.data
		self.stats.accepted += 1
		self._nextAllowedAt = os.clock() + (data.cooldownMs / 1000)
		-- Contact + reward.
		local hitPosition = Vector3.new(data.hitX, origin.Y - 1, data.hitZ)
		self._deps.pile:streamToBag(hitPosition, data.awarded, function()
			local cam = workspace.CurrentCamera
			return if cam then (cam.CFrame * CFrame.new(0.8, -0.6, -1.2)).Position else hitPosition
		end)
		self._deps.audio:play(Tokens.sound.collectRelease, { pitchVariance = 0.12 })
		self._deps.haptics:pulse(0.25, 0.05)
		self._deps.camera:impulse(0.08)
		if data.bagFull then
			self._deps.audio:play(Tokens.sound.bagFull)
			self._deps.haptics:pulse(0.6, 0.12)
		end
		self.collected:Fire(data)
		return true
	end
	self.stats.rejected += 1
	local code = result.code
	if code == "rate_limited" then
		self._nextAllowedAt = os.clock() + 0.1
	end
	self.rejected:Fire(result)
	return false
end

function HandController.destroy(self: HandController)
	self:setEnabled(false)
	self._trove:destroy()
	self.collected:Destroy()
	self.rejected:Destroy()
end

HandController.Motion = Motion
HandController.tween = TweenService

return HandController
