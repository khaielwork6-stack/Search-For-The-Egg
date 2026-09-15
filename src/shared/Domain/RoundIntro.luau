--!strict
-- The round intro's pure parts: what the poster says, which shot is on screen at a given moment, and
-- which subtitle line is showing. Kept out of the client controller so the timing and the wording can
-- be unit-tested headlessly, and so the reward printed on the flyer is derived from the round being
-- played rather than written down anywhere.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local EconomyMath = require(Shared.EconomyMath)

local RoundIntro = {}

export type Shot = { marker: string, at: number, seconds: number, push: number }
export type Beat = { at: number, text: string }

-- The cash prize for finishing this chapter on this difficulty, formatted for the flyer. This is the
-- same arithmetic VictoryService pays out with (dollars -> cents -> difficulty multiplier), so the
-- poster cannot promise a number the round does not award.
function RoundIntro.rewardCents(config: { [string]: any }, chapter: string, difficulty: string): number
	local entry = config.chapters[chapter]
	if not entry then
		return 0
	end
	local rewards = if difficulty == "hard" then entry.hardRewards else entry.normalRewards
	local multiplier = (config.difficulty[difficulty] and config.difficulty[difficulty].rewardMultiplier) or 1
	return EconomyMath.roundHalfUp(EconomyMath.dollarsToCents(rewards.cash) * multiplier)
end

function RoundIntro.rewardText(config: { [string]: any }, chapter: string, difficulty: string): string
	return EconomyMath.formatCents(RoundIntro.rewardCents(config, chapter, difficulty))
end

-- The three lines of the flyer, with the live reward substituted in.
function RoundIntro.posterLines(config: { [string]: any }, chapter: string, difficulty: string): { string }
	local poster = config.round.intro.poster
	return {
		poster.title,
		poster.subtitle,
		poster.rewardPrefix .. RoundIntro.rewardText(config, chapter, difficulty),
		poster.footer,
	}
end

-- The shot covering `t` seconds into the intro, and how far through its move it is. Before the first
-- shot starts the first shot is used at 0; after the last one ends it is held at 1, so a clock that
-- overruns never falls off the end of the list.
function RoundIntro.shotAt(shots: { Shot }, t: number): (Shot?, number)
	if #shots == 0 then
		return nil, 0
	end
	local chosen = shots[1]
	for _, shot in ipairs(shots) do
		if t >= shot.at then
			chosen = shot
		end
	end
	local span = math.max(0.0001, chosen.seconds)
	return chosen, math.clamp((t - chosen.at) / span, 0, 1)
end

-- The subtitle showing at `t`, and how much of it has been typed (0..1). A line stays up until the
-- next one starts, and the last line stays to the end.
function RoundIntro.subtitleAt(beats: { Beat }, t: number, charactersPerSecond: number): (string?, number)
	local current: Beat? = nil
	for _, beat in ipairs(beats) do
		if t >= beat.at then
			current = beat
		end
	end
	if not current then
		return nil, 0
	end
	local line = current :: Beat
	local typed = (t - line.at) * math.max(1, charactersPerSecond)
	return line.text, math.clamp(typed / math.max(1, #line.text), 0, 1)
end

-- How much of a line to show for a reveal fraction, on whole characters.
function RoundIntro.typedText(text: string, fraction: number): string
	local count = math.floor(#text * math.clamp(fraction, 0, 1) + 0.5)
	return string.sub(text, 1, count)
end

-- Where the walking actor should stand at `t`: a straight walk from the start mark to the stand mark
-- over `walkSeconds`, eased so it does not start or stop abruptly, then held.
function RoundIntro.actorAlpha(actor: { [string]: any }, t: number): number
	local span = math.max(0.0001, actor.walkSeconds)
	local raw = math.clamp((t - actor.walkAt) / span, 0, 1)
	-- Smoothstep: no instant acceleration at either end.
	return raw * raw * (3 - 2 * raw)
end

-- Total run time, taken from the last shot rather than the declared duration, so a shot list that
-- runs past `durationSeconds` is still played to its end instead of being cut off.
function RoundIntro.duration(config: { [string]: any }): number
	local intro = config.round.intro
	local last = 0
	for _, shot in ipairs(intro.shots) do
		last = math.max(last, shot.at + shot.seconds)
	end
	return math.max(intro.durationSeconds, last)
end

return RoundIntro
