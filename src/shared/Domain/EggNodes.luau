--!strict
-- Egg spawn node catalogue for a chapter (MASTER_SPEC section 6 "Egg spawn and reveal"). Nodes are
-- laid out on an inner ring/grid of the pile so every candidate has a full cover neighbourhood.
-- Each node defines: grid cell, cover cell set (radius from config), a depth fraction drawn within
-- the configured removal window, and a reveal camera anchor offset. Pure; server-selected.

local PileGrid = require(script.Parent.PileGrid)

local EggNodes = {}

export type Node = {
	id: string,
	x: number,
	z: number,
	coverIndexes: { number },
	weight: number,
}

-- Builds `spawnNodeCountTarget` nodes spread over the interior of the grid (margin of coverRadius+1).
function EggNodes.build(chapter: string, pileConfig: { [string]: any }, eggConfig: { [string]: any }): { Node }
	local width, depth = pileConfig.gridWidth, pileConfig.gridDepth
	local radius = pileConfig.coverRadiusCells
	local margin = radius + 1
	local usableW, usableD = width - margin * 2, depth - margin * 2
	local target = eggConfig.spawnNodeCountTarget
	local columns = math.max(1, math.ceil(math.sqrt(target * usableW / math.max(1, usableD))))
	local rows = math.max(1, math.ceil(target / columns))
	local nodes: { Node } = {}
	for row = 0, rows - 1 do
		for column = 0, columns - 1 do
			if #nodes >= target then
				break
			end
			local x = margin + math.floor((column + 0.5) * usableW / columns)
			local z = margin + math.floor((row + 0.5) * usableD / rows)
			x = math.clamp(x, margin, width - margin - 1)
			z = math.clamp(z, margin, depth - margin - 1)
			local cover = {}
			for dz = -radius, radius do
				for dx = -radius, radius do
					table.insert(cover, PileGrid.index(width, x + dx, z + dz))
				end
			end
			-- Deep-core nodes weigh more than edge nodes: most rounds run long, a few land near the rim.
			local dx = (x + 0.5) / width - 0.5
			local dz = (z + 0.5) / depth - 0.5
			local centred = 1 - math.clamp(math.sqrt(dx * dx + dz * dz) / 0.5, 0, 1)
			local edgeWeight = eggConfig.edgeNodeWeight or 1
			local coreWeight = eggConfig.coreNodeWeight or 1
			local weight = edgeWeight + (coreWeight - edgeWeight) * centred
			table.insert(nodes, {
				id = string.format("%s:node_%d", chapter, #nodes + 1),
				x = x,
				z = z,
				coverIndexes = cover,
				weight = math.max(0.01, weight),
			})
		end
	end
	return nodes
end

-- Depth fraction for a node: uniform within [minimumRemovalFraction, maximumRemovalFraction] (Normal)
-- or the difficulty's own window when it defines one (Hard: eggDepthMinimum/Maximum). A lucky
-- round drops the floor to `luckyMinimumRemovalFraction` so the Egg can sit near the surface.
function EggNodes.rollDepth(eggConfig: { [string]: any }, difficultyEntry: { [string]: any }, roll: number, lucky: boolean?): number
	local minimum = difficultyEntry.eggDepthMinimum or eggConfig.minimumRemovalFraction
	local maximum = difficultyEntry.eggDepthMaximum or eggConfig.maximumRemovalFraction
	if lucky and eggConfig.luckyMinimumRemovalFraction then
		minimum = math.min(minimum, eggConfig.luckyMinimumRemovalFraction)
	end
	return minimum + (maximum - minimum) * roll
end

-- Whether a round is a lucky one (shallow Egg), from one rng roll and `luckyRoundChance`.
function EggNodes.rollLucky(eggConfig: { [string]: any }, roll: number): boolean
	local chance = eggConfig.luckyRoundChance or 0
	return chance > 0 and roll < chance
end

function EggNodes.byId(nodes: { Node }, id: string): Node?
	for _, node in ipairs(nodes) do
		if node.id == id then
			return node
		end
	end
	return nil
end

return EggNodes
