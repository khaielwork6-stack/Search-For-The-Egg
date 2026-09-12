--!strict
-- Build identity attached to analytics and config audit records. `buildLabel` is bumped per
-- verified phase checkpoint; the commit SHA is recorded in docs, not here (no runtime git access).

return table.freeze({
	buildLabel = "phase3-progression-tools",
	phase = 3,
})
