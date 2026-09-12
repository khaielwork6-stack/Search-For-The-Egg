--!strict
-- Server-approved objective/tutorial state ids (MASTER_SPEC section 7). The server advances a
-- player's step; the client maps ids to localized copy. Copy here is original placeholder English
-- (PLACEHOLDER owner: Phase 6 localization pass).

local Objectives = {}

Objectives.STEPS = table.freeze({
	"enter_party",
	"collect_25",
	"sell_first_bag",
	"buy_first_upgrade",
	"search_for_egg",
	"claim_or_complete_round",
})

Objectives.COMPLETE = "complete"

local ORDER: { [string]: number } = {}
for index, id in ipairs(Objectives.STEPS) do
	ORDER[id] = index
end

Objectives.COPY = table.freeze({
	enter_party = table.freeze({ title = "Step onto the henhouse path", detail = "Walk to the glowing doorway and press Interact" }),
	collect_25 = table.freeze({ title = "Gather 25 feathers", detail = "Click or tap the nest to pull feathers into your bag" }),
	sell_first_bag = table.freeze({ title = "Sell your bag", detail = "Carry your feathers to the trading crate" }),
	buy_first_upgrade = table.freeze({ title = "Buy your first upgrade", detail = "Visit the workbench and improve your grasp or bag" }),
	search_for_egg = table.freeze({ title = "Search the nest for the Egg", detail = "Keep clearing. Any patch could hide it" }),
	claim_or_complete_round = table.freeze({ title = "Claim the Egg!", detail = "Hold Interact on the Egg before anyone else" }),
	complete = table.freeze({ title = "Round complete", detail = "Securing rewards..." }),
})

function Objectives.isStep(id: any): boolean
	return type(id) == "string" and ORDER[id] ~= nil
end

function Objectives.indexOf(id: string): number
	return ORDER[id] or 0
end

-- Next step after `id`, or COMPLETE after the last step.
function Objectives.next(id: string): string
	local index = ORDER[id]
	if not index then
		return Objectives.STEPS[1]
	end
	return Objectives.STEPS[index + 1] or Objectives.COMPLETE
end

-- First step not yet completed for this tutorial version, or COMPLETE.
function Objectives.resume(completedSteps: { [string]: boolean }, completed: boolean): string
	if completed then
		return Objectives.COMPLETE
	end
	for _, id in ipairs(Objectives.STEPS) do
		if not completedSteps[id] then
			return id
		end
	end
	return Objectives.COMPLETE
end

-- A step may only complete when it is the current step (strict ordering).
function Objectives.canComplete(current: string, id: string): boolean
	return current == id
end

return Objectives
