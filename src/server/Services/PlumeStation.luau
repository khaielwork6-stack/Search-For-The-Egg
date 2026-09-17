--!strict
-- Professor Plume and his investigation station: a polished bench between the Farmer and the
-- mound with the Rainbow Feather prism analyzer, a magnifying glass, eggshell samples, notes, and
-- the parchment clue board behind it. Everything is built from parts at boot and anchored; the
-- client PlumeController owns the idle motion, the highlight, the board text and the analysis
-- sequence, so nothing here moves on its own and nothing here needs a script.
--
-- Plume's rig is a clone of the owner's Cow Boy (the same source as the Farmer), with the Toolbox
-- accessories, clothing and every script removed, recoloured tawny with a cream chest, and dressed
-- from parts: round brass glasses, an explorer's hat, a satchel. Motor6Ds are kept for the idle.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChapterLayout = require(ReplicatedStorage.Shared.Domain.ChapterLayout)

local PlumeStation = {}

PlumeStation.MODEL_NAME = "ProfessorPlume"
PlumeStation.STATION_NAME = "PlumeStation"
PlumeStation.PROMPT_NAME = "SFE_PlumeAnalyze"
PlumeStation.PLACEHOLDER_TAG = "SFE_ChapterShell"

local WALNUT = Color3.fromRGB(92, 58, 34)
local WALNUT_DEEP = Color3.fromRGB(64, 40, 24)
local BRASS = Color3.fromRGB(198, 152, 70)
local PARCHMENT = Color3.fromRGB(238, 222, 180)
local PARCHMENT_DEEP = Color3.fromRGB(214, 190, 140)
local INK = Color3.fromRGB(70, 46, 28)
local RED_THREAD = Color3.fromRGB(196, 52, 44)
local GLASS = Color3.fromRGB(214, 240, 248)
local PRISM = Color3.fromRGB(236, 208, 255)
local FEATHER_TAWNY = Color3.fromRGB(154, 106, 58)
local FEATHER_CREAM = Color3.fromRGB(240, 222, 184)
local BEAK = Color3.fromRGB(240, 160, 48)
local KHAKI = Color3.fromRGB(196, 176, 128)
local LEATHER = Color3.fromRGB(122, 78, 44)

local function part(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?,
	collide: boolean?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = collide == true
	p.CanQuery = collide == true
	p.CanTouch = false
	p.CastShadow = true
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p:SetAttribute("SFE_Placeholder", PlumeStation.PLACEHOLDER_TAG)
	p.Parent = parent
	return p
end

-- A cylinder standing on its end (Roblox cylinders lie along X).
local function upright(cframe: CFrame): CFrame
	return cframe * CFrame.Angles(0, 0, math.rad(90))
end

local function cylinder(
	parent: Instance,
	name: string,
	radius: number,
	length: number,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?
): Part
	local p = part(parent, name, Vector3.new(length, radius * 2, radius * 2), cframe, color, material)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function wedge(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material?): WedgePart
	local w = Instance.new("WedgePart")
	w.Name = name
	w.Anchored = true
	w.CanCollide = false
	w.CanQuery = false
	w.CanTouch = false
	w.Size = size
	w.CFrame = cframe
	w.Color = color
	w.Material = material or Enum.Material.SmoothPlastic
	w:SetAttribute("SFE_Placeholder", PlumeStation.PLACEHOLDER_TAG)
	w.Parent = parent
	return w
end

local function textLabel(
	parent: Instance,
	name: string,
	text: string,
	size: UDim2,
	position: UDim2,
	font: Enum.Font,
	px: number,
	color: Color3
): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Size = size
	label.Position = position
	label.Font = font
	label.TextSize = px
	label.TextColor3 = color
	label.Text = text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextWrapped = true
	label.Parent = parent
	return label
end

-- The bench: a polished walnut top with a brass edge, four legs and a lower shelf.
local function buildBench(station: Model, base: CFrame)
	local topY = 2.9
	local top =
		part(station, "BenchTop", Vector3.new(7.2, 0.32, 2.7), base * CFrame.new(0, topY, 0), WALNUT, Enum.Material.SmoothPlastic, true)
	top.Reflectance = 0.12
	part(station, "BenchTrim", Vector3.new(7.3, 0.08, 0.08), base * CFrame.new(0, topY + 0.16, -1.37), BRASS, Enum.Material.Metal)
	part(station, "BenchSkirt", Vector3.new(7.0, 0.5, 2.5), base * CFrame.new(0, topY - 0.4, 0), WALNUT_DEEP, Enum.Material.Wood)
	for _, corner in ipairs({ { -3.3, -1.05 }, { 3.3, -1.05 }, { -3.3, 1.05 }, { 3.3, 1.05 } }) do
		part(
			station,
			"BenchLeg",
			Vector3.new(0.36, topY - 0.16, 0.36),
			base * CFrame.new(corner[1], (topY - 0.16) / 2, corner[2]),
			WALNUT_DEEP,
			Enum.Material.Wood
		)
	end
	part(station, "BenchShelf", Vector3.new(6.6, 0.16, 2.2), base * CFrame.new(0, 0.9, 0), WALNUT, Enum.Material.Wood)
	-- A crate of samples under the shelf and a rolled map, so the underside is not bare.
	part(station, "SampleCrate", Vector3.new(1.6, 1.0, 1.2), base * CFrame.new(-2.1, 1.5, 0.2), LEATHER, Enum.Material.WoodPlanks)
	cylinder(
		station,
		"RolledMap",
		0.22,
		1.9,
		base * CFrame.new(1.4, 1.2, 0.3) * CFrame.Angles(0, math.rad(12), 0),
		PARCHMENT,
		Enum.Material.Fabric
	)
	-- The brass nameplate on the front edge.
	local plate =
		part(station, "Nameplate", Vector3.new(2.4, 0.5, 0.06), base * CFrame.new(0, topY - 0.45, -1.28), BRASS, Enum.Material.Metal)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Gui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 100
	gui.LightInfluence = 0.6
	gui.Parent = plate
	local text =
		textLabel(gui, "Text", "NEST FORENSICS", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), Enum.Font.FredokaOne, 30, WALNUT_DEEP)
	text.TextXAlignment = Enum.TextXAlignment.Center
	return topY + 0.16
