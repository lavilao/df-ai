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

---
Task ID: 3
Agent: main (Z.ai)
Task: df-ai 53.16-r3 — module verification + full game-flow automation (worldgen→embark)

Work Log:
- Committed prior session's uncommitted work: compat.lua + API fixes (976a4cc), WORKLOG.md in repo (ff9fb93).
- API audit re-run: 0 hard-missing of 207 refs (was 101). All 11 df-ai modules load cleanly in live DF 53.16-r3 (11 OK / 0 FAIL). compat.lua's 26 resolvers all execute; world-dependent refs resolve at title screen.
- Fixed root-cause bugs in test harness:
  * xwd -root does NOT composite child windows on Xvfb -> use xwd -id <DF window> (rendering was never broken!)
  * xdotool needs LD_LIBRARY_PATH (local-libs) — all "dead clicks" in new scripts were silent libxdo.so load failures
  * dfhack-run output carries ANSI escapes -> all focus-string pattern matches were failing (strip with sed)
  * dfhack.gui.simulateInput DOES NOT EXIST in 53.16 -> use require('gui').simulateInput (Lua gui module)
  * v50 screens ignore synthetic keyboard input + gps mouse injection gets clobbered by real X11 pointer poll
  * DF v50 linux stores saves in XDG: ~/.local/share/Bay 12 Games/Dwarf Fortress/save/ (NOT data/save!)
- Discovered DF CLI worldgen: ./dwarfort -gen <id> <seed> "POCKET ISLAND" (command line.txt); world persists to XDG saves.
- Full UI flow automated via xdotool window-relative clicks (1280x800 forced via WINDOWED:YES+WINDOWEDX:1280):
  * title "Create new world" = (632,442) [5-band layout; 6th band at y=381 when world exists]
  * welcome popup Okay = (641,309)/(671,309) — MUST dismiss before anything else works on new_region
  * new_region "Create world" = (846,753); params settable via Lua (simple_world_size=0 etc.)
  * worldgen-complete: world_done check via world.world_data.world_width > 0
  * choose_game_type: gametypes 0=DWARF_MAIN 1=ADVENTURE_MAIN 2=VIEW_LEGENDS; Fortress = (636,286)
  * choose_start_site: location.region_pos valid (e.g. 11,51); embark_pos_min/max are ABS midmap coords (region*16+offset)
  * region_map access in Lua is NOT [x][y] — flat pointer array ("Cannot read field region_map_entry.N" error) — needs flat indexing fix
  * tutorial popup blocks site screen: box x 552-877 y 300-650 (top border magenta line y=297) — buttons TBD via grid-scan
- Flow state: title→adopt→game_type→Fortress→site screen all working; stuck at tutorial popup dismissal + Embark button.

Stage Summary:
- Module-level port: COMPLETE (0 missing refs, 11/11 modules load)
- Game flow: worldgen + world persistence WORKING; site screen blocked by tutorial modal
- Next: grid-click tutorial popup dismissal, Embark button, setupdwarfgame Play Now, then df-ai fortress observation
- All flow scripts in work/df-ai-port/flow*.sh; captures in captures/

---
Task ID: 4
Agent: main (Z.ai)
Task: Session 3 continued — full game-flow automation for df-ai integration testing

Work Log:
- Ran flow19 (definitive flow) multiple times with progressively hardened clicking.
- SOLVED: reliable click pattern = xdotool windowfocus at boot + 2s hover-settle + click (first click after focus is eaten; retry same position).
- SOLVED: worldgen-complete screen buttons via border-pixel analysis: [Play now!] = x 20-109, y 261-285 center (65,273); [Keep world] = x 123-437.
- SOLVED: bottom tabs on unzoomed site screen: Find embark location (700-840,753), Reclaim (840-1060), Choose origin civ (1060-1260) — but these are HOVER substates.
- SOLVED: Embark button on CLEAN zoomed view = x 840-950, y 735-795, center (895,765) — verified by crop-reading (f14_fail.png).
- DISCOVERED: zoomed local view is INPUT-DEAD in this environment (Xvfb + xdotool XTest + SDL2/XI2): 81-position grid scans, slow clicks (4s holds), drags, gui.simulateInput fake clicks (_MOUSE_L_DOWN + _MOUSE_L), xdotool keys, all keys via simulateInput — ALL ignored after zoomed_in=true. Screen renders + Lua state fully readable/writable (zoomed_in, zoom_cent, location.embark_pos_min/max all settable), enabler receives lbut_down pulses, but button actions never fire.
- Verified NOT the cause: overlay plugin (disabled, no change), site finder (not running), animation timers (0), help popups (closed), main_designation_doing_rectangles (cleared, no change), FPS (15 gfps, fine), window focus (windowfocus applied).
- Tried: pushing df.viewscreen_setupdwarfgamest:new() via dfhack.screen.show() — screen pushes (focus: setupdwarfgame/Dwarves) but is a hollow shell (dwarf_info=0, points=0) — the real Embark button handler does game-state setup that can't be replicated from Lua.
- Region_map Lua access: NOT [x][y] — flat pointer array ("Cannot read field region_map_entry.N") — needs flat-index fix (x*height+y or similar) for df-ai's embark site finder.
- DF v50 title menu (1280x800 windowed): 6 buttons at y 381/442/478/514/550/586, x-center 632. (632,442) = Create new world (no world) / 2nd item.

Stage Summary:
- df-ai port itself: COMPLETE at module level (0 missing API refs, 11/11 modules load, compat resolvers work).
- Integration test blocker: v50 embark screen input in headless Xvfb env — zoomed local view ignores ALL synthetic input (env limitation, not a df-ai issue).
- Documented assets: 20+ flow scripts (flow*.sh, qc*.sh), screenshots in captures/, all UI coordinates mapped.
- Next session options: (a) real XI2 event injection client (python-xlib), (b) pre-made fortress save hunt (DFFD/forums), (c) Xorg-dummy display server instead of Xvfb, (d) DFHack-native embark assistance via C++ plugin.
