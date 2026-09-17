--!strict
-- The round's mid-round event on this client. The server owns every rule and number; this controller
-- only shows them:
--   * a compact pill under the objective banner: name, progress where it has one, and the countdown
--     ("RAINBOW RUSH 0:24", "SUPPLY DROP 84/150 0:31", "CHICK RESCUE 0:40");
--   * Rainbow Rush: the converted records handed to the pile (they render rainbow as they surface),
--     and a rainbow burst over the nest as it starts;
--   * Supply Drop: the server's crate falls in with a thud of dust and a golden ripple, and carries a
--     world fill bar;
--   * Chick Rescue: the owner's DodoBird (or a small built chick) struggles in the server's cage,
--     chirps from where it is every few seconds, and hops out in a golden burst when freed.
-- Start, end and reward lines are the server's announcements (AnnouncementService); the effects are
-- the shared CelebrationController's.
-- The crate's and cage's prompts send the one RoundEventAction request. Motion is scaled down for
-- reduced motion and trimmed on the low quality tier; every instance goes with the event or the round.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Trove = require(Shared.Util.Trove)
local RoundEvents = require(Shared.Domain.RoundEvents)
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local Feedback = require(script.Parent.Parent.UI.Feedback)
local Depth = require(script.Parent.Parent.UI.Components.Depth)
local WorldBillboard = require(script.Parent.Parent.UI.Components.WorldBillboard)

local RoundEventController = {}
RoundEventController.__index = RoundEventController

local FOLDER_NAME = "SFE_RoundEvents"
local DEPOSIT_PROMPT = "SFE_SupplyDeposit"
local RESCUE_PROMPT = "SFE_ChickRescue"
local EVENT_ATTRIBUTE = "SFE_EventId"
local MODELS_FOLDER = "SFE_ToolModels"
local PILL_HEIGHT = 24
local FIND_SECONDS = 6
local DROP_HEIGHT_STUDS = 40

export type RoundEventController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_trove: Trove.Trove,
		_eventTrove: Trove.Trove?,
		_event: { [string]: any }?,
		_endsAt: number,
		_pill: Frame,
		_pillLabel: TextLabel,
		_pillText: string,
		_announcementSpace: number,
		_place: () -> (),
		_bar: { label: TextLabel, fill: Frame }?,
		_chick: { model: Model, anchor: BasePart?, cage: Model?, rest: CFrame, nextChirp: number, freed: boolean }?,
		stats: { started: number, ended: number, requests: number, refused: number, chirps: number },
	},
	RoundEventController
))

local DENIAL_TEXT: { [string]: string } = {
	no_feathers = "Your bag has no normal feathers",
	player_cap = "You have given all you can to this drop",
	filled = "The crate is already full",
	range = "Get closer",
	hold = "Hold a moment longer",
	no_event = "That event is over",
	event_over = "That event is over",
}

local function clockText(seconds: number): string
	local whole = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", math.floor(whole / 60), whole % 60)
end

