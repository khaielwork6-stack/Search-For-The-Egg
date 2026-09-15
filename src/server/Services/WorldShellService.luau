--!strict
-- Builds the compact lobby (MASTER_SPEC 11 "Layout") from original placeholder primitives plus the
-- repo's Feather/Egg meshes: a warm floor ring, the spawn pad facing the chapter portal, and eight
-- purposeful stations on ChapterLayout.lobby (ASSUMED A-LOBBY-04). Every station has a legible sign,
-- a ProximityPrompt that opens its modal, at least one SFE_Ambient motion tag for the client
-- scheduler, and an ambient audio anchor. Geometry parts still carry SFE_Placeholder = "PHASE_6_ART"
-- (final art pass); the composition itself is the Phase 4 deliverable and no primary space is dead.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ChapterLayout = require(ReplicatedStorage.Shared.Domain.ChapterLayout)

local WorldShellService = {}

WorldShellService.FOLDER_NAME = "SFE_LobbyShell"
WorldShellService.PLACEHOLDER_TAG = "PHASE_6_ART"

local PALETTE = {
	straw = Color3.fromRGB(226, 191, 108),
	strawDeep = Color3.fromRGB(190, 145, 62),
	cream = Color3.fromRGB(252, 246, 234),
	sky = Color3.fromRGB(129, 190, 220),
	leaf = Color3.fromRGB(116, 170, 92),
	leafBright = Color3.fromRGB(128, 200, 70),
	ember = Color3.fromRGB(228, 117, 70),
	gold = Color3.fromRGB(246, 182, 40),
	goldDeep = Color3.fromRGB(184, 118, 22),
	teal = Color3.fromRGB(20, 78, 92),
	tealLight = Color3.fromRGB(38, 118, 134),
	wood = Color3.fromRGB(150, 104, 62),
	woodDeep = Color3.fromRGB(104, 70, 42),
	gem = Color3.fromRGB(122, 96, 220),
	moon = Color3.fromRGB(200, 214, 255),
}

-- Station copy (original), the modal each prompt opens, and the world motion it carries.
local STATIONS: { [string]: { title: string, action: string, color: Color3, ambient: string, kind: string } } = {
	party = { title = "Sunlit Henhouse", action = "Form a party", color = PALETTE.sky, ambient = "portalShimmer", kind = "portal" },
	daily = { title = "Daily Nest", action = "Open the nest", color = PALETTE.ember, ambient = "bob", kind = "nest" },
	classes = { title = "Class Cards", action = "Roll a class", color = PALETTE.leaf, ambient = "spin", kind = "cards" },
	shop = { title = "Perk Shop", action = "Browse permanent perks", color = PALETTE.gold, ambient = "bob", kind = "bench" },
	event = { title = "Moonlit Chest", action = "Peek inside", color = PALETTE.gem, ambient = "moonPulse", kind = "chest" },
	inventory = { title = "Tool Rack", action = "Open the rack", color = PALETTE.wood, ambient = "sway", kind = "rack" },
	stats = { title = "Forager Ledger", action = "Read the ledger", color = PALETTE.sky, ambient = "pageFlip", kind = "ledger" },
	codes = { title = "Nest Mailbox", action = "Enter a code", color = PALETTE.leafBright, ambient = "flagWave", kind = "mailbox" },
}

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
	p:SetAttribute("SFE_Placeholder", WorldShellService.PLACEHOLDER_TAG)
	p.Parent = parent
	return p
end

local function label(target: BasePart, text: string, face: Enum.NormalId, pixelsPerStud: number?)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Label"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud or 40
	gui.AlwaysOnTop = false
	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.Font = Enum.Font.FredokaOne
	textLabel.TextScaled = true
	textLabel.TextColor3 = PALETTE.cream
	textLabel.TextStrokeColor3 = Color3.fromRGB(38, 26, 16)
	textLabel.TextStrokeTransparency = 0.2
	textLabel.Text = text
	textLabel.Parent = gui
	gui.Parent = target
end

local function prompt(parent: BasePart, name: string, actionText: string, objectText: string, maxDistance: number)
	local p = Instance.new("ProximityPrompt")
	p.Name = name
	p.ActionText = actionText
	p.ObjectText = objectText
	p.HoldDuration = 0
	p.MaxActivationDistance = maxDistance
	p.RequiresLineOfSight = false
	p.Style = Enum.ProximityPromptStyle.Custom -- drawn by the client PromptController in the UI language
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.GamepadKeyCode = Enum.KeyCode.ButtonX
	p.Parent = parent
	return p
end

local function mesh(role: string, cframe: CFrame, scale: number, parent: Instance, color: Color3?): BasePart?
	local assets = ReplicatedStorage:FindFirstChild("SFE_Assets")
	local template = assets and assets:FindFirstChild(role)
	if not template or not template:IsA("BasePart") then
		return nil
	end
	local clone = template:Clone() :: BasePart
	clone.Name = "Decor_" .. role
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanQuery = false
	clone.CanTouch = false
	clone.Size = template.Size * scale
	clone.CFrame = cframe
	if color then
		clone.Color = color
	end
	clone.Parent = parent
	return clone
end

