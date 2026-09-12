--!strict
-- Configurable unlock policies. Services never write `wins >= 1`; they evaluate the policy object
-- from SYSTEM_CONFIG.chapters.<chapter>.<difficulty>Unlock against a profile's progression.

local UnlockPolicy = {}

export type Policy = { type: string, chapter: string?, difficulty: string?, count: number? }

export type Progression = {
	chapterWins: { [string]: { [string]: number } },
}

function UnlockPolicy.evaluate(policy: Policy, progression: Progression): boolean
	if policy.type == "always" then
		return true
	elseif policy.type == "chapterWins" then
		local chapter = progression.chapterWins[policy.chapter :: string]
		local wins = chapter and chapter[policy.difficulty :: string] or 0
		return wins >= (policy.count or 1)
	end
	error("UnlockPolicy: unknown policy type " .. tostring(policy.type))
end

-- Recomputes every chapter/difficulty unlock from wins. Old saved booleans are never trusted alone.
function UnlockPolicy.recompute(
	chapters: { [string]: any },
	progression: Progression
): ({ [string]: boolean }, { [string]: { [string]: boolean } })
	local unlockedChapters: { [string]: boolean } = {}
	local unlockedDifficulties: { [string]: { [string]: boolean } } = {}
	for chapterKey, chapter in pairs(chapters) do
		local normal = UnlockPolicy.evaluate(chapter.normalUnlock, progression)
		local hard = UnlockPolicy.evaluate(chapter.hardUnlock, progression)
		unlockedChapters[chapterKey] = normal or hard
		unlockedDifficulties[chapterKey] = { normal = normal, hard = hard }
	end
	return unlockedChapters, unlockedDifficulties
end

-- Party start validation: default policy requires every member to own the destination unlock.
function UnlockPolicy.partyCanStart(
	chapters: { [string]: any },
	chapterKey: string,
	difficulty: string,
	memberProgressions: { Progression }
): (boolean, { number })
	local chapter = chapters[chapterKey]
	if not chapter then
		return false, {}
	end
	local policy = if difficulty == "hard" then chapter.hardUnlock else chapter.normalUnlock
	local lockedIndexes: { number } = {}
	for index, progression in ipairs(memberProgressions) do
		if not UnlockPolicy.evaluate(policy, progression) then
			table.insert(lockedIndexes, index)
		end
	end
	return #lockedIndexes == 0, lockedIndexes
end

return UnlockPolicy
