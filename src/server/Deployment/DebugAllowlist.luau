--!strict
-- Studio/private-test debug allowlist. Debug hooks are enabled only when RunService:IsStudio()
-- is true OR the current place is in `privateTestPlaceIds` AND the acting user is allowlisted.
-- Empty lists mean "Studio only". Server-only module; never replicated.

return table.freeze({
	userIds = table.freeze({} :: { number }),
	privateTestPlaceIds = table.freeze({} :: { number }),
})
