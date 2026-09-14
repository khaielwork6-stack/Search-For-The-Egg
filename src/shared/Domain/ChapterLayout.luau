--!strict
-- Same-place world layout shared by server (authority, range checks) and client (visuals). These are
-- presentation constants (studs), not economy tunables; ranges themselves come from
-- SYSTEM_CONFIG.interaction. Coordinates are measured from the owner's two maps (A-LOBBY-04) and
-- live here so the server builders, the station prompts, the pads, and the client ambience read one
-- table. Chapter areas sit far from the lobby so streaming/teleport later is a drop-in change
-- (MASTER_SPEC section 4: architecture must not assume same-place travel).

local ChapterLayout = {}

-- Lobby: the owner's `SearchForTheEgg_Lobby` map (a fenced farm courtyard; ground top y = 2.1).
-- Every position below is measured from that model, so stations sit on the props the map already
-- provides: the two market stalls, the three leaderboard boards behind spawn, the chicken coops and
-- the barn interior, and the four "Join Match" nest pads that form parties. The chapter portal is
-- the barn doorway ("SEARCH FOR THE EGG"). Without the map (headless / old place) the greybox shell
-- builds at the same coordinates so nothing depends on the map being present.
ChapterLayout.LOBBY_MAP_NAME = "SearchForTheEgg_Lobby"
ChapterLayout.lobby = table.freeze({
	origin = Vector3.new(-0.5, 0, -136),
	groundY = 2.1,
	spawn = Vector3.new(-0.5, 3.3, -99), -- LobbySpawn pad; faces the barn
	portal = Vector3.new(-0.5, 6, -166), -- barn doorway (prompt anchor just outside the sliding doors)
	portalTrigger = Vector3.new(-0.5, 3, -163),
	barnFloorY = 2.5,
	stations = table.freeze({
		party = table.freeze({
			position = Vector3.new(-0.5, 5, -166),
			facing = Vector3.new(0, 0, 1),
			modal = "party",
			host = "ChickenBarn",
		}),
		shop = table.freeze({
			position = Vector3.new(-46.5, 5.9, -87),
			facing = Vector3.new(0, 0, 1),
			modal = "shop",
			host = "UpgradeShop",
		}),
		classes = table.freeze({
			position = Vector3.new(45.5, 5.9, -87),
			facing = Vector3.new(0, 0, 1),
			modal = "classes",
			host = "ClassShop",
		}),
		stats = table.freeze({
			position = Vector3.new(-0.5, 9, -81.2),
			facing = Vector3.new(0, 0, -1),
			modal = "stats",
			host = "Leaderboards",
		}),
		daily = table.freeze({
			position = Vector3.new(-13.5, 3.3, -186.5),
			facing = Vector3.new(0, 0, 1),
			modal = "daily",
			host = "ChickenBarn",
		}),
		event = table.freeze({
			position = Vector3.new(12.5, 3.6, -186.5),
			facing = Vector3.new(0, 0, 1),
			modal = "event",
			host = "ChickenBarn",
		}),
		inventory = table.freeze({
			position = Vector3.new(24.5, 4.5, -162.5),
			facing = Vector3.new(0, 0, 1),
			modal = "inventory",
			host = "ChickenBarn",
		}),
		codes = table.freeze({
			position = Vector3.new(-25.5, 4.5, -162.5),
			facing = Vector3.new(0, 0, 1),
			modal = "codes",
			host = "ChickenBarn",
		}),
	}),
	stationOrder = table.freeze({ "party", "daily", "classes", "shop", "event", "inventory", "stats", "codes" }),
	-- Party nest pads ("Join Match 0/4" signs). Standing inside a zone joins that pad's party.
	pads = table.freeze({
		table.freeze({
			index = 1,
			center = Vector3.new(-43.5, 5, -151),
			zoneSize = Vector3.new(17, 6, 17),
			sign = Vector3.new(-43.5, 7.2, -160),
			signPost = Vector3.new(-43.5, 4.6, -160.6),
		}),
		table.freeze({
			index = 2,
			center = Vector3.new(-43.5, 5, -121),
			zoneSize = Vector3.new(17, 6, 17),
			sign = Vector3.new(-43.5, 7.2, -130),
			signPost = Vector3.new(-43.5, 4.6, -130.6),
		}),
		table.freeze({
			index = 3,
			center = Vector3.new(42.5, 5, -151),
			zoneSize = Vector3.new(17, 6, 17),
			sign = Vector3.new(42.5, 7.2, -160),
			signPost = Vector3.new(42.5, 4.6, -160.6),
		}),
		table.freeze({
			index = 4,
			center = Vector3.new(42.5, 5, -121),
			zoneSize = Vector3.new(17, 6, 17),
			sign = Vector3.new(42.5, 7.2, -130),
			signPost = Vector3.new(42.5, 4.6, -130.6),
		}),
	}),
	-- Leaderboard boards behind spawn: map StatName -> our board id.
	boards = table.freeze({
		Board1 = "eggsFound",
		Board2 = "totalWins",
		Board3 = "feathersCollected",
	}),
	-- Vendors the owner placed in the map: each one hosts its station's prompt and speaks for it.
	npcs = table.freeze({
		shop = table.freeze({
			model = "Cow Boy Brother",
			name = "Perk Seller",
			role = "Permanent Perks Shop",
			line = "Perks bought here stay with you on every search, friend!",
			sign = "PERMANENT PERKS",
			subtitle = "UPGRADES THAT STAY WITH YOU",
		}),
		classes = table.freeze({
			model = "Cow Boy",
			name = "Class Master",
			role = "Roll a class",
			line = "Spin the deck and see what kind of forager you are!",
			sign = "CLASSES",
			subtitle = "ROLL YOUR STYLE",
		}),
	}),
	ambientAnchors = table.freeze({
		Vector3.new(-0.5, 12, -164), -- feathers drifting out of the barn door
		Vector3.new(-43.5, 9, -136), -- over the left pads
		Vector3.new(42.5, 9, -136), -- over the right pads
		Vector3.new(-0.5, 8, -110), -- over the spawn path
	}),
})

