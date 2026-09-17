--!strict
-- First-person tool controller: hotbar selection (click/tap, number keys, bumpers), a viewmodel per
-- tool, and Primary-action intents per tool. Hand / Nest Rake send CollectAction (hold-to-gather
-- repeats at the server cooldown once the hold path is unlocked); Confetti Charge sends a throw;
-- Feather Vac sends begin on press and end on release/cancel/focus loss; Scout Chick toggles
-- deploy/recall. Overflow bundles are
-- gathered by walking over them. The server decides every yield, timer, and roll; this controller
-- only animates the feedback envelope.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Signal = require(Shared.Util.Signal)
local Tokens = require(Shared.Design.Tokens)
local Feedback = require(script.Parent.Parent.UI.Feedback)
local ToolSpecs = require(Shared.Domain.ToolSpecs)

local ToolController = {}
ToolController.__index = ToolController

export type ToolController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_swing: number,
		_requestCounter: number?,
		_inFlight: boolean,
		_lastAttemptAt: number?,
		_nextAllowedAt: number,
		_bound: boolean,
		_enabled: boolean,
		_equipped: string,
		_owned: { [string]: boolean },
		_holdActive: boolean,
		_liftedId: number?,
		_vacRunning: boolean,
		_chickActive: boolean,
		_chargeReadyAt: number,
		_lastGatherAt: number,
		_vac: { heat: number, runtimeSeconds: number, coolingSeconds: number, overheated: boolean },
		collected: any,
		rejected: any,
		equippedChanged: any,
		swung: any, -- rake swing sent (viewmodel thrust)
		chargeLit: any, -- dynamite fuse lit (Primary pressed)
		chargeThrown: any, -- (data) throw accepted by the server
		chargeExtinguished: any, -- throw refused or cancelled
		vacChanged: any, -- (running: boolean)
		_chargeLitAt: number?,
		_lastAimAt: number,
		_aimInFlight: boolean,
		_inFlightSince: number?,
		_aimInFlightSince: number?,
		_trove: Trove.Trove,
		stats: {
			sent: number,
			accepted: number,
			rejected: number,
			noTarget: number,
			equips: number,
			throws: number,
			vacStarts: number,
			vacStops: number,
			chickToggles: number,
			gathers: number,
			holdRepeats: number,
		},
	},
	ToolController
))

local RENDER_NAME = "SFE_ToolController"
local GATHER_RADIUS = 6
-- No first-person hands or arms are ever drawn (owner requirement): ToolViewmodelController draws
-- only the equipped tool model and listens to this controller's signals for its motion.