end

-- The Rainbow Feather prism analyzer: a brass base, a glass chamber with a neon prism inside, a
-- refractor ring the client spins, and the light it throws while it works.
local function buildAnalyzer(station: Model, base: CFrame, tableTop: number)
	local origin = base * CFrame.new(1.9, tableTop, 0.1)
	cylinder(station, "AnalyzerBase", 0.95, 0.36, upright(origin * CFrame.new(0, 0.18, 0)), BRASS, Enum.Material.Metal)
	cylinder(station, "AnalyzerFoot", 1.1, 0.1, upright(origin * CFrame.new(0, 0.05, 0)), WALNUT_DEEP, Enum.Material.Metal)
	local chamber =
		part(station, "PrismChamber", Vector3.new(1.6, 1.7, 1.6), origin * CFrame.new(0, 0.36 + 0.85, 0), GLASS, Enum.Material.Glass)
	chamber.Transparency = 0.45
	chamber.Reflectance = 0.08
	local core = Instance.new("Attachment")
	core.Name = "PrismCore"
	core.Position = Vector3.new(0, 0, 0)
	core.Parent = chamber
	local light = Instance.new("PointLight")
	light.Name = "PrismLight"
	light.Color = PRISM
	light.Brightness = 0.35
	light.Range = 5
	light.Shadows = false
	light.Parent = chamber
	-- Two wedges back to back make the triangular prism.
	local prismCF = origin * CFrame.new(0, 0.36 + 0.7, 0)
	local left = wedge(
		station,
		"PrismHalfA",
		Vector3.new(0.5, 1.0, 0.55),
		prismCF * CFrame.new(-0.275, 0, 0) * CFrame.Angles(0, math.rad(180), 0),
		PRISM,
		Enum.Material.Neon
	)
	local right = wedge(station, "PrismHalfB", Vector3.new(0.5, 1.0, 0.55), prismCF * CFrame.new(0.275, 0, 0), PRISM, Enum.Material.Neon)
	left.Transparency = 0.25
	right.Transparency = 0.25
	local ring = cylinder(
		station,
		"Refractor",
		0.72,
		0.07,
		upright(origin * CFrame.new(0, 0.36 + 0.85, 0)),
		Color3.fromRGB(255, 232, 250),
		Enum.Material.Neon
	)
	ring.Transparency = 0.15
	-- A hollow look for the ring: a matching glass disc inside reads as an aperture.
	local aperture =
		cylinder(station, "RefractorAperture", 0.62, 0.09, upright(origin * CFrame.new(0, 0.36 + 0.85, 0)), GLASS, Enum.Material.Glass)
	aperture.Transparency = 0.75
	cylinder(station, "AnalyzerCap", 0.86, 0.14, upright(origin * CFrame.new(0, 0.36 + 1.7 + 0.07, 0)), BRASS, Enum.Material.Metal)
	cylinder(
		station,
		"AnalyzerDial",
		0.22,
		0.1,
		origin * CFrame.new(0, 0.2, -0.95) * CFrame.Angles(0, math.rad(90), 0),
		WALNUT_DEEP,
		Enum.Material.Metal
	)
	part(station, "DialNeedle", Vector3.new(0.05, 0.16, 0.04), origin * CFrame.new(0, 0.24, -1.0), RED_THREAD, Enum.Material.Neon)
	-- The feather intake: a small brass funnel on the side, where the feathers fly in.
	cylinder(station, "Intake", 0.3, 0.5, origin * CFrame.new(-1.05, 0.9, 0), BRASS, Enum.Material.Metal)
	local intake = Instance.new("Attachment")
	intake.Name = "Intake"
	intake.Parent = chamber
	intake.WorldPosition = (origin * CFrame.new(-1.3, 0.9, 0)).Position
