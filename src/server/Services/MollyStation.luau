--!strict
-- Molly the Mole and her surveying station: a heavy field bench east of the mound carrying the
-- miniature Nest Map (nine tiles fixed to the yard's compass), the drill gantry over it, the brass
-- survey machine with its hopper, gauge, lamps, gears, crank and lever, the seismograph, the
-- survey-crate platform and the result board. Built from parts at boot and anchored; the client
-- MollyController owns every motion (idle, selection, drill, gears, needle, lamps, stamps) and the
-- board's writing, so nothing here needs a script and nothing moves on its own.
--
-- Molly is a scaled clone of the owner's Cow Boy rig (scripts, Toolbox accessories, clothing and
-- the Humanoid removed) recoloured as a mole and dressed from parts: helmet with a working lamp,
-- goggles, vest and tool belt, dirt, rolled maps.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChapterLayout = require(ReplicatedStorage.Shared.Domain.ChapterLayout)
local NestSurvey = require(ReplicatedStorage.Shared.Domain.NestSurvey)

local MollyStation = {}

MollyStation.MODEL_NAME = "MollyTheMole"
MollyStation.STATION_NAME = "SurveyStation"
MollyStation.PROMPT_NAME = "SFE_MollySurvey"
MollyStation.PLACEHOLDER_TAG = "SFE_ChapterShell"
MollyStation.RIG_SCALE = 0.62
MollyStation.TILE_PITCH = 1.34 -- tile size plus gap
MollyStation.TILE_SIZE = 1.22

local IRON = Color3.fromRGB(70, 72, 78)
local IRON_DARK = Color3.fromRGB(44, 46, 50)
local BRASS = Color3.fromRGB(198, 152, 70)
local BRASS_DARK = Color3.fromRGB(140, 104, 44)
local OAK = Color3.fromRGB(150, 112, 66)
local OAK_DEEP = Color3.fromRGB(104, 74, 42)
local STRAW = Color3.fromRGB(226, 196, 132)
local STRAW_DEEP = Color3.fromRGB(196, 164, 100)
local PAPER = Color3.fromRGB(244, 238, 222)
local INK = Color3.fromRGB(60, 44, 32)
local RED = Color3.fromRGB(196, 52, 44)
local LAMP_NONE = Color3.fromRGB(120, 150, 190)
local LAMP_WEAK = Color3.fromRGB(240, 170, 60)
local LAMP_STRONG = Color3.fromRGB(255, 208, 90)
local FUR = Color3.fromRGB(64, 50, 44)
local FUR_LIGHT = Color3.fromRGB(96, 78, 66)
local NOSE = Color3.fromRGB(226, 130, 140)
local HELMET = Color3.fromRGB(240, 196, 56)
local VEST = Color3.fromRGB(196, 150, 84)
local LEATHER = Color3.fromRGB(110, 72, 40)
local DIRT = Color3.fromRGB(84, 62, 40)

local function tag(instance: Instance)
	instance:SetAttribute("SFE_Placeholder", MollyStation.PLACEHOLDER_TAG)
end

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
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	tag(p)
	p.Parent = parent
	return p
end

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

local function ball(parent: Instance, name: string, radius: number, cframe: CFrame, color: Color3, material: Enum.Material?): Part
	local p = part(parent, name, Vector3.new(radius * 2, radius * 2, radius * 2), cframe, color, material)
	p.Shape = Enum.PartType.Ball
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
	tag(w)
	w.Parent = parent
	return w
end

local function label(
	parent: Instance,
	name: string,
	text: string,
	size: UDim2,
	position: UDim2,
	font: Enum.Font,
	px: number,
	color: Color3,
	align: Enum.TextXAlignment?
): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = position
	l.Font = font
	l.TextSize = px
	l.TextColor3 = color
	l.Text = text
	l.TextXAlignment = align or Enum.TextXAlignment.Center
	l.TextWrapped = true
	l.Parent = parent
	return l
end

local function surface(parentPart: BasePart, face: Enum.NormalId, pixelsPerStud: number): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Gui"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud
	gui.LightInfluence = 0.7
	gui.Parent = parentPart
	return gui
end

-- The bench: riveted iron frame, oak planks, a lower shelf with field gear.
local function buildBench(station: Model, base: CFrame): number
	local topY = 2.75
	for i = -3, 3 do
		local plank = part(
			station,
			"BenchPlank",
			Vector3.new(1.1, 0.3, 4.2),
			base * CFrame.new(i * 1.14, topY, 0),
			if i % 2 == 0 then OAK else OAK_DEEP,
			Enum.Material.WoodPlanks,
			true
		)
		plank.CanQuery = false
	end
	part(station, "BenchRailFront", Vector3.new(8.2, 0.16, 0.16), base * CFrame.new(0, topY + 0.2, -2.15), IRON, Enum.Material.Metal)
	part(station, "BenchRailBack", Vector3.new(8.2, 0.16, 0.16), base * CFrame.new(0, topY + 0.2, 2.15), IRON, Enum.Material.Metal)
	for _, corner in ipairs({ { -3.8, -1.85 }, { 3.8, -1.85 }, { -3.8, 1.85 }, { 3.8, 1.85 } }) do
		part(
			station,
			"BenchLeg",
			Vector3.new(0.34, topY - 0.15, 0.34),
			base * CFrame.new(corner[1], (topY - 0.15) / 2, corner[2]),
			IRON_DARK,
			Enum.Material.Metal
		)
		for _, y in ipairs({ 0.6, topY - 0.5 }) do
			ball(
				station,
				"Rivet",
				0.07,
				base * CFrame.new(corner[1], y, corner[2] - 0.18 * math.sign(corner[2])),
				BRASS,
				Enum.Material.Metal
			)
		end
	end
	part(station, "BenchBraceX", Vector3.new(7.6, 0.14, 0.14), base * CFrame.new(0, 0.7, -1.85), IRON_DARK, Enum.Material.Metal)
	part(station, "BenchBraceX2", Vector3.new(7.6, 0.14, 0.14), base * CFrame.new(0, 0.7, 1.85), IRON_DARK, Enum.Material.Metal)
	part(station, "BenchShelf", Vector3.new(7.2, 0.14, 3.4), base * CFrame.new(0, 0.85, 0), OAK_DEEP, Enum.Material.WoodPlanks)
	-- Field gear on the shelf: a tin lantern, rolled maps, a sample tray.
	cylinder(
		station,
		"MapRoll1",
		0.2,
		2.6,
		base * CFrame.new(-1.6, 1.13, 0.4) * CFrame.Angles(0, math.rad(8), 0),
		PAPER,
		Enum.Material.Fabric
	)
	cylinder(
		station,
		"MapRoll2",
		0.2,
		2.4,
		base * CFrame.new(-1.5, 1.5, 0.55) * CFrame.Angles(0, math.rad(-4), 0),
		STRAW_DEEP,
		Enum.Material.Fabric
	)
	part(station, "SampleTray", Vector3.new(1.6, 0.16, 1.1), base * CFrame.new(2.0, 1.0, 0.2), IRON, Enum.Material.Metal)
	for i = 1, 4 do
		ball(
			station,
			"SampleClod",
			0.16 + (i % 2) * 0.05,
			base * CFrame.new(1.6 + i * 0.22, 1.2, 0.1 + (i % 2) * 0.3),
			DIRT,
			Enum.Material.Slate
		)
	end
	return topY + 0.15
