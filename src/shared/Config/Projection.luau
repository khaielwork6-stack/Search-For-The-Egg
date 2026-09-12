--!strict
-- Builds the client-safe view of the configuration. Server-only sections (redeem codes, analytics
-- policy) are removed. Product/Game Pass IDs never live in SYSTEM_CONFIG, so nothing here can leak
-- them; the deployment mapping stays in ServerScriptService.

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

local Projection = {}

-- Top-level keys the client must never receive.
Projection.SERVER_ONLY_KEYS = table.freeze({ "codes", "analytics", "$schema" })

function Projection.toClient(raw: { [string]: any }): { [string]: any }
	local copy = TableUtil.deepCopy(raw)
	for _, key in ipairs(Projection.SERVER_ONLY_KEYS) do
		copy[key] = nil
	end
	copy.projection = "client"
	return copy
end

-- True when a projection contains any server-only key (used by tests and the server publisher).
function Projection.leaksServerData(projection: { [string]: any }): boolean
	for _, key in ipairs(Projection.SERVER_ONLY_KEYS) do
		if projection[key] ~= nil then
			return true
		end
	end
	return false
end

return Projection