function RoundEventController.new(deps: {
	net: any,
	round: any,
	hud: any,
	pile: any,
	audio: any,
	vfx: any,
	quality: any,
	accessibility: any,
	config: { [string]: any },
	celebration: any?,
	dialogue: any?,
}): RoundEventController
	local trove = Trove.new()
	local pill = Instance.new("Frame")
	pill.Name = "RoundEventPill"
	pill.AnchorPoint = Vector2.new(0.5, 0)
	pill.Size = UDim2.fromOffset(0, PILL_HEIGHT)
	pill.AutomaticSize = Enum.AutomaticSize.X
	pill.BackgroundColor3 = Tokens.color.panelDeep
	pill.BackgroundTransparency = 0.1
	pill.BorderSizePixel = 0
	pill.ZIndex = Tokens.zIndex.hud
	pill.Visible = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = pill
	local keyline = Depth.keyline(pill, Tokens.stroke.hairline, Tokens.color.gold)
	keyline.Transparency = 0.2
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.md)
	padding.Parent = pill
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(0, 1)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Font = Tokens.typography.label.font
	label.TextSize = Tokens.typography.caption.size
	label.TextColor3 = Tokens.color.goldLight
	label.Text = ""
	label.ZIndex = pill.ZIndex + 1
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = Tokens.color.outline
	stroke.Parent = label
	label.Parent = pill
	pill.Parent = deps.hud.stage
	trove:add(pill)

	local self = setmetatable({
		_deps = deps,
		_trove = trove,
		_eventTrove = nil,
		_event = nil,
		_endsAt = 0,
		_pill = pill,
		_pillLabel = label,
		_pillText = "",
		_announcementSpace = 0,
		_place = function() end,
		_bar = nil,
		_chick = nil,
		stats = { started = 0, ended = 0, requests = 0, refused = 0, chirps = 0 },
	}, RoundEventController)

	-- Sits just under the objective pill and follows its height (the detail line comes and goes), and
	-- steps below a big announcement while one is on screen instead of hiding under it.
	local banner = deps.hud.stage:FindFirstChild("Banner") :: Frame?
	local function place()
		local top = if deps.hud.objectiveBottomPx
			then deps.hud:objectiveBottomPx()
			else Tokens.layout.safeAreaPaddingPx + Tokens.layout.minimumTapTargetPx
		pill.Position = UDim2.new(0.5, 0, 0, top + self._announcementSpace)
	end
	self._place = place
	if banner then
		trove:add(banner:GetPropertyChangedSignal("Size"):Connect(place))
	end
	place()

	trove:add(deps.net:on("RoundEvent", function(payload)
		self:_onRemote(payload)
	end))
	trove:add(deps.round.snapshot:Connect(function(payload)
		self:_onSnapshot(payload)
	end))
	trove:add(deps.round.phaseChanged:Connect(function(phase)
		if phase == "Returning" or phase == "Abandoned" then
			self:clear()
		end
	end))
	trove:add(ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if player ~= Players.LocalPlayer then
			return
		end
		if prompt.Name == DEPOSIT_PROMPT then
			self:request("deposit")
		elseif prompt.Name == RESCUE_PROMPT then
			self:request("rescue")
		end
	end))
	return self
end

-- The announcement banner reports the room it takes under the objective (0 when it is gone).
function RoundEventController.setAnnouncementSpace(self: RoundEventController, px: number)
	self._announcementSpace = math.max(0, px)
	self._place()
end

function RoundEventController.active(self: RoundEventController): { [string]: any }?
	return self._event
end

-- Sends the prompt's action. The server decides everything; a refusal reads as one short line.
function RoundEventController.request(self: RoundEventController, action: string): any
	local deps = self._deps
	if deps.dialogue and deps.dialogue:isOpen() then
		return nil
	end
	local token = deps.round:sessionToken()
	if not token then
		return nil
	end
	self.stats.requests += 1
	local result = deps.net:request("RoundEventAction", { sessionToken = token, action = action })
	if not result.ok then
		self.stats.refused += 1
		local reason = tostring(result.message or result.code)
		Feedback.deny("roundEvent:" .. reason, DENIAL_TEXT[reason] or "Not right now")
	elseif action == "deposit" and self._bar then
		-- The crate takes the feathers: a small puff of dust off its lid.
		local crate = self._bar.label:FindFirstAncestorOfClass("BillboardGui")
		local adornee = crate and crate.Adornee
		if adornee and adornee:IsA("BasePart") then
			deps.vfx:burst("smoke", adornee.Position + Vector3.new(0, 1.8, 0), 0.12)
		end
	end
	return result
end

function RoundEventController._onRemote(self: RoundEventController, payload: { [string]: any })
	if type(payload) ~= "table" then
		return
	end
	local event = payload.event
	if payload.rainbowOverrides and self._deps.pile then
		self._deps.pile:applyRainbowOverrides(payload.rainbowOverrides)
	end
	if type(event) ~= "table" then
		return
	end
	if payload.type == "start" then
		self:_begin(event, true)
	elseif payload.type == "update" then
		if self._event and self._event.id == event.id then
			self:_apply(event)
		else
			self:_begin(event, false)
		end
	elseif payload.type == "end" then
		self:_finish(event, true)
	end
end

-- A snapshot (join, respawn, phase change) carries the event too: join it mid-way or close it.
function RoundEventController._onSnapshot(self: RoundEventController, payload: { [string]: any })
	local event = payload.event
	if type(event) ~= "table" then
		if self._event and payload.phase ~= nil and payload.phase ~= "Searching" then
			self:_teardown()
		end
		return
	end
	if event.kind == "rainbowRush" and event.conversions and self._deps.pile then
		self._deps.pile:applyRainbowOverrides(event.conversions)
	end
	if event.status == "active" then
		if self._event and self._event.id == event.id then
			self:_apply(event)
		else
			self:_begin(event, false)
		end
	elseif self._event and self._event.id == event.id then
		self:_finish(event, false)
	end