end

-- The miniature Nest Map: a round plinth and nine tiles laid in WORLD axes, so BARN is always the
-- yard's west and BACK its north whatever way the bench faces. Tiles are query-able for hovering.
local function buildMap(station: Model, base: CFrame, tableTop: number): (Vector3, { [string]: Part })
	local centre = (base * CFrame.new(-1.9, tableTop, -0.1)).Position
	local plinth =
		cylinder(station, "MapPlinth", 2.45, 0.24, upright(CFrame.new(centre + Vector3.new(0, 0.12, 0))), IRON_DARK, Enum.Material.Metal)
	plinth.CanQuery = false
	cylinder(station, "MapRing", 2.5, 0.08, upright(CFrame.new(centre + Vector3.new(0, 0.26, 0))), BRASS, Enum.Material.Metal)
	cylinder(
		station,
		"MapSand",
		2.2,
		0.06,
		upright(CFrame.new(centre + Vector3.new(0, 0.3, 0))),
		Color3.fromRGB(214, 196, 158),
		Enum.Material.Sand
	)
	local tiles: { [string]: Part } = {}
	local pitch = MollyStation.TILE_PITCH
	for _, region in ipairs(NestSurvey.REGIONS) do
		local row, col = NestSurvey.rowCol(region)
		-- col 1 = west (-X), row 1 (A) = north (-Z).
		local dx, dz = (col - 2) * pitch, (row - 2) * pitch
		local ring = math.max(math.abs(col - 2), math.abs(row - 2))
		local height = if ring == 0 then 0.62 elseif math.abs(col - 2) + math.abs(row - 2) == 1 then 0.46 else 0.34
		local tile = part(
			station,
			"Tile_" .. region,
			Vector3.new(MollyStation.TILE_SIZE, height, MollyStation.TILE_SIZE),
			CFrame.new(centre + Vector3.new(dx, 0.33 + height / 2, dz)),
			if ring == 0 then STRAW else (if ring == 1 and math.abs(col - 2) + math.abs(row - 2) == 1 then STRAW else STRAW_DEEP),
			Enum.Material.Sand
		)
		tile.CanQuery = true
		tile:SetAttribute("SFE_Region", region)
		tile:SetAttribute("SFE_RestY", tile.Position.Y)
		local gui = surface(tile, Enum.NormalId.Top, 60)
		label(gui, "Id", region, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), Enum.Font.FredokaOne, 30, INK)
		-- A few straw tufts so each tile reads as a piece of the mound.
		for t = 1, 3 do
			local a = (t / 3) * math.pi * 2 + (row * 3 + col)
			local tuft = wedge(
				station,
				"Tuft",
				Vector3.new(0.06, 0.26, 0.18),
				CFrame.new(centre + Vector3.new(dx + math.cos(a) * 0.38, 0.33 + height + 0.1, dz + math.sin(a) * 0.38))
					* CFrame.Angles(0, a, math.rad(18)),
				STRAW_DEEP,
				Enum.Material.Sand
			)
			tuft.CanQuery = false
			tuft:SetAttribute("SFE_TuftOf", region)
		end
		tiles[region] = tile
	end
	-- Landmark plates on the plinth's rim, in world directions.
	local plates = {
		{ NestSurvey.LANDMARKS.left, Vector3.new(-2.35, 0.34, 0), 90 },
		{ NestSurvey.LANDMARKS.right, Vector3.new(2.35, 0.34, 0), -90 },
		{ NestSurvey.LANDMARKS.top, Vector3.new(0, 0.34, -2.35), 180 },
		{ NestSurvey.LANDMARKS.bottom, Vector3.new(0, 0.34, 2.35), 0 },
	}
	for _, spec in ipairs(plates) do
		local plate = part(
			station,
			"Landmark_" .. spec[1],
			Vector3.new(1.2, 0.05, 0.36),
			CFrame.new(centre + spec[2]) * CFrame.Angles(0, math.rad(spec[3]), 0),
			BRASS,
			Enum.Material.Metal
		)
		local gui = surface(plate, Enum.NormalId.Top, 100)
		label(gui, "Text", spec[1], UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), Enum.Font.FredokaOne, 24, IRON_DARK)
	end
	-- Brass compass at the north-west corner, needle to north.
	local compassAt = centre + Vector3.new(-1.95, 0.36, -1.95)
	cylinder(station, "CompassDisc", 0.42, 0.06, upright(CFrame.new(compassAt)), BRASS, Enum.Material.Metal)
	cylinder(
		station,
		"CompassFace",
		0.34,
		0.04,
		upright(CFrame.new(compassAt + Vector3.new(0, 0.04, 0))),
		PAPER,
		Enum.Material.SmoothPlastic
	)
	wedge(
		station,
		"CompassNeedleN",
		Vector3.new(0.08, 0.03, 0.3),
		CFrame.new(compassAt + Vector3.new(0, 0.08, -0.15)) * CFrame.Angles(math.rad(90), 0, 0),
		RED,
		Enum.Material.SmoothPlastic
	)
	wedge(
		station,
		"CompassNeedleS",
		Vector3.new(0.08, 0.03, 0.3),
		CFrame.new(compassAt + Vector3.new(0, 0.08, 0.15)) * CFrame.Angles(math.rad(-90), 0, 0),
		IRON_DARK,
		Enum.Material.SmoothPlastic
	)
	local nPlate = part(
		station,
		"CompassN",
		Vector3.new(0.22, 0.02, 0.22),
		CFrame.new(compassAt + Vector3.new(0, 0.1, -0.42)),
		BRASS,
		Enum.Material.Metal
	)
	local nGui = surface(nPlate, Enum.NormalId.Top, 120)
	label(nGui, "N", "N", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), Enum.Font.FredokaOne, 22, IRON_DARK)
	return centre, tiles
