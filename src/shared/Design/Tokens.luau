--!strict
-- Design tokens: typography, color, depth, spacing, radius, stroke, shadow, motion, sound semantics,
-- and input prompts. Every component reads these; nothing hard-codes a pixel offset or a colour.
--
-- Rebuilt 15 Sep 2026 after the owner called the UI flat, bland and obviously generated, with a
-- premium pack ("USE") supplied as the quality bar. What was taken from it is technique, not theme:
--
--   * a control is an extrusion, not a rectangle - a dark base with the face inset so a lip of the
--     base shows along the bottom edge, and pressing collapses the lip,
--   * two strokes, never one - a dark keyline around the whole control and a bright rim just inside
--     the face, which is what makes an edge read as lit rather than drawn,
--   * a banded sheen instead of a linear ramp - the fill returns to its own colour at both ends and
--     lifts only through the middle, so a surface looks curved rather than shaded,
--   * type is one family with weight and size doing the work.
--
-- The palette is ours and stays farm: straw and honey gold, cream and feather white, leaf, sky, warm
-- cocoa outlines. It was lifted several steps in saturation, because the old one was pastel enough
-- that gold read as beige and nothing on a cream panel had any contrast to sit against.

local Tokens = {}

Tokens.color = table.freeze({
	-- Ink (warm browns) for all text on cream. Deepened so body copy holds at small sizes.
	inkStrong = Color3.fromRGB(56, 36, 22),
	ink = Color3.fromRGB(86, 60, 40),
	inkMuted = Color3.fromRGB(142, 118, 96),
	outline = Color3.fromRGB(74, 46, 26), -- the keyline: deep cocoa, warm, never black
	cocoa = Color3.fromRGB(116, 76, 44),
	-- Cream and feather-white surfaces.
	cream = Color3.fromRGB(253, 247, 236),
	creamDeep = Color3.fromRGB(240, 226, 200),
	creamPill = Color3.fromRGB(255, 244, 206),
	featherWhite = Color3.fromRGB(255, 253, 248),
	panel = Color3.fromRGB(254, 249, 239), -- modal / card panel fill
	panelDeep = Color3.fromRGB(242, 230, 208), -- panel gradient foot
	surface = Color3.fromRGB(255, 252, 245),
	surfaceAlt = Color3.fromRGB(248, 238, 220),
	-- Golden yellow (frames, primary actions, highlights). The spine of the whole thing.
	straw = Color3.fromRGB(242, 206, 118),
	strawDeep = Color3.fromRGB(198, 150, 60),
	honey = Color3.fromRGB(255, 208, 60),
	goldLight = Color3.fromRGB(255, 229, 126),
	gold = Color3.fromRGB(255, 193, 42),
	goldDeep = Color3.fromRGB(188, 118, 14),
	-- Teal: small accents only (tabs, selected rings, badges).
	tealPanel = Color3.fromRGB(34, 124, 142),
	tealDeep = Color3.fromRGB(18, 86, 102),
	tealLight = Color3.fromRGB(86, 184, 198),
	tealAccent = Color3.fromRGB(44, 150, 168),
	tealTint = Color3.fromRGB(224, 244, 246),
	sky = Color3.fromRGB(122, 196, 232),
	skyDeep = Color3.fromRGB(56, 132, 182),
	leaf = Color3.fromRGB(114, 178, 88),
	leafBright = Color3.fromRGB(126, 210, 62),
	leafDeep = Color3.fromRGB(58, 120, 42),
	ember = Color3.fromRGB(246, 126, 62),
	emberDeep = Color3.fromRGB(186, 74, 32),
	gem = Color3.fromRGB(134, 104, 238),
	gemDeep = Color3.fromRGB(80, 54, 176),
	overlay = Color3.fromRGB(42, 28, 16),
	shadow = Color3.fromRGB(62, 40, 22),
	success = Color3.fromRGB(96, 180, 86),
	warning = Color3.fromRGB(240, 168, 36),
	danger = Color3.fromRGB(214, 74, 58),
})

-- Depth: the numbers that make a control an object rather than a rectangle. One place, so a button,
-- a card, a modal header and a hotbar slot are lit the same way and read as one kit.
Tokens.depth = table.freeze({
	lipPx = 6, -- how much of the dark base shows under the face
	lipPressedPx = 2, -- ...and what it collapses to when pressed
	panelLipPx = 9,
	keyline = 3, -- the dark outline around the whole control
	keylineThin = 2,
	rim = 1.5, -- the bright rim just inside the face
	rimTransparency = 0.25,
	-- A sheen band: the fill returns to its own colour at both ends and lifts only through the middle,
	-- which reads as a curved surface. A plain top-to-bottom ramp reads as a flat card with a shadow.
	sheenStops = table.freeze({ 0, 0.34, 0.5, 0.66, 1 }),
	sheenLift = 0.17, -- how far the middle band moves towards the light colour
	sheenDrop = 0.06, -- ...and how far the bottom band sinks, so the foot grounds
	innerShadow = 0.82, -- transparency of the soft dark band under a panel header
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
	-- Headings are the display family too. Three families (Fredoka + GothamBold + Gotham) was most of
	-- why screens did not look like one product; size and weight carry the hierarchy instead.
	heading = table.freeze({ font = Enum.Font.FredokaOne, size = 19, lineHeight = 1.15 }),
	body = table.freeze({ font = Enum.Font.GothamMedium, size = 15, lineHeight = 1.3 }),
	caption = table.freeze({ font = Enum.Font.GothamMedium, size = 13, lineHeight = 1.3 }),
	numeral = table.freeze({ font = Enum.Font.FredokaOne, size = 21, lineHeight = 1.0 }),
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
	-- Round intro. Every one but the tick is a silent placeholder until the owner supplies ids.
	introAmbience = "intro.ambience",
	introWind = "intro.wind",
	introFootstep = "intro.footstep",
	introPaper = "intro.paper",
	introSting = "intro.sting",
	introType = "intro.type",
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