end

local function buildMagnifier(station: Model, base: CFrame, tableTop: number)
	local origin = base * CFrame.new(-0.4, tableTop + 0.06, -0.55) * CFrame.Angles(0, math.rad(-28), 0)
	local rim = cylinder(station, "MagnifierRim", 0.62, 0.08, upright(origin), BRASS, Enum.Material.Metal)
	rim.CFrame = upright(origin)
	local lens = cylinder(station, "MagnifierLens", 0.55, 0.05, upright(origin * CFrame.new(0, 0.02, 0)), GLASS, Enum.Material.Glass)
	lens.Transparency = 0.5
	lens.Reflectance = 0.1
	cylinder(
		station,
		"MagnifierHandle",
		0.11,
		1.15,
		origin * CFrame.new(0, 0, 1.15) * CFrame.Angles(0, math.rad(90), 0),
		WALNUT_DEEP,
		Enum.Material.Wood
	)
	cylinder(
		station,
		"MagnifierCollar",
		0.14,
		0.18,
		origin * CFrame.new(0, 0, 0.66) * CFrame.Angles(0, math.rad(90), 0),
		BRASS,
		Enum.Material.Metal
	)
end

local function buildSamples(station: Model, base: CFrame, tableTop: number)
	local origin = base * CFrame.new(-2.55, tableTop, 0.45)
	local dish =
		cylinder(station, "SampleDish", 0.6, 0.12, upright(origin * CFrame.new(0, 0.06, 0)), FEATHER_CREAM, Enum.Material.SmoothPlastic)
	dish.Reflectance = 0.05
	for i, spec in ipairs({ { -0.2, 0.15, 22 }, { 0.18, -0.1, -35 }, { 0.05, 0.22, 70 }, { -0.12, -0.24, -100 } }) do
		local shell = wedge(
			station,
			"Eggshell" .. i,
			Vector3.new(0.34, 0.14, 0.3),
			origin * CFrame.new(spec[1], 0.19, spec[2]) * CFrame.Angles(math.rad(8), math.rad(spec[3]), math.rad(14)),
			Color3.fromRGB(252, 240, 205),
			Enum.Material.Sand
		)
		shell.Transparency = 0
	end
	-- A labelled jar of feather samples beside the dish.
	local jar = cylinder(station, "SampleJar", 0.28, 0.7, upright(origin * CFrame.new(0.95, 0.35, -0.1)), GLASS, Enum.Material.Glass)
	jar.Transparency = 0.5
	cylinder(station, "SampleJarLid", 0.3, 0.08, upright(origin * CFrame.new(0.95, 0.74, -0.1)), BRASS, Enum.Material.Metal)
	local feathers = part(
		station,
		"SampleJarFeathers",
		Vector3.new(0.3, 0.42, 0.3),
		origin * CFrame.new(0.95, 0.3, -0.1) * CFrame.Angles(0, math.rad(30), 0),
		Color3.fromRGB(224, 174, 236),
		Enum.Material.Fabric
	)
	feathers.Transparency = 0.1
end