end

-- The drill gantry: rails either side of the map (world X), a bridge that rides them (world Z),
-- a carriage on the bridge (world X) and the drill head under it. The client moves bridge and head.
local function buildGantry(station: Model, centre: Vector3)
	local railH = 3.8 -- rail height over the map centre
	local span = MollyStation.TILE_PITCH * 3 + 0.6
	for _, x in ipairs({ -span / 2, span / 2 }) do
		part(station, "GantryRail", Vector3.new(0.16, 0.16, span), CFrame.new(centre + Vector3.new(x, railH, 0)), IRON, Enum.Material.Metal)
		for _, z in ipairs({ -span / 2, span / 2 }) do
			part(
				station,
				"GantryPost",
				Vector3.new(0.16, railH + 0.1, 0.16),
				CFrame.new(centre + Vector3.new(x, railH / 2, z)),
				IRON_DARK,
				Enum.Material.Metal
			)
		end
	end
	local bridge = part(
		station,
		"DrillBridge",
		Vector3.new(span + 0.3, 0.2, 0.28),
		CFrame.new(centre + Vector3.new(0, railH + 0.18, 0)),
		BRASS_DARK,
		Enum.Material.Metal
	)
	bridge:SetAttribute("SFE_RestY", bridge.Position.Y)
	local head = Instance.new("Model")
	head.Name = "DrillHead"
	local carriage = part(
		head,
		"DrillCarriage",
		Vector3.new(0.6, 0.5, 0.6),
		CFrame.new(centre + Vector3.new(0, railH + 0.18, 0)),
		IRON,
		Enum.Material.Metal
	)
	part(head, "DrillMotor", Vector3.new(0.44, 0.7, 0.44), CFrame.new(centre + Vector3.new(0, railH - 0.42, 0)), BRASS, Enum.Material.Metal)
	cylinder(
		head,
		"DrillShaft",
		0.08,
		1.6,
		CFrame.new(centre + Vector3.new(0, railH - 1.55, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		IRON,
		Enum.Material.Metal
	)
	local bit = wedge(
		head,
		"DrillBit",
		Vector3.new(0.18, 0.4, 0.18),
		CFrame.new(centre + Vector3.new(0, railH - 2.5, 0)) * CFrame.Angles(math.rad(180), 0, 0),
		IRON_DARK,
		Enum.Material.Metal
	)
	bit.Name = "DrillBit"
	for i = 1, 4 do
		cylinder(
			head,
			"DrillFlute",
			0.11,
			0.14,
			CFrame.new(centre + Vector3.new(0, railH - 0.9 - i * 0.28, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			IRON_DARK,
			Enum.Material.Metal
		)
	end
	head.PrimaryPart = carriage
	head:SetAttribute("SFE_RestY", carriage.Position.Y)
	tag(head)
	head.Parent = station
end

-- The survey machine: the brass housing with its hopper, gauge, lamps, gears, crank, lever, steam.
local function buildMachine(station: Model, base: CFrame, tableTop: number)
	local origin = base * CFrame.new(2.35, tableTop, 0.2)
	local housing =
		part(station, "MachineHousing", Vector3.new(2.5, 2.1, 1.9), origin * CFrame.new(0, 1.05, 0), BRASS_DARK, Enum.Material.Metal)
	housing.CanQuery = false
	part(station, "MachineTrim", Vector3.new(2.6, 0.12, 2.0), origin * CFrame.new(0, 2.1, 0), BRASS, Enum.Material.Metal)
	part(station, "MachineBase", Vector3.new(2.7, 0.14, 2.1), origin * CFrame.new(0, 0.07, 0), IRON_DARK, Enum.Material.Metal)
	for _, corner in ipairs({ { -1.2, -0.9 }, { 1.2, -0.9 }, { -1.2, 0.9 }, { 1.2, 0.9 } }) do
		ball(station, "Rivet", 0.07, origin * CFrame.new(corner[1], 1.9, corner[2]), BRASS, Enum.Material.Metal)
		ball(station, "Rivet", 0.07, origin * CFrame.new(corner[1], 0.3, corner[2]), BRASS, Enum.Material.Metal)
	end
	-- Hopper on top: a brass funnel; feathers fly to HopperMouth.
	cylinder(station, "HopperMouth", 0.75, 0.12, upright(origin * CFrame.new(-0.55, 2.95, 0)), BRASS, Enum.Material.Metal)
	local funnel =
		part(station, "HopperFunnel", Vector3.new(1.1, 0.8, 1.1), origin * CFrame.new(-0.55, 2.5, 0), BRASS_DARK, Enum.Material.Metal)
	local mouth = Instance.new("Attachment")
	mouth.Name = "Mouth"
	mouth.Position = Vector3.new(0, 0.5, 0)
	mouth.Parent = funnel
	cylinder(station, "HopperNeck", 0.3, 0.4, upright(origin * CFrame.new(-0.55, 2.2, 0)), BRASS, Enum.Material.Metal)
	-- Pressure gauge on the front (players' side is -Z local).
	local gaugeCF = origin * CFrame.new(-0.55, 1.35, -0.98)
	cylinder(station, "GaugeRim", 0.5, 0.08, gaugeCF * CFrame.Angles(0, math.rad(90), 0), BRASS, Enum.Material.Metal)
	cylinder(
		station,
		"GaugeFace",
		0.42,
		0.06,
		gaugeCF * CFrame.new(0, 0, -0.03) * CFrame.Angles(0, math.rad(90), 0),
		PAPER,
		Enum.Material.SmoothPlastic
	)
	local gaugeGui = surface(station:FindFirstChild("GaugeFace") :: BasePart, Enum.NormalId.Left, 100)
	for i, mark in ipairs({ "0", "", "", "", "MAX" }) do
		if mark ~= "" then
			label(
				gaugeGui,
				"Mark" .. i,
				mark,
				UDim2.fromScale(0.4, 0.3),
				UDim2.fromScale(if i == 1 then 0.02 else 0.58, 0.62),
				Enum.Font.GothamMedium,
				12,
				INK
			)
		end
	end
	local needle = part(
		station,
		"GaugeNeedle",
		Vector3.new(0.05, 0.36, 0.03),
		gaugeCF * CFrame.new(0, 0.12, -0.08) * CFrame.Angles(0, 0, math.rad(60)),
		RED,
		Enum.Material.SmoothPlastic
	)
	needle:SetAttribute("SFE_Pivot", true)
	local pivot = Instance.new("Attachment")
	pivot.Name = "Pivot"
	pivot.WorldPosition = (gaugeCF * CFrame.new(0, -0.02, -0.08)).Position
	pivot.Parent = needle
	ball(station, "GaugeHub", 0.06, gaugeCF * CFrame.new(0, -0.02, -0.09), BRASS, Enum.Material.Metal)
	-- Signal lamps in a row above the gauge: none (cool), weak (amber), strong (gold).
	for i, spec in ipairs({ { "LampNone", LAMP_NONE }, { "LampWeak", LAMP_WEAK }, { "LampStrong", LAMP_STRONG } }) do
		local lamp = ball(station, spec[1], 0.2, origin * CFrame.new(0.35 + (i - 2) * 0.5, 1.75, -0.98), spec[2], Enum.Material.Neon)
		lamp.Transparency = 0.55
		local light = Instance.new("PointLight")
		light.Name = "Light"
		light.Color = spec[2]
		light.Brightness = 0
		light.Range = 4
		light.Shadows = false
		light.Parent = lamp
		cylinder(
			station,
			"LampSocket",
			0.24,
			0.1,
			origin * CFrame.new(0.35 + (i - 2) * 0.5, 1.75, -0.9) * CFrame.Angles(0, math.rad(90), 0),
			BRASS,
			Enum.Material.Metal
		)
	end
	-- Gears on the right flank (+X local), toothed.
	for i, spec in ipairs({ { 0.55, 0.6, 0.55, 8 }, { 0.36, 1.35, 1.2, 6 }, { 0.42, 1.05, 0.05, 7 } }) do
		local gearCF = origin * CFrame.new(1.35, spec[3] + 0.4, spec[2] - 0.8) * CFrame.Angles(0, 0, 0)
		local gear = cylinder(station, "Gear" .. i, spec[1], 0.16, gearCF, if i == 2 then BRASS else BRASS_DARK, Enum.Material.Metal)
		gear:SetAttribute("SFE_Teeth", spec[4])
		for t = 1, spec[4] do
			local a = t / spec[4] * math.pi * 2
			local tooth = part(
				station,
				"GearTooth" .. i,
				Vector3.new(0.14, 0.16, 0.14),
				gearCF * CFrame.new(0, math.cos(a) * (spec[1] + 0.06), math.sin(a) * (spec[1] + 0.06)) * CFrame.Angles(a, 0, 0),
				gear.Color,
				Enum.Material.Metal
			)
			tooth:SetAttribute("SFE_GearOf", i)
			tooth:SetAttribute("SFE_ToothAngle", a)
		end
	end
	-- Crank on the same flank, below the gears.
	local crankCF = origin * CFrame.new(1.45, 0.55, -0.5)
	local wheel = cylinder(station, "CrankWheel", 0.3, 0.1, crankCF, IRON, Enum.Material.Metal)
	wheel:SetAttribute("SFE_Pivot", true)
	part(station, "CrankArm", Vector3.new(0.08, 0.34, 0.08), crankCF * CFrame.new(0.08, 0.17, 0), IRON_DARK, Enum.Material.Metal):SetAttribute(
		"SFE_CrankPart",
		true
	)
	cylinder(station, "CrankHandle", 0.06, 0.4, crankCF * CFrame.new(0.28, 0.34, 0), OAK, Enum.Material.Wood):SetAttribute(
		"SFE_CrankPart",
		true
	)
	-- The big lever on the left flank (-X local), between machine and seismograph.
	local leverCF = origin * CFrame.new(-1.4, 0.35, -0.55)
	part(station, "LeverMount", Vector3.new(0.3, 0.3, 0.5), leverCF, IRON_DARK, Enum.Material.Metal)
	local lever = part(
		station,
		"Lever",
		Vector3.new(0.1, 1.4, 0.1),
		leverCF * CFrame.new(0, 0.7, 0) * CFrame.Angles(math.rad(-28), 0, 0),
		IRON,
		Enum.Material.Metal
	)
	lever:SetAttribute("SFE_Pivot", true)
	local leverPivot = Instance.new("Attachment")
	leverPivot.Name = "Pivot"
	leverPivot.WorldPosition = leverCF.Position
	leverPivot.Parent = lever
	ball(
		station,
		"LeverKnob",
		0.14,
		leverCF * CFrame.Angles(math.rad(-28), 0, 0) * CFrame.new(0, 1.42, 0),
		RED,
		Enum.Material.SmoothPlastic
	):SetAttribute("SFE_LeverKnob", true)
	-- Steam pipe and whistle on top.
	cylinder(station, "SteamPipe", 0.11, 0.7, upright(origin * CFrame.new(0.75, 2.5, 0.4)), BRASS, Enum.Material.Metal)
	local whistle = cylinder(station, "Whistle", 0.16, 0.3, upright(origin * CFrame.new(0.75, 2.95, 0.4)), BRASS, Enum.Material.Metal)
	local steam = Instance.new("ParticleEmitter")
	steam.Name = "Steam"
	steam.Enabled = false
	steam.Rate = 40
	steam.Lifetime = NumberRange.new(0.5, 0.9)
	steam.Speed = NumberRange.new(3, 5)
	steam.SpreadAngle = Vector2.new(12, 12)
	steam.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 0.9) })
	steam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	steam.Color = ColorSequence.new(Color3.fromRGB(240, 240, 240))
	steam.LightEmission = 0.1
	steam.EmissionDirection = Enum.NormalId.Right -- the cylinder's axis points up after `upright`
	steam.Parent = whistle
	-- Nameplate riveted to the front.
	local plate =
		part(station, "MachinePlate", Vector3.new(1.5, 0.36, 0.05), origin * CFrame.new(0.3, 0.55, -0.98), BRASS, Enum.Material.Metal)
	local gui = surface(plate, Enum.NormalId.Front, 120)
	label(gui, "Text", "MOLE-O-MATIC SURVEYOR", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), Enum.Font.FredokaOne, 18, IRON_DARK)
end

-- The seismograph: paper drum, a strip, the needle arm, and a trace the client draws.
local function buildSeismograph(station: Model, base: CFrame, tableTop: number)
	local origin = base * CFrame.new(0.45, tableTop, 1.25)
	part(station, "SeismoBase", Vector3.new(1.7, 0.2, 0.9), origin * CFrame.new(0, 0.1, 0), IRON_DARK, Enum.Material.Metal)
	cylinder(station, "SeismoDrum", 0.24, 1.4, origin * CFrame.new(0, 0.5, 0.25), IRON, Enum.Material.Metal)
	local strip =
		part(station, "SeismoPaper", Vector3.new(1.5, 0.03, 0.6), origin * CFrame.new(0, 0.32, -0.15), PAPER, Enum.Material.SmoothPlastic)
	local gui = surface(strip, Enum.NormalId.Top, 100)
	local trace = Instance.new("Frame")
	trace.Name = "Trace"
	trace.BackgroundTransparency = 1
	trace.Size = UDim2.fromScale(1, 1)
	trace.Parent = gui
	local bars = 40
	for i = 1, bars do
		local bar = Instance.new("Frame")
		bar.Name = "Bar" .. i
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale((i - 0.5) / bars, 0.5)
		bar.Size = UDim2.new(0.6 / bars, 0, 0, 2)
		bar.BackgroundColor3 = INK
		bar.BorderSizePixel = 0
		bar.Parent = trace
	end
	local arm = part(
		station,
		"SeismoNeedle",
		Vector3.new(0.04, 0.04, 0.7),
		origin * CFrame.new(0.55, 0.42, -0.1) * CFrame.Angles(0, 0, 0),
		IRON,
		Enum.Material.Metal
	)
	arm:SetAttribute("SFE_Pivot", true)
	local pivot = Instance.new("Attachment")
	pivot.Name = "Pivot"
	pivot.WorldPosition = (origin * CFrame.new(0.55, 0.42, 0.25)).Position
	pivot.Parent = arm
	part(station, "SeismoPost", Vector3.new(0.08, 0.36, 0.08), origin * CFrame.new(0.55, 0.28, 0.25), BRASS, Enum.Material.Metal)
end

-- The survey-crate platform beside the bench, with the marker where the crate lands.
local function buildPlatform(station: Model, base: CFrame)
	local origin = base * CFrame.new(5.6, 0, -0.6)
	local deck = part(
		station,
		"CratePlatform",
		Vector3.new(3.0, 0.3, 3.0),
		origin * CFrame.new(0, 0.15, 0),
		OAK_DEEP,
		Enum.Material.WoodPlanks,
		true
	)
	deck.CanQuery = false
	for _, corner in ipairs({ { -1.35, -1.35 }, { 1.35, -1.35 }, { -1.35, 1.35 }, { 1.35, 1.35 } }) do
		part(
			station,
			"PlatformPost",
			Vector3.new(0.18, 0.9, 0.18),
			origin * CFrame.new(corner[1], 0.45, corner[2]),
			BRASS,
			Enum.Material.Metal
		)
	end
	part(
		station,
		"PlatformMarkA",
		Vector3.new(2.2, 0.02, 0.1),
		origin * CFrame.new(0, 0.31, 0) * CFrame.Angles(0, math.rad(45), 0),
		HELMET,
		Enum.Material.SmoothPlastic
	)
	part(
		station,
		"PlatformMarkB",
		Vector3.new(2.2, 0.02, 0.1),
		origin * CFrame.new(0, 0.31, 0) * CFrame.Angles(0, math.rad(-45), 0),
		HELMET,
		Enum.Material.SmoothPlastic
	)
	local spot = Instance.new("Attachment")
	spot.Name = "CrateSpot"
	spot.Position = Vector3.new(0, 0.15 + 0.9, 0)
	spot.Parent = deck
	local sign = part(station, "PlatformSign", Vector3.new(1.8, 0.5, 0.06), origin * CFrame.new(0, 1.4, 1.5), OAK, Enum.Material.Wood)
	part(station, "PlatformSignPost", Vector3.new(0.1, 1.2, 0.1), origin * CFrame.new(0, 0.75, 1.5), OAK_DEEP, Enum.Material.Wood)
	local gui = surface(sign, Enum.NormalId.Front, 100)
	label(gui, "Text", "SURVEY CRATE HERE", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), Enum.Font.FredokaOne, 22, PAPER)
