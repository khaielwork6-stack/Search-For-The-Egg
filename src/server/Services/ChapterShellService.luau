--!strict
-- Builds the Sunlit Henhouse arena from labeled placeholder primitives at the ChapterLayout offset:
-- barn floor and walls, rafters, the nest base collider, the trading crate (sell station) and the
-- workbench (upgrade board) with ProximityPrompts, the round spawn pad, ambient tags for the client
-- scheduler, and the Egg part that is created only on reveal. All instances carry
-- SFE_Placeholder = "PHASE_6_ART". Server-built so all party members see the same world.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChapterLayout = require(ReplicatedStorage.Shared.Domain.ChapterLayout)

local ChapterShellService = {}

ChapterShellService.FOLDER_NAME = "SFE_Chapter1"
ChapterShellService.PLACEHOLDER_TAG = "PHASE_6_ART"

local function part(
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?,
	parent: Instance,
	collide: boolean?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = collide ~= false
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p:SetAttribute("SFE_Placeholder", ChapterShellService.PLACEHOLDER_TAG)
	p.Parent = parent
	return p
end

local function label(target: BasePart, text: string, face: Enum.NormalId, pixelsPerStud: number?)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Label"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud or 40
	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.Font = Enum.Font.FredokaOne
	textLabel.TextScaled = true
	textLabel.TextColor3 = Color3.fromRGB(252, 246, 234)
	textLabel.TextStrokeTransparency = 0.6
	textLabel.Text = text
	textLabel.Parent = gui
	gui.Parent = target
end

local function prompt(parent: BasePart, name: string, actionText: string, objectText: string, hold: number?, maxDistance: number)
	local p = Instance.new("ProximityPrompt")
	p.Name = name
	p.ActionText = actionText
	p.ObjectText = objectText
	p.HoldDuration = hold or 0
	p.MaxActivationDistance = maxDistance
	p.RequiresLineOfSight = false
	p.Style = Enum.ProximityPromptStyle.Custom -- drawn by the client PromptController in the UI language
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.GamepadKeyCode = Enum.KeyCode.ButtonX
	p.Parent = parent
	return p
end

function ChapterShellService.buildGreybox(workspaceService: Workspace, config: { [string]: any }): Folder
	local existing = workspaceService:FindFirstChild(ChapterShellService.FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local layout = ChapterLayout.chapter1
	local folder = Instance.new("Folder")
	folder.Name = ChapterShellService.FOLDER_NAME
	folder:SetAttribute("SFE_Placeholder", ChapterShellService.PLACEHOLDER_TAG)

	local straw = Color3.fromRGB(226, 191, 108)
	local strawDeep = Color3.fromRGB(190, 145, 62)
	local wood = Color3.fromRGB(150, 104, 62)
	local woodDeep = Color3.fromRGB(104, 70, 42)
	local cream = Color3.fromRGB(252, 246, 234)
	local ember = Color3.fromRGB(228, 117, 70)
	local sky = Color3.fromRGB(129, 190, 220)
	local o = layout.origin

	-- Floor and walls (open front toward the lobby side so the space reads as a barn interior).
	part("Floor", layout.floorSize, CFrame.new(o + Vector3.new(0, 0.5, 0)), strawDeep, Enum.Material.WoodPlanks, folder)
	local half = layout.floorSize.X / 2
	local wallHeight = layout.roofHeight
	part(
		"WallBack",
		Vector3.new(layout.floorSize.X, wallHeight, 1),
		CFrame.new(o + Vector3.new(0, wallHeight / 2, half)),
		wood,
		Enum.Material.Wood,
		folder
	)
	part(
		"WallLeft",
		Vector3.new(1, wallHeight, layout.floorSize.Z),
		CFrame.new(o + Vector3.new(-half, wallHeight / 2, 0)),
		wood,
		Enum.Material.Wood,
		folder
	)
	part(
		"WallRight",
		Vector3.new(1, wallHeight, layout.floorSize.Z),
		CFrame.new(o + Vector3.new(half, wallHeight / 2, 0)),
		wood,
		Enum.Material.Wood,
		folder
	)
	part(
		"WallFront",
		Vector3.new(layout.floorSize.X, wallHeight, 1),
		CFrame.new(o + Vector3.new(0, wallHeight / 2, -half)),
		wood,
		Enum.Material.Wood,
		folder
	)
	-- Sunlit window strips on the back wall (neon panes = warm light source).
	for i = -2, 2 do
		local pane = part(
			"Window" .. i,
			Vector3.new(8, 10, 0.4),
			CFrame.new(o + Vector3.new(i * 22, 16, half - 0.8)),
			sky,
			Enum.Material.Neon,
			folder,
			false
		)
		pane:SetAttribute("SFE_Ambient", "sunShimmer")
	end
	-- Rafters with a slowly turning fan and hanging cloth.
	for i = -2, 2 do
		part(
			"Rafter" .. i,
			Vector3.new(layout.floorSize.X, 1.2, 1.2),
			CFrame.new(o + Vector3.new(0, wallHeight - 1, i * 26)),
			woodDeep,
			Enum.Material.Wood,
			folder,
			false
		)
	end
	local fan = part(
		"CeilingFan",
		Vector3.new(14, 0.3, 1.6),
		CFrame.new(o + Vector3.new(0, wallHeight - 3, 10)),
		woodDeep,
		Enum.Material.Wood,
		folder,
		false
	)
	fan:SetAttribute("SFE_Ambient", "spin")
	local cloth = part(
		"HangingCloth",
		Vector3.new(6, 12, 0.3),
		CFrame.new(o + Vector3.new(-40, wallHeight - 8, 30)),
		ember,
		Enum.Material.Fabric,
		folder,
		false
	)
	cloth:SetAttribute("SFE_Ambient", "clothSway")
	local cloth2 = part(
		"HangingCloth2",
		Vector3.new(6, 12, 0.3),
		CFrame.new(o + Vector3.new(44, wallHeight - 8, -20)),
		sky,
		Enum.Material.Fabric,
		folder,
		false
	)
	cloth2:SetAttribute("SFE_Ambient", "clothSway")
	-- Pecking birds: small bobbing blocks on the floor edges.
	for i = 1, 3 do
		local bird = part(
			"Bird" .. i,
			Vector3.new(1.2, 1.2, 1.6),
			CFrame.new(o + Vector3.new(-50 + i * 18, 1.6, -55)),
			cream,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		bird:SetAttribute("SFE_Ambient", "peck")
	end
	-- Dust motes near the spawn lane.
	local dust = part(
		"DustAnchor",
		Vector3.new(1, 1, 1),
		CFrame.new(layout.spawn + Vector3.new(0, 6, 10)),
		cream,
		Enum.Material.SmoothPlastic,
		folder,
		false
	)
	dust.Transparency = 1
	dust:SetAttribute("SFE_Ambient", "dustMote")
	-- Drifting feathers above the nest.
	for i, offset in ipairs({ Vector3.new(-14, 12, 0), Vector3.new(14, 13, 4), Vector3.new(0, 14, -10) }) do
		local anchor = part(
			"FeatherDrift" .. i,
			Vector3.new(1, 1, 1),
			CFrame.new(layout.nestCenter + offset),
			cream,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		anchor.Transparency = 1
		anchor:SetAttribute("SFE_Ambient", "featherDrift")
	end

	-- Nest base: a walkable-around collider under the client-rendered feather cells.
	local gridSize = config.pile.gridWidth * config.pile.cellSizeStuds
	local nestBase = part(
		"NestBase",
		Vector3.new(layout.nestBaseY, gridSize * 1.15, gridSize * 1.15),
		CFrame.new(layout.nestCenter + Vector3.new(0, layout.nestBaseY / 2 + 0.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		strawDeep,
		Enum.Material.Grass,
		folder
	)
	nestBase.Shape = Enum.PartType.Cylinder
	-- Invisible aim plane so client raycasts land on the nest even between visual cells.
	local aimPlane = part(
		"NestAimPlane",
		Vector3.new(gridSize, 0.2, gridSize),
		CFrame.new(layout.nestCenter + Vector3.new(0, layout.nestBaseY + config.pile.aimPlaneHeightStuds, 0)),
		cream,
		Enum.Material.SmoothPlastic,
		folder,
		false
	)
	aimPlane.Transparency = 1
	aimPlane.CanQuery = true

	-- Round spawn pad.
	part("RoundSpawn", Vector3.new(10, 0.4, 10), CFrame.new(layout.spawn - Vector3.new(0, 1.8, 0)), straw, Enum.Material.WoodPlanks, folder)

	-- Trading crate (sell station).
	local crate = part(
		"SellStation",
		Vector3.new(7, 5, 7),
		CFrame.new(layout.sellStation + Vector3.new(0, 3.5, 0)),
		wood,
		Enum.Material.WoodPlanks,
		folder
	)
	label(crate, "Trade Feathers", Enum.NormalId.Top)
	local crateLid = part(
		"SellStationLid",
		Vector3.new(7.4, 0.6, 7.4),
		CFrame.new(layout.sellStation + Vector3.new(0, 6.3, 0)),
		woodDeep,
		Enum.Material.Wood,
		folder,
		false
	)
	crateLid:SetAttribute("SFE_Ambient", "bob")
	prompt(crate, "SFE_Sell", "Trade", "Feather crate", 0, config.interaction.sellRangeStuds)

	-- Workbench (upgrade board).
	local bench = part(
		"UpgradeBoard",
		Vector3.new(9, 4, 4),
		CFrame.new(layout.upgradeBoard + Vector3.new(0, 3, 0)),
		woodDeep,
		Enum.Material.Wood,
		folder
	)
	local board = part(
		"UpgradeSign",
		Vector3.new(9, 4, 0.5),
		CFrame.new(layout.upgradeBoard + Vector3.new(0, 7.5, 1.5)),
		cream,
		Enum.Material.SmoothPlastic,
		folder,
		false
	)
	label(board, "Workbench", Enum.NormalId.Front)
	board:SetAttribute("SFE_Ambient", "bob")
	prompt(bench, "SFE_Upgrade", "Upgrade", "Workbench", 0, config.interaction.upgradeRangeStuds)

	folder:SetAttribute("SFE_ChildCount", #folder:GetChildren())
	folder.Parent = workspaceService
	return folder
end

-- Map mode: the owner's SearchForTheEgg_Map2 model is the arena. Only the invisible aim plane, the
-- station prompts on the map's processor button and supplies counter, and ambient anchors are
-- created; the pit is the nest and the map's spawn pad is the round spawn.
function ChapterShellService.buildFromMap(workspaceService: Workspace, mapModel: Instance, config: { [string]: any }): Folder
	local existing = workspaceService:FindFirstChild(ChapterShellService.FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local layout = ChapterLayout.chapter1
	local folder = Instance.new("Folder")
	folder.Name = ChapterShellService.FOLDER_NAME
	folder:SetAttribute("SFE_MapMode", true)
	folder:SetAttribute("SFE_MapName", mapModel.Name)
	local cream = Color3.fromRGB(252, 246, 234)

	local gridSize = config.pile.gridWidth * config.pile.cellSizeStuds
	local aimPlane = part(
		"NestAimPlane",
		Vector3.new(gridSize, 0.2, gridSize),
		CFrame.new(layout.nestCenter.X, layout.nestBaseY + config.pile.aimPlaneHeightStuds, layout.nestCenter.Z),
		cream,
		Enum.Material.SmoothPlastic,
		folder,
		false
	)
	aimPlane.Transparency = 1
	aimPlane.CanQuery = true

	local function anchor(name: string, position: Vector3, size: Vector3): Part
		local p = part(name, size, CFrame.new(position), cream, Enum.Material.SmoothPlastic, folder, false)
		p.Transparency = 1
		p.CanQuery = true
		return p
	end
	-- Selling: the processor's green button; the conveyors already tell the story.
	local sellAnchor = anchor("SellStation", layout.sellPrompt, Vector3.new(1.6, 1.6, 0.8))
	prompt(sellAnchor, "SFE_Sell", "Trade", "Feather processor", 0, config.interaction.sellRangeStuds)
	-- Upgrades: the FEATHER SUPPLIES counter inside the shop.
	local upgradeAnchor = anchor("UpgradeBoard", layout.upgradePrompt, Vector3.new(6, 1.2, 1.2))
	prompt(upgradeAnchor, "SFE_Upgrade", "Upgrade", "Feather supplies", 0, config.interaction.upgradeRangeStuds)
	upgradeAnchor:SetAttribute("SFE_Ambient", "bob")

	for index, position in ipairs(layout.ambientAnchors) do
		local drift = anchor("FeatherDrift" .. index, position, Vector3.new(1, 1, 1))
		drift.CanQuery = false
		drift:SetAttribute("SFE_Ambient", "featherDrift")
	end
	ChapterShellService.placeDisplays(workspaceService, config)
	ChapterShellService.spawnFarmer(workspaceService, folder, layout, config)

	folder:SetAttribute("SFE_ChildCount", #folder:GetChildren())
	folder.Parent = workspaceService
	return folder
end

-- The Farmer: a clone of the owner's Cow Boy rig standing between the barn and the mound. His
-- anchor carries the vendor presentation attributes and the hand-over prompt.
function ChapterShellService.spawnFarmer(workspaceService: Workspace, folder: Instance, layout: any, config: { [string]: any }): Model?
	if not layout.farmer then
		return nil
	end
	local source = workspaceService:FindFirstChild("Cow Boy")
	if not (source and source:IsA("Model")) then
		return nil
	end
	local farmer = source:Clone()
	farmer.Name = "Farmer"
	for _, descendant in ipairs(farmer:GetDescendants()) do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
	local _, size = farmer:GetBoundingBox()
	local look = CFrame.lookAt(layout.farmer, Vector3.new(layout.farmerFacing.X, layout.farmer.Y, layout.farmerFacing.Z))
	farmer:PivotTo(look * CFrame.new(0, size.Y / 2, 0))
	local humanoid = farmer:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	farmer.Parent = folder
	local root = farmer:FindFirstChild("HumanoidRootPart") :: BasePart?
	local anchorPart = part(
		"farmerVendor",
		Vector3.new(4, 6, 3),
		CFrame.new(root and root.Position or layout.farmer),
		Color3.fromRGB(252, 246, 234),
		Enum.Material.SmoothPlastic,
		folder,
		false
	)
	anchorPart.Transparency = 1
	anchorPart.CanQuery = true
	anchorPart:SetAttribute("SFE_Ambient", "npc")
	anchorPart:SetAttribute("SFE_NpcModel", "Farmer")
	anchorPart:SetAttribute("SFE_NpcName", "Farmer")
	anchorPart:SetAttribute("SFE_NpcRole", "Bring the Egg here")
	anchorPart:SetAttribute("SFE_NpcLine", "Found the Egg? Bring it to me and the search is yours!")
	prompt(anchorPart, "SFE_EggDeliver", "Hand over the Egg", "Farmer", 0, config.eggSpawn.deliverRadiusStuds or 8)
	return farmer
end

-- The Egg rides above the carrier's head; its pickup prompt hides while it is carried.
function ChapterShellService.attachEgg(folder: Instance, character: Model): boolean
	local egg = folder:FindFirstChild("SFE_Egg")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not (egg and egg:IsA("BasePart") and root and root:IsA("BasePart")) then
		return false
	end
	local eggPrompt = egg:FindFirstChildOfClass("ProximityPrompt")
	if eggPrompt then
		eggPrompt.Enabled = false
	end
	egg.Anchored = false
	egg.CanCollide = false
	egg.Massless = true
	egg.CFrame = root.CFrame * CFrame.new(0, 4.2, 0)
	local weld = Instance.new("Weld")
	weld.Name = "SFE_EggCarry"
	weld.Part0 = root
	weld.Part1 = egg
	weld.C0 = CFrame.new(0, 4.2, 0)
	weld.Parent = egg
	return true
end

function ChapterShellService.detachEgg(folder: Instance, position: Vector3): boolean
	local egg = folder:FindFirstChild("SFE_Egg")
	if not (egg and egg:IsA("BasePart")) then
		return false
	end
	local weld = egg:FindFirstChild("SFE_EggCarry")
	if weld then
		weld:Destroy()
	end
	egg.Anchored = true
	egg.CFrame = CFrame.new(position + Vector3.new(0, 0.6, 0))
	local eggPrompt = egg:FindFirstChildOfClass("ProximityPrompt")
	if eggPrompt then
		eggPrompt.Enabled = true
	end
	return true
end

-- The owner's item models become shop displays inside the supplies barn: two bags on the counter,
-- the pitchfork and the dynamite on the rear wall boards. Each carries a Buy prompt; the client
-- draws the price card from the round previews. Missing models are skipped, never rebuilt.
local DISPLAYS: { { key: string, model: string, cframe: CFrame, name: string, scale: number? } } = {
	{
		key = "bag",
		model = "FeatherBag",
		cframe = CFrame.new(-47, 58.75, 299) * CFrame.Angles(0, math.rad(180), 0),
		name = "Upgrade Bag",
		scale = 0.8,
	},
	{
		key = "infiniteBag",
		model = "InfiniteBag",
		cframe = CFrame.new(-36.5, 58.75, 299) * CFrame.Angles(0, math.rad(180), 0),
		name = "Infinite Bag",
		scale = 0.8,
	},
	{
		key = "nestRake",
		model = "Pitchfork",
		cframe = CFrame.new(-54, 60.2, 291.65) * CFrame.Angles(0, 0, math.rad(-62)) * CFrame.new(0, -4.2, 0),
		name = "Nest Rake",
	},
	{
		key = "confettiCharge",
		model = "Dynamite",
		cframe = CFrame.new(-40, 58.4, 292.1) * CFrame.Angles(0, 0, math.rad(-8)),
		name = "Confetti Charge",
	},
}
-- The rear-wall display boards the owner built sit high; they come down to eye level with the items.
local BOARD_Y = 60.2

function ChapterShellService.placeDisplays(workspaceService: Workspace, config: { [string]: any }): number
	local placed = 0
	local map = workspaceService:FindFirstChild(ChapterLayout.CHAPTER1_MAP_NAME)
	local shop = map and map:FindFirstChild("SupplyShop")
	if shop then
		for _, part in ipairs(shop:GetChildren()) do
			if part:IsA("BasePart") and (part.Name == "EmptyDisplayBoard" or part.Name == "EmptyDisplayFrame") then
				part.Position = Vector3.new(part.Position.X, BOARD_Y, part.Position.Z)
			end
		end
	end
	for _, spec in ipairs(DISPLAYS) do
		local model = workspaceService:FindFirstChild(spec.model)
		if not (model and model:IsA("Model")) then
			continue
		end
		if spec.scale and math.abs(model:GetScale() - spec.scale) > 0.01 then
			model:ScaleTo(spec.scale)
		end
		model:PivotTo(spec.cframe)
		model:SetAttribute("SFE_Display", spec.key)
		local host = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
		if host then
			local old = host:FindFirstChild("SFE_Display_" .. spec.key)
			if old then
				old:Destroy()
			end
			prompt(host, "SFE_Display_" .. spec.key, "Inspect", spec.name, 0, math.min(config.interaction.upgradeRangeStuds, 8))
		end
		placed += 1
	end
	return placed
end

ChapterShellService.TOOL_MODELS_FOLDER = "SFE_ToolModels"
-- Workspace paths of the owner's Toolbox models that become first-person viewmodels and the chick.
local TOOL_MODEL_SOURCES: { [string]: { string } } = {
	Pitchfork = { "Pitchfork" },
	Dynamite = { "Dynamite" },
	Vacuum = { "Vacuum" },
	DodoBird = { "Bird", "DodoBird" },
}

-- Clones the owner's tool models into ReplicatedStorage with every script, prompt, sound and
-- emitter removed and every part anchored/non-colliding: the client animates them procedurally.
function ChapterShellService.stageToolModels(workspaceService: Workspace, replicated: Instance): number
	local folder = replicated:FindFirstChild(ChapterShellService.TOOL_MODELS_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = ChapterShellService.TOOL_MODELS_FOLDER
		folder.Parent = replicated
	end
	local staged = 0
	for name, path in pairs(TOOL_MODEL_SOURCES) do
		local source: Instance? = workspaceService
		for _, segment in ipairs(path) do
			source = source and source:FindFirstChild(segment)
		end
		if not (source and source:IsA("Model")) then
			continue
		end
		local old = folder:FindFirstChild(name)
		if old then
			old:Destroy()
		end
		local clone = source:Clone()
		clone.Name = name
		for _, descendant in ipairs(clone:GetDescendants()) do
			if
				descendant:IsA("LuaSourceContainer")
				or descendant:IsA("ProximityPrompt")
				or descendant:IsA("Sound")
				or descendant:IsA("ParticleEmitter")
				or descendant:IsA("LayerCollector")
				or descendant:IsA("Seat")
				or descendant:IsA("Constraint")
				or descendant:IsA("BodyMover")
			then
				descendant:Destroy()
			elseif descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanQuery = false
				descendant.CanTouch = false
				descendant.CastShadow = false
				descendant.Massless = true
			end
		end
		for attribute in pairs(clone:GetAttributes()) do
			clone:SetAttribute(attribute, nil)
		end
		clone.Parent = folder
		staged += 1
	end
	return staged
end

-- Builds the Chapter 1 arena: the owner's map when present, the greybox otherwise.
function ChapterShellService.build(workspaceService: Workspace, config: { [string]: any }): Folder
	local mapModel = workspaceService:FindFirstChild(ChapterLayout.CHAPTER1_MAP_NAME)
	if mapModel then
		return ChapterShellService.buildFromMap(workspaceService, mapModel, config)
	end
	return ChapterShellService.buildGreybox(workspaceService, config)
end

-- Creates the Egg part at reveal time (never earlier: clients cannot learn the position from the
-- DataModel). Includes the hold-to-claim prompt sized from config.
function ChapterShellService.spawnEgg(folder: Instance, position: Vector3, config: { [string]: any }): Part
	local existing = folder:FindFirstChild("SFE_Egg")
	if existing then
		existing:Destroy()
	end
	local egg = Instance.new("Part")
	egg.Name = "SFE_Egg"
	egg.Shape = Enum.PartType.Ball
	egg.Size = Vector3.new(2.2, 2.8, 2.2)
	egg.Anchored = true
	egg.CanCollide = false
	egg.Color = Color3.fromRGB(252, 240, 205)
	egg.Material = Enum.Material.SmoothPlastic
	egg.CFrame = CFrame.new(position + Vector3.new(0, 0.6, 0))
	egg:SetAttribute("SFE_Placeholder", ChapterShellService.PLACEHOLDER_TAG)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 220, 140)
	light.Range = 14
	light.Brightness = 2
	light.Parent = egg
	prompt(egg, "SFE_EggClaim", "Claim the Egg", "Hidden Egg", config.eggSpawn.claimHoldSeconds, config.eggSpawn.claimRadiusStuds)
	egg.Parent = folder
	return egg
end

function ChapterShellService.destroy(workspaceService: Workspace)
	local existing = workspaceService:FindFirstChild(ChapterShellService.FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
end

return ChapterShellService
