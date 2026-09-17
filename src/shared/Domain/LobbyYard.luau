--!strict
-- Pure geometry for the lobby yard chickens: where a chicken may stand and how it picks its next
-- wander target. A point is allowed when it lies inside one of the yard rectangles and outside every
-- exclusion (rectangles, circles, pad zones grown by a margin, and capsules around the lines players
-- walk from spawn to each pad). Paths are checked by sampling, so a walk never cuts across the portal
-- corridor from one side of the door to the other. All positions are Vector2(x, z).

local LobbyYard = {}

export type Rect = { min: Vector2, max: Vector2 }
export type Circle = { center: Vector2, radius: number }
export type Line = { from: Vector2, to: Vector2, radius: number }
export type Yard = {
	rects: { Rect },
	excludeRects: { Rect },
	excludeCircles: { Circle },
	excludeLines: { Line },
}

local function flat(position: Vector3): Vector2
	return Vector2.new(position.X, position.Z)
end

local function inRect(rect: Rect, point: Vector2): boolean
	return point.X >= rect.min.X and point.X <= rect.max.X and point.Y >= rect.min.Y and point.Y <= rect.max.Y
end

-- Distance from a point to a segment.
function LobbyYard.distanceToSegment(point: Vector2, a: Vector2, b: Vector2): number
	local ab = b - a
	local lengthSq = ab:Dot(ab)
	if lengthSq <= 1e-9 then
		return (point - a).Magnitude
	end
	local t = math.clamp((point - a):Dot(ab) / lengthSq, 0, 1)
	return (point - (a + ab * t)).Magnitude
end

-- Builds the yard from ChapterLayout.lobby and the chicken config (margin around pads, clearance
-- around the spawn-to-pad walking lines).
function LobbyYard.fromLayout(lobby: { [string]: any }, chickens: { [string]: any }): Yard
	local source = lobby.chickenYard
	local margin = tonumber(chickens.exclusionMarginStuds) or 0
	local clearance = tonumber(chickens.walkLineClearanceStuds) or 0
	local excludeRects: { Rect } = {}
	for _, rect in ipairs(source.excludeRects) do
		table.insert(excludeRects, { min = rect.min, max = rect.max })
	end
	local excludeLines: { Line } = {}
	local spawn = flat(lobby.spawn)
	for _, pad in ipairs(lobby.pads) do
		local center = flat(pad.center)
		local half = Vector2.new(pad.zoneSize.X / 2 + margin, pad.zoneSize.Z / 2 + margin)
		table.insert(excludeRects, { min = center - half, max = center + half })
		if clearance > 0 then
			table.insert(excludeLines, { from = spawn, to = center, radius = clearance })
		end
	end
	local excludeCircles: { Circle } = {}
	for _, circle in ipairs(source.excludeCircles) do
		table.insert(excludeCircles, { center = circle.center, radius = circle.radius + margin })
	end
	local rects: { Rect } = {}
	for _, rect in ipairs(source.rects) do
		table.insert(rects, { min = rect.min, max = rect.max })
	end
	return { rects = rects, excludeRects = excludeRects, excludeCircles = excludeCircles, excludeLines = excludeLines }
end

-- Index of the yard rectangle holding the point, or nil.
function LobbyYard.rectOf(yard: Yard, point: Vector2): number?
	for index, rect in ipairs(yard.rects) do
		if inRect(rect, point) then
			return index
		end
	end
	return nil
end

function LobbyYard.isExcluded(yard: Yard, point: Vector2): boolean
	for _, rect in ipairs(yard.excludeRects) do
		if inRect(rect, point) then
			return true
		end
	end
	for _, circle in ipairs(yard.excludeCircles) do
		if (point - circle.center).Magnitude <= circle.radius then
			return true
		end
	end
	for _, line in ipairs(yard.excludeLines) do
		if LobbyYard.distanceToSegment(point, line.from, line.to) <= line.radius then
			return true
		end
	end
	return false
end

function LobbyYard.isAllowed(yard: Yard, point: Vector2): boolean
	return LobbyYard.rectOf(yard, point) ~= nil and not LobbyYard.isExcluded(yard, point)
end

-- Every sample along the walk (about one per stud) is allowed.
function LobbyYard.pathAllowed(yard: Yard, from: Vector2, to: Vector2): boolean
	local samples = math.max(2, math.ceil((to - from).Magnitude))
	for i = 0, samples do
		if not LobbyYard.isAllowed(yard, from:Lerp(to, i / samples)) then
			return false
		end
	end
	return true
end

-- A random allowed point anywhere in the yard (rectangles weighted by area), for spawning.
function LobbyYard.randomPoint(yard: Yard, rng: any, attempts: number?): Vector2?
	local total = 0
	for _, rect in ipairs(yard.rects) do
		local size = rect.max - rect.min
		total += size.X * size.Y
	end
	if total <= 0 then
		return nil
	end
	for _ = 1, attempts or 40 do
		local pick = rng:next() * total
		local chosen = yard.rects[#yard.rects]
		for _, rect in ipairs(yard.rects) do
			local size = rect.max - rect.min
			pick -= size.X * size.Y
			if pick <= 0 then
				chosen = rect
				break
			end
		end
		local point = Vector2.new(
			chosen.min.X + rng:next() * (chosen.max.X - chosen.min.X),
			chosen.min.Y + rng:next() * (chosen.max.Y - chosen.min.Y)
		)
		if LobbyYard.isAllowed(yard, point) then
			return point
		end
	end
	return nil
end

-- The next wander target from `from`: within `maxStep` studs, allowed, and reachable in a straight
-- allowed line. `accept` is an optional extra test (the client's ground raycast). Nil when nothing
-- qualified within the attempts; the chicken then simply stays and pecks.
function LobbyYard.pickTarget(
	yard: Yard,
	rng: any,
	from: Vector2,
	maxStep: number,
	accept: ((point: Vector2) -> boolean)?,
	attempts: number?
): Vector2?
	local minStep = math.min(2, maxStep * 0.5)
	for _ = 1, attempts or 12 do
		local angle = rng:next() * math.pi * 2
		local distance = minStep + rng:next() * (maxStep - minStep)
		local point = from + Vector2.new(math.cos(angle), math.sin(angle)) * distance
		if LobbyYard.isAllowed(yard, point) and LobbyYard.pathAllowed(yard, from, point) and (accept == nil or accept(point)) then
			return point
		end
	end
	return nil
end

return LobbyYard