local function buildNotes(station: Model, base: CFrame, tableTop: number)
	local origin = base * CFrame.new(-1.55, tableTop, -0.35)
	for i, spec in ipairs({ { 0, 0, -8 }, { 0.22, 0.12, 11 } }) do
		local sheet = part(
			station,
			"Note" .. i,
			Vector3.new(0.95, 0.03, 1.25),
			origin * CFrame.new(spec[1], 0.02 + (i - 1) * 0.03, spec[2]) * CFrame.Angles(0, math.rad(spec[3]), 0),
			if i == 1 then PARCHMENT_DEEP else PARCHMENT,
			Enum.Material.Fabric
		)
		sheet.CastShadow = false
	end
	-- Ink lines on the top sheet.
	for row = 1, 5 do
		local line = part(
			station,
			"NoteLine" .. row,
			Vector3.new(0.55 - (row % 2) * 0.12, 0.01, 0.04),
			origin * CFrame.new(0.2, 0.07, 0.12 + (row - 3) * 0.17) * CFrame.Angles(0, math.rad(11), 0),
			INK,
			Enum.Material.SmoothPlastic
		)
		line.CastShadow = false
	end
	-- Inkpot and quill.
	cylinder(station, "Inkpot", 0.17, 0.26, upright(origin * CFrame.new(0.95, 0.13, 0.45)), Color3.fromRGB(34, 28, 24), Enum.Material.Glass)
	local quill = cylinder(
		station,
		"Quill",
		0.035,
		0.9,
		origin * CFrame.new(0.95, 0.5, 0.35) * CFrame.Angles(0, 0, math.rad(62)) * CFrame.Angles(0, math.rad(90), 0),
		Color3.fromRGB(250, 246, 236),
		Enum.Material.SmoothPlastic
	)
	quill.Name = "Quill"
	local vane = wedge(
		station,
		"QuillVane",
		Vector3.new(0.05, 0.42, 0.16),
		origin * CFrame.new(1.13, 0.86, 0.32) * CFrame.Angles(math.rad(-20), 0, math.rad(-28)),
		Color3.fromRGB(250, 246, 236),
		Enum.Material.SmoothPlastic
	)
	vane.CastShadow = false
end