function ToolController.new(deps: {
	net: any,
	round: any,
	input: any,
	pile: any,
	vfx: any,
	audio: any,
	haptics: any,
	camera: any,
	accessibility: any,
	hud: any,
	visuals: any,
	feedback: any,
	config: { [string]: any },
}): ToolController
	local self = setmetatable({
		_deps = deps,
		_swing = 0,
		_inFlight = false,
		_inFlightSince = nil,
		_aimInFlightSince = nil,
		_nextAllowedAt = 0,
		_bound = false,
		_enabled = false,
		_equipped = "hand",
		_owned = { hand = true },
		_holdActive = false,
		_liftedId = nil,
		_vacRunning = false,
		_chickActive = false,
		_chargeReadyAt = 0,
		_lastGatherAt = 0,
		_vac = { heat = 0, runtimeSeconds = 1, coolingSeconds = 1, overheated = false },
		collected = Signal.new(),
		rejected = Signal.new(),
		equippedChanged = Signal.new(),
		swung = Signal.new(),
		chargeLit = Signal.new(),
		chargeThrown = Signal.new(),
		chargeExtinguished = Signal.new(),
		vacChanged = Signal.new(),
		_chargeLitAt = nil,
		_lastAimAt = 0,
		_aimInFlight = false,
		_trove = Trove.new(),
		stats = {
			sent = 0,
			accepted = 0,
			rejected = 0,
			noTarget = 0,
			equips = 0,
			throws = 0,
			vacStarts = 0,
			vacStops = 0,
			chickToggles = 0,
			gathers = 0,
			holdRepeats = 0,
		},
	}, ToolController)

	self._trove:add(deps.round.phaseChanged:Connect(function(phase)
		local active = phase == "Searching" or phase == "EggRevealed" or phase == "Countdown" or phase == "Cutscene"
		self:setEnabled(active)
		if phase ~= "Searching" then
			self:_stopHold()
			self:_setVacRunning(false)
			self._chickActive = false
		end
		self:_resetActionState("phase")
		if phase == "Cutscene" then
			self._equipped = "hand"
			self._owned = { hand = true }
			self:_refreshHotbar()
		end
	end))
	self._trove:add(deps.round.playerChanged:Connect(function(player)
		self:_syncFromPlayer(player)
	end))
	self._trove:add(deps.input.actionBegan:Connect(function(action)
		if action == "Primary" then
			self:onPrimaryBegin()
		end
	end))
	self._trove:add(deps.input.actionEnded:Connect(function(action, reason)
		if action == "Primary" then
			self:onPrimaryEnd(reason)
		end
	end))
	-- Hotbar taps, number keys, and bumpers.
	local hotbar = deps.hud.hotbar
	self._trove:add(hotbar.activated:Connect(function(toolId)
		self:equip(toolId)
	end))
	self._trove:add(UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not self._enabled then
			return
		end
		local key = input.KeyCode
		local numbers = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six }
		local index = table.find(numbers, key)
		if index then
			local toolId = hotbar:toolAtIndex(index)
			if toolId then
				self:equip(toolId)
			end
		elseif key == Enum.KeyCode.ButtonR1 then
			self:equip(hotbar:cycle(1))
		elseif key == Enum.KeyCode.ButtonL1 then
			self:equip(hotbar:cycle(-1))
		end
	end))
	self._trove:add(deps.visuals.vacState:Connect(function(payload)
		if payload.userId ~= Players.LocalPlayer.UserId then
			return
		end
		self._vac.heat = payload.heat or self._vac.heat
		self._vac.runtimeSeconds = payload.runtimeSeconds or self._vac.runtimeSeconds
		self._vac.coolingSeconds = payload.coolingSeconds or self._vac.coolingSeconds
		if payload.state == "overheated" then
			self._vac.overheated = true
			self:_setVacRunning(false)
			if Feedback.deny("vac_cooling", "Feather Vac overheated - cooling") then
				deps.haptics:pulse(0.7, 0.15)
			end
		elseif payload.state == "ready" then
			-- Cooled down: the hotbar status clears. No "ready" chime - a cooldown ending is not an event.
			self._vac.overheated = false
		elseif payload.state == "idle" then
			self:_setVacRunning(false)
			if payload.reason == "bag_full" then
				Feedback.deny("bag_full", "Bag full - trade your feathers")
			elseif payload.reason == "range" then
				Feedback.deny("out_of_range", "Aim at the nest", { tone = "info", silent = true })
			end
		elseif payload.state == "running" then
			self:_setVacRunning(true)
		end
		self:_refreshStatus()
	end))
	self._trove:add(deps.visuals.chickState:Connect(function(payload)
		if payload.userId ~= Players.LocalPlayer.UserId then
			return
		end
		if payload.removed and not payload.oneTrip then
			self._chickActive = false
		end
		self:_refreshStatus()
	end))
	self._trove:add(deps.visuals.chargeExploded:Connect(function(payload)
		if payload.userId == Players.LocalPlayer.UserId then
			deps.haptics:pulse(if payload.mini then 0.3 else 0.6, 0.12)
		end
	end))
	self._trove:add(deps.net:on("ToolEvent", function(payload)
		if payload.userId ~= Players.LocalPlayer.UserId then
			return
		end
		if payload.kind == "tools_granted" then
			for _, toolId in ipairs(payload.tools) do
				self._owned[toolId] = true
				deps.hud.toasts:push((deps.config.tools[toolId] and deps.config.tools[toolId].displayName or toolId) .. " ready", "success")
			end
			self:_refreshHotbar()
		elseif payload.kind == "chick_deposit" then
			-- The deposit event carries the traded count (the unit's load is already zeroed by then).
			deps.hud.toasts:push(string.format("Scout Chick traded %d feathers", payload.feathers or 0), "success")
		elseif payload.kind == "tool_award" and (payload.awarded or 0) + (payload.rainbow or 0) > 0 then
			-- Vac ticks and blasts: the same feedback as a hand or rake pick (+N, bag pulse, sounds).
			if payload.toolId == "featherVac" then
				deps.audio:play(Tokens.sound.collectRelease, { pitchVariance = 0.15 })
				deps.haptics:pulse(0.12, 0.03)
			end
			if payload.bagFull then
				Feedback.deny("bag_full", "Bag full - trade your feathers")
			end
			pcall(function()
				self.collected:Fire(payload)
			end)
		end
	end))
	return self
end

function ToolController._syncFromPlayer(self: ToolController, player: { [string]: any })
	local owned = { hand = true }
	for toolId, has in pairs(player.roundTools or {}) do
		if has then
			owned[toolId] = true
		end
	end
	self._owned = owned
	if player.equippedTool and player.equippedTool ~= self._equipped then
		-- Through the announcing path: the viewmodel and hotbar only follow `equippedChanged`.
		self:_applyEquipped(player.equippedTool)
	end
	local vac = player.toolRuntime and player.toolRuntime.featherVac
	if vac then
		self._vac.heat = vac.heat or self._vac.heat
		self._vac.overheated = vac.overheated == true
		self._vacRunning = vac.running == true
	end
	local chick = player.toolRuntime and player.toolRuntime.scoutChick
	if chick then
		self._chickActive = chick.active == true
	end
	self:_refreshHotbar()
end

-- Records the equipped tool locally without a request (the server already made it so).
function ToolController._applyEquipped(self: ToolController, toolId: string)
	if toolId == self._equipped then
		return
	end
	self:_stopHold()
	self._equipped = toolId
	self:_setVacRunning(false)
	self:_resetActionState("equip")
	self._deps.hud.hotbar:setEquipped(toolId)
	self:_refreshStatus()
	self.equippedChanged:Fire(toolId)
end

function ToolController._refreshHotbar(self: ToolController)
	local hotbar = self._deps.hud.hotbar
	hotbar:setOwned(self._owned)
	hotbar:setEquipped(self._equipped)
	self:_refreshStatus()
end

function ToolController._setVacRunning(self: ToolController, running: boolean)
	if self._vacRunning == running then
		return
	end
	self._vacRunning = running
	self.vacChanged:Fire(running)
end

function ToolController._refreshStatus(self: ToolController)
	local hotbar = self._deps.hud.hotbar
	local hud = self._deps.hud
	if self._owned.featherVac then
		local fraction = if self._vac.runtimeSeconds > 0 then self._vac.heat / self._vac.runtimeSeconds else 0
		local text = if self._vac.overheated then "Overheated" elseif self._vacRunning then "Pulling" else "Ready"
		hotbar:setStatus(
			"featherVac",
			fraction,
			text,
			if self._vac.overheated then "danger" elseif fraction > 0.7 then "warning" else "info"
		)
		if hud.setHeat then
			hud:setHeat(
				fraction,
				if self._equipped ~= "featherVac" or not self._enabled
					then "hidden"
					elseif self._vac.overheated then "overheated"
					elseif self._vacRunning then "running"
					else "idle"
			)
		end
	elseif hud.setHeat then
		hud:setHeat(0, "hidden")
	end
	if self._owned.confettiCharge then
		local remaining = math.max(0, self._chargeReadyAt - os.clock())
		hotbar:setStatus(
			"confettiCharge",
			if remaining > 0 then 1 - remaining / math.max(0.01, self._deps.config.tools.confettiCharge.cooldownSeconds) else nil,
			if remaining > 0 then "Cooling" else "Throw",
			"info"
		)
	end
	if self._owned.scoutChick then
		hotbar:setStatus(
			"scoutChick",
			nil,
			if self._chickActive then "Out foraging" else "Docked",
			if self._chickActive then "success" else "info"
		)
	end
end

function ToolController.setEnabled(self: ToolController, enabled: boolean)
	if enabled == self._enabled then
		return
	end
	self._enabled = enabled
	if enabled then
		if not self._bound then
			self._bound = true
			RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 2, function(dt)
				self:_render(dt)
			end)
		end
		self._deps.hud.hotbar:setVisible(true)
	else
		if self._bound then
			self._bound = false
			RunService:UnbindFromRenderStep(RENDER_NAME)
		end
		self:_stopHold()
		self._deps.hud.hotbar:setVisible(false)
	end
