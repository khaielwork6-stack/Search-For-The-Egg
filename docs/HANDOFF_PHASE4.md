# Phase 4 handoff (session moved from the Windows PC to the laptop)

Start Phase 4 from checkpoint `6e2a8e0b02ed78f7d5c08ef61b1e99498c78708f` (Phase 3) plus the commits after it.

Inputs the owner supplied (already in the repo):
- `Search_For_The_Egg_Claude_Code_Build_Pack/UIPACKV2.rbxl` - purchased UI pack. Use ONLY its motion
  recipes (one LocalScript in StarterGui.ScreenGui): hover Back-out 0.18 s, press Sine 0.08 s, release
  Elastic 0.4 s, panel open Back-out 0.45 s + fade Quad 0.3 s, panel close Quad-in 0.3 s + fade 0.25 s,
  blur in 0.3 s / out 0.25 s, notification grow Back 0.4 s + pop Elastic 0.45 s + shrink Quad-in 0.28 s,
  rotation punch (Sine kick then Elastic settle), click ripple. Do not import its frames, icons, or copy.
- `shop.png`, `classes.png`, `stats.png` - the owner's station buttons. They define the visual language:
  gold bevelled frame, deep teal panel, cream pill label, chunky rounded cartoon lettering, leaf accents.
  Fold this into `Shared/Design/Tokens` so every modal, chip and hotbar slot matches; upload the PNGs
  as image assets and reference them from one asset manifest.
- `assets/models/Feather.rbxm`, `assets/models/Egg.rbxm` - free Creator Store meshes (ids recorded as
  attributes) mapped to `ReplicatedStorage.SFE_Assets`. Swap the mesh ids if the owner names other models.

Owner requirement recorded during Phase 3 review: the feather pile must read as one smooth, dense,
organic mound of strands with no visible grid (reference: a straw-mound collection game). Keep the
server's 16x16 logical cells; rebuild the client visual from the Feather mesh, instanced by density with
quality tiers for phone.

Phase 4 inspection findings (12 Sep 2026): no code conflicts; parties, unlocks, profile schema (classes,
perks, rewards, inventory, stats), entitlement service, resolver and luck transform already exist.
ASSUMED policies to register: code normalization/rate limit, leaderboard refresh cadence and write bounds,
class roll animation duration, lobby station coordinates and ambient budgets. Codes stay server-only.
