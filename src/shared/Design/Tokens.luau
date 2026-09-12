--!strict
-- Design tokens: typography, color, spacing, radius, stroke, shadow, motion, sound semantics, and
-- input prompts. Every component reads these; nothing hard-codes a pixel offset or a colour.
-- Palette and names are original to Search for the Egg (warm henhouse light, straw, sky, egg cream).

local Tokens = {}

Tokens.color = table.freeze({
	inkStrong = Color3.fromRGB(46, 36, 28),
	ink = Color3.fromRGB(78, 62, 48),
	inkMuted = Color3.fromRGB(139, 121, 103),
	cream = Color3.fromRGB(252, 246, 234),
	creamDeep = Color3.fromRGB(241, 229, 206),
	straw = Color3.fromRGB(226, 191, 108),
	strawDeep = Color3.fromRGB(190, 145, 62),
	sky = Color3.fromRGB(129, 190, 220),
	skyDeep = Color3.fromRGB(70, 136, 176),
	leaf = Color3.fromRGB(116, 170, 92),
	leafDeep = Color3.fromRGB(74, 128, 60),
	ember = Color3.fromRGB(228, 117, 70),
	emberDeep = Color3.fromRGB(184, 78, 42),
	gem = Color3.fromRGB(122, 96, 220),
	gemDeep = Color3.fromRGB(86, 62, 176),
	surface = Color3.fromRGB(255, 252, 245),
	surfaceAlt = Color3.fromRGB(247, 238, 222),
	overlay = Color3.fromRGB(20, 14, 10),
	success = Color3.fromRGB(88, 160, 84),
	warning = Color3.fromRGB(214, 150, 40),
	danger = Color3.fromRGB(196, 74, 62),
})

Tokens.typography = table.freeze({
	display = table.freeze({ font = Enum.Font.FredokaOne, size = 34, lineHeight = 1.05 }),
	title = table.freeze({ font = Enum.Font.FredokaOne, size = 24, lineHeight = 1.1 }),
	heading = table.freeze({ font = Enum.Font.GothamBold, size = 18, lineHeight = 1.15 }),
	body = table.freeze({ font = Enum.Font.GothamMedium, size = 15, lineHeight = 1.3 }),
	caption = table.freeze({ font = Enum.Font.Gotham, size = 13, lineHeight = 1.3 }),
	numeral = table.freeze({ font = Enum.Font.GothamBlack, size = 20, lineHeight = 1.0 }),
	minimumBodySize = 13,
})

Tokens.spacing = table.freeze({ xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 32 })

Tokens.radius = table.freeze({ sm = 6, md = 10, lg = 16, pill = 999 })

Tokens.stroke = table.freeze({ hairline = 1, standard = 2, bold = 3 })

Tokens.shadow = table.freeze({
	soft = table.freeze({ transparency = 0.82, offset = 3 }),
	lifted = table.freeze({ transparency = 0.7, offset = 6 }),
})

-- Motion durations are capped by polishBudgets.maximumUiTweenSeconds at runtime (Motion module).
Tokens.motion = table.freeze({
	instant = 0.08,
	quick = 0.16,
	standard = 0.24,
	slow = 0.34,
	pressScale = 0.96,
	hoverScale = 1.03,
	popOvershoot = 1.08,
	easeOut = Enum.EasingStyle.Quint,
	easeInOut = Enum.EasingStyle.Sine,
	easeBack = Enum.EasingStyle.Back,
})

-- Semantic sound roles. Actual asset ids resolve through AudioDirector's manifest so UI code never
-- references an asset id. PLACEHOLDER: manifest ids are stand-ins until Phase 6 audio pass.
Tokens.sound = table.freeze({
	uiTap = "ui.tap",
	uiConfirm = "ui.confirm",
	uiCancel = "ui.cancel",
	uiOpen = "ui.open",
	uiClose = "ui.close",
	uiToast = "ui.toast",
	uiError = "ui.error",
	rewardTick = "reward.tick",
})

-- Input prompt glyph keys per input mode; prompts swap without rebuilding UI.
Tokens.prompts = table.freeze({
	mouse = table.freeze({ primary = "LMB", interact = "E", cancel = "Esc", back = "Esc" }),
	touch = table.freeze({ primary = "Tap", interact = "Tap", cancel = "Close", back = "Back" }),
	gamepad = table.freeze({ primary = "RT", interact = "X", cancel = "B", back = "B" }),
})

Tokens.layout = table.freeze({
	minimumTapTargetPx = 44, -- mirrored from polishBudgets.minimumTapTargetPixels; asserted at boot
	phoneShortEdgePx = 480, -- short viewport edge below this = phone (iPhone landscape is ~360-430)
	tabletShortEdgePx = 1100, -- short edge below this with a squarer aspect = tablet
	tabletMaxAspect = 1.6, -- wider than this is a desktop/laptop window
	safeAreaPaddingPx = 12,
	phoneUiScale = 0.86,
	tabletUiScale = 0.94,
	desktopUiScale = 1,
})

Tokens.zIndex = table.freeze({ world = 1, hud = 10, toast = 20, modal = 30, blocking = 40, prompt = 50 })

return Tokens
