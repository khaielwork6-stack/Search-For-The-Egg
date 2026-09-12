--!strict
-- Reservation/teleport adapter. Production uses TeleportService with reserved servers; when the
-- destination place ID is not configured (Phase 1-4 single-place development) the "local" adapter
-- keeps the party in this place and hands the round to RoundService directly. Teleport data is
-- limited to opaque identifiers.

local TeleportAdapter = {}

export type Reservation = { code: string, placeKey: string, placeId: number?, isLocal: boolean }

export type Adapter = {
	reserve: (self: Adapter, placeKey: string) -> (boolean, Reservation?),
	teleport: (self: Adapter, reservation: Reservation, players: { any }, data: { [string]: string }) -> boolean,
	kind: string,
}

-- Local (same-place) --------------------------------------------------------------------------

local Local = {}
Local.__index = Local

function TeleportAdapter.localAdapter(idGen: () -> string): Adapter
	local self = setmetatable({ kind = "local", _idGen = idGen, teleports = {} }, Local)
	return (self :: any) :: Adapter
end

function Local.reserve(self, placeKey: string): (boolean, Reservation?)
	return true, { code = "local:" .. self._idGen(), placeKey = placeKey, placeId = nil, isLocal = true }
end

function Local.teleport(self, reservation: Reservation, players: { any }, data: { [string]: string }): boolean
	table.insert(self.teleports, { reservation = reservation, count = #players, data = data })
	return true
end

-- Real -----------------------------------------------------------------------------------------

local Real = {}
Real.__index = Real

function TeleportAdapter.real(productMap: any): Adapter
	local self = setmetatable({ kind = "real", _productMap = productMap }, Real)
	return (self :: any) :: Adapter
end

function Real.reserve(self, placeKey: string): (boolean, Reservation?)
	local placeId = self._productMap:placeId(placeKey)
	if not placeId then
		return false, nil
	end
	local TeleportService = game:GetService("TeleportService")
	local ok, code = pcall(function()
		return TeleportService:ReserveServer(placeId)
	end)
	if not ok then
		return false, nil
	end
	return true, { code = code, placeKey = placeKey, placeId = placeId, isLocal = false }
end

function Real.teleport(_, reservation: Reservation, players: { any }, data: { [string]: string }): boolean
	if reservation.isLocal or not reservation.placeId then
		return false
	end
	local TeleportService = game:GetService("TeleportService")
	local ok = pcall(function()
		local options = Instance.new("TeleportOptions")
		options.ReservedServerAccessCode = reservation.code
		options:SetTeleportData(data)
		TeleportService:TeleportAsync(reservation.placeId :: number, players, options)
	end)
	return ok
end

-- Failing mock for tests ------------------------------------------------------------------------

function TeleportAdapter.failing(): Adapter
	local self = { kind = "failing" }
	function self.reserve()
		return false, nil
	end
	function self.teleport()
		return false
	end
	return (self :: any) :: Adapter
end

return TeleportAdapter
