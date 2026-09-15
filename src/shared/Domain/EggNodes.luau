--!strict
-- Egg spawn node catalogue for a chapter (MASTER_SPEC section 6 "Egg spawn and reveal"). Nodes are
-- laid out on an inner ring/grid of the pile so every candidate has a full cover neighbourhood.
-- Each node defines: grid cell, cover cell set (radius from config), a depth fraction drawn within
-- the configured removal window, and a reveal camera anchor offset. Pure; server-selected.

local PileGrid = require(script.Parent.PileGrid)
local PileSurface = require(script.Parent.PileSurface)

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
	-- The lattice is square and the mound is round, so roughly a quarter of the lattice points fall
	-- outside the dome and are dropped below. Oversample by that ratio and thin the survivors back to
	-- the target, so the chapter still offers the configured number of spawn nodes.
	local lattice = math.ceil(target * 4 / math.pi)
	local columns = math.max(1, math.ceil(math.sqrt(lattice * usableW / math.max(1, usableD))))
	local rows = math.max(1, math.ceil(lattice / columns))
	local nodes: { Node } = {}
	for row = 0, rows - 1 do
		for column = 0, columns - 1 do
			local x = margin + math.floor((column + 0.5) * usableW / columns)
			local z = margin + math.floor((row + 0.5) * usableD / rows)
			x = math.clamp(x, margin, width - margin - 1)
			z = math.clamp(z, margin, depth - margin - 1)
			-- The grid is square and the mound is round, so this lattice puts candidates in corners the
			-- dome never reaches. A node there sits in a column with no records, which counts as
			-- already uncovered: the Egg would reveal on the round's first collection anywhere.
			local cfg = { pile = pileConfig }
			if PileSurface.columnFullHeight(cfg, width, depth, pileConfig.cellSizeStuds, x, z) <= 0 then
				continue
			end
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
				id = "",
				x = x,
				z = z,
				coverIndexes = cover,
				weight = math.max(0.01, weight),
			})
		end
	end
	-- Thin evenly across the surviving lattice so the kept nodes stay spread over the mound rather
	-- than clustered in the rows the loop happened to reach first.
	local kept: { Node } = nodes
	if #nodes > target then
		kept = {}
		for i = 1, target do
			table.insert(kept, nodes[math.floor((i - 0.5) * #nodes / target) + 1])
		end
	end
	for i, node in ipairs(kept) do
		node.id = string.format("%s:node_%d", chapter, i)
	end
	return kept
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
