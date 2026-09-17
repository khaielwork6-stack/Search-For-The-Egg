--!strict
-- What happens next, in one line, for a player in the lobby. Pure: the client feeds it the replicated
-- state it already has (round phase, session phase, the party projection and its countdown) and draws
-- the result in the HUD pill and on the barn-door board. `hidden` means a round owns the banner.

local NextRoundStatus = {}

export type State = "hidden" | "loading" | "noParty" | "waiting" | "full" | "countdown" | "teleporting" | "returning"

export type Input = {
	roundPhase: string?,
	sessionPhase: string?,
	party: { [string]: any }?,
	countdownRemaining: number?,
	localUserId: number,
	maxPartyPlayers: number,
	onPad: boolean?,
}

export type Status = { state: State, title: string, detail: string? }

-- Round phases in which the lobby is what the player is looking at.
local LOBBY_ROUND_PHASES: { [string]: boolean } = { Lobby = true, Returning = true, Abandoned = true }

function NextRoundStatus.inRound(roundPhase: string?): boolean
	return roundPhase ~= nil and not LOBBY_ROUND_PHASES[roundPhase]
end

-- "0:07" (whole seconds, rounded up so the clock never reads 0 while time remains).
function NextRoundStatus.formatClock(seconds: number): string
	local whole = math.max(0, math.ceil(seconds - 1e-6))
	return string.format("%d:%02d", math.floor(whole / 60), whole % 60)
end

function NextRoundStatus.resolve(input: Input): Status
	if NextRoundStatus.inRound(input.roundPhase) then
		return { state = "hidden", title = "" }
	end
	if input.roundPhase == "Returning" then
		return { state = "returning", title = "Heading back to the farmyard..." }
	end
	local sessionPhase = input.sessionPhase
	if sessionPhase == nil or sessionPhase == "LoadingProfile" or sessionPhase == "LoadRetry" then
		return { state = "loading", title = "Loading your nest..." }
	end
	local party = input.party
	if sessionPhase == "Teleporting" or sessionPhase == "Round" or sessionPhase == "RejoinReserved" then
		return { state = "teleporting", title = "Teleporting to the nest..." }
	end
	if sessionPhase == "Results" then
		return { state = "hidden", title = "" }
	end
	if not party or party.phase == "Closed" then
		return { state = "noParty", title = "Stand on a nest pad to start a search" }
	end
	local phase = party.phase
	if phase == "Reserving" or phase == "Teleporting" then
		return { state = "teleporting", title = "Teleporting to the nest..." }
	end
	if phase == "Countdown" then
		local remaining = input.countdownRemaining
		if remaining ~= nil and remaining <= 0 then
			return { state = "teleporting", title = "Teleporting to the nest..." }
		end
		return {
			state = "countdown",
			title = "Search starts in " .. NextRoundStatus.formatClock(remaining or 0),
			detail = if input.onPad == false then nil else "Stay on the pad",
		}
	end
	local members = #(party.members or {})
	local max = tonumber(party.maxMembers) or input.maxPartyPlayers
	local leader = party.leaderUserId == input.localUserId
	if party.valid == false then
		return {
			state = "waiting",
			title = string.format("Waiting for players %d/%d", members, max),
			detail = "Not everyone can enter this nest yet",
		}
	end
	if members >= max then
		return {
			state = "full",
			title = string.format("Party full %d/%d", members, max),
			detail = if input.onPad then "Search starts in a moment" else "Ready when the leader starts",
		}
	end
	local detail
	if input.onPad then
		detail = if leader then "Starts when full, or Set off at the sign" else "Starts when full or the leader sets off"
	else
		detail = if leader then "Start the search when you're ready" else "The leader starts the search"
	end
	return { state = "waiting", title = string.format("Waiting for players %d/%d", members, max), detail = detail }
end

return NextRoundStatus
