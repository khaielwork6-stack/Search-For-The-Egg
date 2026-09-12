--!strict
-- Pure modal ownership reducer (STATE_MACHINES.md section 13). At most one blocking modal owns
-- focus; a higher-priority modal suspends the current one and restores it on close. Lower
-- priority is a smaller number here (1 = platform purchase prompt, highest).

local ModalReducer = {}

export type ModalEntry = { id: string, priority: number, blocking: boolean }

export type ModalState = {
	stack: { ModalEntry }, -- bottom .. top; top owns focus
	focusReturn: string?, -- id to restore focus to after the top closes
	version: number,
}

ModalReducer.Priority = table.freeze({
	PurchasePrompt = 1,
	Connection = 2,
	Results = 3,
	Party = 4,
	Shop = 5,
	Tutorial = 6,
	Ambient = 7,
})

ModalReducer.Errors = table.freeze({
	ALREADY_OPEN = "already_open",
	NOT_OPEN = "not_open",
	BLOCKED = "blocked_by_higher_priority",
})

function ModalReducer.create(): ModalState
	return { stack = {}, focusReturn = nil, version = 1 }
end

local function bump(state: ModalState, patch: { [string]: any }): ModalState
	local next = table.clone(state) :: any
	for key, value in pairs(patch) do
		next[key] = value
	end
	next.version = state.version + 1
	return next
end

function ModalReducer.top(state: ModalState): ModalEntry?
	return state.stack[#state.stack]
end

function ModalReducer.isOpen(state: ModalState, id: string): boolean
	for _, entry in ipairs(state.stack) do
		if entry.id == id then
			return true
		end
	end
	return false
end

-- Opening rules: equal-or-higher priority (smaller number or same) stacks on top and takes focus;
-- lower priority than the current blocking top is refused (BLOCKED) so a shop cannot cover results.
function ModalReducer.open(state: ModalState, entry: ModalEntry): (ModalState?, string?)
	if ModalReducer.isOpen(state, entry.id) then
		return nil, ModalReducer.Errors.ALREADY_OPEN
	end
	local top = ModalReducer.top(state)
	if top and top.blocking and entry.priority > top.priority then
		return nil, ModalReducer.Errors.BLOCKED
	end
	local stack = table.clone(state.stack)
	table.insert(stack, { id = entry.id, priority = entry.priority, blocking = entry.blocking })
	return bump(state, { stack = stack, focusReturn = top and top.id or false }), nil
end

function ModalReducer.close(state: ModalState, id: string): (ModalState?, string?)
	local index: number? = nil
	for i, entry in ipairs(state.stack) do
		if entry.id == id then
			index = i
		end
	end
	if not index then
		return nil, ModalReducer.Errors.NOT_OPEN
	end
	local stack = table.clone(state.stack)
	table.remove(stack, index)
	local newTop = stack[#stack]
	return bump(state, { stack = stack, focusReturn = newTop and newTop.id or false }), nil
end

function ModalReducer.closeAll(state: ModalState): ModalState
	return bump(state, { stack = {}, focusReturn = false })
end

-- True while any blocking modal is open: gameplay/movement input should be suspended.
function ModalReducer.isBlocking(state: ModalState): boolean
	for _, entry in ipairs(state.stack) do
		if entry.blocking then
			return true
		end
	end
	return false
end

function ModalReducer.normalize(state: ModalState): ModalState
	local out = table.clone(state) :: any
	if out.focusReturn == false then
		out.focusReturn = nil
	end
	return out
end

return ModalReducer