end

function RoundEventController._apply(self: RoundEventController, event: { [string]: any })
	self._event = event
	self._endsAt = os.clock() + (event.remainingMs or 0) / 1000
	self:_refresh()
end

function RoundEventController._refresh(self: RoundEventController)
	local event = self._event
	if not event then
		return
	end
	local name = event.name or RoundEvents.NAMES[event.kind] or "EVENT"
	local remaining = clockText(self._endsAt - os.clock())
	local text = if event.kind == "supplyDrop"
		then string.format("%s %d/%d %s", name, event.progress or 0, event.target or 0, remaining)
		else string.format("%s %s", name, remaining)
	if text ~= self._pillText then
		self._pillText = text
		self._pillLabel.Text = text
	end
	local bar = self._bar
	if bar and event.kind == "supplyDrop" then
		bar.label.Text = string.format("SUPPLY DROP %d/%d", event.progress or 0, event.target or 0)
		local fraction = if (event.target or 0) > 0 then math.clamp((event.progress or 0) / event.target, 0, 1) else 0
		bar.fill.Size = UDim2.fromScale(fraction, 1)
	end
end

function RoundEventController._begin(self: RoundEventController, event: { [string]: any }, fresh: boolean)
	self:_teardown()
	local deps = self._deps
	self.stats.started += 1
	local eventTrove = Trove.new()
	self._eventTrove = eventTrove
	self:_apply(event)
	self._pill.Visible = true
	if fresh and event.kind == "rainbowRush" and deps.celebration then
		-- The nest shimmers: a rainbow burst over the mound's crown.
		local layout = deps.config and ChapterLayout[deps.round.round and deps.round.round.chapter or "chapter1"]
		if layout and layout.nestCenter then
			deps.celebration:burst(layout.nestCenter + Vector3.new(0, 8, 0), "rainbow", 1.4)
		end
	end
	local reduced = deps.accessibility:reducedMotion()
	local low = deps.quality:tier() == "low"
	local id = event.id
	-- The world pieces are the server's and may replicate a moment after the payload.
	if event.kind == "supplyDrop" or event.kind == "chickRescue" then
		task.spawn(function()
			local deadline = os.clock() + FIND_SECONDS
			local model: Model? = nil
			while not model and os.clock() < deadline do
				local folder = workspace:FindFirstChild(FOLDER_NAME)
				if folder then
					for _, child in ipairs(folder:GetChildren()) do
						if child:IsA("Model") and child:GetAttribute(EVENT_ATTRIBUTE) == id then
							model = child
							break
						end
					end
				end
				if not model then
					task.wait(0.2)
				end
			end
			if not model or self._eventTrove ~= eventTrove then
				return
			end
			if event.kind == "supplyDrop" then
				self:_dressCrate(model, eventTrove, fresh and not reduced, low)
			else
				self:_dressCage(model, eventTrove, reduced, low)
			end
		end)
	end
	eventTrove:add(RunService.Heartbeat:Connect(function(dt)
		self:_step(dt, reduced, low)
	end))
end

