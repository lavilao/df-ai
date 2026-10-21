# Worklog — df-ai port to DF 53.16 / DFHack 53.16-r3

---
Task ID: 1
Agent: main (Z.ai)
Task: Port lavilao/df-ai to DF 53.16 + DFHack 53.16-r3

Work Log:
- Cloned lavilao/df-ai (token auth). Branches: develop (0.47.05-r8, ~29.4k lines C++), port-dfhack-50 (migration guide only), lua-rewrite-53.14 (full Lua rewrite, 6 phases, ~4.2k lines, 9 scripts in hack/scripts/df-ai*).
- Read MIGRATION_TO_50.md: v50 breaks ALL of: hooks.cpp (renderer/lockstep/x86 patching — incompatible), camera.cpp, embark.cpp (17 viewscreens), plus ui->plotinfo, ui_sidebar_menus->game, world field renames, plugin ABI change, DF is 64-bit only now.
- Decision: C++ port = rewrite of the hardest 30% from scratch. Lua rewrite path is already phased & 53.14-complete; DFHack 50+ has first-class Lua support. → CONTINUE LUA REWRITE to 53.16-r3. (User pre-approved: "if easier to rewrite in lua, do it".)
- Downloaded DF 53.16 linux classic (bay12) + DFHack 53.16-r3 Linux-64bit. Extracted both into /home/z/my-project/work/df-ai-port/.
- Missing lib libSDL2_image → fetched via `apt-get download libsdl2-image-2.0-0` + dpkg-deb -x into local-libs/ (no root on box).
- Headless runtime WORKS: SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy DFHACK_DISABLE_CONSOLE=1 via .dfhackrc. DF boots to title, DFHack 53.16-r3 ready, dfhack-run channel works (usage: `./dfhack-run lua "code"` — first arg is command, don't quote the whole line).
- Verified live: dfhack.getDFVersion() == v0.53.16 linux64 ITCH. df.global.ui GONE (removed in v50) → plotinfo is the replacement. 

Stage Summary:
- Runtime env: /home/z/my-project/work/df-ai-port/ (DF+DFHack installed, boots headless)
- Strategy: continue lua-rewrite-53.14 branch → target 53.16-r3, fix API drift, test full fortress cycle, then optimize.
- DFHack 53.14→53.16 Lua API delta is small (additions only: dfhack.maps.forEachTile etc., isCitizen dead-unit fix) — no structural breakage expected.

---
Task ID: 2
Agent: main (Z.ai)
Task: In-game testing + API drift fixes (lua-53.16-r3 branch)

Work Log:
- Session harness rebuilt (df_session.sh). CRITICAL discovery: dfhack-run's Console::init does fopen("/dev/stdout","w") which TRUNCATES any file its stdout redirects to — all previous "missing output" was this. All test helpers now pipe (never redirect dfhack-run to files directly).
- Sandbox kills all child processes at end of each tool call — DF must run within a single tool call session (boot, test, kill in one call).
- Fixed df-ai.lua module mode: added `if moduleMode then return AI end` guard (was falling through to handle_command, printing "df-ai is not running." at every boot via script-manager reqscript scan).
- Ran full API-drift audit: extracted all 261 df.*/dfhack.* refs from the 4.2k-line Lua rewrite, validated each against live DF 53.16-r3. Result: 101 hard-missing.
- Enum mappings documented (from live dumps + df-structures 53.16):
  * workshop_type: Craftsdwarf→Craftsdwarfs, Forge→MetalsmithsForge, Ash→Ashery; Smelter/MagmaSmelter/WoodFurnace/GlassFurnace/Kiln are FURNACE types (building_type.Furnace + furnace_type.*)
  * job_type: MakeBin→ConstructBin, MakeMeal→PrepareMeal, MakeMechanisms→ConstructMechanisms, ConstructCage→MakeCage, ConstructChair→ConstructThrone, MakeFloodgate→ConstructFloodgate, MakeHatchCover→ConstructHatchCover, MakeSplint→ConstructSplint, MakeTractionBench→ConstructTractionBench, ProcessCloth→WeaveCloth, ProcessThread→SpinThread
  * REMOVED jobs now raw REACTIONS (data/vanilla/.../reaction_other.txt): BrewDrink→BREW_DRINK_FROM_PLANT(_GROWTH), MAKE_MEAD, MakeSoap→MAKE_SOAP_FROM_TALLOW/OIL, TanATanHides→TAN_A_HIDE, Bookbinding→BIND_BOOK, MakeHive→MAKE_CLAY_HIVE
  * Stepladder/Wheelbarrow/NestBox/Hive/Screw/Jug = TOOL items → MakeTool + tool subtype from raws
  * item_type: BLOCK→BLOCKS, LEATHER→SKIN_TANNED, FURNITURE/PIECES were pseudo-categories (never real) — need semantic rework
  * job_skill: FORGING→METALCRAFT, WEAPONSMITH→FORGE_WEAPON, ARMORSMITH→FORGE_ARMOR, STRAND_EXTRACTOR→EXTRACT_STRAND, WEAVER→WEAVING, CLOTHIER→CLOTHESMAKING, CHEESE_MAKING→CHEESEMAKING, CUT_GEM→CUTGEM, ENCRUST_GEM→ENCRUSTGEM, MECHANIC→MECHANICS
  * tiletype_shape: Wall→WALL; Void/Abyss removed (→EMPTY check)
  * manager_order struct: amount→amount_total, is_valid REMOVED → status.validated bitfield; world.manager_orders is now COMPOUND workquota_handlerst (vector=.all, next_id=.manager_order_next_id); reaction_name field added for reaction orders
  * unit_relation_type.Owner→unit_relationship_type.PetOwner; unit_preference_type gone → unitpref_type (LikeLocation REMOVED entirely)
  * plotinfo.assignments→fortress entity: plotinfo.main.fortress_entity (pointer to historical_entity).assignments; ui.civ_id→plotinfo.main.fortress_entity.civ_id... (fortress_entity is POINTER)
  * building_activityzonest→building_civzonest
  * viewscreen_trade_listst/detailst NOT mapped in v50+ (trade UI is new data-driven screens); viewscreen_choose_start_sitest + viewscreen_setupdwarfgamest ARE mapped (embark automation viable)
  * general_ref_type.IS_JOB removed
- Full enum dumps saved to work/df-ai-port/enum_dump.txt (job_type 0-248, job_skill)

Stage Summary:
- Next: write df-ai/compat.lua (renames + runtime raw-subtype resolvers + modern manager-order creator), rewrite stocks.lua classify_item/queue_order, fix population/plan/trade call sites, re-run audit to 0 hard-missing, then world-gen + embark + full fortress integration test.
