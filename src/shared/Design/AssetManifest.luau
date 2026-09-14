--!strict
-- The one asset manifest: semantic roles -> Roblox asset ids or ReplicatedStorage model names. UI
-- and world code reference roles, never raw ids, so an art swap touches this file only.
-- Image ids are the owner's station-button PNGs uploaded as image assets (docs/HANDOFF_PHASE4.md);
-- an empty string means "no image yet" and components fall back to the token-drawn frame.

local AssetManifest = {}

-- UI art (owner-supplied PNGs in /ui, uploaded as image assets). Roles without art render the
-- token-drawn fallback, so every screen works before an image loads or when one is missing.
AssetManifest.images = table.freeze({
	-- Textures from the owner's UI pack (StarterGui.ScreenGui), reused as subtle surface detail.
	["texture.rays"] = "rbxassetid://92627249277540",
	["texture.studs"] = "rbxassetid://76728843491214",
	["texture.sunburst"] = "rbxassetid://77613333876426",
	["button.close.normal"] = "rbxassetid://132197731374053",
	["button.close.pressed"] = "rbxassetid://70489286740208",
	["button.danger.disabled"] = "rbxassetid://139510908172586",
	["button.danger.normal"] = "rbxassetid://98550146013101",
	["button.danger.pressed"] = "rbxassetid://71198440082319",
	["button.ghost.disabled"] = "rbxassetid://99546561617864",
	["button.ghost.hover"] = "rbxassetid://106737403334227",
	["button.ghost.normal"] = "rbxassetid://83792964102085",
	["button.ghost.pressed"] = "rbxassetid://106165948543643",
	["button.ghost.selected"] = "rbxassetid://105625911166103",
	["button.pill.disabled"] = "rbxassetid://72945202053690",
	["button.pill.normal"] = "rbxassetid://131339277611100",
	["button.pill.selected"] = "rbxassetid://93812356136894",
	["button.primary.disabled"] = "rbxassetid://114972146360090",
	["button.primary.hover"] = "rbxassetid://95153864702139",
	["button.primary.normal"] = "rbxassetid://93340758073630",
	["button.primary.pressed"] = "rbxassetid://81333976775432",
	["button.secondary.disabled"] = "rbxassetid://94938269906696",
	["button.secondary.hover"] = "rbxassetid://73630179374254",
	["button.secondary.normal"] = "rbxassetid://102492100242270",
	["button.secondary.pressed"] = "rbxassetid://137774773624683",
	["class.common.equipped"] = "rbxassetid://90871504679179",
	["class.common.locked"] = "rbxassetid://138729367886629",
	["class.common.owned"] = "rbxassetid://118437567369159",
	["class.epic.equipped"] = "rbxassetid://101728136954256",
	["class.epic.locked"] = "rbxassetid://135976197722508",
	["class.epic.owned"] = "rbxassetid://92395163883241",
	["class.legendary.equipped"] = "rbxassetid://129561637513835",
	["class.legendary.locked"] = "rbxassetid://117400229580923",
	["class.legendary.owned"] = "rbxassetid://85641862384725",
	["class.rare.equipped"] = "rbxassetid://117487981428776",
	["class.rare.locked"] = "rbxassetid://139731356603599",
	["class.rare.owned"] = "rbxassetid://113904358143005",
	["class.uncommon.equipped"] = "rbxassetid://77393147926330",
	["class.uncommon.locked"] = "rbxassetid://100551056625245",
	["class.uncommon.owned"] = "rbxassetid://127417066705702",
	["confetti.gold"] = "rbxassetid://72309830027102",
	["confetti.green"] = "rbxassetid://133599668255984",
	["confetti.purple"] = "rbxassetid://111924207885655",
	["cutscene.caption"] = "rbxassetid://81372630107389",
	["cutscene.vignette"] = "rbxassetid://74979159033983",
	["daily.cell.claimed"] = "rbxassetid://137793659782821",
	["daily.cell.current"] = "rbxassetid://106457852636897",
	["daily.cell.future"] = "rbxassetid://96169101256751",
	["focus.ring"] = "rbxassetid://74860299938860",
	["header.classes"] = "rbxassetid://118536512913420",
	["header.codes"] = "rbxassetid://93705204367408",
	["header.daily"] = "rbxassetid://139180732869253",
	["header.event"] = "rbxassetid://116594433200007",
	["header.inventory"] = "rbxassetid://130261413398156",
	["header.party"] = "rbxassetid://83232836601765",
	["header.results"] = "rbxassetid://85330959459911",
	["header.settings"] = "rbxassetid://74345619865453",
	["header.shop"] = "rbxassetid://133328173356787",
	["header.stats"] = "rbxassetid://125993502588536",
	["header.workbench"] = "rbxassetid://95725902799806",
	["hotbar.slot.disabled"] = "rbxassetid://121893717153708",
	["hotbar.slot.equipped"] = "rbxassetid://113707878724221",
	["hotbar.slot.idle"] = "rbxassetid://114511722452629",
	["hotbar.status.danger"] = "rbxassetid://93221063651230",
	["hotbar.status.green"] = "rbxassetid://106152446084607",
	["hotbar.status.info"] = "rbxassetid://104846030240476",
	["hotbar.status.track"] = "rbxassetid://104112661528199",
	["hotbar.status.warning"] = "rbxassetid://80047814102412",
	["hud.bag.fill.full"] = "rbxassetid://131025638900409",
	["hud.bag.fill.infinite"] = "rbxassetid://92350984309264",
	["hud.bag.fill.normal"] = "rbxassetid://122725465517661",
	["hud.bag.track"] = "rbxassetid://100321810556019",
	["hud.banner"] = "rbxassetid://120122297260941",
	["hud.cash"] = "rbxassetid://91212345677408",
	["hud.chip"] = "rbxassetid://122352739653232",
	["hud.gear"] = "rbxassetid://113404553836143",
	["hud.gem"] = "rbxassetid://111089449734627",
	["hud.prompt"] = "rbxassetid://85325970663845",
	["hud.reticle"] = "rbxassetid://125975322335872",
	["hud.reticle.locked"] = "rbxassetid://129330331951164",
	["hud.timer"] = "rbxassetid://123644860498064",
	["hud.token"] = "rbxassetid://115445046215182",
	["icon.egg"] = "rbxassetid://79580043164375",
	["icon.feather"] = "rbxassetid://131625601959161",
	["meter.fill.gold"] = "rbxassetid://123636109210840",
	["meter.fill.green"] = "rbxassetid://74160632439630",
	["meter.track"] = "rbxassetid://103455746471789",
	["modal.leaf.left"] = "rbxassetid://115672995498915",
	["modal.leaf.right"] = "rbxassetid://136386842176967",
	["modal.row.muted"] = "rbxassetid://101549405664059",
	["modal.row.normal"] = "rbxassetid://74129476912554",
	["modal.title"] = "rbxassetid://125032343474467",
	["party.destination.locked"] = "rbxassetid://84782657415516",
	["party.destination.unavailable"] = "rbxassetid://116103441195385",
	["pickup.chevron"] = "rbxassetid://112104231173949",
	["prompt.action"] = "rbxassetid://88822227237910",
	["prompt.holdRing"] = "rbxassetid://115542686614397",
	["prompt.key"] = "rbxassetid://116362830891430",
	["scroll.thumb"] = "rbxassetid://73769054516689",
	["scroll.track"] = "rbxassetid://70498735416136",
	["station.classes.normal"] = "rbxassetid://130183410712702",
	["station.classes.pressed"] = "rbxassetid://121520729188356",
	["station.codes.normal"] = "rbxassetid://133847168522387",
	["station.codes.pressed"] = "rbxassetid://137508265784006",
	["station.daily.normal"] = "rbxassetid://126761989642320",
	["station.daily.pressed"] = "rbxassetid://128387487714995",
	["station.event.normal"] = "rbxassetid://135736126578218",
	["station.event.pressed"] = "rbxassetid://98830121827647",
	["station.inventory.normal"] = "rbxassetid://134162703235160",
	["station.inventory.pressed"] = "rbxassetid://133653021797580",
	["station.party.normal"] = "rbxassetid://104642621825744",
	["station.party.pressed"] = "rbxassetid://109095027534584",
	["station.shop.normal"] = "rbxassetid://120660448669597",
	["station.shop.pressed"] = "rbxassetid://119246680584431",
	["station.stats.normal"] = "rbxassetid://101558518232372",
	["station.stats.pressed"] = "rbxassetid://73870656150925",
	["textbox.error"] = "rbxassetid://103991128219193",
	["textbox.focused"] = "rbxassetid://98668018496099",
	["textbox.idle"] = "rbxassetid://73324793433538",
	["toast.icon.danger"] = "rbxassetid://122971893471417",
	["toast.icon.info"] = "rbxassetid://122339008323604",
	["toast.icon.reward"] = "rbxassetid://123335721109623",
	["toast.icon.success"] = "rbxassetid://126034182215377",
	["toast.icon.warning"] = "rbxassetid://137830859089571",
	["tool.confettiCharge.normal"] = "rbxassetid://139333397744529",
	["tool.confettiCharge.unowned"] = "rbxassetid://117101401960080",
	["tool.featherVac.normal"] = "rbxassetid://132141786712375",
	["tool.featherVac.unowned"] = "rbxassetid://92360688978433",
	["tool.hand.normal"] = "rbxassetid://85647267307250",
	["tool.hand.unowned"] = "rbxassetid://133824042097876",
	["tool.nestRake.normal"] = "rbxassetid://119150653240087",
	["tool.nestRake.unowned"] = "rbxassetid://89526243588124",
	["tool.scoutChick.normal"] = "rbxassetid://90762827329999",
	["tool.scoutChick.unowned"] = "rbxassetid://114943124115498",
	["victory.plate"] = "rbxassetid://73808842491044",
	["world.leaderboard"] = "rbxassetid://113137522122386",
	["world.portalLintel"] = "rbxassetid://107359923339064",
	["world.stationSign"] = "rbxassetid://101224974046750",
	["world.tradeTop"] = "rbxassetid://138577658352930",
	["world.workbenchSign"] = "rbxassetid://135546911332166",
})