end

-- The result board: the same nine cells with the landmarks, stamped by the client after a scan.
local function buildBoard(station: Model, base: CFrame)
	local origin = base * CFrame.new(0.4, 0, 2.7)
	local lean = CFrame.Angles(math.rad(-6), 0, 0)
	for _, x in ipairs({ -2.0, 2.0 }) do
		part(station, "BoardLeg", Vector3.new(0.18, 6.8, 0.18), origin * CFrame.new(x, 3.4, 0) * lean, IRON_DARK, Enum.Material.Metal)
	end
	part(station, "BoardBar", Vector3.new(4.4, 0.16, 0.16), origin * CFrame.new(0, 2.2, 0) * lean, IRON_DARK, Enum.Material.Metal)
	local board = part(
		station,
		"ResultBoard",
		Vector3.new(4.4, 4.0, 0.14),
		origin * CFrame.new(0, 4.5, -0.1) * lean,
		PAPER,
		Enum.Material.SmoothPlastic
	)
	part(station, "ResultBoardFrame", Vector3.new(4.7, 4.3, 0.1), origin * CFrame.new(0, 4.5, -0.02) * lean, IRON, Enum.Material.Metal)
	local gui = surface(board, Enum.NormalId.Front, 80)
	label(gui, "Title", "NEST SURVEY", UDim2.new(1, 0, 0, 52), UDim2.fromScale(0, 0.02), Enum.Font.FredokaOne, 40, INK)
	local status = label(
		gui,
		"Status",
		"NOT YET RUN",
		UDim2.new(1, 0, 0, 30),
		UDim2.fromScale(0, 0.17),
		Enum.Font.GothamMedium,
		20,
		Color3.fromRGB(140, 120, 100)
	)
	status.Name = "Status"
	-- Landmarks around the grid.
	label(gui, "LandBack", NestSurvey.LANDMARKS.top, UDim2.new(0.5, 0, 0, 22), UDim2.fromScale(0.25, 0.25), Enum.Font.FredokaOne, 16, INK)
	label(
		gui,
		"LandFront",
		NestSurvey.LANDMARKS.bottom,
		UDim2.new(0.5, 0, 0, 22),
		UDim2.fromScale(0.25, 0.93),
		Enum.Font.FredokaOne,
		16,
		INK
	)
	label(gui, "LandBarn", NestSurvey.LANDMARKS.left, UDim2.new(0.15, 0, 0, 22), UDim2.fromScale(0.02, 0.58), Enum.Font.FredokaOne, 16, INK)
	label(
		gui,
		"LandFence",
		NestSurvey.LANDMARKS.right,
		UDim2.new(0.15, 0, 0, 22),
		UDim2.fromScale(0.83, 0.58),
		Enum.Font.FredokaOne,
		16,
		INK
	)
	local grid = Instance.new("Frame")
	grid.Name = "Grid"
	grid.BackgroundTransparency = 1
	grid.Position = UDim2.fromScale(0.2, 0.32)
	grid.Size = UDim2.fromScale(0.6, 0.6)
	grid.Parent = gui
	for _, region in ipairs(NestSurvey.REGIONS) do
		local row, col = NestSurvey.rowCol(region)
		local cell = Instance.new("Frame")
		cell.Name = "Cell_" .. region
		cell.Position = UDim2.fromScale((col - 1) / 3 + 0.01, (row - 1) / 3 + 0.01)
		cell.Size = UDim2.fromScale(1 / 3 - 0.02, 1 / 3 - 0.02)
		cell.BackgroundColor3 = STRAW
		cell.BorderSizePixel = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = cell
		local stroke = Instance.new("UIStroke")
		stroke.Name = "Edge"
		stroke.Color = INK
		stroke.Thickness = 2
		stroke.Transparency = 0.4
		stroke.Parent = cell
		cell.Parent = grid
		label(cell, "Id", region, UDim2.fromScale(1, 0.5), UDim2.fromScale(0, 0.05), Enum.Font.FredokaOne, 22, INK)
		local mark = label(cell, "Mark", "", UDim2.fromScale(1, 0.4), UDim2.fromScale(0, 0.55), Enum.Font.FredokaOne, 14, RED)
		mark.Visible = false
		for i, angle in ipairs({ 45, -45 }) do
			local cross = Instance.new("Frame")
			cross.Name = "Cross" .. i
			cross.AnchorPoint = Vector2.new(0.5, 0.5)
			cross.Position = UDim2.fromScale(0.5, 0.5)
			cross.Size = UDim2.new(1.1, 0, 0, 5)
			cross.Rotation = angle
			cross.BackgroundColor3 = RED
			cross.BorderSizePixel = 0
			cross.Visible = false
			cross.Parent = cell
		end
	end