-- The parchment clue board on its easel behind the bench. The client writes the clue rows.
local function buildBoard(station: Model, base: CFrame)
	-- OWNER 17 Sep 2026: the easel stands at the bench's right end and Plume at its left, so his arms
	-- never cross the board and nothing covers the clues.
	local origin = base * CFrame.new(2.1, 0, 2.15)
	-- Easel: two legs and a crossbar, leaning back a touch.
	local lean = CFrame.Angles(math.rad(-8), 0, 0)
	for _, x in ipairs({ -2.2, 2.2 }) do
		part(station, "EaselLeg", Vector3.new(0.22, 7.2, 0.22), origin * CFrame.new(x, 3.6, 0) * lean, WALNUT_DEEP, Enum.Material.Wood)
	end
	part(station, "EaselBar", Vector3.new(4.9, 0.2, 0.2), origin * CFrame.new(0, 2.55, 0) * lean, WALNUT_DEEP, Enum.Material.Wood)
	part(
		station,
		"EaselBack",
		Vector3.new(0.22, 6.4, 0.22),
		origin * CFrame.new(0, 3.2, 1.1) * CFrame.Angles(math.rad(20), 0, 0),
		WALNUT_DEEP,
		Enum.Material.Wood
	)
	local board =
		part(station, "ClueBoard", Vector3.new(5.0, 3.7, 0.16), origin * CFrame.new(0, 4.6, -0.1) * lean, PARCHMENT, Enum.Material.Fabric)
	board.CastShadow = true
	local frame =
		part(station, "ClueBoardFrame", Vector3.new(5.3, 4.0, 0.12), origin * CFrame.new(0, 4.6, -0.02) * lean, WALNUT, Enum.Material.Wood)
	frame.CastShadow = false
	-- Pins, thread and a crossed-out corner; the board should read as worked on before any clue.
	local pinSpots = { { -1.9, 1.35 }, { 1.4, 1.5 }, { -1.5, -1.2 }, { 1.9, -0.9 } }
	for i, spot in ipairs(pinSpots) do
		local pin = part(
			station,
			"Pin" .. i,
			Vector3.new(0.18, 0.18, 0.18),
			origin * CFrame.new(spot[1], 4.6 + spot[2], -0.22) * lean,
			if i % 2 == 0 then RED_THREAD else Color3.fromRGB(58, 120, 200),
			Enum.Material.SmoothPlastic
		)
		pin.Shape = Enum.PartType.Ball
	end
	local function thread(a: { number }, b: { number }, name: string)
		local pa = (origin * CFrame.new(a[1], 4.6 + a[2], -0.2) * lean).Position
		local pb = (origin * CFrame.new(b[1], 4.6 + b[2], -0.2) * lean).Position
		local mid = (pa + pb) / 2
		local length = (pb - pa).Magnitude
		local t = part(station, name, Vector3.new(0.03, 0.03, length), CFrame.lookAt(mid, pb), RED_THREAD, Enum.Material.SmoothPlastic)
		t.CastShadow = false
	end
	thread(pinSpots[1], pinSpots[2], "Thread1")
	thread(pinSpots[2], pinSpots[4], "Thread2")
	thread(pinSpots[1], pinSpots[3], "Thread3")
	for i, angle in ipairs({ 45, -45 }) do
		local cross = part(
			station,
			"CrossOut" .. i,
			Vector3.new(0.7, 0.05, 0.02),
			origin * CFrame.new(1.65, 4.6 + 0.55, -0.2) * lean * CFrame.Angles(0, 0, math.rad(angle)),
			RED_THREAD,
			Enum.Material.SmoothPlastic
		)
		cross.CastShadow = false
	end
	-- The written face of the board.
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Gui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 80
	gui.LightInfluence = 0.7
	gui.Parent = board
	textLabel(gui, "Title", "NEST CLUES", UDim2.new(0.6, 0, 0, 56), UDim2.fromScale(0.04, 0.03), Enum.Font.FredokaOne, 44, INK)
	local sketch = Instance.new("Frame")
	sketch.Name = "MoundSketch"
	sketch.AnchorPoint = Vector2.new(1, 0)
	sketch.Position = UDim2.fromScale(0.97, 0.06)
	sketch.Size = UDim2.fromOffset(120, 78)
	sketch.BackgroundColor3 = PARCHMENT_DEEP
	sketch.BackgroundTransparency = 0.35
	local sketchCorner = Instance.new("UICorner")
	sketchCorner.CornerRadius = UDim.new(1, 0)
	sketchCorner.Parent = sketch
	local sketchStroke = Instance.new("UIStroke")
	sketchStroke.Color = INK
	sketchStroke.Thickness = 3
	sketchStroke.Transparency = 0.2
	sketchStroke.Parent = sketch
	sketch.Parent = gui
	local barnTag =
		textLabel(gui, "SketchBarn", "barn", UDim2.fromOffset(70, 22), UDim2.new(0.97, -190, 0.06, 26), Enum.Font.GothamMedium, 18, INK)
	barnTag.TextXAlignment = Enum.TextXAlignment.Right
	textLabel(gui, "SketchFence", "fence", UDim2.fromOffset(70, 22), UDim2.new(0.97, 4, 0.06, 26), Enum.Font.GothamMedium, 18, INK)
	local rows = { { "Direction", "DIRECTION" }, { "Depth", "DEPTH" } }
	for i, row in ipairs(rows) do
		local y = 0.36 + (i - 1) * 0.27
		local rowFrame = Instance.new("Frame")
		rowFrame.Name = row[1]
		rowFrame.BackgroundColor3 = PARCHMENT_DEEP
		rowFrame.BackgroundTransparency = 0.55
		rowFrame.Position = UDim2.fromScale(0.04, y)
		rowFrame.Size = UDim2.fromScale(0.92, 0.22)
		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 10)
		rowCorner.Parent = rowFrame
		rowFrame.Parent = gui
		textLabel(rowFrame, "Label", row[2], UDim2.fromScale(0.42, 1), UDim2.fromScale(0.03, 0), Enum.Font.FredokaOne, 30, INK)
		local value = textLabel(
			rowFrame,
			"Value",
			"UNKNOWN",
			UDim2.fromScale(0.54, 1),
			UDim2.fromScale(0.44, 0),
			Enum.Font.FredokaOne,
			30,
			Color3.fromRGB(150, 130, 100)
		)
		value.TextXAlignment = Enum.TextXAlignment.Right
		local stamp = textLabel(
			rowFrame,
			"Stamp",
			"ANALYZED",
			UDim2.fromScale(0.3, 0.5),
			UDim2.fromScale(0.66, 0.5),
			Enum.Font.FredokaOne,
			16,
			RED_THREAD
		)
		stamp.TextXAlignment = Enum.TextXAlignment.Right
		stamp.Visible = false
	end
	return board