-- Nine-slice rectangles (in source-image pixels) for every frame-like asset; art is exported at 2x,
-- so `sliceScale` renders the frame edges at logical size. Roles absent here draw with ScaleType Fit.
AssetManifest.slices = table.freeze({
	["button.danger.disabled"] = { 36, 36, 284, 52 },
	["button.danger.normal"] = { 36, 36, 284, 52 },
	["button.danger.pressed"] = { 36, 36, 284, 52 },
	["button.ghost.disabled"] = { 36, 36, 284, 52 },
	["button.ghost.hover"] = { 36, 36, 284, 52 },
	["button.ghost.normal"] = { 36, 36, 284, 52 },
	["button.ghost.pressed"] = { 36, 36, 284, 52 },
	["button.ghost.selected"] = { 36, 36, 284, 52 },
	["button.pill.disabled"] = { 36, 36, 284, 52 },
	["button.pill.normal"] = { 36, 36, 284, 52 },
	["button.pill.selected"] = { 36, 36, 284, 52 },
	["button.primary.disabled"] = { 36, 36, 284, 52 },
	["button.primary.hover"] = { 36, 36, 284, 52 },
	["button.primary.normal"] = { 36, 36, 284, 52 },
	["button.primary.pressed"] = { 36, 36, 284, 52 },
	["button.secondary.disabled"] = { 36, 36, 284, 52 },
	["button.secondary.hover"] = { 36, 36, 284, 52 },
	["button.secondary.normal"] = { 36, 36, 284, 52 },
	["button.secondary.pressed"] = { 36, 36, 284, 52 },
	["class.common.equipped"] = { 48, 48, 512, 152 },
	["class.common.locked"] = { 48, 48, 512, 152 },
	["class.common.owned"] = { 48, 48, 512, 152 },
	["class.epic.equipped"] = { 48, 48, 512, 152 },
	["class.epic.locked"] = { 48, 48, 512, 152 },
	["class.epic.owned"] = { 48, 48, 512, 152 },
	["class.legendary.equipped"] = { 48, 48, 512, 152 },
	["class.legendary.locked"] = { 48, 48, 512, 152 },
	["class.legendary.owned"] = { 48, 48, 512, 152 },
	["class.rare.equipped"] = { 48, 48, 512, 152 },
	["class.rare.locked"] = { 48, 48, 512, 152 },
	["class.rare.owned"] = { 48, 48, 512, 152 },
	["class.uncommon.equipped"] = { 48, 48, 512, 152 },
	["class.uncommon.locked"] = { 48, 48, 512, 152 },
	["class.uncommon.owned"] = { 48, 48, 512, 152 },
	["cutscene.caption"] = { 60, 50, 900, 130 },
	["daily.cell.claimed"] = { 36, 36, 204, 84 },
	["daily.cell.current"] = { 36, 36, 204, 84 },
	["daily.cell.future"] = { 36, 36, 204, 84 },
	["focus.ring"] = { 36, 36, 284, 52 },
	["hotbar.slot.disabled"] = { 40, 40, 152, 72 },
	["hotbar.slot.equipped"] = { 40, 40, 152, 72 },
	["hotbar.slot.idle"] = { 40, 40, 152, 72 },
	["hotbar.status.danger"] = { 4, 2, 164, 6 },
	["hotbar.status.green"] = { 4, 2, 164, 6 },
	["hotbar.status.info"] = { 4, 2, 164, 6 },
	["hotbar.status.track"] = { 4, 2, 164, 6 },
	["hotbar.status.warning"] = { 4, 2, 164, 6 },
	["hud.bag.fill.full"] = { 40, 36, 340, 52 },
	["hud.bag.fill.infinite"] = { 40, 36, 340, 52 },
	["hud.bag.fill.normal"] = { 40, 36, 340, 52 },
	["hud.bag.track"] = { 40, 36, 340, 52 },
	["hud.banner"] = { 56, 44, 424, 86 },
	["hud.cash"] = { 40, 36, 220, 52 },
	["hud.chip"] = { 40, 36, 136, 52 },
	["hud.prompt"] = { 40, 36, 136, 52 },
	["hud.timer"] = { 40, 36, 220, 52 },
	["meter.fill.gold"] = { 10, 6, 190, 14 },
	["meter.fill.green"] = { 10, 6, 190, 14 },
	["meter.track"] = { 10, 6, 190, 14 },
	["modal.row.muted"] = { 36, 36, 284, 52 },
	["modal.row.normal"] = { 36, 36, 284, 52 },
	["modal.title"] = { 36, 36, 284, 52 },
	["party.destination.locked"] = { 36, 36, 284, 52 },
	["party.destination.unavailable"] = { 36, 36, 284, 52 },
	["prompt.action"] = { 36, 36, 284, 52 },
	["scroll.thumb"] = { 4, 12, 8, 36 },
	["scroll.track"] = { 4, 12, 8, 36 },
	["textbox.error"] = { 36, 36, 284, 52 },
	["textbox.focused"] = { 36, 36, 284, 52 },
	["textbox.idle"] = { 36, 36, 284, 52 },
	["victory.plate"] = { 80, 50, 944, 110 },
})
AssetManifest.sliceScale = 0.5