-- Sunlit Henhouse (Chapter 1): the owner's `SearchForTheEgg_Map2` map (a fenced farmyard; ground
-- top y = 52.1). The nest is a mound on the open ground in the centre of the yard (measured clear of
-- every prop for 17 studs around); the map's earth pit (floor y = 46.5, opening 32 x 48 studs at
-- z 315) is the black hole the sold crates fall into, so the path from the side conveyor's exit
-- (x 14.5, z 311) to the pit stays clear. Feathers are sold at the collection crate parked in front
-- of the front conveyor; upgrades are bought at the FEATHER SUPPLIES counter. The logical grid is
-- 16 x 16 cells of `pile.cellSizeStuds` centred on `nestCenter`.
ChapterLayout.CHAPTER1_MAP_NAME = "SearchForTheEgg_Map2"
ChapterLayout.chapter1 = table.freeze({
	origin = Vector3.new(0, 52, 350),
	floorSize = Vector3.new(140, 1, 140),
	groundY = 52.1,
	spawn = Vector3.new(0, 53.3, 404), -- MapSpawn at the south gate path; faces the mound
	nestCenter = Vector3.new(0, 52, 372),
	nestBaseY = 52, -- flat yard ground under the mound
	pitOpening = Vector3.new(32, 0, 48),
	blackHole = Vector3.new(0, 46.3, 315), -- the earth pit's dark floor: crates vanish below it
	sellStation = Vector3.new(47, 53.8, 348.5), -- the collection crate (CollectionCrate pivot)
	sellPrompt = Vector3.new(47, 55.6, 348.5),
	crate = table.freeze({
		modelPath = table.freeze({ "Crates", "CollectionCrate" }),
		home = Vector3.new(47, 53.75, 348.51), -- CollectionCrate pivot as authored
		beltTopY = 56.1, -- DarkBelt top face of both conveyors
		crateBottomOffset = 1.85, -- pivot y minus the crate's bottom face
		frontBeltStart = Vector3.new(47, 0, 344), -- south roller of the front conveyor
		machineEntry = Vector3.new(47, 0, 319), -- front portal of the processor
		machineTurn = Vector3.new(47, 0, 311), -- inside, on the side conveyor's line
		sideBeltStart = Vector3.new(39, 0, 311), -- side portal / east roller
		sideBeltEnd = Vector3.new(14.5, 0, 311), -- west roller: the exit
		pitRim = Vector3.new(6, 0, 313.5),
	}),
	upgradeBoard = Vector3.new(-45, 53.8, 303), -- in front of the supplies counter (inside the shop)
	upgradePrompt = Vector3.new(-45, 58.9, 301.2),
	farmer = Vector3.new(-28, 52.1, 338), -- the Farmer stands between the barn door and the mound
	farmerFacing = Vector3.new(0, 52.1, 372),
	chickPathY = 52.1, -- scout chicks walk at ground level between the mound and the crate
	-- Perches the chick flies between while the crate is away (measured 14 Sep 2026 from the map:
	-- crate rear rim top 55.6, crate corner post top 55.4, conveyor end roller top 56.4). Feet height.
	chickPerches = table.freeze({
		Vector3.new(47, 55.7, 351.5),
		Vector3.new(51.2, 55.5, 345.8),
		Vector3.new(44.5, 56.5, 344.5),
	}),
	roofHeight = 26,
	ambientAnchors = table.freeze({
		Vector3.new(0, 67, 372), -- over the mound
		Vector3.new(-12, 62, 385),
		Vector3.new(12, 62, 360),
		Vector3.new(47, 60, 332), -- over the conveyor
	}),
})