end

-- Glasses, hat and satchel are parts welded to the rig, so they ride the head and torso when the
-- client animates the joints.
local function dress(rig: Model)
	local head = rig:FindFirstChild("Head") :: BasePart?
	local upper = rig:FindFirstChild("UpperTorso") :: BasePart?
	local lower = rig:FindFirstChild("LowerTorso") :: BasePart?
	if not (head and upper and lower) then
		return
	end
	local function weld(p: BasePart, to: BasePart)
		local w = Instance.new("WeldConstraint")
		w.Part0 = to
		w.Part1 = p
		w.Parent = p
	end
	-- Clipboard in the left hand: a walnut board, a parchment sheet and a brass clip, welded to the
	-- hand so the idle carries it to his chest.
	local leftHand = rig:FindFirstChild("LeftHand") :: BasePart?
	if leftHand then
		local grip = leftHand.CFrame * CFrame.new(0.12, -0.25, -0.62) * CFrame.Angles(math.rad(-12), math.rad(90), 0)
		local board = part(rig, "Clipboard", Vector3.new(1.05, 1.35, 0.08), grip, WALNUT, Enum.Material.Wood)
		board.CanCollide = false
		board.CanQuery = false
		weld(board, leftHand)
		local sheet =
			part(rig, "ClipboardSheet", Vector3.new(0.9, 1.15, 0.03), grip * CFrame.new(0, -0.04, -0.05), PARCHMENT, Enum.Material.Fabric)
		sheet.CanCollide = false
		sheet.CanQuery = false
		weld(sheet, leftHand)
		local clip = part(rig, "ClipboardClip", Vector3.new(0.5, 0.16, 0.12), grip * CFrame.new(0, 0.6, -0.06), BRASS, Enum.Material.Metal)
		clip.CanCollide = false
		clip.CanQuery = false
		weld(clip, leftHand)
	end
	local hs = head.Size
	local front = head.CFrame * CFrame.new(0, 0.05, -hs.Z / 2)
	-- Round brass glasses.
	for _, x in ipairs({ -0.48, 0.48 }) do
		local rim = cylinder(
			rig,
			"GlassesRim",
			0.44,
			0.08,
			front * CFrame.new(x, 0.02, -0.08) * CFrame.Angles(0, math.rad(90), 0),
			BRASS,
			Enum.Material.Metal
		)
		weld(rim, head)
		local lens = cylinder(
			rig,
			"GlassesLens",
			0.4,
			0.04,
			front * CFrame.new(x, 0.02, -0.08) * CFrame.Angles(0, math.rad(90), 0),
			GLASS,
			Enum.Material.Glass
		)
		lens.Transparency = 0.55
		lens.Reflectance = 0.12
		weld(lens, head)
	end
	local bridge = part(rig, "GlassesBridge", Vector3.new(0.18, 0.06, 0.06), front * CFrame.new(0, 0.06, -0.08), BRASS, Enum.Material.Metal)
	weld(bridge, head)
	for _, x in ipairs({ -0.9, 0.9 }) do
		local arm = part(
			rig,
			"GlassesArm",
			Vector3.new(0.05, 0.05, hs.Z * 0.55),
			head.CFrame * CFrame.new(x, 0.07, -hs.Z * 0.2),
			BRASS,
			Enum.Material.Metal
		)
		weld(arm, head)
	end
	-- Beak below the glasses.
	local beak = wedge(
		rig,
		"Beak",
		Vector3.new(0.42, 0.26, 0.5),
		front * CFrame.new(0, -0.32, -0.16) * CFrame.Angles(math.rad(90), 0, 0),
		BEAK,
		Enum.Material.SmoothPlastic
	)
	weld(beak, head)
	-- Explorer's hat: crown, band and a wide brim, with two feather tufts poking out under it.
	local top = head.CFrame * CFrame.new(0, hs.Y / 2, 0)
	local brim = cylinder(rig, "HatBrim", hs.X * 0.62, 0.1, upright(top * CFrame.new(0, 0.02, 0.05)), KHAKI, Enum.Material.Fabric)
	weld(brim, head)
	local crown = cylinder(rig, "HatCrown", hs.X * 0.4, 0.95, upright(top * CFrame.new(0, 0.52, 0.05)), KHAKI, Enum.Material.Fabric)
	weld(crown, head)
	local band = cylinder(rig, "HatBand", hs.X * 0.41, 0.22, upright(top * CFrame.new(0, 0.2, 0.05)), LEATHER, Enum.Material.Leather)
	weld(band, head)
	for _, spec in ipairs({ { -0.7, 28 }, { 0.75, -22 } }) do
		local tuft = wedge(
			rig,
			"Tuft",
			Vector3.new(0.08, 0.5, 0.22),
			top * CFrame.new(spec[1], 0.25, -0.2) * CFrame.Angles(math.rad(-30), 0, math.rad(spec[2])),
			FEATHER_TAWNY,
			Enum.Material.Fabric
		)
		weld(tuft, head)
	end
	-- Satchel on the left hip with a strap across the chest.
	local satchel = part(
		rig,
		"Satchel",
		Vector3.new(1.15, 0.95, 0.42),
		lower.CFrame * CFrame.new(-lower.Size.X / 2 - 0.1, -0.15, 0.1) * CFrame.Angles(0, 0, math.rad(6)),
		LEATHER,
		Enum.Material.Leather
	)
	weld(satchel, lower)
	local flap = part(
		rig,
		"SatchelFlap",
		Vector3.new(1.17, 0.42, 0.46),
		lower.CFrame * CFrame.new(-lower.Size.X / 2 - 0.1, 0.12, 0.1) * CFrame.Angles(0, 0, math.rad(6)),
		WALNUT_DEEP,
		Enum.Material.Leather
	)
	weld(flap, lower)
	local buckle = part(
		rig,
		"SatchelBuckle",
		Vector3.new(0.22, 0.22, 0.06),
		lower.CFrame * CFrame.new(-lower.Size.X / 2 - 0.1, 0.0, -0.15) * CFrame.Angles(0, 0, math.rad(6)),
		BRASS,
		Enum.Material.Metal
	)
	weld(buckle, lower)
	local strap = part(
		rig,
		"SatchelStrap",
		Vector3.new(0.3, upper.Size.Y * 1.25, 0.12),
		upper.CFrame * CFrame.new(0.1, 0.05, -upper.Size.Z / 2 - 0.02) * CFrame.Angles(0, 0, math.rad(-34)),
		LEATHER,
		Enum.Material.Leather
	)
	weld(strap, upper)
	-- A pocket magnifier hangs from the strap.
	local lensSmall = cylinder(
		rig,
		"PocketLens",
		0.16,
		0.05,
		upper.CFrame * CFrame.new(0.55, -0.6, -upper.Size.Z / 2 - 0.12) * CFrame.Angles(0, math.rad(90), 0),
		BRASS,
		Enum.Material.Metal
	)
	weld(lensSmall, upper)
