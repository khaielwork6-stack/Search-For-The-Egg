--!strict
-- Same-place world layout shared by server (authority, range checks) and client (visuals). These are
-- presentation constants (studs), not economy tunables; ranges themselves come from
-- SYSTEM_CONFIG.interaction. Chapter areas sit far from the lobby so streaming/teleport later is a
-- drop-in change (MASTER_SPEC section 4: architecture must not assume same-place travel).
-- Lobby station coordinates are ASSUMED (A-LOBBY-04) and live here so the server builder, the
-- station prompts, and the client ambience read one table.

local ChapterLayout = {}

-- Compact lobby composition (MASTER_SPEC 11 "Layout"): the chapter portal straight ahead of spawn
-- (+Z), Daily and Classes on the primary sightlines flanking the path, Shop (perks) and the Event
-- chest adjacent, Inventory beside the portal path, Stats/leaderboards, Codes and the Group reward
-- on the secondary sightline behind the spawn pad. Every station faces the spawn path.
ChapterLayout.lobby = table.freeze({
	origin = Vector3.new(0, 0, 0),
	spawn = Vector3.new(0, 3, -18),
	portal = Vector3.new(0, 7, 22),
	portalTrigger = Vector3.new(0, 3, 19),
	stations = table.freeze({
		party = table.freeze({ position = Vector3.new(0, 0, 22), facing = Vector3.new(0, 0, -1), modal = "party" }),
		daily = table.freeze({ position = Vector3.new(-20, 0, 6), facing = Vector3.new(1, 0, -0.4), modal = "daily" }),
		classes = table.freeze({ position = Vector3.new(20, 0, 6), facing = Vector3.new(-1, 0, -0.4), modal = "classes" }),
		shop = table.freeze({ position = Vector3.new(-26, 0, -10), facing = Vector3.new(1, 0, 0), modal = "shop" }),
		event = table.freeze({ position = Vector3.new(26, 0, -10), facing = Vector3.new(-1, 0, 0), modal = "event" }),
		inventory = table.freeze({ position = Vector3.new(-12, 0, 20), facing = Vector3.new(0.6, 0, -1), modal = "inventory" }),
		stats = table.freeze({ position = Vector3.new(14, 0, -30), facing = Vector3.new(-0.5, 0, 1), modal = "stats" }),
		codes = table.freeze({ position = Vector3.new(-14, 0, -30), facing = Vector3.new(0.5, 0, 1), modal = "codes" }),
	}),
	stationOrder = table.freeze({ "party", "daily", "classes", "shop", "event", "inventory", "stats", "codes" }),
})

-- Sunlit Henhouse (Chapter 1). Nest is a 40x40 stud footprint (16 x 2.5) centred on `nestCenter`.
ChapterLayout.chapter1 = table.freeze({
	origin = Vector3.new(0, 0, 400),
	floorSize = Vector3.new(140, 1, 140),
	spawn = Vector3.new(0, 3, 352), -- faces +Z toward the nest
	nestCenter = Vector3.new(0, 0, 410),
	nestBaseY = 1, -- top of the nest base collider (players stand at floor level around it)
	sellStation = Vector3.new(-26, 0, 372),
	upgradeBoard = Vector3.new(26, 0, 372),
	roofHeight = 26,
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
