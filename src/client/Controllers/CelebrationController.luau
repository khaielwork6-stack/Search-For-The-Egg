--!strict
-- Reusable celebration effects for the round's big moments. Every effect reads the quality tier and
-- the reduced-motion setting, and everything is built once and reused: the ripple rings, the burst
-- attachments and their emitters, and the edge glow are pooled; the only per-call instances are the
-- particles an emitter spits out, which the engine owns and retires on its own.
--
--   goldenRipple(position, radius)   a flat gold ring expanding across the ground, fading
--   burst(position, kind, strength)  ParticleEmitter:Emit from a pooled attachment ("gold" rises,
--                                    "rainbow" scatters); scaled down automatically near the camera
--   cameraPunch(strength, seconds)   a short FOV push through CameraFeedback.nudge (so camera-shake
--                                    off and reduced motion apply exactly as they do to every kick)
--   musicDip(seconds, depth)         ducks the Music bus through AudioDirector.duck (SFX untouched)
--   screenFlash(tone)                a quick glow on the screen edges; never a dark overlay
--   confetti(origin?, count?)        the 2D confetti burst on the HUD stage
--   carrierGlow(character)           gold highlight + trail on a character; returns a remover
--
-- No sound lives here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Tokens = require(Shared.Design.Tokens)
local Confetti = require(script.Parent.Parent.UI.Components.Confetti)
local AnnouncementBanner = require(script.Parent.Parent.UI.AnnouncementBanner)

local CelebrationController = {}
CelebrationController.__index = CelebrationController

export type Tone = "gold" | "rainbow" | "success" | "info"

type Emitters = { attachment: Attachment, gold: ParticleEmitter, rainbow: ParticleEmitter }

export type CelebrationController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_trove: Trove.Trove,
		_folder: Folder,
		_rings: { CylinderHandleAdornment },
		_ringCursor: number,
		_emitters: { Emitters },
		_emitterCursor: number,
		_edgeGui: ScreenGui?,
		_edges: { Frame },
		_edgeGradients: { UIGradient },
		_flashToken: number,
		stats: { ripples: number, bursts: number, punches: number, dips: number, flashes: number, particles: number },
	},
	CelebrationController
))

local RING_POOL = 4
local EMITTER_POOL = 4
local EDGE_FRACTION = 0.14

local TONE_COLOR: { [string]: Color3 } = {
	gold = Tokens.color.gold,
	success = Tokens.color.leafBright,
	info = Tokens.color.sky,
	rainbow = Color3.fromRGB(226, 150, 255),
}

function CelebrationController.new(deps: {
	quality: any,
	accessibility: any,
	camera: any,
	audio: any,
	hud: any?,
}): CelebrationController
	local self = setmetatable({
		_deps = deps,
		_trove = Trove.new(),
		_folder = Instance.new("Folder"),
		_rings = {},
		_ringCursor = 0,
		_emitters = {},
		_emitterCursor = 0,
		_edgeGui = nil,
		_edges = {},
		_edgeGradients = {},
		_flashToken = 0,
		stats = { ripples = 0, bursts = 0, punches = 0, dips = 0, flashes = 0, particles = 0 },
	}, CelebrationController)
	self._folder.Name = "SFE_Celebration"
	self._folder.Parent = workspace
	self._trove:add(self._folder)
	return self
end

function CelebrationController._tier(self: CelebrationController): string
	local quality = self._deps.quality
	return if quality and quality.tier then quality:tier() else "high"
end

function CelebrationController._reduced(self: CelebrationController): boolean
	local accessibility = self._deps.accessibility
	return accessibility ~= nil and accessibility:reducedMotion()
end

-- Effect count multiplier for the tier and the motion setting.
function CelebrationController.scaleFor(tier: string, reducedMotion: boolean): number
	local scale = if tier == "low" then 0.35 elseif tier == "medium" then 0.65 else 1
	if reducedMotion then
		scale *= 0.4
	end
	return scale
end

-- ---------------------------------------------------------------------------------------------
-- Golden ripple
-- ---------------------------------------------------------------------------------------------

