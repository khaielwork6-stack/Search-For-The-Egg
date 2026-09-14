--!strict
-- Copy for round upgrades shared by the workbench modal and the upgrade book: a title and a
-- one-line value description per path, a tagline per tool, and a short story per path.

local UpgradeCopy = {}

local function seconds(value: number?): string
	return if value then string.format("%.2fs", value) else "-"
end

export type Label = { title: string, describe: (any) -> string, story: string?, icon: string? }

UpgradeCopy.LABELS = {
	bag = {
		title = "Bag capacity",
		story = "Carry more before the walk back to the crate.",
		icon = "icon.feather",
		describe = function(entry)
			return entry and (tostring(entry.capacity) .. " feathers") or "-"
		end,
	},
	handGrasp = {
		title = "Grasp",
		story = "A firmer grip on every pull.",
		icon = "tool.hand.normal",
		describe = function(entry)
			return entry and (tostring(entry.amount) .. " per pull") or "-"
		end,
	},
	handSpeed = {
		title = "Speed",
		story = "Quicker legs between the nest and the crate.",
		icon = "hud.timer",
		describe = function(entry)
			return entry and (tostring(entry.walkSpeed) .. " walk") or "-"
		end,
	},
	handHold = {
		title = "Hold",
		story = "Hold to gather feathers continuously.\nCLICK  →  HOLD",
		icon = "tool.hand.normal",
		describe = function(entry)
			if not entry or not entry.enabled then
				return "off"
			end
			return "every " .. seconds(entry.intervalSeconds)
		end,
	},
	["nestRake.sweep"] = {
		title = "Sweep",
		story = "More feathers in every rake.",
		icon = "tool.nestRake.normal",
		describe = function(entry)
			return entry and (tostring(entry.yield) .. " per sweep") or "-"
		end,
	},
	["nestRake.cooldown"] = {
		title = "Cooldown",
		story = "Less waiting between sweeps.",
		icon = "hud.timer",
		describe = function(entry)
			return entry and seconds(entry.seconds) or "-"
		end,
	},
	["nestRake.hold"] = {
		title = "Hold",
		story = "Hold to keep raking.",
		icon = "tool.nestRake.normal",
		describe = function(entry)
			if not entry or not entry.enabled then
				return "off"
			end
			return "every " .. seconds(entry.intervalSeconds)
		end,
	},
	["confettiCharge.luckyBlast"] = {
		title = "Lucky Blast",
		story = "Blasts can shake loose Rainbow Feathers.",
		icon = "hud.gem",
		describe = function(entry)
			return entry and string.format("%d%% rainbow", math.floor(entry.rainbowChance * 100 + 0.5)) or "-"
		end,
	},
	["confettiCharge.speed"] = {
		title = "Speed",
		story = "A shorter fuse.",
		icon = "hud.timer",
		describe = function(entry)
			return entry and (seconds(entry.fuseSeconds) .. " fuse") or "-"
		end,
	},
	["confettiCharge.power"] = {
		title = "Power",
		story = "A wider crater, more feathers.",
		icon = "tool.confettiCharge.normal",
		describe = function(entry)
			return entry and string.format("%d studs, %d feathers", entry.radiusStuds, entry.yield) or "-"
		end,
	},
	["featherVac.power"] = {
		title = "Power",
		story = "Stronger suction.",
		icon = "tool.featherVac.normal",
		describe = function(entry)
			return entry and (tostring(entry.perSecond) .. " per second") or "-"
		end,
	},
	["featherVac.cooling"] = {
		title = "Cooling",
		story = "Cools down faster after a run.",
		icon = "hud.timer",
		describe = function(entry)
			return entry and seconds(entry.seconds) or "-"
		end,
	},
	["featherVac.runtime"] = {
		title = "Runtime",
		story = "Runs longer before it overheats.",
		icon = "tool.featherVac.normal",
		describe = function(entry)
			return entry and seconds(entry.seconds) or "-"
		end,
	},
	["scoutChick.speed"] = {
		title = "Speed",
		story = "A quicker chick.",
		icon = "tool.scoutChick.normal",
		describe = function(entry)
			return entry and (tostring(entry.value) .. " studs/s") or "-"
		end,
	},
	["scoutChick.grasp"] = {
		title = "Grasp",
		story = "More feathers per peck.",
		icon = "tool.scoutChick.normal",
		describe = function(entry)
			return entry and (tostring(entry.value) .. " per peck") or "-"
		end,
	},
	["scoutChick.capacity"] = {
		title = "Capacity",
		story = "Carries more each trip.",
		icon = "tool.scoutChick.normal",
		describe = function(entry)
			return entry and (tostring(entry.value) .. " feathers") or "-"
		end,
	},
} :: { [string]: Label }

-- One line per tool for the acquisition row; the paths describe themselves once the tool is owned.
UpgradeCopy.TOOL_TAGLINES = {
	nestRake = "Sweeps several feathers in one pull",
	confettiCharge = "Blasts a patch of the nest loose",
	featherVac = "Hoovers feathers while it runs",
	scoutChick = "A chick that pecks feathers for you",
} :: { [string]: string }

return UpgradeCopy
