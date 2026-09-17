--!strict
-- Server-built world pieces for the round events: the Supply Drop crate and the Chick Rescue cage,
-- each with the ProximityPrompt that drives its request. Built at the event's preset spot (never on
-- the pile), anchored, script-free, tagged with the event id so the client can find and dress them
-- (the crate's fall, the fill bar, the chick inside the cage). Removed shortly after the event ends
-- so a client's closing beat (the freed hop, the crate's last bar) has a moment to play.

local RoundEventWorld = {}
RoundEventWorld.__index = RoundEventWorld

RoundEventWorld.FOLDER_NAME = "SFE_RoundEvents"
RoundEventWorld.DEPOSIT_PROMPT = "SFE_SupplyDeposit"
RoundEventWorld.RESCUE_PROMPT = "SFE_ChickRescue"
RoundEventWorld.EVENT_ATTRIBUTE = "SFE_EventId"

local WOOD = Color3.fromRGB(150, 104, 60)
local WOOD_DEEP = Color3.fromRGB(104, 70, 40)
local IRON = Color3.fromRGB(70, 72, 80)
local STRAW = Color3.fromRGB(226, 196, 120)

export type RoundEventWorld = typeof(setmetatable(
	{} :: { _workspace: Instance, _config: { [string]: any }, _models: { [string]: Model } },
	RoundEventWorld
))

function RoundEventWorld.new(workspaceService: Instance, config: { [string]: any }): RoundEventWorld
	return setmetatable({ _workspace = workspaceService, _config = config, _models = {} }, RoundEventWorld)
end