-- Sign post shared by every station: a plank with the title behind and above the emblem, facing the
-- spawn path so the name reads before the player reaches the prompt.
local function sign(folder: Instance, id: string, base: Vector3, facing: Vector3, color: Color3, title: string): Part
	local anchor = base - facing * 3.6 + Vector3.new(0, 6.6, 0)
	local look = CFrame.lookAt(anchor, anchor + facing)
	local post = part(
		id .. "SignPost",
		Vector3.new(0.5, 6.6, 0.5),
		CFrame.new(anchor - Vector3.new(0, 3.3, 0)),
		PALETTE.woodDeep,
		Enum.Material.Wood,
		folder,
		false
	)
	local _post = post
	local board = part(id .. "Sign", Vector3.new(7, 2.4, 0.5), look, color, Enum.Material.SmoothPlastic, folder, false)
	local frame =
		part(id .. "SignFrame", Vector3.new(7.6, 3, 0.4), look * CFrame.new(0, 0, 0.1), PALETTE.goldDeep, Enum.Material.Wood, folder, false)
	local _ = frame
	label(board, title, Enum.NormalId.Front, 32)
	return board
end

local function station(folder: Instance, config: { [string]: any }, id: string)
	local layout = ChapterLayout.station(id) :: { [string]: any }
	local spec = STATIONS[id]
	local base = layout.position
	local facing = (layout.facing :: Vector3).Unit
	local look = CFrame.lookAt(base, base + facing)
	local range = config.lobby.stationPromptRangeStuds

	local plinth = part(id .. "Base", Vector3.new(7, 1, 7), look * CFrame.new(0, 0.5, 0), PALETTE.strawDeep, Enum.Material.Wood, folder)
	local plinthTrim = part(
		id .. "Trim",
		Vector3.new(7.6, 0.3, 7.6),
		look * CFrame.new(0, 1.05, 0),
		PALETTE.gold,
		Enum.Material.SmoothPlastic,
		folder,
		false
	)
	local _ = plinthTrim
	local focus: BasePart
	if spec.kind == "nest" then
		local nest = part(
			id .. "Nest",
			Vector3.new(4.5, 1.6, 4.5),
			look * CFrame.new(0, 1.8, 0) * CFrame.Angles(0, 0, math.rad(90)),
			PALETTE.straw,
			Enum.Material.Grass,
			folder,
			false
		)
		nest.Shape = Enum.PartType.Cylinder
		focus = part(
			id .. "Emblem",
			Vector3.new(2, 2.6, 2),
			look * CFrame.new(0, 3.6, 0),
			spec.color,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		focus.Shape = Enum.PartType.Ball
		mesh("Egg", look * CFrame.new(1.2, 3.2, 0.8), 0.9, folder)
		mesh("Egg", look * CFrame.new(-1.1, 3.2, -0.6), 0.8, folder, PALETTE.sky)
	elseif spec.kind == "cards" then
		focus = part(
			id .. "Emblem",
			Vector3.new(2.6, 3.6, 0.3),
			look * CFrame.new(0, 3.4, 0),
			spec.color,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		local cardL = part(
			id .. "CardL",
			Vector3.new(2.2, 3.2, 0.3),
			look * CFrame.new(-1.6, 3.2, 0.4) * CFrame.Angles(0, math.rad(25), 0),
			PALETTE.sky,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		local cardR = part(
			id .. "CardR",
			Vector3.new(2.2, 3.2, 0.3),
			look * CFrame.new(1.6, 3.2, 0.4) * CFrame.Angles(0, math.rad(-25), 0),
			PALETTE.gem,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		cardL:SetAttribute("SFE_Ambient", "sway")
		cardR:SetAttribute("SFE_Ambient", "sway")
		mesh("Egg", look * CFrame.new(0, 3.4, 0.3), 0.7, folder, PALETTE.gold)
	elseif spec.kind == "bench" then
		focus = part(
			id .. "Emblem",
			Vector3.new(5, 1.2, 2.4),
			look * CFrame.new(0, 2.4, 0),
			PALETTE.woodDeep,
			Enum.Material.Wood,
			folder,
			false
		)
		local anvil =
			part(id .. "Anvil", Vector3.new(1.6, 1.2, 1.2), look * CFrame.new(0.8, 3.6, 0), spec.color, Enum.Material.Metal, folder, false)
		anvil:SetAttribute("SFE_Ambient", "bob")
		local bag = part(
			id .. "Bag",
			Vector3.new(1.4, 1.6, 1.4),
			look * CFrame.new(-1.3, 3.8, 0),
			PALETTE.straw,
			Enum.Material.Fabric,
			folder,
			false
		)
		bag.Shape = Enum.PartType.Ball
		bag:SetAttribute("SFE_Ambient", "bob")
	elseif spec.kind == "chest" then
		focus = part(
			id .. "Emblem",
			Vector3.new(3.4, 2.2, 2.4),
			look * CFrame.new(0, 2.6, 0),
			PALETTE.woodDeep,
			Enum.Material.Wood,
			folder,
			false
		)
		local lid = part(
			id .. "Lid",
			Vector3.new(3.6, 0.6, 2.6),
			look * CFrame.new(0, 4, -0.2) * CFrame.Angles(math.rad(-20), 0, 0),
			PALETTE.woodDeep,
			Enum.Material.Wood,
			folder,
			false
		)
		lid:SetAttribute("SFE_Ambient", "bob")
		local glow =
			part(id .. "Glow", Vector3.new(2.6, 0.4, 1.8), look * CFrame.new(0, 3.8, 0), PALETTE.moon, Enum.Material.Neon, folder, false)
		glow.Transparency = 0.3
		glow:SetAttribute("SFE_Ambient", "moonPulse")
		local beam =
			part(id .. "Beam", Vector3.new(2.2, 9, 2.2), look * CFrame.new(0, 8.5, 0), PALETTE.moon, Enum.Material.Neon, folder, false)
		beam.Shape = Enum.PartType.Cylinder
		beam.CFrame = look * CFrame.new(0, 8.5, 0) * CFrame.Angles(0, 0, math.rad(90))
		beam.Transparency = 0.82
		beam:SetAttribute("SFE_Ambient", "moonPulse")
	elseif spec.kind == "rack" then
		focus =
			part(id .. "Emblem", Vector3.new(5.5, 4.5, 0.6), look * CFrame.new(0, 3.3, 0), spec.color, Enum.Material.Wood, folder, false)
		for index, color in ipairs({ PALETTE.strawDeep, PALETTE.ember, PALETTE.sky, PALETTE.gold }) do
			local hook = part(
				id .. "Hook" .. index,
				Vector3.new(0.5, 2.6, 0.5),
				look * CFrame.new(-2 + (index - 1) * 1.3, 3.2, 0.5),
				color,
				Enum.Material.SmoothPlastic,
				folder,
				false
			)
			hook:SetAttribute("SFE_Ambient", "sway")
		end
	elseif spec.kind == "ledger" then
		focus = part(
			id .. "Emblem",
			Vector3.new(4.6, 5.6, 0.6),
			look * CFrame.new(0, 3.9, 0),
			spec.color,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		local boardGui = Instance.new("SurfaceGui")
		boardGui.Name = "SFE_LeaderboardSurface"
		boardGui.Face = Enum.NormalId.Front
		boardGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		boardGui.PixelsPerStud = 40
		boardGui.Parent = focus
		local page = part(
			id .. "Page",
			Vector3.new(1.8, 2.4, 0.2),
			look * CFrame.new(2.9, 4.4, 0.2),
			PALETTE.cream,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		page:SetAttribute("SFE_Ambient", "pageFlip")
		mesh("Feather", look * CFrame.new(-2.9, 4.4, 0.3) * CFrame.Angles(0, 0, math.rad(-20)), 1.8, folder)
	elseif spec.kind == "mailbox" then
		local post = part(
			id .. "Post",
			Vector3.new(0.5, 3.2, 0.5),
			look * CFrame.new(0, 2.6, 0),
			PALETTE.woodDeep,
			Enum.Material.Wood,
			folder,
			false
		)
		local _ = post
		focus = part(
			id .. "Emblem",
			Vector3.new(2.6, 1.8, 1.6),
			look * CFrame.new(0, 4.6, 0),
			spec.color,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		local flag = part(
			id .. "Flag",
			Vector3.new(0.2, 1.4, 0.8),
			look * CFrame.new(1.4, 5.4, 0),
			PALETTE.ember,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		flag:SetAttribute("SFE_Ambient", "flagWave")
	else
		focus = plinth
	end
	focus:SetAttribute("SFE_Ambient", spec.ambient)
	focus:SetAttribute("SFE_Station", id)
	focus:SetAttribute("SFE_Modal", layout.modal)
	local audioAnchor =
		part(id .. "Audio", Vector3.new(1, 1, 1), look * CFrame.new(0, 3, 0), PALETTE.cream, Enum.Material.SmoothPlastic, folder, false)
	audioAnchor.Transparency = 1
	audioAnchor:SetAttribute("SFE_AudioRole", "station.hum")
	sign(folder, id, base, facing, spec.color, spec.title)
	prompt(focus, "SFE_Station_" .. id, spec.action, spec.title, range)
	-- Interaction feedback: the prompt target is highlighted client-side on hover through the
	-- ProximityPrompt itself; a leaf pair at the foot of each plinth reads as the shared accent.
	for side = -1, 1, 2 do
		local leafPart = part(
			id .. "Leaf" .. (side + 2),
			Vector3.new(1.6, 0.3, 0.9),
			look * CFrame.new(side * 3.2, 1.2, 2.6) * CFrame.Angles(0, math.rad(side * 30), 0),
			PALETTE.leafBright,
			Enum.Material.Grass,
			folder,
			false
		)
		leafPart:SetAttribute("SFE_Ambient", "sway")
	end
end

function WorldShellService.buildGreybox(workspaceService: Workspace, spawnLocation: SpawnLocation?, config: { [string]: any }): Folder
	local existing = workspaceService:FindFirstChild(WorldShellService.FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = WorldShellService.FOLDER_NAME
	folder:SetAttribute("SFE_Placeholder", WorldShellService.PLACEHOLDER_TAG)

	local lobby = ChapterLayout.lobby
	local origin = CFrame.new(lobby.origin)

	-- Warm floor disc with a wider straw disc beneath it so a straw rim reads as the nest edge.
	local floor = part("Floor", Vector3.new(1, 96, 96), origin * CFrame.new(0, 0.5, 0), PALETTE.cream, Enum.Material.Fabric, folder)
	floor.Shape = Enum.PartType.Cylinder
	floor.CFrame = origin * CFrame.new(0, 0.5, 0) * CFrame.Angles(0, 0, math.rad(90))
	local rim = part("StrawRim", Vector3.new(0.6, 104, 104), origin * CFrame.new(0, 0.3, 0), PALETTE.strawDeep, Enum.Material.Grass, folder)
	rim.Shape = Enum.PartType.Cylinder
	rim.CFrame = origin * CFrame.new(0, 0.3, 0) * CFrame.Angles(0, 0, math.rad(90))
	-- Straw path from spawn to the portal keeps the primary route unmistakable.
	part("Path", Vector3.new(8, 0.2, 40), origin * CFrame.new(0, 1.1, 2), PALETTE.straw, Enum.Material.WoodPlanks, folder)

	-- Spawn pad facing +Z toward the portal frame.
	local pad = part(
		"SpawnPad",
		Vector3.new(10, 0.4, 10),
		CFrame.new(lobby.spawn - Vector3.new(0, 1.8, 0)),
		PALETTE.straw,
		Enum.Material.WoodPlanks,
		folder
	)
	pad:SetAttribute("SFE_Ambient", "dustMote")
	if spawnLocation then
		spawnLocation.CFrame =
			CFrame.lookAt(lobby.spawn - Vector3.new(0, 1, 0), Vector3.new(lobby.portal.X, lobby.spawn.Y - 1, lobby.portal.Z))
		spawnLocation.Anchored = true
	end

	-- Chapter portal frame: two posts and a lintel, straight ahead of spawn; the diorama is the party
	-- station focus (SFE_Portal keeps the Phase 2 prompt name).
	local portal = lobby.portal
	local postL = part(
		"PortalPostL",
		Vector3.new(1.6, 12, 1.6),
		origin * CFrame.new(portal.X - 6, 7, portal.Z),
		PALETTE.strawDeep,
		Enum.Material.Wood,
		folder
	)
	local postR = part(
		"PortalPostR",
		Vector3.new(1.6, 12, 1.6),
		origin * CFrame.new(portal.X + 6, 7, portal.Z),
		PALETTE.strawDeep,
		Enum.Material.Wood,
		folder
	)
	local lintel = part(
		"PortalLintel",
		Vector3.new(15, 1.6, 1.6),
		origin * CFrame.new(portal.X, 13.5, portal.Z),
		PALETTE.strawDeep,
		Enum.Material.Wood,
		folder
	)
	local diorama = part(
		"PortalDiorama",
		Vector3.new(11, 10, 0.4),
		origin * CFrame.new(portal.X, 7, portal.Z + 0.6),
		PALETTE.sky,
		Enum.Material.Neon,
		folder,
		false
	)
	diorama.Transparency = 0.35
	diorama:SetAttribute("SFE_Ambient", "portalShimmer")
	diorama:SetAttribute("SFE_Station", "party")
	diorama:SetAttribute("SFE_Modal", "party")
	label(lintel, STATIONS.party.title, Enum.NormalId.Front)
	prompt(diorama, "SFE_Portal", STATIONS.party.action, STATIONS.party.title, config.lobby.stationPromptRangeStuds + 2)
	postL:SetAttribute("SFE_Ambient", "clothSway")
	postR:SetAttribute("SFE_Ambient", "clothSway")
	-- Party silhouette pedestal in front of the portal (the client fills it from PartyProjection).
	local silhouette = part(
		"PartySilhouettes",
		Vector3.new(9, 0.4, 2),
		origin * CFrame.new(portal.X, 1.3, portal.Z - 5),
		PALETTE.strawDeep,
		Enum.Material.Wood,
		folder,
		false
	)
	silhouette:SetAttribute("SFE_PartySilhouettes", true)
	for i = 1, config.project.maxPartyPlayers do
		local slot = part(
			"PartySlot" .. i,
			Vector3.new(1.2, 2.4, 0.4),
			origin * CFrame.new(portal.X - 3.75 + (i - 1) * 2.5, 2.7, portal.Z - 5),
			PALETTE.cream,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		slot.Transparency = 0.75
		slot:SetAttribute("SFE_PartySlot", i)
	end
	local portalAudio = part(
		"partyAudio",
		Vector3.new(1, 1, 1),
		origin * CFrame.new(portal.X, 6, portal.Z),
		PALETTE.cream,
		Enum.Material.SmoothPlastic,
		folder,
		false
	)
	portalAudio.Transparency = 1
	portalAudio:SetAttribute("SFE_AudioRole", "station.hum")

	-- Stations on the configured sightlines (portal handled above).
	for _, id in ipairs(lobby.stationOrder) do
		if id ~= "party" then
			station(folder, config, id)
		end
	end

	-- Ambient life: feather drift anchors, a slow fan overhead, hanging cloth, pecking birds.
	for index, offset in ipairs({ Vector3.new(-12, 10, 8), Vector3.new(12, 11, 8), Vector3.new(0, 12, -6), Vector3.new(0, 9, -28) }) do
		local anchor = part(
			"FeatherDrift" .. index,
			Vector3.new(1, 1, 1),
			origin * CFrame.new(offset),
			PALETTE.cream,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		anchor.Transparency = 1
		anchor:SetAttribute("SFE_Ambient", "featherDrift")
	end
	local fan =
		part("LobbyFan", Vector3.new(12, 0.3, 1.4), origin * CFrame.new(0, 17, 0), PALETTE.woodDeep, Enum.Material.Wood, folder, false)
	fan:SetAttribute("SFE_Ambient", "spin")
	local fanPost =
		part("LobbyFanPost", Vector3.new(0.6, 6, 0.6), origin * CFrame.new(0, 20, 0), PALETTE.woodDeep, Enum.Material.Wood, folder, false)
	local _ = fanPost
	for index, offset in ipairs({ Vector3.new(-30, 9, -2), Vector3.new(30, 9, -2) }) do
		local cloth = part(
			"Bunting" .. index,
			Vector3.new(0.3, 6, 10),
			origin * CFrame.new(offset),
			if index == 1 then PALETTE.ember else PALETTE.sky,
			Enum.Material.Fabric,
			folder,
			false
		)
		cloth:SetAttribute("SFE_Ambient", "clothSway")
	end
	for i = 1, 3 do
		local bird = part(
			"Bird" .. i,
			Vector3.new(1.2, 1.2, 1.6),
			origin * CFrame.new(-34 + i * 16, 1.6, -40),
			PALETTE.cream,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		bird:SetAttribute("SFE_Ambient", "peck")
	end

	-- Clients wait for this count before scanning: a folder replicates before its children.
	folder:SetAttribute("SFE_ChildCount", #folder:GetChildren())
	folder.Parent = workspaceService
	return folder
end

-- ---------------------------------------------------------------------------------------------
-- Map mode: the owner's SearchForTheEgg_Lobby model is the environment. Only functional and ambient
-- instances are created here (prompt anchors on the map's own props, the two small barn props the
-- map lacks, feather-drift anchors, the party pad zones), so nothing greybox is dropped on the art.
-- ---------------------------------------------------------------------------------------------

local function anchor(folder: Instance, name: string, position: Vector3, size: Vector3?): Part
	local p = part(name, size or Vector3.new(2, 2, 2), CFrame.new(position), PALETTE.cream, Enum.Material.SmoothPlastic, folder, false)
	p.Transparency = 1
	p.CanQuery = false
	return p
end

-- Rewrites the owner's stall signs so the vendor's purpose reads from across the yard.
local function retitleStall(mapModel: Instance, hostName: string, sign: string?, subtitle: string?)
	local host = mapModel:FindFirstChild(hostName)
	if not host then
		return
	end
	local function setText(partName: string, text: string?)
		if not text then
			return
		end
		local partInstance = host:FindFirstChild(partName, true)
		local gui = partInstance and partInstance:FindFirstChildOfClass("SurfaceGui")
		if gui then
			for _, descendant in ipairs(gui:GetDescendants()) do
				if descendant:IsA("TextLabel") then
					descendant.Text = text
				end
			end
		end
	end
	setText("ShopSign", sign)
	setText("ShopSubtitle", subtitle)
end

-- Daily Nest: a straw ring with three eggs on the barn floor in front of the nesting shelf.
local function buildDailyNest(folder: Instance, base: Vector3)
	local ring = part(
		"DailyNestRing",
		Vector3.new(1.1, 5.2, 5.2),
		CFrame.new(base + Vector3.new(0, 0.55, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		PALETTE.straw,
		Enum.Material.Grass,
		folder
	)
	ring.Shape = Enum.PartType.Cylinder
	local hollow = part(
		"DailyNestHollow",
		Vector3.new(0.5, 3.4, 3.4),
		CFrame.new(base + Vector3.new(0, 0.9, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		PALETTE.strawDeep,
		Enum.Material.Fabric,
		folder,
		false
	)
	hollow.Shape = Enum.PartType.Cylinder
	for i = 1, 3 do
		local angle = (i / 3) * math.pi * 2
		local egg = part(
			"DailyNestEgg" .. i,
			Vector3.new(1.1, 1.4, 1.1),
			CFrame.new(base + Vector3.new(math.cos(angle) * 0.9, 1.65, math.sin(angle) * 0.9)) * CFrame.Angles(0, angle, math.rad(12)),
			PALETTE.cream,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		egg.Shape = Enum.PartType.Ball
		egg:SetAttribute("SFE_Ambient", "bob")
	end
	local glow = Instance.new("PointLight")
	glow.Color = PALETTE.gold
	glow.Range = 9
	glow.Brightness = 0.8
	glow.Parent = hollow
	return ring
end

-- Moonlit Chest: a teal chest with a gold lid ajar and a moon glow, against the barn's rear shelf.
local function buildMoonChest(folder: Instance, base: Vector3)
	local body = part(
		"MoonChestBody",
		Vector3.new(3.6, 2.2, 2.4),
		CFrame.new(base + Vector3.new(0, 1.1, 0)),
		PALETTE.teal,
		Enum.Material.Wood,
		folder
	)
	local lid = part(
		"MoonChestLid",
		Vector3.new(3.8, 0.7, 2.6),
		CFrame.new(base + Vector3.new(0, 2.55, -0.55)) * CFrame.Angles(math.rad(-28), 0, 0),
		PALETTE.goldDeep,
		Enum.Material.Wood,
		folder,
		false
	)
	lid:SetAttribute("SFE_Ambient", "bob")
	local band = part(
		"MoonChestBand",
		Vector3.new(3.7, 0.5, 2.5),
		CFrame.new(base + Vector3.new(0, 1.1, 0)),
		PALETTE.gold,
		Enum.Material.SmoothPlastic,
		folder,
		false
	)
	local _ = band
	local moon = part(
		"MoonChestGlow",
		Vector3.new(1.4, 1.4, 1.4),
		CFrame.new(base + Vector3.new(0, 2.2, 0.2)),
		PALETTE.moon,
		Enum.Material.Neon,
		folder,
		false
	)
	moon.Shape = Enum.PartType.Ball
	moon:SetAttribute("SFE_Ambient", "moonPulse")
	local light = Instance.new("PointLight")
	light.Color = PALETTE.moon
	light.Range = 12
	light.Brightness = 1.2
	light.Parent = moon
	return body
end

function WorldShellService.buildFromMap(workspaceService: Workspace, mapModel: Instance, config: { [string]: any }): Folder
	local existing = workspaceService:FindFirstChild(WorldShellService.FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = WorldShellService.FOLDER_NAME
	folder:SetAttribute("SFE_MapMode", true)
	folder:SetAttribute("SFE_MapName", mapModel.Name)
	local lobby = ChapterLayout.lobby
	local range = config.lobby.stationPromptRangeStuds

	-- The map ships its own queue/leaderboard script; our server owns those signs.
	local vendorScript = mapModel:FindFirstChild("LobbyRuntime")
	if vendorScript and vendorScript:IsA("BaseScript") and not vendorScript.Disabled then
		vendorScript.Disabled = true
		warn("[SFE][World] disabled the map's LobbyRuntime script (the game server drives pads and boards)")
	end

	-- Portal: the barn doorway. A thin threshold plate carries the prompt and the objective highlight.
	local threshold = anchor(folder, "PortalAnchor", lobby.portal, Vector3.new(10, 9, 0.6))
	threshold.CanQuery = true
	threshold:SetAttribute("SFE_Ambient", "portalShimmer")
	threshold:SetAttribute("SFE_Station", "party")
	prompt(threshold, "SFE_Portal", "Set off to search", STATIONS.party.title, range + 2)
	local portalAudio = anchor(folder, "partyAudio", lobby.portal + Vector3.new(0, 2, 0))
	portalAudio:SetAttribute("SFE_AudioRole", "station.hum")

	-- Barn props the map does not provide: the Daily Nest and the Moonlit Chest.
	local dailyFocus = buildDailyNest(folder, lobby.stations.daily.position - Vector3.new(0, 0.8, 0))
	local chestFocus = buildMoonChest(folder, lobby.stations.event.position - Vector3.new(0, 1.1, 0))

	-- Station prompts on the map's own props (counters, boards, coops) or on our props. Stations
	-- with a vendor NPC in the map put their prompt on the vendor and speak through them.
	local focusByStation: { [string]: BasePart } = { daily = dailyFocus, event = chestFocus }
	for _, id in ipairs(lobby.stationOrder) do
		if id ~= "party" then
			local spec = STATIONS[id]
			local layout = ChapterLayout.station(id) :: { [string]: any }
			local focus = focusByStation[id]
			local npc = lobby.npcs[id]
			local vendor = npc and workspaceService:FindFirstChild(npc.model)
			local vendorRoot = vendor and vendor:FindFirstChild("HumanoidRootPart")
			local objectText, actionText = spec.title, spec.action
			if not focus and vendorRoot and vendorRoot:IsA("BasePart") then
				focus = anchor(folder, id .. "Vendor", vendorRoot.Position, Vector3.new(4, 6, 3))
				focus.CanQuery = true
				focus:SetAttribute("SFE_Ambient", "npc")
				focus:SetAttribute("SFE_NpcModel", npc.model)
				focus:SetAttribute("SFE_NpcName", npc.name)
				focus:SetAttribute("SFE_NpcRole", npc.role)
				focus:SetAttribute("SFE_NpcLine", npc.line)
				objectText, actionText = npc.name, "Talk"
				retitleStall(mapModel, layout.host, npc.sign, npc.subtitle)
				local humanoid = vendor:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
				end
			elseif not focus then
				focus = anchor(folder, id .. "Anchor", layout.position, Vector3.new(4, 3, 2))
				focus.CanQuery = true
			end
			focus:SetAttribute("SFE_Station", id)
			focus:SetAttribute("SFE_Modal", layout.modal)
			local stationPrompt = prompt(focus, "SFE_Station_" .. id, actionText, objectText, range)
			if actionText == "Talk" then
				-- Chest height on the vendor, under the nameplate and clear of the stall sign.
				stationPrompt.UIOffset = Vector2.new(0, -70)
			end
			local audioAnchor = anchor(folder, id .. "Audio", layout.position + Vector3.new(0, 2, 0))
			audioAnchor:SetAttribute("SFE_AudioRole", "station.hum")
		end
	end

	-- Party nest pads: zone volumes (server-checked), a glowing floor disc with a ring of light
	-- posts as the barrier, a floating board (client-drawn from SFE_PadText), and a "set off"
	-- prompt on each sign post.
	for _, pad in ipairs(lobby.pads) do
		local zone = anchor(folder, "PadZone" .. pad.index, pad.center, pad.zoneSize)
		zone:SetAttribute("SFE_Pad", pad.index)
		zone:SetAttribute("SFE_Ambient", "padBoard")
		zone:SetAttribute("SFE_PadText", string.format("0/%d\nTouch to create a party", config.project.maxPartyPlayers))
		local floorY = lobby.groundY + 0.06
		local radius = pad.zoneSize.X / 2 - 0.6
		local glow = part(
			"PadGlow" .. pad.index,
			Vector3.new(0.12, radius * 2, radius * 2),
			CFrame.new(pad.center.X, floorY, pad.center.Z) * CFrame.Angles(0, 0, math.rad(90)),
			PALETTE.tealLight,
			Enum.Material.Neon,
			folder,
			false
		)
		glow.Shape = Enum.PartType.Cylinder
		glow.Transparency = 0.55
		glow.CanQuery = false
		glow:SetAttribute("SFE_Ambient", "padPulse")
		glow:SetAttribute("SFE_Pad", pad.index)
		local rim = part(
			"PadRim" .. pad.index,
			Vector3.new(0.3, radius * 2 + 1.2, radius * 2 + 1.2),
			CFrame.new(pad.center.X, floorY - 0.05, pad.center.Z) * CFrame.Angles(0, 0, math.rad(90)),
			PALETTE.gold,
			Enum.Material.SmoothPlastic,
			folder,
			false
		)
		rim.Shape = Enum.PartType.Cylinder
		rim.Transparency = 0.15
		rim.CanQuery = false
		for postIndex = 1, 12 do
			local angle = (postIndex - 1) / 12 * math.pi * 2
			local postPosition =
				Vector3.new(pad.center.X + math.cos(angle) * (radius + 0.3), floorY + 1.4, pad.center.Z + math.sin(angle) * (radius + 0.3))
			local lightPost = part(
				"PadPost" .. pad.index .. "_" .. postIndex,
				Vector3.new(0.35, 2.8, 0.35),
				CFrame.new(postPosition),
				PALETTE.tealLight,
				Enum.Material.Neon,
				folder,
				false
			)
			lightPost.Transparency = 0.35
			lightPost.CanQuery = false
			lightPost:SetAttribute("SFE_Pad", pad.index)
			lightPost:SetAttribute("SFE_PadPost", true)
		end
		local light = Instance.new("PointLight")
		light.Color = PALETTE.tealLight
		light.Brightness = 1.2
		light.Range = 14
		light.Parent = glow
		local post = anchor(folder, "PadStart" .. pad.index, pad.signPost + Vector3.new(0, 1.2, 0), Vector3.new(2, 3, 2))
		post.CanQuery = true
		prompt(post, "SFE_PadStart_" .. pad.index, "Set off", "Party nest " .. pad.index, range)
	end

	-- Ambient life: feather drift anchors and dust at spawn.
	for index, position in ipairs(lobby.ambientAnchors) do
		local drift = anchor(folder, "FeatherDrift" .. index, position)
		drift:SetAttribute("SFE_Ambient", "featherDrift")
	end
	local dust = anchor(folder, "SpawnDust", lobby.spawn + Vector3.new(0, 2, 0), Vector3.new(6, 1, 6))
	dust:SetAttribute("SFE_Ambient", "dustMote")

	folder:SetAttribute("SFE_ChildCount", #folder:GetChildren())
	folder.Parent = workspaceService
	return folder
end

-- Builds the lobby: the owner's map when present, the greybox shell otherwise.
function WorldShellService.build(workspaceService: Workspace, spawnLocation: SpawnLocation?, config: { [string]: any }): Folder
	local mapModel = workspaceService:FindFirstChild(ChapterLayout.LOBBY_MAP_NAME)
	if mapModel then
		-- The map carries its own spawn pad; the stray default SpawnLocation must not win.
		if spawnLocation and spawnLocation.Parent == workspaceService then
			spawnLocation.Enabled = false
		end
		return WorldShellService.buildFromMap(workspaceService, mapModel, config)
	end
	return WorldShellService.buildGreybox(workspaceService, spawnLocation, config)
end

function WorldShellService.isMapMode(folder: Instance?): boolean
	return folder ~= nil and folder:GetAttribute("SFE_MapMode") == true
end

-- Writes the map's queue sign for a pad (map mode only).
-- Mirrors the pad's status onto its zone anchor so clients draw the floating board from it.
function WorldShellService.setPadText(workspaceService: Workspace, index: number, text: string)
	local shell = workspaceService:FindFirstChild(WorldShellService.FOLDER_NAME)
	local zone = shell and shell:FindFirstChild("PadZone" .. index)
	if zone and zone:GetAttribute("SFE_PadText") ~= text then
		zone:SetAttribute("SFE_PadText", text)
	end
end

function WorldShellService.setPadSign(workspaceService: Workspace, index: number, text: string)
	local mapModel = workspaceService:FindFirstChild(ChapterLayout.LOBBY_MAP_NAME)
	local queues = mapModel and mapModel:FindFirstChild("Queues")
	local queue = queues and queues:FindFirstChild("Queue" .. index)
	local sign = queue and queue:FindFirstChild("QueueSign")
	local display = sign and sign:FindFirstChild("Display")
	local label = display and display:FindFirstChild("Text")
	if label and label:IsA("TextLabel") and label.Text ~= text then
		label.Text = text
	end
end

-- Fills the owner's three global boards from a LeaderboardService snapshot.
--
-- The boards are top-level Workspace models whose rows were authored as a stack of frames with
-- duplicated names (`Top1`, `Top2`, `Empty`, `Top3`, then six more `Top4`s). Names are therefore
-- useless for ordering, so rows are sorted by their Y position inside the scrolling frame and filled
-- top to bottom. Each row carries `PlayerIcon`, `Place`, `PlayerName` and `Amount`, which is exactly
-- the shape the reference boards use.

local MEDALS = {
	Color3.fromRGB(255, 205, 66), -- gold
	Color3.fromRGB(214, 218, 226), -- silver
	Color3.fromRGB(205, 140, 88), -- bronze
}
local PLAIN_RANK = Color3.fromRGB(252, 246, 234)
local thumbnailCache: { [number]: string } = {}

-- A player's headshot, cached for the life of the server. A failure returns an empty image rather
-- than blocking the board, and is retried on the next refresh.
local function thumbnailFor(userId: number): string
	local cached = thumbnailCache[userId]
	if cached then
		return cached
	end
	local ok, image = pcall(function()
		return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
	end)
	if ok and type(image) == "string" and image ~= "" then
		thumbnailCache[userId] = image
		return image
	end
	return ""
end

-- Times are stored as integer milliseconds and shown as m:ss.cc; everything else is a plain count
-- with thousands separators, so a seven-figure feather total stays readable at a distance.
local function formatValue(value: number, unit: string?): string
	if unit == "ms" then
		local total = math.max(0, math.floor(value))
		local minutes = math.floor(total / 60000)
		local seconds = math.floor(total % 60000 / 1000)
		local hundredths = math.floor(total % 1000 / 10)
		return string.format("%d:%02d.%02d", minutes, seconds, hundredths)
	end
	local whole = tostring(math.floor(value))
	local grouped = whole:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (grouped:gsub("^,", ""))
end

-- The trailing number in a row's name ("Row3", "Entry 07"), or nil when it has none.
local function trailingNumber(name: string): number?
	local digits = string.match(name, "(%d+)%s*$")
	return if digits then tonumber(digits) else nil
end

-- The board's rows, top of the podium first.
--
-- Ordering has to come from whatever actually positions the rows. The authored boards stack theirs
-- with a UIListLayout, which leaves every row at the same `Position` - so sorting on Position, as
-- this used to, compared equal values and handed back an arbitrary order. Ask the layout how it
-- sorts instead, and only fall back to Position when there is no layout doing the work.
local function rowsOf(board: Instance): { Instance }
	local scroller: Instance? = nil
	for _, descendant in ipairs(board:GetDescendants()) do
		if descendant:IsA("ScrollingFrame") then
			scroller = descendant
			break
		end
	end
	if not scroller then
		return {}
	end
	local layout = (scroller :: Instance):FindFirstChildWhichIsA("UIListLayout")
	type Entry = { row: GuiObject, index: number }
	local entries: { Entry } = {}
	for index, child in ipairs((scroller :: Instance):GetChildren()) do
		if child:IsA("GuiObject") and child:FindFirstChild("PlayerName") then
			table.insert(entries, { row = child :: GuiObject, index = index })
		end
	end
	-- Child order is the last tiebreak, so equal keys stay in the order the board author wrote them
	-- rather than shuffling between refreshes.
	table.sort(entries, function(a, b)
		if layout == nil then
			local ay = a.row.Position.Y.Scale + a.row.Position.Y.Offset / 1000
			local by = b.row.Position.Y.Scale + b.row.Position.Y.Offset / 1000
			if ay ~= by then
				return ay < by
			end
		elseif (layout :: UIListLayout).SortOrder == Enum.SortOrder.Name then
			local an, bn = trailingNumber(a.row.Name), trailingNumber(b.row.Name)
			if an and bn and an ~= bn then
				return an < bn
			end
			if a.row.Name ~= b.row.Name then
				return a.row.Name < b.row.Name
			end
		elseif a.row.LayoutOrder ~= b.row.LayoutOrder then
			return a.row.LayoutOrder < b.row.LayoutOrder
		end
		return a.index < b.index
	end)
	local rows: { Instance } = {}
	for _, entry in ipairs(entries) do
		table.insert(rows, entry.row)
	end
	return rows
end

function WorldShellService.applyLeaderboards(workspaceService: Workspace, snapshot: { [string]: any })
	local byId: { [string]: any } = {}
	for _, board in ipairs(snapshot.boards or {}) do
		byId[board.id] = board
	end
	for boardName, boardId in pairs(ChapterLayout.lobby.boards) do
		local model = workspaceService:FindFirstChild(boardName)
		local data = byId[boardId]
		if model and data then
			local rows = rowsOf(model)
			for index, row in ipairs(rows) do
				local entry = data.rows[index]
				local place = row:FindFirstChild("Place")
				local name = row:FindFirstChild("PlayerName")
				local amount = row:FindFirstChild("Amount")
				local icon = row:FindFirstChild("PlayerIcon")
				if place and place:IsA("TextLabel") then
					place.Text = "#" .. index
					-- Top three read as medals; the rest stay plain so the podium is obvious. An empty
					-- slot never gets one: a bronze #3 above a dash claims a third place nobody holds.
					place.TextColor3 = if entry then MEDALS[index] or PLAIN_RANK else PLAIN_RANK
				end
				if name and name:IsA("TextLabel") then
					name.Text = if entry then tostring(entry.name) else "—"
				end
				if amount and amount:IsA("TextLabel") then
					amount.Text = if entry then formatValue(tonumber(entry.value) or 0, data.unit) else ""
				end
				if icon and icon:IsA("ImageLabel") then
					icon.Image = if entry then thumbnailFor(tonumber(entry.userId) or 0) else ""
				end
				row.Visible = true
			end
			-- One GLOBAL / ALL TIME line per board, so nobody reads it as this server's scores.
			local header = model:FindFirstChild("SFE_BoardScope", true)
			if not header then
				for _, descendant in ipairs(model:GetDescendants()) do
					if descendant:IsA("SurfaceGui") then
						local plate = Instance.new("TextLabel")
						plate.Name = "SFE_BoardScope"
						plate.AnchorPoint = Vector2.new(0.5, 1)
						plate.Position = UDim2.fromScale(0.5, 1)
						plate.Size = UDim2.fromScale(1, 0.07)
						plate.BackgroundTransparency = 1
						plate.Font = Enum.Font.FredokaOne
						plate.TextScaled = true
						plate.TextColor3 = Color3.fromRGB(255, 226, 140)
						plate.Text = "GLOBAL  ·  ALL TIME"
						plate.ZIndex = 10
						plate.Parent = descendant
						break
					end
				end
			end
		end
	end
end

function WorldShellService.instanceCount(folder: Instance): number
	return #folder:GetDescendants()
end

WorldShellService.STATIONS = STATIONS

return WorldShellService
