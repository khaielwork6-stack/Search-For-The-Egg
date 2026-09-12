--!strict
-- Builds the intentional Phase 1 lobby shell from labeled placeholder primitives so Play Solo lands
-- in a composed space rather than an empty baseplate: a warm floor ring, a spawn pad facing the
-- chapter portal frame, three station pedestals on the primary sightlines, and tag attributes the
-- client ambient scheduler reads. Every instance carries SFE_Placeholder = "PHASE_4_ART" so the
-- Phase 4/6 art pass can find and replace it. Server-built so all clients see the same shell.

local WorldShellService = {}

WorldShellService.FOLDER_NAME = "SFE_LobbyShell"
WorldShellService.PLACEHOLDER_TAG = "PHASE_4_ART"

local function part(name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material?, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = true
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

local function label(target: BasePart, text: string, face: Enum.NormalId)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Label"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.AlwaysOnTop = false
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

function WorldShellService.build(workspaceService: Workspace, spawnLocation: SpawnLocation?): Folder
	local existing = workspaceService:FindFirstChild(WorldShellService.FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = WorldShellService.FOLDER_NAME
	folder:SetAttribute("SFE_Placeholder", WorldShellService.PLACEHOLDER_TAG)

	local origin = CFrame.new(0, 0, 0)
	local straw = Color3.fromRGB(226, 191, 108)
	local strawDeep = Color3.fromRGB(190, 145, 62)
	local cream = Color3.fromRGB(252, 246, 234)
	local sky = Color3.fromRGB(129, 190, 220)
	local leaf = Color3.fromRGB(116, 170, 92)
	local ember = Color3.fromRGB(228, 117, 70)

	-- Warm floor disc with a wider straw disc beneath it so a straw rim reads as the nest edge.
	-- Cylinder parts use Size.X as the axis length; rotating 90 degrees about Z stands them upright.
	local floor = part("Floor", Vector3.new(1, 96, 96), origin * CFrame.new(0, 0.5, 0), cream, Enum.Material.Fabric, folder)
	floor.Shape = Enum.PartType.Cylinder
	floor.CFrame = origin * CFrame.new(0, 0.5, 0) * CFrame.Angles(0, 0, math.rad(90))
	local rim = part("StrawRim", Vector3.new(0.6, 104, 104), origin * CFrame.new(0, 0.3, 0), strawDeep, Enum.Material.Grass, folder)
	rim.Shape = Enum.PartType.Cylinder
	rim.CFrame = origin * CFrame.new(0, 0.3, 0) * CFrame.Angles(0, 0, math.rad(90))

	-- Spawn pad facing +Z toward the portal frame.
	local pad = part("SpawnPad", Vector3.new(10, 0.4, 10), origin * CFrame.new(0, 1.2, -18), straw, Enum.Material.WoodPlanks, folder)
	pad:SetAttribute("SFE_Ambient", "dustMote")
	if spawnLocation then
		spawnLocation.CFrame = origin * CFrame.new(0, 2, -18)
		spawnLocation.Anchored = true
	end

	-- Chapter portal frame: two posts and a lintel, straight ahead of spawn.
	local postL = part("PortalPostL", Vector3.new(1.6, 12, 1.6), origin * CFrame.new(-6, 7, 22), strawDeep, Enum.Material.Wood, folder)
	local postR = part("PortalPostR", Vector3.new(1.6, 12, 1.6), origin * CFrame.new(6, 7, 22), strawDeep, Enum.Material.Wood, folder)
	local lintel = part("PortalLintel", Vector3.new(15, 1.6, 1.6), origin * CFrame.new(0, 13.5, 22), strawDeep, Enum.Material.Wood, folder)
	local diorama = part("PortalDiorama", Vector3.new(11, 10, 0.4), origin * CFrame.new(0, 7, 22.6), sky, Enum.Material.Neon, folder)
	diorama.CanCollide = false
	diorama.Transparency = 0.35
	diorama:SetAttribute("SFE_Ambient", "portalShimmer")
	label(lintel, "Sunlit Henhouse", Enum.NormalId.Front)
	postL:SetAttribute("SFE_Ambient", "clothSway")
	postR:SetAttribute("SFE_Ambient", "clothSway")

	-- Station pedestals on the primary sightlines (Daily left, Classes right, Perks far right).
	local function pedestal(name: string, cframe: CFrame, color: Color3, text: string, ambient: string)
		local base = part(name .. "Base", Vector3.new(6, 1, 6), cframe, strawDeep, Enum.Material.Wood, folder)
		local top = part(name .. "Emblem", Vector3.new(3, 3, 3), cframe * CFrame.new(0, 3, 0), color, Enum.Material.SmoothPlastic, folder)
		top.CanCollide = false
		top:SetAttribute("SFE_Ambient", ambient)
		label(base, text, Enum.NormalId.Top)
		return top
	end
	pedestal("Daily", origin * CFrame.new(-22, 1.5, 4), ember, "Daily Nest", "bob")
	pedestal("Classes", origin * CFrame.new(22, 1.5, 4), leaf, "Classes", "spin")
	pedestal("Perks", origin * CFrame.new(26, 1.5, -12), sky, "Perk Bench", "bob")

	-- Feather drift emitters: the client scheduler spawns pooled strands near these anchors.
	for index, offset in ipairs({ Vector3.new(-12, 10, 8), Vector3.new(12, 11, 8), Vector3.new(0, 12, -6) }) do
		local anchor =
			part("FeatherDrift" .. index, Vector3.new(1, 1, 1), origin * CFrame.new(offset), cream, Enum.Material.SmoothPlastic, folder)
		anchor.Transparency = 1
		anchor.CanCollide = false
		anchor:SetAttribute("SFE_Ambient", "featherDrift")
	end

	-- Clients wait for this count before scanning: a folder replicates before its children.
	folder:SetAttribute("SFE_ChildCount", #folder:GetChildren())
	folder.Parent = workspaceService
	return folder
end

function WorldShellService.instanceCount(folder: Instance): number
	return #folder:GetDescendants()
end

return WorldShellService
