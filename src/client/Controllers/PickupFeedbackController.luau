--!strict
-- One pickup is one transaction, and this is the only place its presentation lives:
--
--   press    (0 ms)      the targeted record loosens, a pluck sounds, the reticle dips;
--   release  (~50 ms)    the exact record leaves the coat, lifts a hair, a glint and a few down
--                        motes mark where it was, the next record beneath it is already showing;
--   flight   (~200 ms)   that same part arcs out and tucks into the carried bundle, rolling and
--                        shrinking, with a short trail; a quiet air sound rides with it;
--   landing              the bundle takes the weight, the bag counter pulses, "+1 Feather" rises
--                        beside the bundle, the landing sound and a UI tick play, the camera dips
--                        a fraction of a degree. The bag's authoritative value is applied here, so
--                        the number changes when the feather arrives and not before.
--
-- Everything is keyed by the feather record id the server confirmed. Flights overlap (pooled, capped
-- at pickup.maxFlights - a flight past the cap lands instantly, it is never cancelled); a refusal
-- cancels only its own record. Nothing here changes inventory, and nothing touches any record but
-- the one that was picked. The same flight also carries every other source of a pick (rake streams,
-- another player's vac) through `PileVisualController.setFlightDriver`, and the sale choreography
-- (bag counting down as representative feathers stream from the bundle into the crate, cash counting
-- up, the popup at the end) lives here too, so a trade reads as the same physical language.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local AssetManifest = require(Shared.Design.AssetManifest)
local FeatherLayout = require(Shared.Domain.FeatherLayout)
local SalePopup = require(script.Parent.Parent.UI.SalePopup)
local Feedback = require(script.Parent.Parent.UI.Feedback)

local PickupFeedbackController = {}
PickupFeedbackController.__index = PickupFeedbackController

export type Deps = {
	hud: any,
	pile: any,
	audio: any,
	haptics: any,
	camera: any,
	vfx: any,
	accessibility: any,
	quality: any,
	round: any,
	crate: any,
	config: { [string]: any },
}

type Flight = {
	part: BasePart,
	id: number?,
	trail: Trail?,
	attachments: { Attachment },
	returnTo: (BasePart) -> (),
	started: number,
	baseSize: Vector3?,
	baseColor: Color3?,
}

export type PickupFeedbackController = typeof(setmetatable(
	{} :: {
		_deps: Deps,
		_trove: Trove.Trove,
		_active: { Flight },
		_pressed: { [number]: boolean },
		_floatPool: { TextLabel },
		_floatBusy: { TextLabel },
		_streamPool: { BasePart },
		_saleThread: thread?,
		stats: {
			presses: number,
			cancelled: number,
			flights: number,
			landings: number,
			instantLandings: number,
			floats: number,
			sales: number,
		},
	},
	PickupFeedbackController
))

local TEMPLATE_SIZE = Vector3.new(0.54, 1.44, 0.13)

local function easeOutCubic(t: number): number
	local u = 1 - t
	return 1 - u * u * u
end

local function easeInOutSine(t: number): number
	return -(math.cos(math.pi * t) - 1) / 2
end

function PickupFeedbackController.new(deps: Deps): PickupFeedbackController
	local self = setmetatable({
		_deps = deps,
		_trove = Trove.new(),
		_active = {},
		_pressed = {},
		_floatPool = {},
		_floatBusy = {},
		_streamPool = {},
		_saleThread = nil,
		stats = { presses = 0, cancelled = 0, flights = 0, landings = 0, instantLandings = 0, floats = 0, sales = 0 },
	}, PickupFeedbackController)

	-- Every source of a pick flies through here.
	deps.pile:setFlightDriver(function(part, from, target, options)
		self:fly(part, from, target, {
			seconds = options and options.seconds or nil,
			quiet = true,
			returnTo = function(flown)
				deps.pile:returnFlown(flown)
			end,
		})
	end)
	self._trove:add(function()
		if deps.pile.setFlightDriver then
			deps.pile:setFlightDriver(nil)
		end
	end)
	self._trove:add(deps.round.sale:Connect(function(sale)
		self:_onSale(sale)
	end))
	self._trove:add(deps.round.phaseChanged:Connect(function(phase)
		if phase ~= "Searching" and phase ~= "EggRevealed" then
			self:reset("phase")
		end
	end))
	local player = Players.LocalPlayer
	self._trove:add(player.CharacterRemoving:Connect(function()
		self:reset("character")
	end))
	return self
end

function PickupFeedbackController._pickup(self: PickupFeedbackController): { [string]: any }
	return self._deps.config.pile.visual.pickup
end

-- ---------------------------------------------------------------------------------------------
-- Press / cancel
-- ---------------------------------------------------------------------------------------------

-- The instant of input, before any network round trip: the record loosens, the pluck sounds, the
-- reticle dips. Nothing authoritative changes.
function PickupFeedbackController.press(self: PickupFeedbackController, featherId: number)
	self.stats.presses += 1
	self._pressed[featherId] = true
	if self._deps.pile.beginLift then
		self._deps.pile:beginLift(featherId)
	end
	self._deps.audio:play(Tokens.sound.collectTug)
	if self._deps.hud.reticlePunch then
		self._deps.hud:reticlePunch()
	end
end

-- The server refused this record. Stale (someone else has it, it is buried) means it leaves the
-- screen; any other refusal eases it back into its seat. Only this record is touched.
function PickupFeedbackController.cancel(self: PickupFeedbackController, featherId: number, stale: boolean)
	self._pressed[featherId] = nil
	self.stats.cancelled += 1
	if stale and self._deps.pile.dropFeather then
		self._deps.pile:dropFeather(featherId)
	elseif self._deps.pile.cancelLift then
		self._deps.pile:cancelLift(featherId)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Flight
-- ---------------------------------------------------------------------------------------------

local function attachTrail(part: BasePart, seconds: number, color: Color3): (Trail, { Attachment })
	local a = Instance.new("Attachment")
	a.Name = "TrailA"
	a.Position = Vector3.new(0, part.Size.Y * 0.25, 0)
	a.Parent = part
	local b = Instance.new("Attachment")
	b.Name = "TrailB"
	b.Position = Vector3.new(0, -part.Size.Y * 0.25, 0)
	b.Parent = part
	local trail = Instance.new("Trail")
	trail.Name = "PickTrail"
	trail.Attachment0 = a
	trail.Attachment1 = b
	trail.Lifetime = seconds
	trail.MinLength = 0.05
	trail.LightEmission = 0.6
	trail.Color = ColorSequence.new(color)
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) })
	trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.2) })
	trail.Parent = part
	return trail, { a, b }