end

-- Molly's tripod and theodolite beside the bench.
local function buildTripod(station: Model, base: CFrame)
	local origin = base * CFrame.new(-5.4, 0, -0.9)
	for i = 1, 3 do
		local a = i / 3 * math.pi * 2
		local foot = origin * CFrame.new(math.cos(a) * 0.9, 0, math.sin(a) * 0.9)
		local top = origin * CFrame.new(0, 3.0, 0)
		local mid = (foot.Position + top.Position) / 2
		local length = (top.Position - foot.Position).Magnitude
		part(
			station,
			"TripodLeg",
			Vector3.new(0.1, length, 0.1),
			CFrame.lookAt(mid, top.Position) * CFrame.Angles(math.rad(90), 0, 0),
			OAK_DEEP,
			Enum.Material.Wood
		)
	end
	cylinder(station, "TripodHead", 0.3, 0.2, upright(origin * CFrame.new(0, 3.1, 0)), BRASS, Enum.Material.Metal)
	cylinder(
		station,
		"Theodolite",
		0.12,
		0.9,
		origin * CFrame.new(0, 3.35, 0) * CFrame.Angles(0, math.rad(-20), 0),
		BRASS_DARK,
		Enum.Material.Metal
	)
	cylinder(
		station,
		"TheodoliteLens",
		0.14,
		0.06,
		origin * CFrame.new(0, 3.35, 0) * CFrame.Angles(0, math.rad(-20), 0) * CFrame.new(0.48, 0, 0),
		Color3.fromRGB(200, 230, 240),
		Enum.Material.Glass
	)