local function folderOf(self: RoundEventWorld): Folder
	local existing = self._workspace:FindFirstChild(RoundEventWorld.FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = RoundEventWorld.FOLDER_NAME
	folder.Parent = self._workspace
	return folder
end

local function part(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	collide: boolean?,
	shape: Enum.PartType?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = collide == true
	p.CanQuery = collide == true
	p.CanTouch = false
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material
	p.Shape = shape or Enum.PartType.Block
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function prompt(anchor: BasePart, name: string, action: string, object: string, hold: number, range: number)
	local p = Instance.new("ProximityPrompt")
	p.Name = name
	p.ActionText = action
	p.ObjectText = object
	p.HoldDuration = hold
	-- A stud inside the server's own range check, so a prompt that shows is a request that passes.
	p.MaxActivationDistance = math.max(4, range - 1)
	p.RequiresLineOfSight = false
	p.Style = Enum.ProximityPromptStyle.Custom
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.GamepadKeyCode = Enum.KeyCode.ButtonX
	p.Parent = anchor
end

-- The Supply Drop crate, resting on the ground at `position` (the client plays its fall).
function RoundEventWorld.buildCrate(parent: Instance, event: any, config: { [string]: any }): Model
	local model = Instance.new("Model")
	model.Name = "SupplyDrop"
	local base = CFrame.new(event.position)
	local body = part(model, "Body", Vector3.new(4, 3.2, 4), base * CFrame.new(0, 1.6, 0), WOOD, Enum.Material.WoodPlanks, true)
	for _, corner in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
		part(
			model,
			"Post",
			Vector3.new(0.45, 3.3, 0.45),
			base * CFrame.new(corner[1] * 1.85, 1.65, corner[2] * 1.85),
			WOOD_DEEP,
			Enum.Material.Wood
		)
	end
	for _, y in ipairs({ 0.7, 2.5 }) do
		part(model, "Band", Vector3.new(4.12, 0.22, 4.12), base * CFrame.new(0, y, 0), IRON, Enum.Material.Metal)
	end
	part(model, "Lid", Vector3.new(4.2, 0.3, 4.2), base * CFrame.new(0, 3.35, 0), WOOD_DEEP, Enum.Material.WoodPlanks)
	part(model, "Straw", Vector3.new(3.4, 0.25, 3.4), base * CFrame.new(0, 3.55, 0), STRAW, Enum.Material.Fabric)
	local anchor = part(model, "PromptAnchor", Vector3.new(0.4, 0.4, 0.4), base * CFrame.new(0, 2.4, 0), WOOD, Enum.Material.Wood)
	anchor.Transparency = 1
	local spec = config.roundEvents.events.supplyDrop
	prompt(anchor, RoundEventWorld.DEPOSIT_PROMPT, "Deposit feathers", "Supply Drop", 0, spec.rangeStuds)
	model.PrimaryPart = body
	model:SetAttribute(RoundEventWorld.EVENT_ATTRIBUTE, event.id)
	model:SetAttribute("SFE_EventKind", event.kind)
	model.Parent = parent
	return model
end

-- The Chick Rescue cage: a wooden base, a ring of bars and a lid with a padlock. The chick itself is
-- the client's (the owner's DodoBird, staged for every client).
function RoundEventWorld.buildCage(parent: Instance, event: any, config: { [string]: any }): Model
	local model = Instance.new("Model")
	model.Name = "ChickCage"
	local base = CFrame.new(event.position)
	local floor = part(
		model,
		"Base",
		Vector3.new(0.35, 3.2, 3.2),
		base * CFrame.new(0, 0.18, 0) * CFrame.Angles(0, 0, math.rad(90)),
		WOOD_DEEP,
		Enum.Material.WoodPlanks,
		true,
		Enum.PartType.Cylinder
	)
	local bars = 10
	for i = 1, bars do
		local angle = (i / bars) * math.pi * 2
		part(
			model,
			"Bar",
			Vector3.new(0.12, 2.7, 0.12),
			base * CFrame.new(math.cos(angle) * 1.4, 1.7, math.sin(angle) * 1.4),
			IRON,
			Enum.Material.Metal
		)
	end
	part(
		model,
		"Lid",
		Vector3.new(0.25, 3.2, 3.2),
		base * CFrame.new(0, 3.1, 0) * CFrame.Angles(0, 0, math.rad(90)),
		IRON,
		Enum.Material.Metal,
		false,
		Enum.PartType.Cylinder
	)
	part(model, "Padlock", Vector3.new(0.45, 0.5, 0.2), base * CFrame.new(0, 1.5, -1.5), Color3.fromRGB(214, 170, 60), Enum.Material.Metal)
	local anchor = part(model, "PromptAnchor", Vector3.new(0.4, 0.4, 0.4), base * CFrame.new(0, 1.6, 0), IRON, Enum.Material.Metal)
	anchor.Transparency = 1
	local spec = config.roundEvents.events.chickRescue
	prompt(anchor, RoundEventWorld.RESCUE_PROMPT, "Free the chick", "Trapped chick", spec.holdSeconds, spec.rangeStuds)
	model.PrimaryPart = floor
	model:SetAttribute(RoundEventWorld.EVENT_ATTRIBUTE, event.id)
	model:SetAttribute("SFE_EventKind", event.kind)
	model.Parent = parent
	return model
end

function RoundEventWorld.spawn(self: RoundEventWorld, _runtime: any, event: any)
	if not event.position then
		return -- Rainbow Rush lives in the pile itself
	end
	local folder = folderOf(self)
	local model = if event.kind == "supplyDrop"
		then RoundEventWorld.buildCrate(folder, event, self._config)
		else RoundEventWorld.buildCage(folder, event, self._config)
	self._models[event.id] = model
end

function RoundEventWorld.despawn(self: RoundEventWorld, _runtime: any, event: any)
	local model = self._models[event.id]
	if not model then
		return
	end
	self._models[event.id] = nil
	-- The prompt goes at once; the model stays a beat for the client's closing animation.
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			descendant.Enabled = false
		end
	end
	task.delay(if event.result == "completed" then 2.5 else 0.8, function()
		model:Destroy()
	end)
end

return RoundEventWorld
