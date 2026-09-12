# Deployment IDs (owner action required before Phase 5 live testing)

`src/server/Deployment/ProductIds.luau` is the only place live Roblox IDs are allowed. Every value is
`nil` (`TODO_DEPLOYMENT_IDS`). The server refuses unknown IDs, never prompts for an unmapped product, and
logs `missingDeploymentIds=<count>` at boot. `ProductMap` derives the expected key set from
`SYSTEM_CONFIG.json`, so a key that is not configured is rejected at startup and a configured key with no
ID is reported by `ProductMap:missingKeys()` (visible in the Studio debug status).

## Keys to supply

| Section | Key | Grant handler kind | Source of truth for price |
|---|---|---|---|
| placeIds | lobby, chapter1, chapter2 | teleport | n/a |
| gamePasses | doubleGems, infiniteBag | pass:* | `monetization.passes` |
| gamePasses | doubleLuck, fastRolls, extraClassSlot | pass:* | `classes.products` |
| gamePasses | nestRakePermanent, confettiChargePermanent, featherVacPermanent, scoutChickPermanent | permanentTool:* | `tools.*.permanentRobux` |
| developerProducts | gemBundle100, gemBundle400 | gems:* | `monetization.gemBundles` |
| developerProducts | nestRakeOneRound, confettiChargeOneRound, featherVacOneRound, scoutChickOneRound | oneRoundTool:* | `tools.*.oneRoundRobux` |
| developerProducts | eventChest3, eventChest5, eventChest10 | eventChest:* | `monetization.eventChest.robuxBundles` |
| developerProducts | skipBagUpgrade | skipUpgrade:bag | `bags.levels[].skipRobux` |

Fill the table in `ProductIds.luau` with positive integer IDs from the target experience. Duplicate IDs,
non-integers, and keys the config does not know cause a startup error (covered by `tests/Transactions.spec.luau`).

Until `placeIds.chapter1` is set, parties resolve through the same-place local teleport adapter.