end

-- Every gate a request can leave behind, cleared together: a tool swap, a phase change, a refused
-- request or a stuck reply must never leave collection locked.
function ToolController._resetActionState(self: ToolController, reason: string?)
	self._inFlight = false
	self._inFlightSince = nil
	self._aimInFlight = false
	self._aimInFlightSince = nil
	self._chargeLitAt = nil
	self._lastAttemptAt = nil
	self._nextAllowedAt = math.min(self._nextAllowedAt, os.clock() + 0.25)
	if reason == "phase" then
		self._nextAllowedAt = 0
	end
end

function ToolController._render(self: ToolController, dt: number)
	self._swing = math.max(0, self._swing - dt * 4)
	local now = os.clock()
	self:_stepHold()
	-- Watchdog: a reply that never lands (remote dropped, handler error) cannot hold the gate.
	if self._inFlight and now - (self._inFlightSince or now) > 3 then
		warn("[SFE][Tool] collect request never returned; releasing the gate")
		self._inFlight = false
		self._inFlightSince = nil
	end
	if self._aimInFlight and now - (self._aimInFlightSince or now) > 3 then
		self._aimInFlight = false
		self._aimInFlightSince = nil
	end
	-- Dynamite: a lit stick leaves the hand after the light beat even if the button is held on.
	local litAt = self._chargeLitAt
	if litAt and self._equipped == "confettiCharge" then
		local feel = (self._deps.config.toolFeel or {}).confettiCharge or {}
		if now - litAt >= (feel.maxHoldSeconds or 1.1) then
			self:_throwCharge()
		end
	end
	-- Vac: follow the reticle while running (the server re-resolves every aim and stops out of range).
	if self._vacRunning and self._equipped == "featherVac" then
		local feel = (self._deps.config.toolFeel or {}).featherVac or {}
		local interval = 1 / math.max(1, feel.aimUpdateHz or 6)
		if not self._aimInFlight and now - self._lastAimAt >= interval then
			self._lastAimAt = now
			self:_sendVacAim()
		end
		-- Bag-full stops come from the server's vac_state (its capacity is the truth); a stale local
		-- projection must never cut the suction short.
	end
	-- Local heat interpolation between authoritative vac events (the server owns the real value).
	if self._owned.featherVac and self._vac.runtimeSeconds > 0 then
		if self._vacRunning then
			self._vac.heat = math.min(self._vac.runtimeSeconds, self._vac.heat + dt)
		elseif self._vac.heat > 0 then
			self._vac.heat = math.max(0, self._vac.heat - dt * (self._vac.runtimeSeconds / math.max(0.01, self._vac.coolingSeconds)))
		end
		self:_refreshStatus()
	end
	-- Walk-over bundle gathering (throttled).
	local now = os.clock()
	if now - self._lastGatherAt > 0.35 and self._deps.round:phase() == "Searching" then
		self._lastGatherAt = now
		self:_tryGatherNearby()
	end
	if self._owned.confettiCharge and self._chargeReadyAt > now - 0.2 then
		self:_refreshStatus()
	end