end

local function recolour(rig: Model)
	for _, child in ipairs(rig:GetChildren()) do
		if child:IsA("BasePart") and child.Name ~= "HumanoidRootPart" then
			local isLeg = string.find(child.Name, "LowerLeg") or string.find(child.Name, "Foot")
			local isCream = string.find(child.Name, "Hand") or child.Name == "UpperTorso"
			if isLeg then
				child.Color = BEAK
				child.Material = Enum.Material.SmoothPlastic
			else
				child.Color = if isCream then FEATHER_CREAM else FEATHER_TAWNY
				child.Material = Enum.Material.Fabric
			end
		end
	end
	-- A cream bib over the chest so the vest reads even from the front.
	local upper = rig:FindFirstChild("UpperTorso") :: BasePart?
	if upper then
		local bib = part(
			rig,
			"ChestBib",
			Vector3.new(upper.Size.X * 0.62, upper.Size.Y * 0.9, 0.12),
			upper.CFrame * CFrame.new(0, -0.1, -upper.Size.Z / 2 - 0.04),
			FEATHER_CREAM,
			Enum.Material.Fabric
		)
		local w = Instance.new("WeldConstraint")
		w.Part0 = upper
		w.Part1 = bib
		w.Parent = bib
	end
end

-- Builds Plume's rig from the owner's Cow Boy: no scripts, no Toolbox accessories, no clothing.
function PlumeStation.spawnPlume(workspaceService: Workspace, folder: Instance, cframe: CFrame): Model?
	local source = workspaceService:FindFirstChild("Cow Boy")
	if not (source and source:IsA("Model")) then
		return nil
	end
	local rig = source:Clone()
	rig.Name = PlumeStation.MODEL_NAME
	for _, descendant in ipairs(rig:GetDescendants()) do
		if descendant:IsA("BaseScript") or descendant:IsA("Accessory") or descendant:IsA("Clothing") or descendant:IsA("Humanoid") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
	local _, size = rig:GetBoundingBox()
	rig:PivotTo(cframe * CFrame.new(0, size.Y / 2, 0))
	-- The pivot is the root, not the box's centre: measure the lowest sole and stand him on the sand.
	local lowest = math.huge
	for _, descendant in ipairs(rig:GetDescendants()) do
		if descendant:IsA("BasePart") then
			lowest = math.min(lowest, descendant.Position.Y - descendant.Size.Y / 2)
		end
	end
	if lowest ~= math.huge then
		rig:PivotTo(rig:GetPivot() * CFrame.new(0, cframe.Position.Y - lowest, 0))
	end
	recolour(rig)
	dress(rig)
	rig:SetAttribute("SFE_Placeholder", PlumeStation.PLACEHOLDER_TAG)
	rig.Parent = folder
	return rig