-- Models under ReplicatedStorage.SFE_Assets (Rojo maps assets/models). Free Creator Store meshes with
-- their source ids recorded as attributes on the instances (SFE_SourceAssetId).
AssetManifest.models = table.freeze({
	feather = "Feather",
	egg = "Egg",
})

-- The canonical mesh asset id per model role. Rojo's rbxm sync drops the MeshId/MeshSize metadata off
-- MeshParts (the synced template renders as a blank box), so `warm()` rebuilds the mesh from these
-- ids and applies it to the template in place. These are the ids the owner's source meshes carry.
AssetManifest.meshAssets = table.freeze({
	feather = "rbxassetid://439102658",
	egg = "rbxassetid://873833344",
})

-- Nine-slice description for a frame-like role: (id, sliceCenter, sliceScale) or nil without art.
function AssetManifest.skin(role: string): (string?, Rect?, number)
	local id = AssetManifest.image(role)
	if not id then
		return nil, nil, 1
	end
	local spec = (AssetManifest.slices :: any)[role]
	if not spec then
		return id, nil, 1
	end
	-- Rect is a Roblox datatype; headless test runs (no Rect global) get the id without a slice.
	local ok, rect = pcall(function()
		return Rect.new(spec[1], spec[2], spec[3], spec[4])
	end)
	if not ok then
		return id, nil, 1
	end
	return id, rect, AssetManifest.sliceScale
