--!strict
-- Builds the Sunlit Henhouse arena from labeled placeholder primitives at the ChapterLayout offset:
-- barn floor and walls, rafters, the nest base collider, the trading crate (sell station) and the
-- workbench (upgrade board) with ProximityPrompts, the round spawn pad, ambient tags for the client
-- scheduler, and the Egg part that is created only on reveal. All instances carry
-- SFE_Placeholder = "PHASE_6_ART". Server-built so all party members see the same world.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChapterLayout = require(ReplicatedStorage.Shared.Domain.ChapterLayout)
local RoundIntro = require(ReplicatedStorage.Shared.Domain.RoundIntro)

local ChapterShellService = {}

ChapterShellService.FOLDER_NAME = "SFE_Chapter1"
ChapterShellService.INTRO_FOLDER_NAME = "SFE_IntroSet"
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

-- Big world-space word over a station (the "SELL" sign over the crates): red outlined letters that
-- scale with distance so they read from anywhere in the yard.
local function worldSign(parent: BasePart, text: string, offset: Vector3)
	local gui = Instance.new("BillboardGui")
	gui.Name = "SFE_Sign_" .. text
	gui.Adornee = parent
	gui.Size = UDim2.fromScale(9, 3)
	gui.StudsOffsetWorldSpace = offset
	gui.MaxDistance = 160
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.ResetOnSpawn = false
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = text
	label.TextColor3 = Color3.fromRGB(226, 66, 56)
	label.TextStrokeColor3 = Color3.fromRGB(255, 250, 238)
	label.TextStrokeTransparency = 0
	label.Parent = gui
	gui.Parent = parent
	return gui
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
	worldSign(crate, "SELL", Vector3.new(0, 5.5, 0))
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
	prompt(crate, "SFE_Sell", "Sell feathers", "Feather crate", 0, config.interaction.sellRangeStuds)

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
	prompt(sellAnchor, "SFE_Sell", "Sell feathers", "Feather crates", 0, config.interaction.sellRangeStuds)
	worldSign(sellAnchor, "SELL", Vector3.new(0, 6.5, 0))
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
local DISPLAYS: { { key: string, model: string, cframe: CFrame, name: string, scale: number?, stand: CFrame? } } = {
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
	-- Tools hang on the left wall (x -62) on the boards moved there, leaving the counter to the bags.
	{
		key = "nestRake",
		model = "Pitchfork",
		cframe = CFrame.new(-60.3, 60.2, 299.5)
			* CFrame.Angles(0, math.rad(90), 0)
			* CFrame.Angles(0, 0, math.rad(-62))
			* CFrame.new(0, -4.2, 0),
		name = "Nest Rake",
	},
	{
		key = "confettiCharge",
		model = "Dynamite",
		cframe = CFrame.new(-60.4, 58.4, 310) * CFrame.Angles(0, math.rad(90), 0) * CFrame.Angles(0, 0, math.rad(-8)),
		name = "Confetti Charge",
	},
	-- The Scout Chick (owner's Bird) perches on a rope-tied crate beside the counter.
	{
		key = "scoutChick",
		model = "Bird",
		cframe = CFrame.new(-31.5, 58.15, 303.5) * CFrame.Angles(0, math.rad(35), 0),
		name = "Scout Chick",
		scale = 0.38,
		stand = CFrame.new(-31.5, 55.3, 303.5),
	},
}

-- A cream crate tied with two tan ropes: the stand under a display (the reference's drone crate).
local function buildStand(parent: Instance, cframe: CFrame): Part
	local crate =
		part("ScoutStand", Vector3.new(3.6, 3, 3.6), cframe, Color3.fromRGB(240, 229, 200), Enum.Material.SmoothPlastic, parent, true)
	crate.CanQuery = false
	local rope = Color3.fromRGB(206, 160, 104)
	part("StandRopeX", Vector3.new(3.7, 0.4, 0.5), cframe * CFrame.new(0, 0.85, 0), rope, Enum.Material.Fabric, parent, false)
	part("StandRopeZ", Vector3.new(0.5, 0.4, 3.7), cframe * CFrame.new(0, 0.85, 0), rope, Enum.Material.Fabric, parent, false)
	part("StandRopeXFront", Vector3.new(0.5, 3.05, 0.1), cframe * CFrame.new(0, 0, 1.83), rope, Enum.Material.Fabric, parent, false)
	part("StandRopeXBack", Vector3.new(0.5, 3.05, 0.1), cframe * CFrame.new(0, 0, -1.83), rope, Enum.Material.Fabric, parent, false)
	part("StandRopeZLeft", Vector3.new(0.1, 3.05, 0.5), cframe * CFrame.new(-1.83, 0, 0), rope, Enum.Material.Fabric, parent, false)
	part("StandRopeZRight", Vector3.new(0.1, 3.05, 0.5), cframe * CFrame.new(1.83, 0, 0), rope, Enum.Material.Fabric, parent, false)
	return crate
end
-- The rear-wall display boards the owner built sit high; they come down to eye level with the items.
local BOARD_Y = 60.2

function ChapterShellService.placeDisplays(workspaceService: Workspace, config: { [string]: any }): number
	local placed = 0
	local map = workspaceService:FindFirstChild(ChapterLayout.CHAPTER1_MAP_NAME)
	local shop = map and map:FindFirstChild("SupplyShop")
	if shop then
		-- The two board+frame pairs leave the rear wall for the left wall (inner face x -61.5),
		-- at eye level, one behind each tool.
		local slots = { 299.5, 310 }
		local boards, frames = {}, {}
		for _, part in ipairs(shop:GetChildren()) do
			if part:IsA("BasePart") and part.Name == "EmptyDisplayBoard" then
				table.insert(boards, part)
			elseif part:IsA("BasePart") and part.Name == "EmptyDisplayFrame" then
				table.insert(frames, part)
			end
		end
		table.sort(boards, function(a, b)
			return a.Position.X < b.Position.X
		end)
		table.sort(frames, function(a, b)
			return a.Position.X < b.Position.X
		end)
		for index, z in ipairs(slots) do
			local frame, board = frames[index], boards[index]
			if frame then
				frame.CFrame = CFrame.new(-61.5 + frame.Size.Z * 0.5, BOARD_Y, z) * CFrame.Angles(0, math.rad(90), 0)
			end
			if board then
				board.CFrame = CFrame.new(-61.5 + (frame and frame.Size.Z or 0.45) + board.Size.Z * 0.5, BOARD_Y, z)
					* CFrame.Angles(0, math.rad(90), 0)
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
		-- Display models never move or collide (the Bird's rig is unanchored in the Toolbox asset).
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
			end
		end
		if spec.stand then
			local holder = model.Parent or workspaceService
			local old = holder:FindFirstChild("ScoutStand")
			if old then
				old:Destroy()
			end
			buildStand(holder, spec.stand)
		end
		model:PivotTo(spec.cframe)
		model:SetAttribute("SFE_Display", spec.key)
		if not model.PrimaryPart then
			model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true)
		end
		local host = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
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
-- The round intro's set: a rustic sign with a parchment flyer beside the south gate path, and the
-- five named camera markers. Built once with the world, not per round.
--
-- The markers are real named parts rather than numbers buried in a controller, so framing can be
-- adjusted by dragging them in Studio and read straight back out; `round.intro.markers` is only the
-- authored default. The client falls back to the config, and then to a plain fade, if a marker is
-- missing, so a deleted marker degrades the shot instead of trapping the player.
--
-- The flyer's reward is left at the chapter's own value here. The client rewrites it locally for the
-- difficulty its round is actually being played on, which never replicates and so cannot disagree
-- between two parties sharing a server.
function ChapterShellService.buildIntroSet(folder: Instance, config: { [string]: any }): Folder
	local intro = config.round.intro
	local layout = ChapterLayout.chapter1
	local existing = folder:FindFirstChild(ChapterShellService.INTRO_FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local set = Instance.new("Folder")
	set.Name = ChapterShellService.INTRO_FOLDER_NAME
	set.Parent = folder

	for name, marker in pairs(intro.markers) do
		local position = Vector3.new(marker.position[1], marker.position[2], marker.position[3])
		local lookAt = Vector3.new(marker.lookAt[1], marker.lookAt[2], marker.lookAt[3])
		local pin = part(name, Vector3.new(0.6, 0.6, 1.6), CFrame.lookAt(position, lookAt), Color3.fromRGB(255, 120, 60), nil, set, false)
		pin.Transparency = 1
		pin.CanQuery = false
		pin.CanTouch = false
		pin.CastShadow = false
		pin:SetAttribute("SFE_FieldOfView", marker.fieldOfView)
	end

	local sign = intro.sign
	local base = Vector3.new(sign.position[1], sign.position[2], sign.position[3])
	local facing = Vector3.new(sign.facing[1], sign.facing[2], sign.facing[3])
	if facing.Magnitude < 0.01 then
		facing = Vector3.new(0, 0, 1)
	end
	facing = facing.Unit
	local postHeight = sign.postHeightStuds
	local board = Vector3.new(sign.boardSizeStuds[1], sign.boardSizeStuds[2], sign.boardSizeStuds[3])
	local model = Instance.new("Model")
	model.Name = "SFE_IntroSign"
	model.Parent = set

	local postCF = CFrame.lookAt(base + Vector3.new(0, postHeight / 2, 0), base + Vector3.new(0, postHeight / 2, 0) + facing)
	part("SignPost", Vector3.new(0.7, postHeight, 0.7), postCF, Color3.fromRGB(152, 99, 60), nil, model, true)
	-- The board hangs on the camera-facing side of the post, not centred on it, or the post draws a
	-- stripe straight down the middle of the flyer.
	local boardCentre = base + Vector3.new(0, postHeight - board.Y / 2 + 0.3, 0) + facing * (0.35 + board.Z / 2)
	local boardCF = CFrame.lookAt(boardCentre, boardCentre + facing)
	local boardPart = part("SignBoard", board, boardCF, Color3.fromRGB(190, 137, 85), nil, model, true)
	model.PrimaryPart = boardPart

	-- The parchment is its own part so the intro can lift it off the board and put it in the actor's
	-- hand without rebuilding anything.
	local inset = sign.parchmentInsetStuds
	local paper = Vector3.new(board.X - inset * 2, board.Y - inset * 2, 0.08)
	local paperCF = boardCF * CFrame.new(0, 0, -(board.Z / 2 + paper.Z / 2 + 0.01))
	local parchment = part("IntroParchment", paper, paperCF, Color3.fromRGB(246, 232, 198), nil, model, false)
	parchment.CanQuery = false
	parchment:SetAttribute("SFE_IntroParchment", true)
	local tackCF = paperCF * CFrame.new(0, paper.Y / 2 - 0.3, -0.06)
	local tack = part("Tack", Vector3.new(0.22, 0.22, 0.12), tackCF, Color3.fromRGB(120, 92, 64), nil, model, false)
	tack.Shape = Enum.PartType.Cylinder
	tack.CFrame = tackCF * CFrame.Angles(0, math.rad(90), 0)
	tack.CanQuery = false

	ChapterShellService.paintParchment(parchment, config, "chapter1", "normal")
	local _ = layout
	return set
end

-- Draws the flyer onto a parchment part. Text is laid out on a fixed pixel canvas at a high
-- pixels-per-stud and never scaled to fit, so it stays crisp and does not shimmer as the camera
-- moves or the graphics level changes. Safe to call again to change the wording.
function ChapterShellService.paintParchment(parchment: BasePart, config: { [string]: any }, chapter: string, difficulty: string)
	local intro = config.round.intro
	local lines = RoundIntro.posterLines(config, chapter, difficulty)
	local existing = parchment:FindFirstChild("Flyer")
	if existing then
		existing:Destroy()
	end
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Flyer"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = intro.sign.pixelsPerStud
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.MaxDistance = 90
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local paper = Instance.new("Frame")
	paper.Name = "Paper"
	paper.Size = UDim2.fromScale(1, 1)
	paper.BackgroundColor3 = Color3.fromRGB(246, 232, 198)
	paper.BorderSizePixel = 0
	paper.Parent = gui
	local aged = Instance.new("UIGradient")
	aged.Rotation = 90
	aged.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(250, 240, 212)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(243, 228, 192)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(230, 208, 166)),
	})
	aged.Parent = paper
	local edge = Instance.new("UIStroke")
	edge.Thickness = 3
	edge.Color = Color3.fromRGB(176, 143, 96)
	edge.Transparency = 0.25
	edge.Parent = paper
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.06, 0)
	pad.PaddingBottom = UDim.new(0.05, 0)
	pad.PaddingLeft = UDim.new(0.07, 0)
	pad.PaddingRight = UDim.new(0.07, 0)
	pad.Parent = paper

	-- Text is sized from the canvas rather than scaled to fit, so a line never resizes itself between
	-- graphics levels (which is what makes SurfaceGui text shimmer as the camera moves).
	local canvasHeight = parchment.Size.Y * intro.sign.pixelsPerStud
	local function text(name: string, value: string, y: number, height: number, scale: number, color: Color3)
		local size = math.max(8, math.floor(canvasHeight * scale + 0.5))
		local label = Instance.new("TextLabel")
		label.Name = name
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.Position = UDim2.fromScale(0.5, y)
		label.Size = UDim2.fromScale(1, height)
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = false
		label.TextSize = size
		label.TextWrapped = true
		label.TextColor3 = color
		label.Text = value
		label.Parent = paper
		return label
	end
	local cocoa = Color3.fromRGB(96, 62, 34)
	local ember = Color3.fromRGB(188, 68, 44)
	text("Title", lines[1], 0.01, 0.13, 0.125, cocoa)
	text("Subtitle", lines[2], 0.15, 0.15, 0.065, ember)
	text("Reward", lines[3], 0.32, 0.13, 0.115, cocoa)
	text("Footer", lines[4], 0.9, 0.08, 0.05, Color3.fromRGB(150, 118, 78))

	-- A drawn mound of feathers rather than an uploaded image, so the flyer needs no art pipeline.
	local mound = Instance.new("Frame")
	mound.Name = "Mound"
	mound.BackgroundTransparency = 1
	mound.AnchorPoint = Vector2.new(0.5, 1)
	mound.Position = UDim2.fromScale(0.5, 0.88)
	mound.Size = UDim2.fromScale(0.86, 0.36)
	mound.Parent = paper
	for index = 1, 26 do
		local quill = Instance.new("Frame")
		quill.Name = "Quill" .. index
		local t = (index - 1) / 25
		local row = index % 4
		quill.AnchorPoint = Vector2.new(0.5, 1)
		quill.Position = UDim2.fromScale(0.08 + t * 0.84, 1 - row * 0.17 - math.abs(t - 0.5) * 0.1)
		quill.Size = UDim2.fromScale(0.2, 0.07)
		quill.BackgroundColor3 = if row % 2 == 0 then Color3.fromRGB(176, 143, 96) else Color3.fromRGB(152, 120, 76)
		quill.BorderSizePixel = 0
		quill.Rotation = -28 + (index % 7) * 9
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(1, 0)
		round.Parent = quill
		quill.Parent = mound
	end
	gui.Parent = parchment
end

function ChapterShellService.build(workspaceService: Workspace, config: { [string]: any }): Folder
	local mapModel = workspaceService:FindFirstChild(ChapterLayout.CHAPTER1_MAP_NAME)
	local folder = if mapModel
		then ChapterShellService.buildFromMap(workspaceService, mapModel, config)
		else ChapterShellService.buildGreybox(workspaceService, config)
	local ok, err = pcall(ChapterShellService.buildIntroSet, folder, config)
	if not ok then
		-- The intro set is presentation only: the round must still start without it.
		warn("[SFE][Chapter] intro set failed to build: " .. tostring(err))
	end
	return folder
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