function CelebrationController._ring(self: CelebrationController): CylinderHandleAdornment
	self._ringCursor = self._ringCursor % RING_POOL + 1
	local ring = self._rings[self._ringCursor]
	if not ring then
		ring = Instance.new("CylinderHandleAdornment")
		ring.Name = "Ripple"
		ring.Adornee = workspace.Terrain
		ring.AlwaysOnTop = false
		ring.ZIndex = 1
		ring.Height = 0.18
		ring.Color3 = Tokens.color.gold
		ring.Transparency = 1
		ring.Visible = false
		ring.Parent = self._folder
		self._rings[self._ringCursor] = ring
	end
	return ring :: CylinderHandleAdornment
end

function CelebrationController.goldenRipple(self: CelebrationController, worldPosition: Vector3, radiusStuds: number?)
	local radius = math.max(2, radiusStuds or 24)
	local tier = self:_tier()
	local reduced = self:_reduced()
	self.stats.ripples += 1
	local rings = if tier == "low" or reduced then 1 else 2
	for index = 1, rings do
		local ring = self:_ring()
		local delayTime = (index - 1) * 0.2
		local thickness = math.max(0.6, radius * 0.06)
		-- Flat on the ground: the cylinder's axis runs along the CFrame's look vector.
		ring.CFrame = CFrame.new(worldPosition + Vector3.new(0, 0.15, 0)) * CFrame.Angles(math.rad(90), 0, 0)
		ring.Color3 = if index == 1 then Tokens.color.goldLight else Tokens.color.gold
		ring.Visible = true
		local seconds = if reduced then 0.8 else 1.15
		if reduced then
			ring.Radius = radius
			ring.InnerRadius = radius - thickness
			ring.Transparency = 0.45
			TweenService:Create(ring, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = 1 }):Play()
		else
			ring.Radius = 0.8
			ring.InnerRadius = 0.2
			ring.Transparency = 0.1
			TweenService:Create(ring, TweenInfo.new(seconds, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, 0, false, delayTime), {
				Radius = radius * (1 - 0.18 * (index - 1)),
				InnerRadius = radius * (1 - 0.18 * (index - 1)) - thickness,
				Transparency = 1,
			}):Play()
		end
		task.delay(seconds + delayTime + 0.05, function()
			if ring.Transparency >= 0.99 then
				ring.Visible = false
			end
		end)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Particle bursts
-- ---------------------------------------------------------------------------------------------

local function newEmitter(parent: Attachment, name: string): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Enabled = false
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Drag = 2.5
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Parent = parent
	return emitter
end

function CelebrationController._emitterSet(self: CelebrationController): Emitters
	self._emitterCursor = self._emitterCursor % EMITTER_POOL + 1
	local set = self._emitters[self._emitterCursor]
	if not set then
		local attachment = Instance.new("Attachment")
		attachment.Name = "SFE_CelebrationBurst"
		attachment.Parent = workspace.Terrain
		self._trove:add(attachment)
		set = { attachment = attachment, gold = newEmitter(attachment, "Gold"), rainbow = newEmitter(attachment, "Rainbow") }
		self._emitters[self._emitterCursor] = set
	end
	return set :: Emitters
end