end

-- Builds the whole station into the arena folder. Idempotent per folder.
function PlumeStation.build(workspaceService: Workspace, folder: Instance, layout: any, config: { [string]: any }): Model?
	if not layout.clueStation then
		return nil
	end
	local existing = folder:FindFirstChild(PlumeStation.STATION_NAME)
	if existing then
		existing:Destroy()
	end
	local station = Instance.new("Model")
	station.Name = PlumeStation.STATION_NAME
	local base =
		CFrame.lookAt(layout.clueStation, Vector3.new(layout.clueStationFacing.X, layout.clueStation.Y, layout.clueStationFacing.Z))
	local tableTop = buildBench(station, base)
	buildAnalyzer(station, base, tableTop)
	buildMagnifier(station, base, tableTop)
	buildSamples(station, base, tableTop)
	buildNotes(station, base, tableTop)
	buildBoard(station, base)
	-- The prompt anchor: an invisible block over the bench, so the prompt reads over the station.
	local anchor = part(
		station,
		"PlumeAnchor",
		Vector3.new(8.5, 5.5, 4.5),
		base * CFrame.new(-0.4, 2.8, 0.6),
		Color3.new(1, 1, 1),
		Enum.Material.SmoothPlastic
	)
	anchor.Transparency = 1
	anchor.CanQuery = false -- the prompt needs no raycast target; aim and camera rays pass through
	anchor:SetAttribute("SFE_Ambient", "plume")
	anchor:SetAttribute("SFE_NpcModel", PlumeStation.MODEL_NAME)
	anchor:SetAttribute("SFE_NpcName", "Professor Plume")
	anchor:SetAttribute("SFE_NpcRole", "Nest forensics")
	local p = Instance.new("ProximityPrompt")
	p.Name = PlumeStation.PROMPT_NAME
	p.ActionText = "ANALYZE CLUES"
	p.ObjectText = "Professor Plume"
	p.HoldDuration = 0
	p.MaxActivationDistance = config.clues.stationRangeStuds
	p.RequiresLineOfSight = false
	p.Style = Enum.ProximityPromptStyle.Custom
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.GamepadKeyCode = Enum.KeyCode.ButtonX
	p.Parent = anchor
	station.PrimaryPart = anchor
	station:SetAttribute("SFE_Placeholder", PlumeStation.PLACEHOLDER_TAG)
	station.Parent = folder
	-- Plume stands behind the bench's left end, clear of the easel, facing the same way as the station.
	local rig = PlumeStation.spawnPlume(workspaceService, folder, base * CFrame.new(-3.6, 0, 1.9))
	if rig then
		local root = rig:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			anchor:SetAttribute("SFE_PlumeRootY", root.Position.Y)
		end
	end
	return station
end

-- Used by the greybox path and tests: where the layout puts the station.
function PlumeStation.stationCFrame(chapter: string): CFrame?
	local layout = ChapterLayout[chapter]
	if not (layout and layout.clueStation) then
		return nil
	end
	return CFrame.lookAt(layout.clueStation, Vector3.new(layout.clueStationFacing.X, layout.clueStation.Y, layout.clueStationFacing.Z))
end

return PlumeStation