end

function ToolController.equipped(self: ToolController): string
	return self._equipped
end

function ToolController.owned(self: ToolController): { [string]: boolean }
	return table.clone(self._owned)
end

-- Equips a tool through the server; refuses locally when not owned.
function ToolController.equip(self: ToolController, toolId: string): boolean
	if not self._owned[toolId] or toolId == self._equipped then
		return false
	end
	self:_stopHold()
	local result = self._deps.net:request("ToolEquip", { toolId = toolId })
	if not result.ok then
		if result.code ~= "rate_limited" then
			Feedback.deny("equip_refused")
		end
		return false
	end
	self._equipped = toolId
	self:_setVacRunning(false)
	self:_resetActionState("equip")
	self.stats.equips += 1
	self._deps.hud.hotbar:setEquipped(toolId)
	self._deps.audio:play(Tokens.sound.uiTap)
	self._deps.haptics:pulse(0.15, 0.03)
	self:_refreshStatus()
	self.equippedChanged:Fire(toolId)
	return true
end

local function aimRay(aimTarget: Vector3?): (Vector3?, Vector3?, string?)
	local camera = workspace.CurrentCamera
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not camera or not root then
		return nil, nil, nil
	end
	local origin = root.Position + Vector3.new(0, 1.5, 0)
	local direction = if aimTarget then (aimTarget - origin).Unit else camera.CFrame.LookVector
	return origin, direction, nil
end