end

function AssetManifest.image(role: string): string?
	local id = (AssetManifest.images :: any)[role]
	if type(id) ~= "string" or id == "" or string.find(id, "ASSET_", 1, true) then
		return nil
	end
	return id
end

local function assetFolder(): Instance?
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	return ReplicatedStorage:FindFirstChild("SFE_Assets")
end

-- True when the template's mesh actually loaded (non-zero MeshSize). A blank MeshPart (Rojo-stripped
-- MeshId or unloaded metadata) reports MeshSize (0,0,0) and renders as its bounding box.
local function meshHealthy(template: Instance): boolean
	if not template:IsA("MeshPart") then
		return true
	end
	local okProps, meshSize = pcall(function()
		return (template :: any).MeshSize
	end)
	return not okProps or (typeof(meshSize) == "Vector3" and meshSize.Magnitude > 0)
end

-- Returns the template instance for a model role (or nil when the asset folder is unavailable).
function AssetManifest.model(role: string): Instance?
	local name = (AssetManifest.models :: any)[role]
	if type(name) ~= "string" then
		return nil
	end
	local folder = assetFolder()
	local template = folder and folder:FindFirstChild(name)
	-- Only hand out a mesh template once its mesh is loaded; otherwise callers should use their own
	-- fallback (a plain part) rather than clone a blank box that renders as a slab.
	if template and template:IsA("MeshPart") and not meshHealthy(template) then
		return nil
	end
	return template
