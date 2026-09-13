--!strict
-- Moonlit Cellar (Chapter 2) shared puzzle machine (MASTER_SPEC 12, STATE_MACHINES 11; ASSUMED
-- A-CH2-02..08). Pure and deterministic: the server generates one solution per round from the
-- validated sets below, applies party inputs through `apply`, and projects only what players may
-- see. Nothing here reads a service or the DataModel, so every path is unit-testable headlessly.
--
-- Stages (data-driven order from chapters.chapter2.puzzles.order):
--   findKey -> activateLevers -> solveCrystals -> solveCode -> solveTiles -> releaseHatchling -> exit
-- Wrong inputs give layered feedback and never corrupt the solution; every puzzle stays solvable
-- (levers reset to the start of the sequence, tiles can always be rotated back, code/count have
-- unlimited attempts), so a round can never softlock.

local CellarPuzzles = {}

export type LeverLabel = { color: string, symbol: string }

export type Solution = {
	leverOrder: { number }, -- lever indexes in the order they must be activated
	crystalCount: number, -- glowing clusters the party must count
	code: string, -- four digits
	codeNotes: { { position: number, digit: string, slot: number } }, -- digit per position, spread over four note slots
	tileScramble: { number }, -- initial rotation (0-3 quarter turns) per tile, index 1..16
}

export type State = {
	stageIndex: number, -- index into the configured order
	key: { revealed: boolean, held: boolean, heldBy: number? },
	levers: { states: { boolean }, progress: number, resets: number },
	crystals: { solved: boolean, attempts: number },
	code: { solved: boolean, attempts: number },
	tiles: { rotations: { number }, solved: boolean, moves: number, resets: number },
	hatchling: { released: boolean, releasedBy: number? },
	completedAt: { [string]: number }, -- stage -> serverNowMs
}

export type Action = { kind: string, index: number?, count: number?, value: any? }

export type Result = {
	ok: boolean,
	code: string, -- "ok" | "not_yet" | "already_done" | "wrong" | "invalid" | "reset"
	message: string?,
	feedback: string?, -- layered feedback id for the client (e.g. "too_low", "sequence_reset")
	stage: string, -- stage after the action
	advanced: boolean, -- true when the stage index moved forward
	solvedStage: string?, -- stage that was completed by this action
	extra: { [string]: any }?,
}

CellarPuzzles.STAGE_KINDS = table.freeze({
	findKey = "pickupKey",
	activateLevers = "lever",
	solveCrystals = "crystals",
	solveCode = "code",
	solveTiles = "tile",
	releaseHatchling = "release",
	exit = "exit",
})

-- Original placeholder copy (PLACEHOLDER owner: Phase 6 localization pass). Symbols accompany colours.
CellarPuzzles.COPY = table.freeze({
	findKey = table.freeze({
		title = "Find the cellar key",
		detail = "Dig through the nesting debris. The key is buried somewhere in the mound",
	}),
	activateLevers = table.freeze({
		title = "Wake the three mechanisms",
		detail = "Read the moon plaque: pull the marked levers in its order",
	}),
	solveCrystals = table.freeze({
		title = "Count the glowing clusters",
		detail = "Count every lit crystal in the alcove and set the dial",
	}),
	solveCode = table.freeze({
		title = "Assemble the four-digit code",
		detail = "Four notes are pinned around the cellar. Read them in order I to IV",
	}),
	solveTiles = table.freeze({ title = "Restore the moon mosaic", detail = "Turn the tiles until every glyph points up" }),
	releaseHatchling = table.freeze({ title = "Free the hatchling", detail = "Open the cage and the barrier will fall" }),
	exit = table.freeze({ title = "Take the Egg and climb out", detail = "Hold Interact on the Egg at the ladder" }),
	done = table.freeze({ title = "Cellar cleared", detail = "Securing rewards..." }),
})

CellarPuzzles.SYMBOL_GLYPH = table.freeze({ triangle = "▲", circle = "●", square = "■", diamond = "◆", star = "★" })

CellarPuzzles.NOTE_NUMERALS = table.freeze({ "I", "II", "III", "IV" })

local function puzzlesConfig(cfg: { [string]: any }): { [string]: any }
	return cfg.chapters.chapter2.puzzles
end

function CellarPuzzles.stages(cfg: { [string]: any }): { string }
	return table.clone(puzzlesConfig(cfg).order)
end

function CellarPuzzles.stageAt(cfg: { [string]: any }, index: number): string
	local order = puzzlesConfig(cfg).order
	return if index > #order then "done" else order[index]
end

-- Fisher-Yates over 1..n using rng:next() in [0,1).
local function permutation(n: number, rng: any): { number }
	local out = table.create(n)
	for i = 1, n do
		out[i] = i
	end
	for i = n, 2, -1 do
		local j = math.floor(rng:next() * i) + 1
		out[i], out[j] = out[j], out[i]
	end
	return out
