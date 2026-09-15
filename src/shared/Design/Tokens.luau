--!strict
-- Design tokens: typography, color, spacing, radius, stroke, shadow, motion, sound semantics, and
-- input prompts. Every component reads these; nothing hard-codes a pixel offset or a colour.
-- Palette and names are original to Search for the Egg. Phase 4 folds the owner's station-button
-- language in (gold bevelled frame, deep teal panel, cream pill label, chunky rounded lettering, leaf
-- accents) so every modal, chip, card, and hotbar slot shares one visual system.

local Tokens = {}

Tokens.color = table.freeze({
	-- Ink (soft browns) for all text on cream.
	inkStrong = Color3.fromRGB(64, 44, 30),
	ink = Color3.fromRGB(92, 68, 48),
	inkMuted = Color3.fromRGB(150, 128, 106),
	outline = Color3.fromRGB(88, 58, 34), -- soft cocoa outline (chunky, never black)
	cocoa = Color3.fromRGB(122, 84, 52),
	-- Cream and feather-white surfaces.
	cream = Color3.fromRGB(252, 246, 234),
	creamDeep = Color3.fromRGB(241, 229, 206),
	creamPill = Color3.fromRGB(255, 243, 208),
	featherWhite = Color3.fromRGB(255, 253, 248),
	panel = Color3.fromRGB(253, 248, 238), -- modal / card panel fill
	panelDeep = Color3.fromRGB(245, 235, 216), -- panel gradient foot
	surface = Color3.fromRGB(255, 252, 245),
	surfaceAlt = Color3.fromRGB(247, 238, 222),
	-- Golden yellow (frames, primary actions, highlights).
	straw = Color3.fromRGB(230, 196, 112),
	strawDeep = Color3.fromRGB(194, 150, 66),
	honey = Color3.fromRGB(255, 205, 66),
	goldLight = Color3.fromRGB(255, 226, 110),
	gold = Color3.fromRGB(246, 184, 44),
	goldDeep = Color3.fromRGB(196, 130, 26),
	-- Teal: small accents only (tabs, selected rings, badges).
	tealPanel = Color3.fromRGB(38, 118, 134),
	tealDeep = Color3.fromRGB(22, 84, 98),
	tealLight = Color3.fromRGB(78, 170, 184),
	tealAccent = Color3.fromRGB(46, 140, 156),
	tealTint = Color3.fromRGB(224, 242, 244),
	sky = Color3.fromRGB(129, 190, 220),
	skyDeep = Color3.fromRGB(70, 136, 176),
	leaf = Color3.fromRGB(116, 170, 92),
	leafBright = Color3.fromRGB(128, 200, 70),
	leafDeep = Color3.fromRGB(74, 128, 60),
	ember = Color3.fromRGB(232, 122, 74),
	emberDeep = Color3.fromRGB(190, 82, 44),
	gem = Color3.fromRGB(122, 96, 220),
	gemDeep = Color3.fromRGB(86, 62, 176),
	overlay = Color3.fromRGB(46, 32, 20),
	shadow = Color3.fromRGB(70, 48, 28),
	success = Color3.fromRGB(96, 168, 90),
	warning = Color3.fromRGB(222, 158, 44),
	danger = Color3.fromRGB(204, 82, 66),
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

Tokens.radius = table.freeze({ sm = 8, md = 12, lg = 18, xl = 26, pill = 999 })

Tokens.stroke = table.freeze({ hairline = 1, standard = 2, bold = 3, frame = 4 })

Tokens.shadow = table.freeze({
	soft = table.freeze({ transparency = 0.86, offset = 3 }),
	lifted = table.freeze({ transparency = 0.78, offset = 6 }),
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
	-- Rebuilt UI recipes: attention pulse (only when useful), toast slide, error shake, sheen sweep.
	pulse = table.freeze({ seconds = 0.45, style = "Sine", direction = "InOut", scale = 1.05 }),
	toastSlide = table.freeze({ seconds = 0.34, style = "Back", direction = "Out" }),
	shake = table.freeze({ seconds = 0.36, style = "Elastic", direction = "Out", degrees = 3 }),
	sheen = table.freeze({ seconds = 0.45, style = "Sine", direction = "InOut" }),
	lift = table.freeze({ seconds = 0.22, style = "Quad", direction = "Out" }),
})

-- Semantic sound roles (owner ids mapped in AudioDirector, 13 Sep 2026). Actual asset ids resolve through AudioDirector's manifest so UI code never
-- references an asset id. PLACEHOLDER: manifest ids are stand-ins until Phase 6 audio pass.
Tokens.sound = table.freeze({
	uiTap = "ui.tap",
	uiConfirm = "ui.confirm",
	uiCancel = "ui.cancel",
	uiOpen = "ui.open",
	uiClose = "ui.close",
	uiToast = "ui.toast",
	uiError = "ui.error",
	uiHover = "ui.hover",
	uiTab = "ui.tab",
	uiSwitch = "ui.switch",
	uiSelect = "ui.select",
	uiConfetti = "ui.confetti",
	uiPop = "ui.pop",
	uiPageFlip = "ui.pageFlip",
	purchase = "shop.purchase",
	rewardTick = "reward.tick",
	rewardLand = "reward.land",
	rollSpin = "class.spin",
	rollLand = "class.land",
	collectTug = "collect.tug",
	collectRelease = "collect.release",
	collectRainbow = "collect.rainbow",
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
	-- Tool feel (viewmodels, projectiles, blasts). PLACEHOLDER built-ins until the owner supplies ids.
	rakeSwing = "tool.rakeSwing",
	rakeImpact = "tool.rakeImpact",
	fuseLight = "tool.fuseLight",
	fuseHiss = "tool.fuseHiss",
	throw = "tool.throw",
	blast = "tool.blast",
	vacMotor = "tool.vacMotor",
	vacSuck = "tool.vacSuck",
	chickChirp = "tool.chickChirp",
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

Tokens.zIndex = table.freeze({ world = 1, hud = 10, toast = 20, modal = 30, blocking = 40, prompt = 50, veil = 60 })

-- Icon glyph sizes (vector icons drawn from frames; see UI/Components/Icons).
Tokens.icon = table.freeze({ sm = 16, md = 22, lg = 32 })

return Tokens