ChapterLayout.chapter2 = table.freeze({
	origin = Vector3.new(0, 0, 800),
	floorSize = Vector3.new(150, 1, 150),
	spawn = Vector3.new(0, 3, 742), -- faces +Z toward the mound
	nestCenter = Vector3.new(0, 0, 790),
	nestBaseY = 1,
	sellStation = Vector3.new(-30, 0, 758),
	upgradeBoard = Vector3.new(30, 0, 758),
	roofHeight = 18,
	moonShaft = Vector3.new(0, 18, 790),
	plaque = Vector3.new(-58, 6, 776),
	levers = table.freeze({
		Vector3.new(-58, 0, 790),
		Vector3.new(-58, 0, 806),
		Vector3.new(-58, 0, 822),
	}),
	crystalAlcove = Vector3.new(58, 0, 786), -- clusters spread around this point
	crystalDial = Vector3.new(50, 0, 800),
	codeDoor = Vector3.new(58, 0, 818),
	noteSlots = table.freeze({
		Vector3.new(-40, 5, 848),
		Vector3.new(40, 5, 848),
		Vector3.new(-58, 5, 838),
		Vector3.new(58, 5, 838),
	}),
	tileWall = Vector3.new(0, 6, 858), -- mosaic centre on the far wall
	cage = Vector3.new(-18, 0, 848),
	barrier = Vector3.new(0, 0, 862),
	exitLadder = Vector3.new(0, 0, 868),
	eggExit = Vector3.new(0, 1, 866), -- the Egg appears at the foot of the ladder
	eggAtExit = true,
})

-- World position of a pile cell centre for a grid (cells are 2.5 studs by config).
function ChapterLayout.cellWorldPosition(
	chapter: { [string]: any },
	gridWidth: number,
	gridDepth: number,
	cellSize: number,
	x: number,
	z: number,
	height: number?
): Vector3
	local halfW = gridWidth * cellSize / 2
	local halfD = gridDepth * cellSize / 2
	local center = chapter.nestCenter
	return Vector3.new(center.X - halfW + (x + 0.5) * cellSize, chapter.nestBaseY + (height or 0), center.Z - halfD + (z + 0.5) * cellSize)
end

-- Grid min corner (world) for converting hit points to cells.
function ChapterLayout.gridMinCorner(chapter: { [string]: any }, gridWidth: number, gridDepth: number, cellSize: number): Vector3
	local center = chapter.nestCenter
	return Vector3.new(center.X - gridWidth * cellSize / 2, chapter.nestBaseY, center.Z - gridDepth * cellSize / 2)
end

-- Lobby station lookup by id (nil for unknown ids).
function ChapterLayout.station(id: string): { [string]: any }?
	return (ChapterLayout.lobby.stations :: any)[id]
end

return ChapterLayout