end

-- Generates one valid solution from the configured sets. Every generated solution is reachable:
-- lever order is a permutation, the crystal count is inside the visible range, the code is four
-- digits (distinct when configured), and the tile scramble is a set of quarter turns that can
-- always be rotated back to upright.
function CellarPuzzles.generate(cfg: { [string]: any }, rng: any): Solution
	local p = puzzlesConfig(cfg)
	local leverOrder = permutation(p.leverCount, rng)

	local range = p.crystalCountRange
	local crystalCount = range.min + math.floor(rng:next() * (range.max - range.min + 1))
	crystalCount = math.clamp(crystalCount, range.min, range.max)

	local digits = {}
	local used: { [number]: boolean } = {}
	for _ = 1, p.codeDigits do
		local digit = math.floor(rng:next() * 10)
		if p.codeDistinctDigits then
			local guard = 0
			while used[digit] and guard < 20 do
				digit = (digit + 1) % 10
				guard += 1
			end
			used[digit] = true
		end
		table.insert(digits, tostring(math.clamp(digit, 0, 9)))
	end
	local code = table.concat(digits)
	-- Notes: position I..IV each carry one digit; their physical slots are shuffled so the party
	-- must read the numerals, not the placement order.
	local slots = permutation(p.codeDigits, rng)
	local codeNotes = {}
	for position = 1, p.codeDigits do
		table.insert(codeNotes, { position = position, digit = digits[position], slot = slots[position] })
	end

	local tileScramble = table.create(p.tileRotationPuzzleSize, 0)
	local scrambled = 0
	for i = 1, p.tileRotationPuzzleSize do
		local turns = math.floor(rng:next() * 4)
		tileScramble[i] = turns
		if turns ~= 0 then
			scrambled += 1
		end
	end
	-- Guarantee a real puzzle: at least the configured number of tiles start out of place.
	local i = 1
	while scrambled < p.tileMinimumScrambled and i <= p.tileRotationPuzzleSize do
		if tileScramble[i] == 0 then
			tileScramble[i] = 1 + math.floor(rng:next() * 3)
			scrambled += 1
		end
		i += 1
	end

	return { leverOrder = leverOrder, crystalCount = crystalCount, code = code, codeNotes = codeNotes, tileScramble = tileScramble }
end

function CellarPuzzles.newState(cfg: { [string]: any }, solution: Solution): State
	local p = puzzlesConfig(cfg)
	local leverStates = table.create(p.leverCount, false)
	for i = 1, p.leverCount do
		leverStates[i] = false
	end
	return {
		stageIndex = 1,
		key = { revealed = false, held = false, heldBy = nil },
		levers = { states = leverStates, progress = 0, resets = 0 },
		crystals = { solved = false, attempts = 0 },
		code = { solved = false, attempts = 0 },
		tiles = { rotations = table.clone(solution.tileScramble), solved = false, moves = 0, resets = 0 },
		hatchling = { released = false, releasedBy = nil },
		completedAt = {},
	}
end

function CellarPuzzles.currentStage(cfg: { [string]: any }, state: State): string
	return CellarPuzzles.stageAt(cfg, state.stageIndex)
end

function CellarPuzzles.isDone(cfg: { [string]: any }, state: State): boolean
	return state.stageIndex > #puzzlesConfig(cfg).order
end

-- Called by the server when the debris mound exposes the key (the Chapter 2 counterpart of the
-- Egg reveal). Idempotent.
function CellarPuzzles.revealKey(state: State): State
	if state.key.revealed then
		return state
	end
	local next = table.clone(state)
	next.key = { revealed = true, held = false, heldBy = nil }
	return next
end

local function stageIndexOf(cfg: { [string]: any }, stage: string): number?
	for index, id in ipairs(puzzlesConfig(cfg).order) do
		if id == stage then
			return index
		end
	end
	return nil
end

local function result(ok: boolean, code: string, stage: string, fields: { [string]: any }?): Result
	local out: any = { ok = ok, code = code, stage = stage, advanced = false }
	if fields then
		for key, value in pairs(fields) do
			out[key] = value
		end
	end
	return out :: Result
end

local function advance(cfg: { [string]: any }, state: State, nowMs: number): (State, string)
	local solved = CellarPuzzles.currentStage(cfg, state)
	local completed = table.clone(state.completedAt)
	completed[solved] = nowMs
	state.completedAt = completed
	state.stageIndex += 1
	return state, solved
end