-- Area-tool aim (Nest Rake, Feather Vac): the crosshair ray - the same ray the pile resolves the
-- reticle record on - plus that record's id as a hint. The server re-resolves the strike from the ray
-- (surface first) and only honours the hint when the record is on the ray and in sight, so the tool
-- takes what the player is looking at. `aimTarget` (Studio automation) keeps the body-origin ray.
function ToolController._toolAim(self: ToolController, aimTarget: Vector3?): (Vector3?, Vector3?, number?)
	local origin, direction = aimRay(aimTarget)
	local pile = self._deps.pile
	if aimTarget or not origin or not pile or not pile.aimRay then
		return origin, direction, nil
	end
	local rayOrigin, rayDirection = pile:aimRay()
	if not rayOrigin or not rayDirection or rayDirection.Magnitude < 1e-6 then
		return origin, direction, nil
	end
	local target = pile:resolveUnderCursor()
	local hint = if target then target.featherId else nil
	-- First person: the camera is the eye, well inside the server's origin tolerance. Any other camera
	-- aims from the body through the crosshair's world point instead.
	if (rayOrigin - (origin - Vector3.new(0, 1.5, 0))).Magnitude <= 3 then
		return rayOrigin, rayDirection.Unit, hint
	end
	local point = if target then target.position else rayOrigin + rayDirection.Unit * self._deps.config.interaction.defaultRangeStuds
	return origin, (point - origin).Unit, hint
end

function ToolController.canCollect(self: ToolController): boolean
	return self._enabled and os.clock() >= self._nextAllowedAt and self._deps.round:phase() == "Searching"
end

-- Hand: one request for the ONE feather under the reticle (owner requirement: single-feather pickup).
-- Rake: one sweep request aimed from the camera. `aimTarget` (Studio automation only) replaces the
-- camera look direction with a world point. Debounce: a request in flight, the cooldown, and the
-- configured debounce window all swallow extra inputs, so one input never sends two requests.
function ToolController.tryCollect(self: ToolController, aimTarget: Vector3?): boolean
	if not self:canCollect() or self._inFlight then
		return false
	end
	local now = os.clock()
	if now - (self._lastAttemptAt or 0) < self._deps.config.interaction.collectDebounceSeconds then
		return false
	end
	self._lastAttemptAt = now
	local toolId = self._equipped
	if toolId ~= "hand" and toolId ~= "nestRake" then
		return false
	end
	local token = self._deps.round:sessionToken()
	local origin, direction = aimRay(aimTarget)
	local hintId: number? = nil
	if toolId == "nestRake" then
		origin, direction, hintId = self:_toolAim(aimTarget)
	end
	if not origin or not direction or not token then
		return false
	end
	local featherId: number? = nil
	if toolId == "hand" then
		-- Resolve at the instant of the click, through the exact cursor/crosshair: the first feather
		-- record the ray meets is the one requested, nothing behind or beside it.
		local target
		if aimTarget then
			local camera = workspace.CurrentCamera
			local eye = if camera then camera.CFrame.Position else origin
			target = self._deps.pile:resolveTarget(eye, (aimTarget - eye).Unit)
		else
			target = self._deps.pile:resolveUnderCursor()
		end
		if not target then
			-- Nothing collectible under the reticle: no request, no feedback spam.
			self.stats.noTarget += 1
			self.rejected:Fire({ ok = false, code = "not_found", message = "no_target", local_ = true })
			return false
		end
		featherId = target.featherId
		-- Aim at the record's base (its logical position), not at whichever point of the vane the
		-- reticle ray touched.
		local base = target.part.CFrame * CFrame.new(0, -target.part.Size.Y * 0.5, 0)
		direction = (base.Position - origin).Unit
	end
	-- Cosmetic response starts now: the targeted feather loosens before the server answers.
	if featherId then
		self._deps.feedback:press(featherId)
		self._liftedId = featherId
	end
	-- Full bag: no request, no pile change, clear feedback (throttled). Capacity mirrors the HUD's
	-- derivation (server projection first, config level as the fallback); the server re-checks anyway.
	local player = self._deps.round.player
	if player and player.bagInfinite ~= true then
		local levels = self._deps.config.bags.levels
		local capacity = player.bagCapacity or (levels[player.bagLevel or 1] or levels[1]).capacity
		if (player.carriedStandard or 0) + (player.carriedRainbow or 0) >= capacity then
			-- One refusal, then five quiet seconds for this reason (Feedback owns the window).
			if Feedback.deny("bag_full", "Bag full - trade your feathers") then
				self._deps.haptics:pulse(0.5, 0.1)
			end
			self.stats.rejected += 1
			self.rejected:Fire({ ok = false, code = "invalid_state", message = "bag_full", local_ = true })
			return false
		end
	end
	self._swing = 1
	self.stats.sent += 1
	self._requestCounter = (self._requestCounter or 0) + 1
	self._inFlight = true
	self._inFlightSince = now
	if toolId == "nestRake" then
		pcall(function()
			self.swung:Fire()
		end)
	end
	local okRequest, result = pcall(function()
		return self._deps.net:request("CollectAction", {
			sessionToken = token,
			origin = origin,
			direction = direction,
			toolId = toolId,
			requestId = self._requestCounter,
			featherId = featherId or hintId,
		})
	end)
	self._inFlight = false
	self._inFlightSince = nil
	if not okRequest or type(result) ~= "table" then
		warn("[SFE][Tool] collect request failed: " .. tostring(result))
		result = { ok = false, code = "unavailable", message = "request_failed" }
	end
	if self._liftedId and (not result.ok or not result.data or result.data.featherId ~= self._liftedId) then
		-- Two kinds of refusal. "Someone else has it" or "that record is buried" means the thing under
		-- the reticle is stale on this client: the server no longer holds it as collectible, so it
		-- must leave the screen now rather than settle back into its seat and be aimed at again. Any
		-- other refusal - range, cooldown, a full bag - leaves a live record where it was.
		local stale = not result.ok
			and (result.message == "already_collected" or result.message == "not_exposed" or result.message == "no_feather")
		self._deps.feedback:cancel(self._liftedId, stale)
	end
	self._liftedId = nil
	if result.ok and result.data then
		local data = result.data
		local visual = self._deps.config.pile.visual
		self.stats.accepted += 1
		self._nextAllowedAt = os.clock() + (data.cooldownMs / 1000)
		self._lastCooldownSeconds = data.cooldownMs / 1000
		local hitPosition = Vector3.new(data.hitX, data.hitY or (origin.Y - 1), data.hitZ)
		-- The presentation - release, flight, landing, bag, sound, camera - is one transaction owned
		-- by the pickup feedback controller. It can never block the next request: the award is
		-- already authoritative.
		local okVisual, visualError = pcall(function()
			self._deps.feedback:collected(data, hitPosition, toolId)
		end)
		if not okVisual then
			warn("[SFE][Tool] pick feedback failed: " .. tostring(visualError))
		end
		if toolId == "nestRake" then
			self._deps.camera:impulse(visual.cameraImpulseRake)
		end
		pcall(function()
			self.collected:Fire(data)
		end)
		return true
	end
	self.stats.rejected += 1
	if result.message == "no_feathers" then
		Feedback.deny("no_feathers", "Nothing left there - aim at fresh feathers", { tone = "info", silent = true })
	end
	-- A refused request never re-sends immediately: hold the debounce window before the next try,
	-- and a server cooldown refusal waits out that cooldown instead of hammering it.
	local debounce = self._deps.config.interaction.collectDebounceSeconds
	self._nextAllowedAt = math.max(self._nextAllowedAt, os.clock() + debounce)
	if result.message == "cooldown" then
		self._nextAllowedAt = math.max(self._nextAllowedAt, os.clock() + math.max(debounce, (self._lastCooldownSeconds or 0.3) * 0.5))
	end
	pcall(function()
		self.rejected:Fire(result)
	end)
	return false
