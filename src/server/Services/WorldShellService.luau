--!strict
-- Builds the compact lobby (MASTER_SPEC 11 "Layout") from original placeholder primitives plus the
-- repo's Feather/Egg meshes: a warm floor ring, the spawn pad facing the chapter portal, and eight
-- purposeful stations on ChapterLayout.lobby (ASSUMED A-LOBBY-04). Every station has a legible sign,
-- a ProximityPrompt that opens its modal, at least one SFE_Ambient motion tag for the client
-- scheduler, and an ambient audio anchor. Geometry parts still carry SFE_Placeholder = "PHASE_6_ART"
-- (final art pass); the composition itself is the Phase 4 deliverable and no primary space is dead.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
	classes = { title = "Class Cards", action = "Browse classes", color = PALETTE.leaf, ambient = "spin", kind = "cards" },
	shop = { title = "Perk Bench", action = "Open the shop", color = PALETTE.gold, ambient = "bob", kind = "bench" },
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

function WorldShellService.build(workspaceService: Workspace, spawnLocation: SpawnLocation?, config: { [string]: any }): Folder
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

function WorldShellService.instanceCount(folder: Instance): number
	return #folder:GetDescendants()
end

WorldShellService.STATIONS = STATIONS

return WorldShellService