end

-- Molly's dressing: helmet with a lit lamp, goggles, vest, tool belt, dirt, a map tube on her back.
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
	local hs = head.Size
	local front = head.CFrame * CFrame.new(0, 0, -hs.Z / 2)
	-- Snout and nose.
	local snout = part(
		rig,
		"Snout",
		Vector3.new(hs.X * 0.42, hs.Y * 0.36, 0.42),
		front * CFrame.new(0, -0.18, -0.16),
		FUR_LIGHT,
		Enum.Material.Fabric
	)
	weld(snout, head)
	local nose = ball(rig, "Nose", 0.16, front * CFrame.new(0, -0.12, -0.42), NOSE, Enum.Material.SmoothPlastic)
	weld(nose, head)
	for _, x in ipairs({ -0.14, 0.14 }) do
		local whisker = part(
			rig,
			"Whisker",
			Vector3.new(0.6, 0.02, 0.02),
			front * CFrame.new(x * 3, -0.2, -0.3) * CFrame.Angles(0, math.rad(x * 60), 0),
			PAPER,
			Enum.Material.SmoothPlastic
		)
		weld(whisker, head)
	end
	-- Goggles: two lenses on a strap, worn up on the helmet rim until the sequence pulls them down.
	local goggleY = 0.18
	for _, x in ipairs({ -0.3, 0.3 }) do
		local rim = cylinder(
			rig,
			"GoggleRim",
			0.26,
			0.1,
			front * CFrame.new(x, goggleY, -0.06) * CFrame.Angles(0, math.rad(90), 0),
			BRASS,
			Enum.Material.Metal
		)
		weld(rim, head)
		local lens = cylinder(
			rig,
			"GoggleLens",
			0.22,
			0.05,
			front * CFrame.new(x, goggleY, -0.08) * CFrame.Angles(0, math.rad(90), 0),
			Color3.fromRGB(150, 210, 190),
			Enum.Material.Glass
		)
		lens.Transparency = 0.35
		weld(lens, head)
	end
	local strap = part(
		rig,
		"GoggleStrap",
		Vector3.new(hs.X * 1.02, 0.12, hs.Z * 1.02),
		head.CFrame * CFrame.new(0, goggleY, 0.02),
		LEATHER,
		Enum.Material.Leather
	)
	weld(strap, head)
	-- Mining helmet: crown, brim and the lamp.
	local top = head.CFrame * CFrame.new(0, hs.Y / 2, 0)
	local crown =
		cylinder(rig, "HelmetCrown", hs.X * 0.5, 0.42, upright(top * CFrame.new(0, 0.28, 0.02)), HELMET, Enum.Material.SmoothPlastic)
	weld(crown, head)
	local dome = ball(rig, "HelmetDome", hs.X * 0.5, top * CFrame.new(0, 0.32, 0.02), HELMET, Enum.Material.SmoothPlastic)
	weld(dome, head)
	local brim = cylinder(
		rig,
		"HelmetBrim",
		hs.X * 0.6,
		0.08,
		upright(top * CFrame.new(0, 0.1, 0.02)),
		Color3.fromRGB(210, 168, 40),
		Enum.Material.SmoothPlastic
	)
	weld(brim, head)
	local lamp = cylinder(
		rig,
		"HelmetLamp",
		0.14,
		0.2,
		top * CFrame.new(0, 0.42, -hs.Z * 0.45) * CFrame.Angles(0, math.rad(90), 0),
		IRON_DARK,
		Enum.Material.Metal
	)
	weld(lamp, head)
	local lens = cylinder(
		rig,
		"HelmetLampLens",
		0.11,
		0.04,
		top * CFrame.new(0, 0.42, -hs.Z * 0.45 - 0.11) * CFrame.Angles(0, math.rad(90), 0),
		Color3.fromRGB(255, 244, 200),
		Enum.Material.Neon
	)
	weld(lens, head)
	local beam = Instance.new("SpotLight")
	beam.Name = "Beam"
	beam.Face = Enum.NormalId.Left
	beam.Angle = 55
	beam.Range = 14
	beam.Brightness = 1.6
	beam.Color = Color3.fromRGB(255, 240, 200)
	beam.Shadows = false
	beam.Parent = lens
	-- Utility vest with pockets, and the tool belt.
	local vest = part(
		rig,
		"Vest",
		Vector3.new(upper.Size.X * 1.08, upper.Size.Y * 0.9, upper.Size.Z * 1.12),
		upper.CFrame * CFrame.new(0, -0.02, 0),
		VEST,
		Enum.Material.Fabric
	)
	weld(vest, upper)
	for _, x in ipairs({ -0.28, 0.28 }) do
		local pocket = part(
			rig,
			"VestPocket",
			Vector3.new(upper.Size.X * 0.32, upper.Size.Y * 0.3, 0.1),
			upper.CFrame * CFrame.new(x * upper.Size.X, -upper.Size.Y * 0.18, -upper.Size.Z * 0.62),
			LEATHER,
			Enum.Material.Fabric
		)
		weld(pocket, upper)
	end
	local belt = part(
		rig,
		"ToolBelt",
		Vector3.new(lower.Size.X * 1.14, 0.22, lower.Size.Z * 1.18),
		lower.CFrame * CFrame.new(0, 0.1, 0),
		LEATHER,
		Enum.Material.Leather
	)
	weld(belt, lower)
	local buckle = part(
		rig,
		"BeltBuckle",
		Vector3.new(0.24, 0.2, 0.06),
		lower.CFrame * CFrame.new(0, 0.1, -lower.Size.Z * 0.62),
		BRASS,
		Enum.Material.Metal
	)
	weld(buckle, lower)
	local hammer = part(
		rig,
		"BeltHammer",
		Vector3.new(0.08, 0.5, 0.08),
		lower.CFrame * CFrame.new(lower.Size.X * 0.6, -0.15, 0.1),
		OAK,
		Enum.Material.Wood
	)
	weld(hammer, lower)
	local hammerHead = part(
		rig,
		"BeltHammerHead",
		Vector3.new(0.14, 0.12, 0.26),
		lower.CFrame * CFrame.new(lower.Size.X * 0.6, 0.12, 0.1),
		IRON,
		Enum.Material.Metal
	)
	weld(hammerHead, lower)
	local tape = cylinder(
		rig,
		"BeltTape",
		0.14,
		0.12,
		lower.CFrame * CFrame.new(-lower.Size.X * 0.6, -0.05, -0.05) * CFrame.Angles(0, 0, 0),
		HELMET,
		Enum.Material.SmoothPlastic
	)
	weld(tape, lower)
	-- Rolled maps in a tube on her back.
	local tube = cylinder(
		rig,
		"MapTube",
		0.16,
		upper.Size.Y * 1.3,
		upper.CFrame * CFrame.new(0.15, 0.1, upper.Size.Z * 0.62) * CFrame.Angles(0, 0, math.rad(70)),
		LEATHER,
		Enum.Material.Leather
	)
	weld(tube, upper)
	local maps = cylinder(
		rig,
		"MapTubeMaps",
		0.12,
		upper.Size.Y * 1.5,
		upper.CFrame * CFrame.new(0.15, 0.1, upper.Size.Z * 0.62) * CFrame.Angles(0, 0, math.rad(70)),
		PAPER,
		Enum.Material.Fabric
	)
	weld(maps, upper)
	-- Dirt: dark smudges on hands, knees and the vest.
	for _, spec in ipairs({
		{ "LeftHand", 0, -0.1, -0.2 },
		{ "RightHand", 0.05, 0.1, -0.15 },
		{ "LeftLowerLeg", 0.05, 0.3, -0.3 },
		{ "RightLowerLeg", -0.05, 0.2, -0.3 },
	}) do
		local limb = rig:FindFirstChild(spec[1]) :: BasePart?
		if limb then
			local smudge = part(
				rig,
				"Dirt",
				Vector3.new(limb.Size.X * 0.7, limb.Size.Y * 0.35, 0.04),
				limb.CFrame * CFrame.new(spec[2], spec[3], limb.Size.Z / 2 * math.sign(spec[4]) + spec[4] * 0.1),
				DIRT,
				Enum.Material.Slate
			)
			weld(smudge, limb)
		end
	end
	local vestDirt = part(
		rig,
		"Dirt",
		Vector3.new(upper.Size.X * 0.4, upper.Size.Y * 0.2, 0.04),
		upper.CFrame * CFrame.new(-upper.Size.X * 0.2, -upper.Size.Y * 0.4, -upper.Size.Z * 0.64),
		DIRT,
		Enum.Material.Slate
	)
	weld(vestDirt, upper)