end

function ToolController._holdEnabled(self: ToolController): boolean
	local player = self._deps.round.player
	if not player then
		return false
	end
	local cfg = self._deps.config
	if self._equipped == "hand" then
		local entry = cfg.handUpgrades.hold[(player.handLevels and player.handLevels.hold or 0) + 1]
		return entry ~= nil and entry.enabled == true
	elseif self._equipped == "nestRake" then
		local levels = player.toolLevels and player.toolLevels.nestRake
		local entry = cfg.toolUpgrades.nestRake.hold[(levels and levels.hold or 0) + 1]
		return entry ~= nil and entry.enabled == true
	end
	return false
end

-- Held input is a state, not a loop: the render step fires the next pick the moment the cooldown
-- gate opens and the last reply is in, targeting from the live reticle each time.
function ToolController._startHold(self: ToolController)
	self._holdActive = true
end

function ToolController._stopHold(self: ToolController)
	self._holdActive = false
	if self._deps.hud and self._deps.hud.setHold then
		self._deps.hud:setHold(false)
	end
end

function ToolController._stepHold(self: ToolController)
	if not self._holdActive then
		return
	end
	if not self._enabled or not self._deps.input:isHeld("Primary") or (self._equipped ~= "hand" and self._equipped ~= "nestRake") then
		self:_stopHold()
		return
	end
	local now = os.clock()
	local remaining = math.max(0, self._nextAllowedAt - now)
	local cooldown = math.max(0.05, self._lastCooldownSeconds or 0.3)
	if self._deps.hud and self._deps.hud.setHold then
		self._deps.hud:setHold(true, 1 - math.clamp(remaining / cooldown, 0, 1))
	end
	if self._inFlight or remaining > 0 or not self:_holdEnabled() then
		return
	end
	task.spawn(function()
		if self:tryCollect() then
			self.stats.holdRepeats += 1
		end
	end)