end

local function stripTrail(flight: Flight)
	if flight.trail then
		flight.trail:Destroy()
		flight.trail = nil
	end
	for _, attachment in ipairs(flight.attachments) do
		attachment:Destroy()
	end
	table.clear(flight.attachments)
end

-- Flies `part` from `from` to wherever `target()` says the bundle is, then hands it back through
-- `returnTo`. `onLand` fires exactly once when it arrives. Past the flight cap the part lands at
-- once (hooks still fire) so a burst of picks never waits on the presentation.
function PickupFeedbackController.fly(
	self: PickupFeedbackController,
	part: BasePart,
	from: Vector3,
	target: () -> Vector3,
	options: {
		seconds: number?,
		quiet: boolean?,
		rainbow: boolean?,
		id: number?,
		returnTo: ((BasePart) -> ())?,
		onLand: (() -> ())?,
		release: boolean?,
	}
)
	local pickup = self:_pickup()
	local motion = self._deps.accessibility:motionSettings()
	local returnTo = options.returnTo or function(flown)
		self._deps.pile:returnFlown(flown)
	end
	local landed = false
	local function land()
		if landed then
			return
		end
		landed = true
		self.stats.landings += 1
		if options.onLand then
			local ok, err = pcall(options.onLand)
			if not ok then
				warn("[SFE][Pickup] landing hook failed: " .. tostring(err))
			end
		end
	end
	if #self._active >= pickup.maxFlights then
		self.stats.instantLandings += 1
		returnTo(part)
		land()
		return
	end
	local flight: Flight = {
		part = part,
		id = options.id,
		trail = nil,
		attachments = {},
		returnTo = returnTo,
		started = os.clock(),
		baseSize = part.Size,
		baseColor = part.Color,
	}
	table.insert(self._active, flight)
	self.stats.flights += 1
	local releaseSeconds = if options.release == false then 0 else Motion.clampSeconds(pickup.releaseSeconds, motion)
	local flightSeconds = Motion.clampSeconds(options.seconds or pickup.flightSeconds, motion)
	local lift = Motion.amplitude(pickup.releaseLiftStuds, motion)
	local arc = Motion.amplitude(pickup.flightArcStuds, motion)
	local side = Motion.amplitude(pickup.flightSideStuds, motion)
	local roll = math.rad(pickup.flightRollDegrees)
	local baseSize = part.Size
	-- In flight the feather warms a step towards gold: still the same feather, but lit, so it reads
	-- against the white mound it just left. Restored before the part goes back to the pool.
	local baseColor = part.Color
	local flightColor = baseColor:Lerp(Color3.fromRGB(255, 214, 120), if options.rainbow then 0 else 0.35)
	part.Color = flightColor
	-- The release starts from the seat the record actually had; `from` is the same point for a
	-- coat record and the spawn point for a stream part.
	local seat = if (part.Position - from).Magnitude > 0.5 then CFrame.new(from) else part.CFrame
	local trailColor = if options.rainbow then Color3.fromRGB(236, 190, 255) else Color3.fromRGB(255, 236, 190)
	if not motion.reducedMotion and (self._deps.quality == nil or self._deps.quality:tier() ~= "low") then
		flight.trail, flight.attachments = attachTrail(part, pickup.trailSeconds, trailColor)
	end
	if not options.quiet then
		self._deps.audio:play(Tokens.sound.collectFlight)
	end
	local function finish()
		local index = table.find(self._active, flight)
		if index then
			table.remove(self._active, index)
		end
		stripTrail(flight)
		part.Size = baseSize
		part.Transparency = 0
		part.Color = baseColor
		returnTo(part)
		land()
	end
	task.spawn(function()
		-- Release: up and out of the surface along the feather's own normal, a touch larger.
		local elapsed = 0
		local up = seat.UpVector
		while elapsed < releaseSeconds do
			local dt = RunService.Heartbeat:Wait()
			if not table.find(self._active, flight) then
				return
			end
			elapsed += dt
			local t = math.clamp(elapsed / releaseSeconds, 0, 1)
			local e = easeOutCubic(t)
			part.CFrame = seat + up * (lift * e) + Vector3.new(0, lift * 0.4 * e, 0)
			part.Size = baseSize * (1 + (pickup.launchScale - 1) * e)
		end
		-- Flight: a three-point curve that bows outward, then tucks into the bundle.
		local origin = part.Position
		local camera = workspace.CurrentCamera
		local right = if camera then camera.CFrame.RightVector else Vector3.xAxis
		elapsed = 0
		while elapsed < flightSeconds do
			local dt = RunService.Heartbeat:Wait()
			if not table.find(self._active, flight) then
				return
			end
			elapsed += dt
			local t = math.clamp(elapsed / flightSeconds, 0, 1)
			local e = easeInOutSine(t)
			local destination = target()
			local control = origin:Lerp(destination, 0.45) + Vector3.new(0, arc, 0) + right * side
			local point = origin:Lerp(control, e):Lerp(control:Lerp(destination, e), e)
			local ahead = control:Lerp(destination, e) - origin:Lerp(control, e)
			local facing = if ahead.Magnitude > 1e-4 then CFrame.lookAt(point, point + ahead) else CFrame.new(point)
			part.CFrame = facing * CFrame.Angles(math.rad(90), 0, roll * e)
			local scale = pickup.launchScale + (pickup.tuckScale - pickup.launchScale) * e
			part.Size = baseSize * scale
			part.Transparency = if t > 0.85 then (t - 0.85) / 0.15 * 0.6 else 0
		end
		finish()
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Confirmed pick: the transaction from release to landing
-- ---------------------------------------------------------------------------------------------

-- The exact records the server removed, in the order it chose them. Nothing else ever animates: the
-- cavity the player sees is the reward they got.
local function ids(data: { [string]: any }): { number }
	local list = {}
	if data.featherId then
		table.insert(list, data.featherId)
		return list
	end
	if type(data.featherIds) == "table" then
		for _, featherId in ipairs(data.featherIds) do
			table.insert(list, featherId)
		end
		return list
	end
	for _, removal in ipairs(data.cells or {}) do
		for _, slot in ipairs(removal.slots or {}) do
			table.insert(list, FeatherLayout.featherId(removal.index, slot))
		end
	end
	return list
end

-- The server accepted `data` (one record for the hand, a streamed set for the rake). Each record
-- detaches and flies; the bag, bundle, float, sounds and camera all happen at the first landing.
function PickupFeedbackController.collected(self: PickupFeedbackController, data: { [string]: any }, hitPosition: Vector3, toolId: string)
	local pickup = self:_pickup()
	local deps = self._deps
	local list = ids(data)
	local rainbow = (data.rainbow or 0) > 0
	local awarded = (data.awarded or 0) + (data.rainbow or 0)
	local stagger = (deps.config.tools.nestRake or {}).streamStaggerSeconds or 0.028
	local streamed = if #list > 1 then #list else 0
	data.streamSeconds = if streamed > 1 then streamed * stagger else 0
	local function destination(): Vector3
		return deps.hud:carriedStackWorldPoint() or hitPosition
	end
	local firstLanded = false
	if deps.hud.holdBag then
		deps.hud:holdBag()
	end
	local function landing(index: number)
		if not firstLanded then
			firstLanded = true
			deps.hud:onCollected(data)
			if deps.hud.releaseBag then
				deps.hud:releaseBag()
			end
			self:float(awarded, rainbow)
			deps.audio:play(Tokens.sound.collectRelease)
			deps.audio:play(Tokens.sound.collectTick)
			if rainbow then
				-- A Rainbow Feather lands like any feather (its float and bundle say it is special); the
				-- extra ping it used to layer on the landing was never an assigned sound.
				deps.haptics:pulse(0.6, 0.12)
			end
			deps.haptics:pulse(if toolId == "nestRake" then 0.4 else 0.25, 0.05)
			deps.camera:nudge({
				studs = pickup.cameraNudgeStuds,
				degrees = pickup.cameraNudgeDegrees,
				fov = pickup.cameraFovDegrees,
				returnSeconds = pickup.cameraReturnSeconds,
			})
			if data.bagFull then
				-- The pick that filled the bag: the refusal voice, once per window, through the gate.
				Feedback.deny("bag_full", "Bag full - trade your feathers")
				deps.haptics:pulse(0.6, 0.12)
			end
		elseif index % 3 == 0 then
			-- A streamed sweep keeps ticking as it lands, thinned so it never becomes a wall.
			deps.audio:play(Tokens.sound.collectTick)
			deps.hud.carriedStack:land(pickup.landSquashScale * 0.7, pickup.landTiltDegrees * 0.5)
		end
	end
	for index, featherId in ipairs(list) do
		self._pressed[featherId] = nil
		local delay = (index - 1) * stagger
		local function go()
			local part, from = deps.pile:detachFeather(featherId, hitPosition)
			if not part then
				landing(index)
				return
			end
			-- Contact: a concentrated glint and a few down motes at the source. Only the first of a
			-- stream, so a sweep is one contact and not thirty.
			if index == 1 then
				deps.vfx:burst("glint", from, 0.05)
				if pickup.moteCount > 0 then
					deps.vfx:burst("down", from, pickup.moteSeconds * (pickup.moteCount / 12))
				end
			end
			self:fly(part, from, destination, {
				id = featherId,
				rainbow = rainbow and index == 1,
				quiet = index > 1,
				onLand = function()
					landing(index)
				end,
			})
		end
		if delay <= 0 then
			go()
		else
			task.delay(delay, go)
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- "+1 Feather" beside the bundle (pooled)
-- ---------------------------------------------------------------------------------------------

function PickupFeedbackController._acquireFloat(self: PickupFeedbackController): TextLabel?
	local pickup = self:_pickup()
	local label = table.remove(self._floatPool)
	if not label then
		if #self._floatBusy >= pickup.floatPoolSize then
			-- Recycle the oldest rather than growing without bound under spam.
			label = table.remove(self._floatBusy, 1)
		else
			label = Instance.new("TextLabel")
			label.Name = "PickupFloat"
			label.BackgroundTransparency = 1
			label.AnchorPoint = Vector2.new(0, 0.5)
			label.Size = UDim2.fromScale(0.9, 0.2)
			label.Font = Tokens.typography.label.font
			label.TextScaled = true
			label.TextXAlignment = Enum.TextXAlignment.Left
			local constraint = Instance.new("UITextSizeConstraint")
			constraint.MaxTextSize = 22
			constraint.MinTextSize = 10
			constraint.Parent = label
			local stroke = Instance.new("UIStroke")
			stroke.Name = "Outline"
			stroke.Thickness = 2.4
			stroke.Color = Tokens.color.outline
			stroke.Parent = label
			label.ZIndex = 6
		end
	end
	return label
end

function PickupFeedbackController.float(self: PickupFeedbackController, amount: number, rainbow: boolean)
	if amount <= 0 then
		return
	end
	local pickup = self:_pickup()
	local hud = self._deps.hud
	local frame = hud.carriedStack and hud.carriedStack.frame
	if not frame or not frame.Visible then
		return
	end
	local label = self:_acquireFloat()
	if not label then
		return
	end
	local motion = self._deps.accessibility:motionSettings()
	self.stats.floats += 1
	table.insert(self._floatBusy, label)
	local word = if rainbow then "Rainbow Feather" else "Feather"
	if amount > 1 then
		word ..= "s"
	end
	label.Text = string.format("+%d %s", amount, word)
	label.TextColor3 = if rainbow then Color3.fromRGB(226, 150, 255) else Tokens.color.goldLight
	label.TextTransparency = 0
	local stroke = label:FindFirstChild("Outline") :: UIStroke?
	if stroke then
		stroke.Transparency = 0
	end
	local startY = 0.14
	label.Position = UDim2.fromScale(0.04, startY)
	label.Parent = frame
	local seconds = Motion.clampSeconds(pickup.floatSeconds, motion)
	local rise = Motion.amplitude(pickup.floatRisePx, motion)
	local scale = label:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = label
	scale.Scale = 0.7
	TweenService:Create(scale, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	TweenService:Create(label, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.04, 0, startY, -rise),
	}):Play()
	task.delay(seconds * 0.5, function()
		if label.Parent ~= frame then
			return
		end
		TweenService:Create(label, TweenInfo.new(seconds * 0.5), { TextTransparency = 1 }):Play()
		if stroke then
			TweenService:Create(stroke, TweenInfo.new(seconds * 0.5), { Transparency = 1 }):Play()
		end
	end)
	task.delay(seconds + 0.05, function()
		local index = table.find(self._floatBusy, label)
		if index then
			table.remove(self._floatBusy, index)
			label.Parent = nil
			table.insert(self._floatPool, label)
		end
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Sale: the bundle streams into the crate, the bag counts down, the cash counts up
-- ---------------------------------------------------------------------------------------------

function PickupFeedbackController._acquireStreamPart(self: PickupFeedbackController): BasePart
	local part = table.remove(self._streamPool)
	if part then
		return part
	end
	local template = AssetManifest.model("feather")
	if template and template:IsA("BasePart") then
		part = template:Clone() :: BasePart
	else
		part = Instance.new("Part")
		part.Size = TEMPLATE_SIZE
	end
	part.Name = "SaleFeather"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = Color3.fromRGB(246, 236, 214)
	part.Size = TEMPLATE_SIZE * 1.4
	return part :: BasePart
end

function PickupFeedbackController._onSale(self: PickupFeedbackController, sale: { [string]: any })
	local deps = self._deps
	local pickup = self:_pickup()
	local motion = deps.accessibility:motionSettings()
	self.stats.sales += 1
	if self._saleThread then
		task.cancel(self._saleThread)
		self._saleThread = nil
	end
	local count = (sale.standardCount or 0) + (sale.rainbowCount or 0)
	local capacity = deps.config.bags.levels[(deps.round.player and deps.round.player.bagLevel) or 1].capacity
	local infinite = deps.round.player and deps.round.player.bagInfinite == true
	local seconds = Motion.clampSeconds(pickup.saleStreamSeconds, motion)
	deps.audio:play(Tokens.sound.sellArc)
	deps.hud.carriedStack:clear(true)
	-- Representative feathers from the bundle's world point into the crate's mouth.
	local n = math.min(pickup.saleStreamCount, count)
	local mouth = deps.crate and deps.crate.mouth and deps.crate:mouth() or nil
	local origin = deps.hud:carriedStackWorldPoint()
	local landedCount = 0
	local function tick()
		landedCount += 1
		if deps.crate then
			deps.crate:squash(0.06)
			deps.crate:showFeathers(landedCount / math.max(1, n))
		end
		deps.audio:play(Tokens.sound.sellTick)
		local at = deps.crate and deps.crate:mouth() or nil
		if at and landedCount % 2 == 0 then
			deps.vfx:burst("sparkle", at, 0.12)
		end
	end
	local streamed = n > 0 and mouth ~= nil and origin ~= nil
	if streamed then
		local camera = workspace.CurrentCamera
		local gap = seconds / math.max(1, n)
		for index = 1, n do
			task.delay((index - 1) * gap, function()
				local part = self:_acquireStreamPart()
				local spread = if camera then camera.CFrame.RightVector * ((index % 3) - 1) * 0.25 else Vector3.zero
				part.CFrame = CFrame.new((origin :: Vector3) + spread)
				part.Transparency = 0
				part.Parent = workspace
				self:fly(part, part.Position, function()
					return deps.crate:mouth() or (mouth :: Vector3)
				end, {
					seconds = 0.26,
					quiet = index > 1,
					release = false,
					returnTo = function(flown)
						flown.Parent = nil
						table.insert(self._streamPool, flown)
					end,
					onLand = tick,
				})
			end)
		end
	elseif deps.crate then
		deps.crate:showFeathers(1)
	end
	-- Bag counts down as the feathers leave; cash counts up as they land.
	local started = os.clock()
	local countdownSeconds = if streamed then seconds + 0.2 else 0.25
	self._saleThread = task.spawn(function()
		while true do
			local t = math.clamp((os.clock() - started) / countdownSeconds, 0, 1)
			local shown = math.floor(count * (1 - easeOutCubic(t)) + 0.5)
			deps.hud.round:setBag(shown, capacity, infinite, false)
			if t >= 1 then
				break
			end
			task.wait()
		end
		deps.hud.round:setBag(0, capacity, false, true)
		self._saleThread = nil
	end)
	task.delay(if streamed then seconds * 0.35 else 0, function()
		deps.hud.round:setCash(sale.cashCents, true, function()
			deps.audio:play(Tokens.sound.sellTick, { pitchVariance = 0.05 })
		end)
	end)
	-- The total, once the last feather is in.
	task.delay(if streamed then seconds + 0.3 else 0.1, function()
		-- One sale, one sound and one card: the burst is the sale's voice (the Rainbow ping and the
		-- popup's confetti pop that used to stack on it are gone), and the popup names the Rainbow
		-- Feathers itself rather than a second toast doing it.
		if sale.finalCents >= 100 then
			deps.audio:play(Tokens.sound.sellBurst)
		end
		SalePopup.show(deps.hud.stage, {
			feathers = count,
			rainbow = sale.rainbowCount or 0,
			cents = sale.finalCents,
			motion = motion,
			tier = if deps.quality then deps.quality:tier() else nil,
		})
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------------

-- Everything in flight lands now and every float clears: a round end, a respawn, a teleport.
function PickupFeedbackController.reset(self: PickupFeedbackController, _reason: string?)
	local active = self._active
	self._active = {}
	for _, flight in ipairs(active) do
		stripTrail(flight)
		flight.part.Transparency = 0
		flight.part.Size = flight.baseSize or flight.part.Size
		if flight.baseColor then
			flight.part.Color = flight.baseColor
		end
		local ok, err = pcall(flight.returnTo, flight.part)
		if not ok then
			warn("[SFE][Pickup] could not return a flown part: " .. tostring(err))
		end
	end
	for _, label in ipairs(self._floatBusy) do
		label.Parent = nil
		table.insert(self._floatPool, label)
	end
	table.clear(self._floatBusy)
	table.clear(self._pressed)
	if self._deps.hud.releaseAllBagHolds then
		self._deps.hud:releaseAllBagHolds()
	end
	if self._saleThread then
		task.cancel(self._saleThread)
		self._saleThread = nil
	end
end

function PickupFeedbackController.status(self: PickupFeedbackController): { [string]: any }
	local pending = 0
	for _ in pairs(self._pressed) do
		pending += 1
	end
	return {
		activeFlights = #self._active,
		pendingPresses = pending,
		floatsBusy = #self._floatBusy,
		floatsPooled = #self._floatPool,
		streamPooled = #self._streamPool,
		cameraNeutral = if self._deps.camera.isNeutral then self._deps.camera:isNeutral() else nil,
		stats = self.stats,
	}
end

function PickupFeedbackController.destroy(self: PickupFeedbackController)
	self:reset("destroy")
	for _, label in ipairs(self._floatPool) do
		label:Destroy()
	end
	for _, part in ipairs(self._streamPool) do
		part:Destroy()
	end
	self._trove:destroy()
end

return PickupFeedbackController