-- Applies one party input. Returns the next state (a shallow copy; the input state is untouched)
-- and a result. Inputs for a stage that is not current are refused with "not_yet" (earlier stages
-- report "already_done"); nothing about the solution is ever revealed by a refusal.
function CellarPuzzles.apply(
	cfg: { [string]: any },
	state: State,
	solution: Solution,
	action: Action,
	userId: number,
	nowMs: number
): (State, Result)
	local p = puzzlesConfig(cfg)
	local stage = CellarPuzzles.currentStage(cfg, state)
	local kind = action.kind

	if kind == "reset" then
		-- Recovery for the current stage only (A-CH2-03): levers restart the sequence, tiles return to
		-- the round's scramble. Other stages have nothing to reset.
		local next = table.clone(state)
		if stage == "activateLevers" then
			local states = table.create(p.leverCount, false)
			for i = 1, p.leverCount do
				states[i] = false
			end
			next.levers = { states = states, progress = 0, resets = state.levers.resets + 1 }
			return next, result(true, "reset", stage, { feedback = "levers_reset" })
		elseif stage == "solveTiles" then
			next.tiles = {
				rotations = table.clone(solution.tileScramble),
				solved = false,
				moves = state.tiles.moves,
				resets = state.tiles.resets + 1,
			}
			return next, result(true, "reset", stage, { feedback = "tiles_reset" })
		end
		return state, result(false, "invalid", stage, { message = "nothing_to_reset" })
	end

	local expectedStage: string? = nil
	for stageId, stageKind in pairs(CellarPuzzles.STAGE_KINDS) do
		if stageKind == kind then
			expectedStage = stageId
		end
	end
	if not expectedStage or kind == "exit" then
		return state, result(false, "invalid", stage, { message = "unknown_action" })
	end
	if expectedStage ~= stage then
		local expectedIndex = stageIndexOf(cfg, expectedStage)
		if expectedIndex and expectedIndex < state.stageIndex then
			return state, result(false, "already_done", stage)
		end
		return state, result(false, "not_yet", stage)
	end

	local next = table.clone(state)

	if kind == "pickupKey" then
		if not state.key.revealed then
			return state, result(false, "not_yet", stage, { message = "key_hidden" })
		end
		next.key = { revealed = true, held = true, heldBy = userId }
		local advanced, solved = advance(cfg, next, nowMs)
		return advanced,
			result(true, "ok", CellarPuzzles.currentStage(cfg, advanced), { advanced = true, solvedStage = solved, feedback = "key_taken" })
	end

	if kind == "lever" then
		local index = action.index
		if type(index) ~= "number" or index < 1 or index > p.leverCount or index % 1 ~= 0 then
			return state, result(false, "invalid", stage, { message = "lever_index" })
		end
		if state.levers.states[index] then
			return state, result(false, "already_done", stage, { feedback = "lever_already_lit" })
		end
		local expectedIndex = solution.leverOrder[state.levers.progress + 1]
		if index ~= expectedIndex then
			if p.leverResetOnWrongOrder then
				local states = table.create(p.leverCount, false)
				for i = 1, p.leverCount do
					states[i] = false
				end
				next.levers = { states = states, progress = 0, resets = state.levers.resets + 1 }
				return next, result(false, "wrong", stage, { feedback = "sequence_reset" })
			end
			return state, result(false, "wrong", stage, { feedback = "wrong_lever" })
		end
		local states = table.clone(state.levers.states)
		states[index] = true
		next.levers = { states = states, progress = state.levers.progress + 1, resets = state.levers.resets }
		if next.levers.progress >= p.leverCount then
			local advanced, solved = advance(cfg, next, nowMs)
			return advanced,
				result(
					true,
					"ok",
					CellarPuzzles.currentStage(cfg, advanced),
					{ advanced = true, solvedStage = solved, feedback = "mechanisms_awake" }
				)
		end
		return next, result(true, "ok", stage, { feedback = "lever_lit", extra = { progress = next.levers.progress } })
	end

	if kind == "crystals" then
		local value = if action.count ~= nil then action.count else action.value
		if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 99 then
			return state, result(false, "invalid", stage, { message = "count_value" })
		end
		next.crystals = { solved = state.crystals.solved, attempts = state.crystals.attempts + 1 }
		if value == solution.crystalCount then
			next.crystals.solved = true
			local advanced, solved = advance(cfg, next, nowMs)
			return advanced,
				result(
					true,
					"ok",
					CellarPuzzles.currentStage(cfg, advanced),
					{ advanced = true, solvedStage = solved, feedback = "count_right" }
				)
		end
		return next, result(false, "wrong", stage, { feedback = if value < solution.crystalCount then "too_low" else "too_high" })
	end

	if kind == "code" then
		local value = action.value
		if type(value) ~= "string" or #value ~= p.codeDigits or not string.match(value, "^%d+$") then
			return state, result(false, "invalid", stage, { message = "code_value" })
		end
		next.code = { solved = state.code.solved, attempts = state.code.attempts + 1 }
		if value == solution.code then
			next.code.solved = true
			local advanced, solved = advance(cfg, next, nowMs)
			return advanced,
				result(
					true,
					"ok",
					CellarPuzzles.currentStage(cfg, advanced),
					{ advanced = true, solvedStage = solved, feedback = "code_right" }
				)
		end
		local matches = 0
		for i = 1, p.codeDigits do
			if string.sub(value, i, i) == string.sub(solution.code, i, i) then
				matches += 1
			end
		end
		return next, result(false, "wrong", stage, { feedback = "code_wrong", extra = { matches = matches } })
	end

	if kind == "tile" then
		local index = action.index
		if type(index) ~= "number" or index < 1 or index > p.tileRotationPuzzleSize or index % 1 ~= 0 then
			return state, result(false, "invalid", stage, { message = "tile_index" })
		end
		local rotations = table.clone(state.tiles.rotations)
		rotations[index] = (rotations[index] + 1) % 4
		local solvedNow = true
		for _, turns in ipairs(rotations) do
			if turns ~= 0 then
				solvedNow = false
				break
			end
		end
		next.tiles = { rotations = rotations, solved = solvedNow, moves = state.tiles.moves + 1, resets = state.tiles.resets }
		if solvedNow then
			local advanced, solved = advance(cfg, next, nowMs)
			return advanced,
				result(
					true,
					"ok",
					CellarPuzzles.currentStage(cfg, advanced),
					{ advanced = true, solvedStage = solved, feedback = "mosaic_restored" }
				)
		end
		return next, result(true, "ok", stage, { feedback = "tile_turned", extra = { index = index, rotation = rotations[index] } })
	end

	if kind == "release" then
		next.hatchling = { released = true, releasedBy = userId }
		local advanced, solved = advance(cfg, next, nowMs)
		return advanced,
			result(
				true,
				"ok",
				CellarPuzzles.currentStage(cfg, advanced),
				{ advanced = true, solvedStage = solved, feedback = "hatchling_free" }
			)
	end

	return state, result(false, "invalid", stage, { message = "unknown_action" })