end

function ToolController.onPrimaryBegin(self: ToolController)
	if not self._enabled or self._deps.round:phase() ~= "Searching" then
		return
	end
	local toolId = self._equipped
	if toolId == "hand" or toolId == "nestRake" then
		self:tryCollect()
		if self:_holdEnabled() then
			self:_startHold()
		end
	elseif toolId == "confettiCharge" then
		self:_lightCharge()
	elseif toolId == "featherVac" then
		self:beginAction()
	elseif toolId == "scoutChick" then
		if self._chickActive then
			self:endAction()
		else
			self:beginAction()
		end
	end
end

function ToolController.onPrimaryEnd(self: ToolController, reason: string?)
	self:_stopHold()
	if self._equipped == "featherVac" and self._vacRunning then
		self:endAction()
	elseif self._equipped == "confettiCharge" and self._chargeLitAt then
		if reason == "cancelled" or reason == "suspended" then
			self._chargeLitAt = nil
			self.chargeExtinguished:Fire()
			return
		end
		-- Release throws once the light beat has played (a quick tap still lights, then throws).
		local feel = (self._deps.config.toolFeel or {}).confettiCharge or {}
		local remaining = (feel.lightSeconds or 0.28) - (os.clock() - self._chargeLitAt)
		if remaining > 0 then
			local litAt = self._chargeLitAt
			task.delay(remaining, function()
				if self._chargeLitAt == litAt then
					self:_throwCharge()
				end
			end)
		else
			self:_throwCharge()
		end
	end
end

-- Dynamite, beat one: light the fuse. Refused locally while the last charge cools or is still live
-- (the server enforces both again on the throw).
function ToolController._lightCharge(self: ToolController)
	if self._chargeLitAt then
		return
	end
	if os.clock() < self._chargeReadyAt then
		Feedback.deny("charge_cooling", "Confetti Charge is cooling", { tone = "info" })
		return
	end
	self._chargeLitAt = os.clock()
	self.chargeLit:Fire()
end

-- Dynamite, beat two: the throw request. Success spawns the world projectile through ToolEvent.
function ToolController._throwCharge(self: ToolController)
	if not self._chargeLitAt then
		return
	end
	self._chargeLitAt = nil
	local result = self:beginAction()
	if result.ok then
		self.chargeThrown:Fire(result.data)
	else
		self.chargeExtinguished:Fire()
	end
end

-- Vac aim update from the reticle (camera ray), never yielding the render step.
function ToolController._sendVacAim(self: ToolController)
	local token = self._deps.round:sessionToken()
	local origin, direction, hintId = self:_toolAim(nil)
	if not token or not origin or not direction then
		return
	end
	self._aimInFlight = true
	self._aimInFlightSince = os.clock()
	task.spawn(function()
		local ok, result = pcall(function()
			return self._deps.net:request("ToolActionAim", {
				sessionToken = token,
				toolId = "featherVac",
				origin = origin,
				direction = direction,
				featherId = hintId,
			})
		end)
		self._aimInFlight = false
		self._aimInFlightSince = nil
		if not ok or type(result) ~= "table" then
			return
		end
		if result.ok and result.data and result.data.running == false then
			self:_setVacRunning(false)
			self:_refreshStatus()
		end
	end)
end