-- `kind` "gold" rises from the point (the Egg's light); "rainbow" scatters in every direction.
-- `strength` ~0..2 scales the count and the reach. Near the camera (a burst at the carried bundle)
-- the particles shrink and slow with distance so they read as sparkle, not a wall.
function CelebrationController.burst(self: CelebrationController, worldPosition: Vector3, kind: string?, strength: number?): number
	local power = math.clamp(strength or 1, 0, 2)
	local scale = CelebrationController.scaleFor(self:_tier(), self:_reduced())
	local rainbow = kind == "rainbow"
	local count = math.floor((if rainbow then 28 else 40) * power * scale + 0.5)
	if count <= 0 then
		return 0
	end
	local near = 1
	local camera = workspace.CurrentCamera
	if camera then
		near = math.clamp((worldPosition - camera.CFrame.Position).Magnitude / 16, 0.1, 1)
	end
	local set = self:_emitterSet()
	set.attachment.WorldPosition = worldPosition
	local reach = (0.6 + 0.4 * math.min(power, 1)) * near * (if self:_reduced() then 0.5 else 1)
	local emitter = if rainbow then set.rainbow else set.gold
	if rainbow then
		emitter.Color = AnnouncementBanner.rainbow()
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.34 * near),
			NumberSequenceKeypoint.new(0.6, 0.24 * near),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		emitter.Lifetime = NumberRange.new(0.45, 0.9)
		emitter.Speed = NumberRange.new(5 * reach, 12 * reach)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Acceleration = Vector3.new(0, -4 * near, 0)
	else
		emitter.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Tokens.color.goldLight),
			ColorSequenceKeypoint.new(0.5, Tokens.color.gold),
			ColorSequenceKeypoint.new(1, Tokens.color.goldDeep),
		})
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5 * near),
			NumberSequenceKeypoint.new(0.5, 0.36 * near),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		emitter.Lifetime = NumberRange.new(0.8, 1.5)
		emitter.Speed = NumberRange.new(10 * reach, 22 * reach)
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.SpreadAngle = Vector2.new(40, 40)
		emitter.Acceleration = Vector3.new(0, -9 * near, 0)
	end
	emitter:Emit(count)
	self.stats.bursts += 1
	self.stats.particles += count
	return count
end

-- ---------------------------------------------------------------------------------------------
-- Camera, music
-- ---------------------------------------------------------------------------------------------

function CelebrationController.cameraPunch(self: CelebrationController, strength: number, seconds: number?)
	local camera = self._deps.camera
	if not camera or not camera.nudge then
		return
	end
	self.stats.punches += 1
	local power = math.clamp(strength, 0, 1.5)
	-- FOV only: no positional or pitch offset, so the punch is safe while a scripted camera shot (the
	-- reveal framing, the return ease) owns the CFrame and nothing rewrites it each frame.
	camera:nudge({ studs = 0, degrees = 0, fov = -7 * power, returnSeconds = math.max(0.15, seconds or 0.45) })
end

function CelebrationController.musicDip(self: CelebrationController, seconds: number, depth: number?)
	local audio = self._deps.audio
	if not audio or not audio.duck then
		return
	end
	self.stats.dips += 1
	audio:duck(seconds, depth or 0.6)
end

-- ---------------------------------------------------------------------------------------------
-- Screen edge glow
-- ---------------------------------------------------------------------------------------------

function CelebrationController._buildEdges(self: CelebrationController): ScreenGui?
	if self._edgeGui and self._edgeGui.Parent then
		return self._edgeGui
	end
	local player = Players.LocalPlayer
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_EdgeGlow"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = -1 -- under the HUD: a glow on the world, never over the controls
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	self._edges = {}
	self._edgeGradients = {}
	-- Each edge fades from the screen border inwards.
	local specs = {
		{
			name = "Top",
			anchor = Vector2.new(0, 0),
			position = UDim2.fromScale(0, 0),
			size = UDim2.fromScale(1, EDGE_FRACTION),
			rotation = 90,
		},
		{
			name = "Bottom",
			anchor = Vector2.new(0, 1),
			position = UDim2.fromScale(0, 1),
			size = UDim2.fromScale(1, EDGE_FRACTION),
			rotation = -90,
		},
		{
			name = "Left",
			anchor = Vector2.new(0, 0),
			position = UDim2.fromScale(0, 0),
			size = UDim2.fromScale(EDGE_FRACTION * 0.6, 1),
			rotation = 0,
		},
		{
			name = "Right",
			anchor = Vector2.new(1, 0),
			position = UDim2.fromScale(1, 0),
			size = UDim2.fromScale(EDGE_FRACTION * 0.6, 1),
			rotation = 180,
		},
	}
	for _, spec in ipairs(specs) do
		local edge = Instance.new("Frame")
		edge.Name = spec.name
		edge.AnchorPoint = spec.anchor
		edge.Position = spec.position
		edge.Size = spec.size
		edge.BackgroundColor3 = Color3.new(1, 1, 1)
		edge.BackgroundTransparency = 1
		edge.BorderSizePixel = 0
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = spec.rotation
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.45, 0.7),
			NumberSequenceKeypoint.new(1, 1),
		})
		gradient.Parent = edge
		edge.Parent = gui
		table.insert(self._edges, edge)
		table.insert(self._edgeGradients, gradient)
	end
	gui.Parent = playerGui
	self._trove:add(gui)
	self._edgeGui = gui
	return gui