end

-- Client-safe projection: visible world facts and progress, never the solution. The visible world
-- (plaque, crystals, notes) is built by the server from the solution and replicates as parts.
function CellarPuzzles.project(cfg: { [string]: any }, state: State): { [string]: any }
	local p = puzzlesConfig(cfg)
	local stage = CellarPuzzles.currentStage(cfg, state)
	local labels = {}
	for index, entry in ipairs(p.leverLabels) do
		labels[index] = { color = entry.color, symbol = entry.symbol, glyph = CellarPuzzles.SYMBOL_GLYPH[entry.symbol] or "?" }
	end
	return {
		stage = stage,
		stageIndex = state.stageIndex,
		order = table.clone(p.order),
		key = { revealed = state.key.revealed, held = state.key.held, heldBy = state.key.heldBy },
		levers = { labels = labels, states = table.clone(state.levers.states), progress = state.levers.progress, count = p.leverCount },
		crystals = { solved = state.crystals.solved, attempts = state.crystals.attempts },
		code = { solved = state.code.solved, attempts = state.code.attempts, digits = p.codeDigits },
		tiles = {
			rotations = table.clone(state.tiles.rotations),
			solved = state.tiles.solved,
			moves = state.tiles.moves,
			size = p.tileRotationPuzzleSize,
		},
		hatchling = { released = state.hatchling.released },
		completedAt = table.clone(state.completedAt),
		copy = CellarPuzzles.COPY[stage] or CellarPuzzles.COPY.done,
	}
end

-- World specification for the server-side builder (solution-derived, server-only): the plaque
-- text, crystal count, and note contents.
function CellarPuzzles.worldSpec(cfg: { [string]: any }, solution: Solution): { [string]: any }
	local p = puzzlesConfig(cfg)
	local plaque = {}
	for _, leverIndex in ipairs(solution.leverOrder) do
		local label = p.leverLabels[leverIndex]
		table.insert(plaque, (CellarPuzzles.SYMBOL_GLYPH[label.symbol] or "?") .. " " .. label.color)
	end
	local notes = {}
	for _, note in ipairs(solution.codeNotes) do
		notes[note.slot] = { numeral = CellarPuzzles.NOTE_NUMERALS[note.position], digit = note.digit, position = note.position }
	end
	return {
		plaqueText = "When the moon rises: " .. table.concat(plaque, ", then "),
		crystalCount = solution.crystalCount,
		notes = notes,
		leverLabels = p.leverLabels,
	}
end

return CellarPuzzles
