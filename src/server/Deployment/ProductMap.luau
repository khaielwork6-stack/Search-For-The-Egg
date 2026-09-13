--!strict
-- Validated product/pass/place mapping interface. Derives the expected key set from SYSTEM_CONFIG
-- so a configured product with no deployment ID is reported as missing, and an ID the config does
-- not know is refused. Unknown/missing IDs never grant anything.

local ProductMap = {}
ProductMap.__index = ProductMap

export type Entry = { key: string, kind: "gamePass" | "developerProduct" | "place", id: number?, grant: string }

export type ProductMap = typeof(setmetatable({} :: { _entries: { [string]: Entry }, _byId: { [string]: Entry } }, ProductMap))

-- Expected keys are derived from config, never typed by hand in services.
function ProductMap.expectedKeys(cfg: { [string]: any }): { Entry }
	local entries: { Entry } = {}
	local function add(key: string, kind: "gamePass" | "developerProduct" | "place", grant: string)
		table.insert(entries, { key = key, kind = kind, id = nil, grant = grant })
	end
	add("lobby", "place", "teleport")
	for chapterKey in pairs(cfg.chapters) do
		add(chapterKey, "place", "teleport")
	end
	for passKey in pairs(cfg.monetization.passes) do
		add(passKey, "gamePass", "pass:" .. passKey)
	end
	for _, key in ipairs({ "doubleLuck", "fastRolls", "extraClassSlot" }) do
		add(key, "gamePass", "pass:" .. key)
	end
	for toolId in pairs(cfg.tools) do
		add(toolId .. "Permanent", "gamePass", "permanentTool:" .. toolId)
		add(toolId .. "OneRound", "developerProduct", "oneRoundTool:" .. toolId)
	end
	for _, bundle in ipairs(cfg.monetization.gemBundles) do
		add("gemBundle" .. tostring(bundle.gems), "developerProduct", "gems:" .. tostring(bundle.gems))
	end
	for _, bundle in ipairs(cfg.monetization.eventChest.robuxBundles) do
		add("eventChest" .. tostring(bundle.count), "developerProduct", "eventChest:" .. tostring(bundle.count))
	end
	add("skipBagUpgrade", "developerProduct", "skipUpgrade:bag")
	table.sort(entries, function(a, b)
		return a.key < b.key
	end)
	return entries
end

-- Builds the map from config plus the deployment ID table. Validates the ID table shape and
-- refuses duplicate or non-positive-integer IDs.
function ProductMap.new(cfg: { [string]: any }, deployment: { [string]: any }): ProductMap
	local entries: { [string]: Entry } = {}
	local byId: { [string]: Entry } = {}
	local sections = { place = "placeIds", gamePass = "gamePasses", developerProduct = "developerProducts" }

	for _, entry in ipairs(ProductMap.expectedKeys(cfg)) do
		local section = deployment[sections[entry.kind]]
		local id = section and section[entry.key]
		if id ~= nil then
			if type(id) ~= "number" or id <= 0 or id % 1 ~= 0 then
				error("ProductMap: deployment id for " .. entry.key .. " must be a positive integer")
			end
			local idKey = entry.kind .. ":" .. tostring(id)
			if byId[idKey] then
				error("ProductMap: duplicate deployment id " .. tostring(id) .. " for " .. entry.key .. " and " .. byId[idKey].key)
			end
			entry.id = id
			byId[idKey] = entry
		end
		entries[entry.key] = entry
	end

	-- Refuse deployment keys that the config does not expect (typos never map to a grant).
	for _, sectionName in pairs(sections) do
		local section = deployment[sectionName]
		if type(section) == "table" then
			for key in pairs(section) do
				if not entries[key] then
					error("ProductMap: deployment key '" .. tostring(key) .. "' is not a configured product")
				end
			end
		end
	end

	return setmetatable({ _entries = entries, _byId = byId }, ProductMap)
end

-- Studio-only deployment table with synthetic ids (900001, 900002, ...) so the whole purchase pipeline
-- (prompt -> receipt -> ledger -> grant -> projection) can be exercised against the mock Marketplace
-- adapter. Never used outside Studio; the shipped ProductIds file stays the only live source.
function ProductMap.studioMockDeployment(cfg: { [string]: any }): { [string]: any }
	local deployment = { placeIds = {}, gamePasses = {}, developerProducts = {} }
	local sections = { place = "placeIds", gamePass = "gamePasses", developerProduct = "developerProducts" }
	local nextId = 900001
	for _, entry in ipairs(ProductMap.expectedKeys(cfg)) do
		if entry.kind ~= "place" then
			deployment[sections[entry.kind]][entry.key] = nextId
			nextId += 1
		end
	end
	return deployment
end

function ProductMap.resolve(self: ProductMap, key: string): Entry?
	return self._entries[key]
end

function ProductMap.isConfigured(self: ProductMap, key: string): boolean
	local entry = self._entries[key]
	return entry ~= nil and entry.id ~= nil
end

-- Reverse lookup for receipts / ownership checks. Unknown IDs return nil (caller must refuse).
function ProductMap.lookupDeveloperProduct(self: ProductMap, productId: number): Entry?
	return self._byId["developerProduct:" .. tostring(productId)]
end

function ProductMap.lookupGamePass(self: ProductMap, passId: number): Entry?
	return self._byId["gamePass:" .. tostring(passId)]
end

function ProductMap.placeId(self: ProductMap, key: string): number?
	local entry = self._entries[key]
	return if entry and entry.kind == "place" then entry.id else nil
end

function ProductMap.missingKeys(self: ProductMap): { string }
	local out = {}
	for key, entry in pairs(self._entries) do
		if entry.id == nil then
			table.insert(out, key)
		end
	end
	table.sort(out)
	return out
end

function ProductMap.count(self: ProductMap): number
	local n = 0
	for _ in pairs(self._entries) do
		n += 1
	end
	return n
end

return ProductMap