end

-- Rebuilds each model role's mesh from `meshAssets` when the synced template is blank, applying the
-- fresh mesh in place and keeping the template's Size, colour, material, and double-sided flag.
-- Yields once per repaired mesh. Safe to call on server and client, more than once (idempotent), and
-- no-ops outside Roblox or when InsertService/asset access is unavailable. Returns the repair count.
function AssetManifest.warm(): number
	local folder = assetFolder()
	if not folder then
		return 0
	end
	local okService, InsertService = pcall(game.GetService, game, "InsertService")
	if not okService or not InsertService then
		return 0
	end
	local repaired = 0
	for role, name in pairs(AssetManifest.models) do
		local template = folder:FindFirstChild(name)
		local meshId = (AssetManifest.meshAssets :: any)[role]
		if template and template:IsA("MeshPart") and type(meshId) == "string" and meshId ~= "" and not meshHealthy(template) then
			local okCreate, created = pcall(function()
				return (InsertService :: any):CreateMeshPartAsync(meshId, Enum.CollisionFidelity.Box, Enum.RenderFidelity.Precise)
			end)
			if okCreate and created then
				local size = template.Size
				local okApply = pcall(function()
					(template :: any):ApplyMesh(created)
				end)
				template.Size = size
				-- Distance LOD and both faces: a big pile of these clones stays cheap and never shows a
				-- culled back face at a grazing angle.
				pcall(function()
					local t = template :: any
					t.RenderFidelity = Enum.RenderFidelity.Automatic
					t.DoubleSided = true
				end)
				created:Destroy()
				if okApply and meshHealthy(template) then
					repaired += 1
				end
			end
		end
	end
	return repaired
end

return AssetManifest