function RoundEventController._dressCrate(self: RoundEventController, model: Model, eventTrove: Trove.Trove, animate: boolean, low: boolean)
	local deps = self._deps
	local body = model:FindFirstChild("Body") :: BasePart?
	if not body then
		return
	end
	local gui = WorldBillboard.create(body, "SFE_SupplyBar", Vector2.new(5.6, 1.5), Vector3.new(0, 3.6, 0), 90, body)
	eventTrove:add(gui)
	local label = WorldBillboard.text(gui, "Label", "SUPPLY DROP", {
		size = UDim2.fromScale(1, 0.55),
		position = UDim2.fromScale(0.5, 0),
		anchor = Vector2.new(0.5, 0),
		color = Tokens.color.goldLight,
	})
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.fromScale(0.5, 0.96)
	track.Size = UDim2.fromScale(0.9, 0.3)
	track.BackgroundColor3 = Tokens.color.panelDeep
	track.BorderSizePixel = 0
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0.5, 0)
	trackCorner.Parent = track
	Depth.keyline(track, Tokens.stroke.hairline)
	track.Parent = gui
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Tokens.color.leaf
	fill.BorderSizePixel = 0
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0.5, 0)
	fillCorner.Parent = fill
	fill.Parent = track
	self._bar = { label = label, fill = fill }
	self:_refresh()
	local rest = model:GetPivot()
	local puffAt = rest.Position - Vector3.new(0, body.Size.Y * 0.5 - 0.2, 0)
	local function landed(strong: boolean)
		deps.vfx:burst("smoke", puffAt, if low or not strong then 0.15 else 0.35)
		if deps.celebration and strong then
			deps.celebration:goldenRipple(puffAt, 7)
			local camera = workspace.CurrentCamera
			if camera and (camera.CFrame.Position - puffAt).Magnitude < 45 then
				deps.celebration:cameraPunch(0.35, 0.3)
			end
		end
	end
	if not animate then
		landed(false)
		return
	end
	-- The fall: straight down from the sky, accelerating, a squash on landing and a puff of dust.
	local seconds = deps.config.roundEvents.events.supplyDrop.dropSeconds
	local started = os.clock()
	model:PivotTo(rest + Vector3.new(0, DROP_HEIGHT_STUDS, 0))
	local connection
	connection = RunService.Heartbeat:Connect(function()
		if model.Parent == nil then
			connection:Disconnect()
			return
		end
		local t = math.clamp((os.clock() - started) / seconds, 0, 1)
		model:PivotTo(rest + Vector3.new(0, DROP_HEIGHT_STUDS * (1 - t * t), 0))
		if t >= 1 then
			connection:Disconnect()
			model:PivotTo(rest)
			landed(true)
		end
	end)
	eventTrove:add(connection)
	eventTrove:add(function()
		if model.Parent then
			model:PivotTo(rest)
		end
	end)
end

local function buildChick(): Model
	local folder = ReplicatedStorage:FindFirstChild(MODELS_FOLDER)
	local source = folder and folder:FindFirstChild("DodoBird")
	if source and source:IsA("Model") then
		local model = source:Clone()
		model:ScaleTo(0.3)
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanQuery = false
				descendant.CanTouch = false
				if descendant.Name == "Origin" then
					descendant.Transparency = 1
				end
			end
		end
		model.Name = "SFE_EventChick"
		return model
	end
	-- Fallback: a small built chick (body, head, beak).
	local model = Instance.new("Model")
	model.Name = "SFE_EventChick"
	local function ball(name: string, size: Vector3, offset: Vector3, color: Color3): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Shape = Enum.PartType.Ball
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Size = size
		p.Color = color
		p.Material = Enum.Material.SmoothPlastic
		p.CFrame = CFrame.new(offset)
		p.Parent = model
		return p
	end
	local body = ball("Body", Vector3.new(1.1, 1, 1.1), Vector3.new(0, 0.5, 0), Tokens.color.straw)
	ball("Head", Vector3.new(0.7, 0.7, 0.7), Vector3.new(0, 1.15, -0.25), Tokens.color.honey)
	ball("Beak", Vector3.new(0.22, 0.18, 0.3), Vector3.new(0, 1.1, -0.62), Color3.fromRGB(240, 150, 40))
	model.PrimaryPart = body
	return model
end

function RoundEventController._dressCage(self: RoundEventController, cage: Model, eventTrove: Trove.Trove, _reduced: boolean, _low: boolean)
	local anchor = cage:FindFirstChild("PromptAnchor") :: BasePart?
	local chick = buildChick()
	local _, size = chick:GetBoundingBox()
	local floorTop = cage:GetPivot().Position + Vector3.new(0, 0.36, 0)
	local rest = CFrame.new(floorTop + Vector3.new(0, size.Y * 0.5, 0))
	chick:PivotTo(rest)
	chick.Parent = workspace
	eventTrove:add(chick)
	self._chick = {
		model = chick,
		anchor = anchor,
		cage = cage,
		rest = rest,
		nextChirp = os.clock() + 0.4,
		freed = false,
	}
end