end

function CelebrationController.screenFlash(self: CelebrationController, tone: string?)
	local gui = self:_buildEdges()
	if not gui then
		return
	end
	self.stats.flashes += 1
	self._flashToken += 1
	local token = self._flashToken
	local reduced = self:_reduced()
	local color = TONE_COLOR[tone or "gold"] or Tokens.color.gold
	local peak = if reduced then 0.62 else 0.3
	gui.Enabled = true
	for index, edge in ipairs(self._edges) do
		edge.BackgroundColor3 = if tone == "rainbow" then Color3.new(1, 1, 1) else color
		local gradient = self._edgeGradients[index]
		gradient.Color = if tone == "rainbow" then AnnouncementBanner.rainbow() else ColorSequence.new(color)
		edge.BackgroundTransparency = 1
		local rise = TweenService:Create(
			edge,
			TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = peak }
		)
		rise:Play()
		rise.Completed:Once(function()
			if self._flashToken ~= token then
				return
			end
			TweenService:Create(edge, TweenInfo.new(if reduced then 0.5 else 0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
				BackgroundTransparency = 1,
			}):Play()
		end)
	end
	task.delay(1, function()
		if self._flashToken == token then
			gui.Enabled = false
		end
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Confetti and the carrier's glow
-- ---------------------------------------------------------------------------------------------

function CelebrationController.confetti(self: CelebrationController, origin: UDim2?, count: number?)
	local hud = self._deps.hud
	local stage = hud and hud.stage
	if not stage then
		return
	end
	Confetti.burst(stage, {
		origin = origin or UDim2.fromScale(0.5, 0.3),
		count = count or 44,
		spread = 300,
		motion = self._deps.accessibility:motionSettings(),
		tier = self:_tier(),
		zIndex = Tokens.zIndex.toast + 6,
	})
end

-- Gold highlight and a gold trail on `character`, seen by everyone. Returns the remover. The trail is
-- skipped on the low tier and under reduced motion (the highlight carries it there).
function CelebrationController.carrierGlow(self: CelebrationController, character: Model): () -> ()
	local created: { Instance } = {}
	local highlight = Instance.new("Highlight")
	highlight.Name = "SFE_CarrierGlow"
	highlight.FillColor = Tokens.color.goldLight
	highlight.FillTransparency = 0.72
	highlight.OutlineColor = Tokens.color.gold
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = character
	table.insert(created, highlight)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") and self:_tier() ~= "low" and not self:_reduced() then
		local top = Instance.new("Attachment")
		top.Name = "SFE_CarrierTrailTop"
		top.Position = Vector3.new(0, 1.2, 0)
		top.Parent = root
		local bottom = Instance.new("Attachment")
		bottom.Name = "SFE_CarrierTrailBottom"
		bottom.Position = Vector3.new(0, -1.6, 0)
		bottom.Parent = root
		local trail = Instance.new("Trail")
		trail.Name = "SFE_CarrierTrail"
		trail.Attachment0 = top
		trail.Attachment1 = bottom
		trail.Lifetime = 0.55
		trail.MinLength = 0.2
		trail.FaceCamera = true
		trail.LightEmission = 1
		trail.Color = ColorSequence.new(Tokens.color.goldLight, Tokens.color.gold)
		trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
		trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.2) })
		trail.Parent = root
		table.insert(created, top)
		table.insert(created, bottom)
		table.insert(created, trail)
	end
	return function()
		for _, instance in ipairs(created) do
			instance:Destroy()
		end
		table.clear(created)
	end
end

function CelebrationController.destroy(self: CelebrationController)
	self._trove:destroy()
	table.clear(self._rings)
	table.clear(self._emitters)
	table.clear(self._edges)
	table.clear(self._edgeGradients)
end

return CelebrationController