end

local function recolour(rig: Model)
	for _, child in ipairs(rig:GetChildren()) do
		if child:IsA("BasePart") and child.Name ~= "HumanoidRootPart" then
			local isPaw = string.find(child.Name, "Hand") or string.find(child.Name, "Foot")
			child.Color = if isPaw then NOSE else FUR
			child.Material = if isPaw then Enum.Material.SmoothPlastic else Enum.Material.Fabric
		end
	end
end

-- Molly's rig from the owner's Cow Boy: no scripts, no Toolbox accessories, no clothing, scaled short.
function MollyStation.spawnMolly(workspaceService: Workspace, folder: Instance, cframe: CFrame): Model?
	local source = workspaceService:FindFirstChild("Cow Boy")
	if not (source and source:IsA("Model")) then
		return nil
	end
	local rig = source:Clone()
	rig.Name = MollyStation.MODEL_NAME
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
	rig:ScaleTo(MollyStation.RIG_SCALE)
	local _, size = rig:GetBoundingBox()
	rig:PivotTo(cframe * CFrame.new(0, size.Y / 2, 0))
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
	tag(rig)
	rig.Parent = folder
	return rig
end

function MollyStation.build(workspaceService: Workspace, folder: Instance, layout: any, config: { [string]: any }): Model?
	if not layout.surveyStation then
		return nil
	end
	local existing = folder:FindFirstChild(MollyStation.STATION_NAME)
	if existing then
		existing:Destroy()
	end
	local station = Instance.new("Model")
	station.Name = MollyStation.STATION_NAME
	local base =
		CFrame.lookAt(layout.surveyStation, Vector3.new(layout.surveyStationFacing.X, layout.surveyStation.Y, layout.surveyStationFacing.Z))
	local tableTop = buildBench(station, base)
	local mapCentre = buildMap(station, base, tableTop)
	buildGantry(station, mapCentre)
	buildMachine(station, base, tableTop)
	buildSeismograph(station, base, tableTop)
	buildPlatform(station, base)
	buildBoard(station, base)
	buildTripod(station, base)
	station:SetAttribute("SFE_MapCentre", mapCentre)
	local anchor = part(
		station,
		"MollyAnchor",
		Vector3.new(9.5, 5.5, 5),
		base * CFrame.new(0.4, 2.8, 0.6),
		Color3.new(1, 1, 1),
		Enum.Material.SmoothPlastic
	)
	anchor.Transparency = 1
	anchor.CanQuery = false
	anchor:SetAttribute("SFE_Ambient", "molly")
	anchor:SetAttribute("SFE_NpcModel", MollyStation.MODEL_NAME)
	anchor:SetAttribute("SFE_NpcName", "Molly the Mole")
	anchor:SetAttribute("SFE_NpcRole", "Underground surveyor")
	local p = Instance.new("ProximityPrompt")
	p.Name = MollyStation.PROMPT_NAME
	p.ActionText = "SURVEY THE NEST"
	p.ObjectText = "Molly the Mole"
	p.HoldDuration = 0
	p.MaxActivationDistance = config.survey.stationRangeStuds
	p.RequiresLineOfSight = false
	p.Style = Enum.ProximityPromptStyle.Custom
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.GamepadKeyCode = Enum.KeyCode.ButtonX
	p.Parent = anchor
	station.PrimaryPart = anchor
	tag(station)
	station.Parent = folder
	-- Molly stands behind the map end of the bench, facing the players' side.
	MollyStation.spawnMolly(workspaceService, folder, base * CFrame.new(-1.9, 0, 1.9))
	return station
end

function MollyStation.stationCFrame(chapter: string): CFrame?
	local layout = ChapterLayout[chapter]
	if not (layout and layout.surveyStation) then
		return nil
	end
	return CFrame.lookAt(
		layout.surveyStation,
		Vector3.new(layout.surveyStationFacing.X, layout.surveyStation.Y, layout.surveyStationFacing.Z)
	)
end

return MollyStation
