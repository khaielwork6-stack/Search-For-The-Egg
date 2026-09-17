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
	-- Rebuilt 17 Sep 2026 to the owner's reference clip: charcoal panels, near-black outlines, white
	-- lettering with a black stroke, saturated green for every "go" action, red for close and back,
	-- gold for VIP and prizes, blue for currency, purple for gems and premium. The token NAMES are
	-- kept so every screen re-skins at once; only the values changed. "ink" is now white on dark.
	inkStrong = Color3.fromRGB(255, 255, 255),
	ink = Color3.fromRGB(236, 238, 246),
	inkMuted = Color3.fromRGB(178, 184, 206),
	outline = Color3.fromRGB(12, 13, 20), -- the keyline: near-black, thick
	cocoa = Color3.fromRGB(70, 74, 96), -- mid slate: plates, pills, secondary fills
	-- Surfaces: charcoal panel, deeper lip, slate cards.
	cream = Color3.fromRGB(46, 49, 64),
	creamDeep = Color3.fromRGB(33, 35, 48),
	creamPill = Color3.fromRGB(59, 62, 82),
	featherWhite = Color3.fromRGB(255, 255, 255),
	panel = Color3.fromRGB(46, 49, 64), -- modal / card panel fill
	panelDeep = Color3.fromRGB(30, 32, 44), -- panel lip / foot
	surface = Color3.fromRGB(59, 62, 82), -- rows and cards on a panel
	surfaceAlt = Color3.fromRGB(50, 53, 70),
	-- Gold: VIP, prizes, highlights.
	straw = Color3.fromRGB(255, 199, 44),
	strawDeep = Color3.fromRGB(201, 138, 0),
	honey = Color3.fromRGB(255, 208, 60),
	goldLight = Color3.fromRGB(255, 230, 120),
	gold = Color3.fromRGB(255, 199, 44),
	goldDeep = Color3.fromRGB(201, 138, 0),
	-- Teal / blue: currency, shop, selected rings.
	tealPanel = Color3.fromRGB(36, 150, 170),
	tealDeep = Color3.fromRGB(20, 96, 120),
	tealLight = Color3.fromRGB(110, 226, 226),
	tealAccent = Color3.fromRGB(56, 190, 200),
	tealTint = Color3.fromRGB(40, 66, 90),
	sky = Color3.fromRGB(56, 168, 255),
	skyDeep = Color3.fromRGB(24, 100, 180),
	-- Green: the "go" colour and claimed states.
	leaf = Color3.fromRGB(76, 200, 60),
	leafBright = Color3.fromRGB(150, 240, 60),
	leafDeep = Color3.fromRGB(34, 140, 26),
	-- Red: close, back, danger.
	ember = Color3.fromRGB(240, 64, 64),
	emberDeep = Color3.fromRGB(160, 26, 26),
	gem = Color3.fromRGB(150, 84, 240),
	gemDeep = Color3.fromRGB(92, 40, 170),
	overlay = Color3.fromRGB(8, 9, 14),
	shadow = Color3.fromRGB(0, 0, 0),
	success = Color3.fromRGB(96, 208, 40),
	warning = Color3.fromRGB(255, 199, 44),
	danger = Color3.fromRGB(240, 64, 64),
})

-- Depth: the numbers that make a control an object rather than a rectangle. One place, so a button,
-- a card, a modal header and a hotbar slot are lit the same way and read as one kit.
Tokens.depth = table.freeze({
	lipPx = 6, -- how much of the dark base shows under the face
	lipPressedPx = 2, -- ...and what it collapses to when pressed
	panelLipPx = 10,
	keyline = 4, -- the near-black outline around the whole control: thick, like the reference
	keylineThin = 3,
	rim = 1.5, -- the faint light rim just inside the face
	rimTransparency = 0.72,
	-- A sheen band: the fill returns to its own colour at both ends and lifts only through the middle,
	-- which reads as a curved surface. A plain top-to-bottom ramp reads as a flat card with a shadow.
	sheenStops = table.freeze({ 0, 0.02, 0.42, 0.7, 1 }),
	sheenLift = 0.34, -- the top of a face is lit this far towards the light colour (a lime cap on green)
	sheenDrop = 0.2, -- ...and the foot sinks this far, so every face reads as a glossy ramp
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
	display = table.freeze({ font = Enum.Font.FredokaOne, size = 40, lineHeight = 1.05 }),
	title = table.freeze({ font = Enum.Font.FredokaOne, size = 28, lineHeight = 1.1 }),
	label = table.freeze({ font = Enum.Font.FredokaOne, size = 20, lineHeight = 1.1 }), -- pill labels / station names
	-- Headings are the display family too. Three families (Fredoka + GothamBold + Gotham) was most of
	-- why screens did not look like one product; size and weight carry the hierarchy instead.
	heading = table.freeze({ font = Enum.Font.FredokaOne, size = 22, lineHeight = 1.15 }),
	-- One family for everything, the way the reference reads: body copy is the same rounded bold,
	-- smaller, white with a thin stroke.
	body = table.freeze({ font = Enum.Font.FredokaOne, size = 17, lineHeight = 1.25 }),
	caption = table.freeze({ font = Enum.Font.FredokaOne, size = 15, lineHeight = 1.25 }),
	numeral = table.freeze({ font = Enum.Font.FredokaOne, size = 24, lineHeight = 1.0 }),
	minimumBodySize = 14,
})

Tokens.spacing = table.freeze({ xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 32 })

Tokens.radius = table.freeze({ sm = 10, md = 14, lg = 20, xl = 26, pill = 999 })

Tokens.stroke = table.freeze({ hairline = 1.5, standard = 3, bold = 4, frame = 5 })

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
	collectFlight = "collect.flight",
	collectTick = "collect.tick",
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
	blastLow = "tool.blastLow",
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
	stationButtonPx = 84, -- lobby station rail buttons (square, >= tap target): big, like the reference
	cardMaxWidthPx = 560,
	cardMaxHeightFraction = 0.9, -- of the viewport; content scrolls inside
})

Tokens.zIndex = table.freeze({ world = 1, hud = 10, toast = 20, modal = 30, blocking = 40, prompt = 50, veil = 60 })

-- Icon glyph sizes (vector icons drawn from frames; see UI/Components/Icons).
Tokens.icon = table.freeze({ sm = 16, md = 22, lg = 32 })

return Tokens
