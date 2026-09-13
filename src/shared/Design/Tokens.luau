--!strict
-- Design tokens: typography, color, spacing, radius, stroke, shadow, motion, sound semantics, and
-- input prompts. Every component reads these; nothing hard-codes a pixel offset or a colour.
-- Palette and names are original to Search for the Egg. Phase 4 folds the owner's station-button
-- language in (gold bevelled frame, deep teal panel, cream pill label, chunky rounded lettering, leaf
-- accents) so every modal, chip, card, and hotbar slot shares one visual system.

local Tokens = {}

Tokens.color = table.freeze({
	inkStrong = Color3.fromRGB(46, 36, 28),
	ink = Color3.fromRGB(78, 62, 48),
	inkMuted = Color3.fromRGB(139, 121, 103),
	outline = Color3.fromRGB(38, 26, 16), -- chunky cartoon outline
	cream = Color3.fromRGB(252, 246, 234),
	creamDeep = Color3.fromRGB(241, 229, 206),
	creamPill = Color3.fromRGB(255, 241, 200), -- pill label fill
	straw = Color3.fromRGB(226, 191, 108),
	strawDeep = Color3.fromRGB(190, 145, 62),
	goldLight = Color3.fromRGB(255, 220, 92), -- bevel highlight
	gold = Color3.fromRGB(246, 182, 40), -- frame base
	goldDeep = Color3.fromRGB(184, 118, 22), -- bevel shadow
	tealPanel = Color3.fromRGB(20, 78, 92), -- deep teal panel
	tealDeep = Color3.fromRGB(11, 50, 62),
	tealLight = Color3.fromRGB(38, 118, 134),
	sky = Color3.fromRGB(129, 190, 220),
	skyDeep = Color3.fromRGB(70, 136, 176),
	leaf = Color3.fromRGB(116, 170, 92),
	leafBright = Color3.fromRGB(128, 200, 70), -- leaf accents
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

-- Class card accent colours keyed by rarity band (weight thresholds resolved by the classes modal).
Tokens.rarity = table.freeze({
	common = table.freeze({ fill = Color3.fromRGB(96, 178, 236), deep = Color3.fromRGB(40, 110, 176) }),
	uncommon = table.freeze({ fill = Color3.fromRGB(128, 200, 70), deep = Color3.fromRGB(64, 128, 44) }),
	rare = table.freeze({ fill = Color3.fromRGB(255, 208, 48), deep = Color3.fromRGB(196, 132, 12) }),
	epic = table.freeze({ fill = Color3.fromRGB(176, 88, 236), deep = Color3.fromRGB(104, 40, 160) }),
	legendary = table.freeze({ fill = Color3.fromRGB(255, 120, 60), deep = Color3.fromRGB(176, 56, 20) }),
})

Tokens.typography = table.freeze({
	display = table.freeze({ font = Enum.Font.FredokaOne, size = 34, lineHeight = 1.05 }),
	title = table.freeze({ font = Enum.Font.FredokaOne, size = 24, lineHeight = 1.1 }),
	label = table.freeze({ font = Enum.Font.FredokaOne, size = 18, lineHeight = 1.1 }), -- pill labels / station names
	heading = table.freeze({ font = Enum.Font.GothamBold, size = 18, lineHeight = 1.15 }),
	body = table.freeze({ font = Enum.Font.GothamMedium, size = 15, lineHeight = 1.3 }),
	caption = table.freeze({ font = Enum.Font.Gotham, size = 13, lineHeight = 1.3 }),
	numeral = table.freeze({ font = Enum.Font.GothamBlack, size = 20, lineHeight = 1.0 }),
	minimumBodySize = 13,
})

Tokens.spacing = table.freeze({ xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 32 })

Tokens.radius = table.freeze({ sm = 6, md = 10, lg = 16, xl = 22, pill = 999 })

Tokens.stroke = table.freeze({ hairline = 1, standard = 2, bold = 3, frame = 4 })

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

-- Owner-supplied motion recipes (docs/HANDOFF_PHASE4.md). Each recipe names its easing style and
-- direction as strings so tests can assert on them; Motion.recipe resolves the TweenInfo and applies
-- the tween cap / reduced-motion scale.
Tokens.recipes = table.freeze({
	hover = table.freeze({ seconds = 0.18, style = "Back", direction = "Out", scale = 1.05 }),
	press = table.freeze({ seconds = 0.08, style = "Sine", direction = "In", scale = 0.94 }),
	release = table.freeze({ seconds = 0.4, style = "Elastic", direction = "Out", scale = 1 }),
	panelOpen = table.freeze({ seconds = 0.45, style = "Back", direction = "Out", fromScale = 0.82 }),
	panelFadeIn = table.freeze({ seconds = 0.3, style = "Quad", direction = "Out" }),
	panelClose = table.freeze({ seconds = 0.3, style = "Quad", direction = "In", toScale = 0.86 }),
	panelFadeOut = table.freeze({ seconds = 0.25, style = "Quad", direction = "In" }),
	blurIn = table.freeze({ seconds = 0.3, style = "Quad", direction = "Out", size = 14 }),
	blurOut = table.freeze({ seconds = 0.25, style = "Quad", direction = "In" }),
	notifyGrow = table.freeze({ seconds = 0.4, style = "Back", direction = "Out", fromScale = 0.6 }),
	notifyPop = table.freeze({ seconds = 0.45, style = "Elastic", direction = "Out", scale = 1.06 }),
	notifyShrink = table.freeze({ seconds = 0.28, style = "Quad", direction = "In", toScale = 0.7 }),
	rotationKick = table.freeze({ seconds = 0.1, style = "Sine", direction = "Out", degrees = 9 }),
	rotationSettle = table.freeze({ seconds = 0.45, style = "Elastic", direction = "Out" }),
	ripple = table.freeze({ seconds = 0.4, style = "Quad", direction = "Out", scale = 2.4 }),
	countUp = table.freeze({ seconds = 0.45, style = "Quad", direction = "Out" }),
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
	rewardLand = "reward.land",
	rollSpin = "class.spin",
	rollLand = "class.land",
	collectTug = "collect.tug",
	collectRelease = "collect.release",
	bagFull = "collect.bagFull",
	sellArc = "sell.arc",
	sellTick = "sell.tick",
	sellBurst = "sell.burst",
	upgradeChord = "upgrade.chord",
	eggChime = "egg.chime",
	eggClaimHold = "egg.claimHold",
	victoryStem = "victory.stem",
	countdownTick = "round.countdownTick",
	countdownGo = "round.countdownGo",
	stationHum = "station.hum",
	stationChime = "station.chime",
	partyReady = "party.ready",
})

-- Input prompt glyph keys per input mode; prompts swap without rebuilding UI.
Tokens.prompts = table.freeze({
	mouse = table.freeze({ primary = "LMB", interact = "E", cancel = "Esc", back = "Esc", menu = "Tab" }),
	touch = table.freeze({ primary = "Tap", interact = "Tap", cancel = "Close", back = "Back", menu = "Tap" }),
	gamepad = table.freeze({ primary = "RT", interact = "X", cancel = "B", back = "B", menu = "Y" }),
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
	stationButtonPx = 64, -- lobby station rail buttons (square, >= tap target)
	cardMaxWidthPx = 560,
	cardMaxHeightFraction = 0.9, -- of the viewport; content scrolls inside
})

Tokens.zIndex = table.freeze({ world = 1, hud = 10, toast = 20, modal = 30, blocking = 40, prompt = 50 })

return Tokens