function RoundEventController._step(self: RoundEventController, _dt: number, reduced: boolean, low: boolean)
	local event = self._event
	if not event then
		return
	end
	self:_refresh()
	local chick = self._chick
	if chick and not chick.freed and chick.model.Parent then
		local now = os.clock()
		-- Trapped: a restless shuffle and a flap now and then (none under reduced motion).
		if not reduced then
			local amount = if low then 0.5 else 1
			local wobble = math.sin(now * 9) * 0.12 * amount
			local hop = math.max(0, math.sin(now * 3.1)) ^ 8 * 0.35 * amount
			chick.model:PivotTo(chick.rest * CFrame.new(0, hop, 0) * CFrame.Angles(0, math.sin(now * 0.8) * 1.2, wobble))
		end
		local interval = self._deps.config.roundEvents.events.chickRescue.chirpIntervalSeconds
		if now >= chick.nextChirp then
			chick.nextChirp = now + interval
			local at = chick.anchor or chick.model.PrimaryPart
			if at then
				self._deps.audio:play(Tokens.sound.eventChirp, { at = at })
				self.stats.chirps += 1
			end
		end
	end
end

function RoundEventController._finish(self: RoundEventController, event: { [string]: any }, fresh: boolean)
	local current = self._event
	if not current or current.id ~= event.id then
		return
	end
	local deps = self._deps
	self._event = event
	self:_refresh()
	self.stats.ended += 1
	self._pill.Visible = false
	self._event = nil
	local eventTrove = self._eventTrove
	local chick = self._chick
	if fresh and event.result == "completed" and chick and chick.model.Parent then
		chick.freed = true
		self:_freeChick(chick, eventTrove)
	elseif fresh and event.result == "completed" and self._bar then
		self._bar.fill.Size = UDim2.fromScale(1, 1)
		self._bar.fill.BackgroundColor3 = Tokens.color.leafBright
		local gui = self._bar.label:FindFirstAncestorOfClass("BillboardGui")
		local adornee = gui and gui.Adornee
		if deps.celebration and adornee and adornee:IsA("BasePart") then
			deps.celebration:burst(adornee.Position + Vector3.new(0, 2, 0), "gold", 1)
		end
	end
	-- Leave the closing beat a moment on screen, then take everything away.
	if eventTrove then
		self._eventTrove = nil
		self._bar = nil
		self._chick = nil
		task.delay(if event.result == "completed" then 2 else 0.4, function()
			eventTrove:destroy()
		end)
	end
end

-- Freed: the bars vanish (locally), the chick hops up and out in a burst and is gone.
function RoundEventController._freeChick(self: RoundEventController, chick: any, eventTrove: Trove.Trove?)
	local deps = self._deps
	local reduced = deps.accessibility:reducedMotion()
	if chick.cage then
		for _, part in ipairs(chick.cage:GetChildren()) do
			if part:IsA("BasePart") and (part.Name == "Bar" or part.Name == "Lid" or part.Name == "Padlock") then
				part.Transparency = 1
			end
		end
	end
	local origin = chick.rest
	if deps.celebration then
		deps.celebration:burst(origin.Position + Vector3.new(0, 0.8, 0), "gold", 0.9)
	else
		deps.vfx:burst("spark", origin.Position + Vector3.new(0, 0.8, 0), if deps.quality:tier() == "low" then 0.15 else 0.35)
	end
	if reduced then
		return
	end
	local started = os.clock()
	local model = chick.model
	local connection
	connection = RunService.Heartbeat:Connect(function()
		if model.Parent == nil then
			connection:Disconnect()
			return
		end
		local t = math.clamp((os.clock() - started) / 1.2, 0, 1)
		local height = math.sin(t * math.pi) * 4
		model:PivotTo(origin * CFrame.new(0, height, -t * 5) * CFrame.Angles(0, t * math.pi * 2, 0))
		if t >= 1 then
			connection:Disconnect()
		end
	end)
	if eventTrove then
		eventTrove:add(connection)
	end
end

function RoundEventController._teardown(self: RoundEventController)
	if self._eventTrove then
		self._eventTrove:destroy()
		self._eventTrove = nil
	end
	self._event = nil
	self._bar = nil
	self._chick = nil
	self._pill.Visible = false
	self._pillText = ""
end

-- The round ended or the player left it: nothing of the event stays.
function RoundEventController.clear(self: RoundEventController)
	self:_teardown()
end

function RoundEventController.destroy(self: RoundEventController)
	self:_teardown()
	self._trove:destroy()
end

return RoundEventController
