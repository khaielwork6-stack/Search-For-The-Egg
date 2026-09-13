# Search For The Egg

Cozy first-person collection and hidden-object experience for Roblox. Built in six controlled phases from
the build pack in `Search_For_The_Egg_Claude_Code_Build_Pack/` (start with `START_HERE.md` there).

Current checkpoint: **Phase 4 - lobby and meta** (parties and chapter selection, classes and rerolls, perks,
daily rewards, codes, group reward, inventory, stats and leaderboards, the modal system with the owner's visual
language and motion recipes, and the smooth feather-mound pile) on top of the Phase 3 progression and tools.
The lobby and Chapter 1 now run inside the owner's two map models (`SearchForTheEgg_Lobby`, `SearchForTheEgg_Map2`,
place assets) with a greybox fallback when they are absent. See `docs/IMPLEMENTATION_STATUS.md`.

## Toolchain

Tools are pinned in `rokit.toml` (install with [Rokit](https://github.com/rojo-rbx/rokit): `rokit install`).

| Tool | Purpose |
|---|---|
| Rojo 7.7.0 | Sync/build (`default.project.json`), headless build (`test.project.json`) |
| Lune 0.10.5 | Headless test/check runner (`lune/`) |
| StyLua 2.5.2, Selene 0.31.0 | Formatting and linting |
| luau-lsp 1.69.0 | Type analysis (advisory; needs `build/globalTypes.d.luau`) |

## Commands

```bash
lune run lune/test
```
Builds `test.project.json`, loads the place headlessly, runs every `tests/*.spec.luau`, exits non-zero on failure.

```bash
lune run lune/check
```
Validates `SYSTEM_CONFIG.json`, checks `ECONOMY_TABLES.csv` against it, scans for hard-coded prices/IDs,
runs `stylua --check` and `selene`.

```bash
rojo serve
```
Then connect the Rojo plugin in Studio. To build a place file instead: `rojo build -o "Search For The Egg.rbxlx"`.

## Layout

- `src/shared` - configuration facade, domain math (pile grid, Egg nodes, tool specs, objectives, layout), reducers, network schema, design tokens, test framework.
- `src/server` - bootstrap, profile store, transactions/receipts, adapters, services (round, collection, tools, awards, selling, upgrades, Egg, victory, objectives, arena), Studio-only debug hooks.
- `src/client` - bootstrap, controllers (net, profile, input, modal, audio, VFX, ambient, HUD, round, pile visuals, tools, tool visuals, interactions, objectives, victory), UI components (hotbar, workbench, round strip).
- `tests` - spec modules plus `Helpers/GameplayHarness` (run headlessly and in Studio from the same files).
- `docs` - inspection report, implementation status, Studio verification evidence, deployment ID checklist.

## Configuration

All tunables come from `Search_For_The_Egg_Claude_Code_Build_Pack/SYSTEM_CONFIG.json`, mapped by Rojo into
`ServerStorage.SFE.SystemConfig`. The server validates and freezes it, then publishes a sanitized client
projection (no redeem codes, no analytics policy). Live product/pass/place IDs live only in
`src/server/Deployment/ProductIds.luau` (see `docs/DEPLOYMENT_IDS.md`).