-- Sends ToolActionBegin for the equipped continuous/area tool. Returns the envelope.
function ToolController.beginAction(self: ToolController, aimTarget: Vector3?): any
	local toolId = self._equipped
	local token = self._deps.round:sessionToken()
	local origin, direction = aimRay(aimTarget)
	local hintId: number? = nil
	if toolId == "featherVac" then
		origin, direction, hintId = self:_toolAim(aimTarget)
	end
	if not token or not origin or not direction then
		return { ok = false, code = "no_character" }
	end
	self.stats.sent += 1
	local result = self._deps.net:request(
		"ToolActionBegin",
		{ sessionToken = token, toolId = toolId, origin = origin, direction = direction, featherId = hintId }
	)
	if result.ok then
		self.stats.accepted += 1
		self._swing = 1
		if toolId == "confettiCharge" then
			self.stats.throws += 1
			self._chargeReadyAt = os.clock() + (result.data.cooldownMs / 1000)
			self._deps.audio:play(Tokens.sound.collectRelease, { pitchVariance = 0.2 })
			self._deps.haptics:pulse(0.3, 0.05)
		elseif toolId == "featherVac" then
			self.stats.vacStarts += 1
			self._lastAimAt = os.clock()
			self:_setVacRunning(true)
		elseif toolId == "scoutChick" then
			self.stats.chickToggles += 1
			self._chickActive = true
			self._deps.audio:play(Tokens.sound.uiConfirm)
		end
		self:_refreshStatus()
		return result
	end
	self.stats.rejected += 1
	local message = result.message
	if message == "overheated" then
		Feedback.deny("vac_cooling", "Feather Vac is still cooling")
	elseif message == "bag_full" then
		Feedback.deny("bag_full", "Bag full - trade your feathers")
	elseif message == "charge_live" then
		Feedback.deny("charge_live", "One charge at a time", { tone = "info" })
	elseif result.code == "out_of_range" then
		-- A charge is thrown wherever it is aimed, so this is no longer "aim at the nest": the only
		-- way a throw is out of range now is the server disagreeing about where the character is.
		Feedback.deny(
			"out_of_range",
			if self._equipped == "confettiCharge" then "Too far to throw from here" else "Aim at the nest",
			{ tone = "info" }
		)
	elseif result.code ~= "rate_limited" then
		Feedback.deny("tool:" .. tostring(message or result.code))
	end
	self.rejected:Fire(result)
	return result
end

function ToolController.endAction(self: ToolController): any
	local toolId = self._equipped
	local token = self._deps.round:sessionToken()
	if not token then
		return { ok = false }
	end
	local result = self._deps.net:request("ToolActionEnd", { sessionToken = token, toolId = toolId })
	if toolId == "featherVac" then
		self:_setVacRunning(false)
		self.stats.vacStops += 1
	elseif toolId == "scoutChick" then
		self._chickActive = false
		self.stats.chickToggles += 1
		self._deps.audio:play(Tokens.sound.uiCancel)
	end
	self:_refreshStatus()
	return result
end

function ToolController._tryGatherNearby(self: ToolController)
	-- A full bag cannot take a bundle; do not spam the server (the bundle waits in the world).
	local player = self._deps.round.player
	if player and player.bagCapacity and not player.bagInfinite then
		if (player.carriedStandard + player.carriedRainbow) >= player.bagCapacity then
			return
		end
	end
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local bundleId = self._deps.visuals:nearestBundle(root.Position, GATHER_RADIUS)
	if not bundleId then
		return
	end
	self:gather(bundleId)
end

function ToolController.gather(self: ToolController, bundleId: string): any
	local token = self._deps.round:sessionToken()
	if not token then
		return { ok = false }
	end
	local result = self._deps.net:request("BundleGather", { sessionToken = token, bundleId = bundleId })
	if result.ok and result.data then
		self.stats.gathers += 1
		local data = result.data
		self._deps.pile:streamToBag(Vector3.new(data.hitX, 2, data.hitZ), data.awarded, function()
			local cam = workspace.CurrentCamera
			return if cam then (cam.CFrame * CFrame.new(0.8, -0.6, -1.2)).Position else Vector3.new(data.hitX, 2, data.hitZ)
		end)
		self._deps.audio:play(Tokens.sound.collectRelease, { pitchVariance = 0.1 })
		self.collected:Fire(data)
	end
	return result
end

function ToolController.status(self: ToolController): { [string]: any }
	return {
		equipped = self._equipped,
		owned = table.clone(self._owned),
		vac = table.clone(self._vac),
		vacRunning = self._vacRunning,
		chickActive = self._chickActive,
		inFlight = self._inFlight,
		nextAllowedIn = math.max(0, self._nextAllowedAt - os.clock()),
		chargeLit = self._chargeLitAt ~= nil,
		chargeReadyIn = math.max(0, self._chargeReadyAt - os.clock()),
		holdEnabled = self:_holdEnabled(),
		stats = table.clone(self.stats),
	}
end

function ToolController.destroy(self: ToolController)
	self:setEnabled(false)
	self._trove:destroy()
	self.collected:Destroy()
	self.rejected:Destroy()
	self.equippedChanged:Destroy()
	self.swung:Destroy()
	self.chargeLit:Destroy()
	self.chargeThrown:Destroy()
	self.chargeExtinguished:Destroy()
	self.vacChanged:Destroy()
end

ToolController.TOOL_IDS = ToolSpecs.TOOL_IDS

return ToolController
