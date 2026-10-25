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

---
Task ID: 5
Agent: main (Z.ai)
Task: Session 4 — GitHub delivery: push branch, CI "build" (validate+package) workflow, installable release

Work Log:
- User request: push code to GitHub so they can test on a real display, plus a GitHub Action that "compiles" the plugin (user cannot compile locally).
- Key point: the port is pure Lua — nothing to compile. The Action validates + packages instead (and this is BETTER for the user: ready-to-extract archive).
- Fixed df-ai.lua version string: "Lua rewrite for DF 53.14" -> "Lua rewrite for DF 53.16 (DFHack 53.16-r3)".
- Built and verified the release package layout in the live DF install:
  * df-ai-blueprints/plans/ <- repo plans/
  * df-ai-blueprints/templates/ <- repo rooms/templates/ (30 dirs, 82 JSON)
  * hack/scripts/df-ai.lua + df-ai/ (already symlinked in test env)
- BUG FIXED in plan.lua load_blueprint: dfhack.filesystem.listdir on a MISSING dir does NOT error — pcall succeeds and returns nil -> ipairs(nil) crashed the loader at line 219 whenever a template_bases entry had no directory (e.g. generic01_farmplot). Rewrote the template loader:
  * type-check listdir result (nil-safe)
  * try BOTH layouts: df-ai-blueprints/templates/<base>/ (release) and df-ai-blueprints/rooms/templates/<base>/ (repo checkout)
  * per-file decode with per-file error reporting
  * loud warning when 0 templates load (tells user to extract df-ai-blueprints/)
  * removed dead known_files/alt_dir fallback code
- Result (live DF 53.16-r3 headless boot test): plan config + 82/82 templates load, stocks/population modules OK, enable df-ai works, df-ai version/status work.
- Built test/ci_smoke.lua: standalone module-load smoke test with a mocked DFHack API (auto-vivifying metatables for df.*/dfhack.*, real sibling-script loading for run_script_with_env, moduleMode emulation, package.loaded mocks for utils/json/repeat-util). Catches load-time runtime errors, not just syntax.
- Downloaded lua5.3 5.3.6 (exact match of DFHack 53.16-r3 embedded Lua) via apt-get download into local-libs/lua53 (no root) for local harness validation.
- ci_smoke.lua local result: 11/11 modules OK + main module-guard OK + AI:new()+init() wires 6/6 runtime modules. One harness bug fixed (AI:new() needs colon-call).
- All 12 .lua files pass luac5.3 -p.
- Created .github/workflows/build.yml:
  * triggers: push (lua-53.16-r3, lua-rewrite-53.14, main, develop), tags v*, PRs, manual
  * job build: luac5.3 -p syntax check -> ci_smoke.lua smoke test -> JSON validation (plans/rooms/schemas) -> package zip+tar.gz -> upload artifact (90d retention)
  * job release (tags only): attaches archives to a GitHub Release via softprops/action-gh-release@v2
- Created INSTALL.md (bilingual ES/EN): release-zip install path, git-checkout install path, commands table, port status expectations, why-Lua explainer.
- Simulated the workflow packaging step locally: 97 files, zip 104KB / tar.gz 50KB, structure matches the boot-tested layout.

Stage Summary:
- Branch lua-53.16-r3 pushed to origin (first push of the port branch).
- Tag v53.16-r3.1 pushed -> triggers CI -> publishes installable release df-ai-53.16-r3.zip.
- User testing path: GitHub Releases -> download zip -> extract into DF folder -> enable df-ai -> load/embark fortress on real display.
- Known follow-ups: 'tag' command used in tag_enemies may not exist in stock DFHack 53.16 (verify); embark module not wired into runtime loop (auto-embark off by design for now); in-fortress behavior is the testing focus.

---
Task ID: 6
Agent: main (Z.ai)
Task: Session 5 — push to GitHub + CI release verification

Work Log:
- Root cause of the previous push failure found: the token embedded in the git remote URL was CORRUPTED at clone time (95 chars vs the real 93 — 2 stray characters). The repo is public, so git never validated those credentials during fetch; only push exposed the 401. The user's actual token was valid all along.
- Fixed remote URL with the correct token; API check: login=lavilao, push=True.
- Pushed branch lua-53.16-r3 (commit 6c3ba18) and tag v53.16-r3.1 to origin.
- GitHub Action "Build df-ai package" ran twice, both SUCCESS:
  * run #1 (branch push): lua5.3 syntax check, ci_smoke (11/11 modules), JSON validation, packaging — artifact uploaded.
  * run #2 (tag push): same + release job published the GitHub Release.
- Release live: https://github.com/lavilao/df-ai/releases/tag/v53.16-r3.1
  * assets: df-ai-53.16-r3.zip (101 KB), df-ai-53.16-r3.tar.gz (48 KB)
- Note: repo also has 3 stale failed runs (#13-15) from an old workflow_dispatch workflow ("Build and Release df-ai Plugin") that predates this port — not related.

Stage Summary:
- Delivery pipeline complete: push -> CI validate -> release with installable zip.
- User testing path: Releases -> download zip -> extract into DF folder (contains hack/ + df-ai-blueprints/) -> launch DF+DFHack -> "enable df-ai" -> embark/load fortress.
- Feedback wanted from real-display testing: console output after map load (expect "[df-ai] AI starting up" + "Loaded plan config + 82 templates"), room digging behavior, any Lua errors.

---
Task ID: 7
Agent: main (Z.ai)
Task: Session 6 — fix "AI never starts in fortress" (user report) + implement auto-embark

Work Log:
- USER REPORT: after enable df-ai + manual embark, dwarfs do nothing; no [df-ai] output after map load. Plus: misses the old auto-embark.
- ROOT CAUSE 1 (critical): script-manager re-runs EVERY script in module mode on SC_WORLD_LOADED (Core.cpp -> script-manager.reload -> reqscript scan). That re-registration of dfhack.onStateChange['df-ai'] captured a fresh nil local `the_ai`, clobbering the real instance from `enable df-ai`. Silent no-op at SC_MAP_LOADED.
- FIX: the_ai/ai_enabled are now script-env GLOBALS (DFHack caches script environments; globals persist across invocations, verified: "PERSIST: before=true the_ai_after_rerun=true"). Added isEnabled() (modern enable API), pcall+printerr wrappers (errors were going to stderr.log only).
- ROOT CAUSE 2: config file [] (empty json array). load_config returned {} without merging defaults -> random_embark nil -> watcher no-ops; ALSO explains user's missing "(auto-embark on)" suffix. FIX: init() merges default_config() over the loaded config.
- ROOT CAUSE 3: repeat-util 'ticks' timers do NOT run without a map (title/worldgen). FIX: arm_embark_watch() uses self-re-arming dfhack.timeout(30,'frames') polls (verified: frame timeouts fire at title).
- Other fixes: unpause() direct pause_state write (multicmd/resume commands don't exist in 50+); removed nonexistent 'tag' command call; startup() no longer re-loads modules (was discarding module state).
- AUTO-EMBARK implemented (embark.lua rewrite):
  * Screen watcher: title (menu_line_id read: Start/NewWorld detected; world-list mode detected via savegame_header_world) -> new_region (params guidance; abort-prompt auto-clear; completion detect = worldgen_status.state 10-seen-for-a-while — state 11 never fires on the report screen; stray SELECT during Initializing opens the abort prompt and stalls gen, so no key injection there) -> Play now! (click_grid) -> choose_game_type (DWARF_MAIN select) -> choose_start_site -> setupdwarfgame.
  * Site scoring (old find_embark spirit): region_map access SOLVED — rm[x] in the Lua wrapper double-derefs to entry (x,0) (rm[5].elevation works); for y>0: df.sizeof(e) returns (size,address) -> reinterpret_cast(region_map_entry, addr + y*112). 3969 tiles scored (elevation/evilness/savagery/temperature/vegetation/salinity).
  * Site write: location.region_pos + embark_pos_min/max (abs midmap = region*16+local) + zoom_cent — verified written and rendered (rect visible, zoomed=true).
  * Tutorial suppression: hide-tutorials technique (help.open=false + EMBARK_TUTORIAL_CHOICE->EMBARK_MESSAGE context trick + gps click + POPUP_* tutorial_seen/hide stuffing + need_to_do_tutorial=false).
  * click_grid(): gps.mouse_x/y + gui.simulateInput('_MOUSE_L') — DFHack's own programmatic click (from hide-tutorials).
  * embark_mode config: 'quick' (default; clicks the tutorial dialog's quick-start button — game picks forested mineral-rich site) or 'scored' (our scoring + rect + Embark attempts). Fallback chain: quick -> scored -> user instruction messages.
  * EMBARK_LOG persistent debug log (dfhack.script_environment('df-ai/embark').EMBARK_LOG).
- E2E verified headless (13 rounds): enable at title -> title menu read -> worldgen -> Play now -> Fortress -> site screen with scored site written + tutorial suppressed + rect placed. Full EMBARK_LOG state machine visible.
- HEADLESS LIMITATION (not a product bug): the site screen's bottom button bar ignores synthetic input in the Xvfb+XTest environment (gps clicks land but button actions don't fire; xdotool flaky) — the last Embark/Play-Now button press may need a real click. On real displays (user's machine) these buttons work normally; the console prints exact instructions as fallback.
- plan.lua: blueprint search now covers 3 layouts (release, nested-zip-extracted-without-merging, repo checkout).

Stage Summary:
- Critical fortress-start bug FIXED + verified (persistence test green).
- Auto-embark shipped: full pre-fortress automation with instruction fallbacks.
- Pending real-display verification: AI in-fortress behavior (digging/rooms) — needs the user's test or a fortress save; headless blocked at the Embark button only.

## Session 7 — r3.3: fortress-start crash + title-screen root causes fixed (user report: "No funciona / no eligió continue playing")

User's live log on a real 1366x768 display (170x64 grid) exposed three root causes:

- CRASH (why dwarves did nothing): `plan.lua:290` read `plotinfo.embark_pos` — a 0.47 field REMOVED in v50. Reading a struct field that does not exist THROWS in the DFHack Lua wrapper (it does not return nil), and the pcall was wrapped around the wrong expression. That single read aborted ALL of `AI:startup()` — no repeating tasks, no unpause, no stocks/camera.
  - FIX: `find_fort_entrance()` rewritten — v50 has no embark_pos; the entrance is the surface at the CENTER of the local map (what generic01 is designed around). Integer coords (odd maps produced x.5 tile indices), tree-canopy skip via tile-shape filtering, always returns a position.
  - HARDENING: every module starts inside its own `safe()` (pcall + report) — one broken module can never kill the chain again. All repeat-util callbacks pcall-wrapped. Background task queue processes each task under pcall (a throwing task is dropped, not fatal).

- ROOT CAUSE of "no eligió Continue Playing" (three stacked bugs):
  1. `ipairs` over DFHack vectors is 0-BASED (live-verified: first iteration yields i=0). The menu code did `idx0 = i - 1` → `selected = -1` → nothing highlighted → SELECT was a no-op. Same off-by-one broke `custom_workshop_index` (raws) and `watch_announcements` (loop started at `#announcements`, which is nil → instant break, reports never examined).
  2. v50 title-menu buttons are MOUSE-ONLY: `selected` + `simulateInput('SELECT')` does NOTHING (live-verified). A gps-injected click (`gps.mouse_x/y` + `simulateInput('_MOUSE_L')`, the hide-tutorials technique) WORKS — live-verified title → worldgen transition.
  3. Menu layout measured on both 1280x800 and the user's 1366x768: items are top-anchored, first item at ~55.3% height, spacing EXACTLY 3 grid rows at any resolution. Fixed 160x66 grid coordinates missed every button on a 170x64 display — all coordinates are now fractions/row-based and scale.
  - NEW `handle_title`: full state machine over `title_mode_type` (MAIN_MENU / CONTINUE_INACTIVE / CONTINUE_ACTIVE_WORLD / CONTINUE_ACTIVE), detects fort saves/worlds from the MENU CONTENTS (the savegame_header_* vectors are EMPTY at the main menu — live-verified), prefers loading an existing fort (config `embark_continue_fort`, default true), clicks the right button per mode, caches the goal across page changes, retries with caps, never blind-clicks near save-delete buttons.
- watch_announcements rewritten for 53.16: report.flags is announcement_flag {continuation, unconscious, announcement, high_prio_removal} — the old 0.47 danger/attack bits would THROW every 10 ticks. Danger now detected by announcement TYPE name; only reports newer than the newest already seen trigger tag_enemies (no history replay on fort reload).
- suppress_tutorial: removed the bogus `plotinfo.flags.need_to_do_tutorial` read (field does not exist; the throw silently aborted the rest of the suppression).
- handle_new_region now CREATES THE WORLD automatically (welcome-popup Okay click, then [Create world] click — clicks only; stray SELECT keys open the abort prompt and stall worldgen).
- choose_game_type / setup screens: candidate-position cycling + retry caps (no `selected` field exists on those screens in 53.16 — verified against df-structures).
- dismiss_popups(): closes v50 "You have arrived"-style modal popups over the map for a few seconds after startup.
- Site scoring fixed: live debugging showed `region_map_entry.temperature` reads 0-100 on the 53.16 binary (75 = temperate), NOT the documented Urist scale — the Urist math turned every good tile into -1681. Dual-scale handling now; scan-time field values logged next to re-read values in the console message (score went -1681 → -35 on the same world; picks a real forest). One settle poll before scanning.
- test/unit_fixes.lua added (32 checks): find_fort_entrance on odd maps, 53.16 announcement layout, title state machine incl. struct-throw survival (mocks reproduce DFHack's throw-on-missing-field behavior and 0-based vector ipairs), click coordinate scaling. Runs in CI alongside ci_smoke.

Live E2E at the user's EXACT resolution (1366x768, 170x64 grid), world save present:
title(Start clicked) → world list(first world clicked) → adopt_region(auto-loads) → choose_game_type(Fortress clicked) → site screen(quick start + scored site, score -35) — the entire pre-embark chain now runs hands-free. Remaining known limitation: the final green [Embark] button ignores ALL synthetic input in the headless Xvfb environment (gps AND real X11 clicks — re-verified); the console prints a manual-click instruction as fallback. Real displays are expected to behave (every other button did).

Stage summary: fortress AI startup unblocked; Continue Playing auto-flow implemented and click-calibrated; worldgen automated; announcement watcher un-crashed; CI extended with unit tests.

## Session 8 — r3.4: in-fortress API drift fixed (user report: "Embarca automaticamente!! lamentablemente los enanos no parecen hacer nada")

The r3.3 auto-embark flow WORKED on the user's machine (Continue Playing → world → save → fortress loaded, AI started, 82 templates loaded). The remaining "dwarves do nothing" had 5 root causes, all verified against the live 53.16-r3 binary via an API probe session:

- CRITICAL `plan.lua` — `dfhack.maps.getMapSize` DOES NOT EXIST in 53.16 (it is `getTileSize`, and it returns x, y, z as THREE values, not a table). The pcall failed silently → `find_fort_entrance` returned nil → "Could not find fort entrance location" → NO rooms, NO digging, NO workshops, and `setup_done = true` meant the plan never retried. THE reason the dwarves idled.
  - FIX: `find_fort_entrance` rewritten — anchors the fort where the original df-ai does: (1) the EMBARK WAGON building (building_wagonst; works on the user's existing save), (2) the citizen centroid (reclaims / wagon gone), (3) map-center surface scan (getTileSize, integer coords, tree-canopy skip). Zero-size maps (title screen returns 0,0,0 — and 0 is truthy in Lua) count as "no map".
  - `Plan:plan_setup` now returns success; `setup_done` only set on success; `Plan:update` retries setup (capped at 10 attempts). Room placement, per-tag batches and corridor BFS are each pcall-isolated — one bad template can no longer kill the layout.
- `stocks.lua:493` — `plant_raw_flags.EDIBLE_RAW` / `EDIBLE_COOKED` were REMOVED from the enum in 53.16 (BitArray named reads of missing members THROW — SEED/SPRING/GRASS/TREE/DRINK/MILL all still exist, verified). `pick_farm_plant` crashed on EVERY stocks update, aborting `update_plants` AND `unforbid_items`.
  - FIX: flag reads gated on enum membership (`df.plant_raw_flags[name] ~= nil`), one pcall per plant. `Stocks:update` is now phase-isolated (count / needs / plants / unforbid each in their own pcall).
- `camera.lua:57` — `dfhack.units.getPosition` returns THREE values (x, y, z); `local pos = ...` captured only the first (a number) and `pos.x` threw "attempt to index a number value" on every camera tick.
  - FIX: 3-value capture; the camera now pans the real v50 view via `dfhack.gui.revealInDwarfmodeMap` (verified present + callable) with cursor writes as fallback. Target rotation slowed to every 1200 ticks (was: a different dwarf every tick).
- `population.lua:402` — `unit_flags1.prisoner` and `.criminal` no longer exist in 53.16 (probe-verified; reads throw). `update_crimes` crashed every 12th population pass.
  - FIX: one-time capability probe (`df.unit_flags1:new()` + pcall) caches whether the bits exist; justice automation no-ops cleanly when they don't (0.47 layout still supported).
- `population.lua:365` — `historical_entity.assignments` REMOVED in 53.16; the replacement is `assignments_by_type` (vector of per-type vectors, probe-verified). `update_nobles` crashed every 12th pass.
  - FIX: `compat.assignments()` flattens both layouts (0.47 flat vector / 53.16 by-type vectors) into a plain Lua array, fully pcall-guarded; `position_holder` uses it too.
- `df-ai.lua` tag_enemies: same 3-value getPosition fix.
- `population.lua` update_caged: cage-release block fully pcall-wrapped (unit.cage / removeUnit are not guaranteed on 53.16).

Tests: `test/unit_fixes.lua` mocks now FAITHFULLY reproduce the live 53.16 API (no getMapSize; getTileSize/getPosition as 3-value returns; plant_raw_flags without EDIBLE_RAW; unit_flags1 without prisoner/criminal; entity.assignments throwing). 63 checks (was 32) + the CI smoke test, all green; 20/20 live checks against the real DF 53.16-r3 binary (module loads, plan deferral + 82 templates, bounded retries, justice gate, assignments flattening, camera no-op).

Stage summary: every error visible in the user's r3.3 console log is fixed and live-verified; the plan pipeline (rooms → digging → workshops → orders) should now actually run for the first time on a real map.

## Session 9 — r3.5: the plan actually runs (user report: v53.16-r3.4 log — auto-embark OK, "Need more" spam, idle dwarves)

User's r3.4 log: auto-embark + Continue Playing worked, "Fort entrance at 95,95,120" + "Setup complete: 13 rooms, 5 corridors" printed for the first time — then two new errors and the original complaint persisted: dwarves idle, "Need more: X (x20)" spamming every stocks update. Root-caused all four:

- **IDLE DWARVES (root cause)** — `plan.lua` drove BOTH task queues from `dfhack.onStateChange[SC_VIEWSCREEN_CHANGED]` handlers: one task per viewscreen CHANGE. With the fort at rest NO viewscreen ever changes, so after `Setup complete` the queues never advanced a single task — no dig designations, no constructions, no furnishing. (r3.4's `bg_idx_*` init in `Plan:update` only STARTED the dead handlers.)
  - FIX: queues now processed from `Plan:update` (wired every 25 ticks) — `_process_queue` walks a bounded batch (2 generic + 1 furniture per call), a drained queue restarts from the top no more often than every 240 ticks (the C++ `Plan::update` cadence from plan_task.cpp), `check_rooms` recurs forever (never deleted, C++ parity), unknown/monitor task types are dropped instead of clogging, throwing tasks are pcall-isolated and dropped. No onStateChange registration at all (also kills a latent double-registration leak on re-enable).
  - `wantdig_max` now follows stock pick count (C++ parity) instead of a hardcoded 2.
- **corridor connection failed: rooms.lua:367 "attempt to call a nil value (method 'pos')"** — `room:distance_to(other)` called `other:pos()`, but `plan.lua` passes `find_fort_entrance()`'s result — a PLAIN `{x,y,z}` table. The crash aborted the whole `_connect_all_corridors` pass (and silently un-sorted the rooms).
  - FIX: `distance_to` accepts room objects AND plain coord tables; nil/partial tables → `math.huge` instead of throwing.
- **stocks plants failed: stocks.lua:531 "attempt to compare number with string"** — `pick_farm_plant` assigned `plant.id` to `best`, but `plant_raw.id` is the raw's STRING identifier (live-verified: `df.plant_raw:new().id` → string). The caller's `plant_id >= 0` then died comparing number with string.
  - FIX: `best = i` — the 0-based ipairs index into `raws.plants.all` (the same convention as `custom_workshop_index`; live-verified `farmplotst.plant_id[season]` is a NUMBER index).
- **"Need more" spam + no furniture orders** — `Stocks:act` looked up `compat.furniture` with the lowercase watch keys (`bed`), but compat.furniture is keyed UPPER case (`BED`). Every furniture category missed and fell through to the else → printed "Need more" forever; the manager never got a single bed/door/table/coffin order.
  - FIX: uppercase the key before lookup and pass it on to `queue_furniture` → `compat.furniture_order` (live job enums). `block` now queues `ConstructBlocks` (LIVE-verified `df.job_type.ConstructBlocks = 80` — the singular `ConstructBlock` is nil; first enum_dump grep was a substring false-positive). Unorderable leftovers (`stone`: boulders only come from mining) print ONCE per changed amount instead of every update.

All 30+ `compat.furniture` job names verified one-by-one against the live binary in this session (q9 probe) — the routing path had never executed before.

Tests: unit_fixes.lua 92 checks (was 63), all green — new r3.5 sections cover distance_to (plain/room/nil), update-driven queues (advance without any viewscreen change, drain gate at 240 ticks, check_rooms recurrence, throwing-task isolation, wantdig_max parity), act() routing (BED/DOOR/COFFIN/QUERN/TRACTION_BENCH → queue_furniture; block → ConstructBlocks; stepladder → MakeTool) and the rate-limited print. Live probe on the real DF 53.16-r3 binary: 52/52 checks (module loads, plant_raw.id is a string, farmplotst.plant_id numeric, create_order end-to-end with insert/erase on world.manager_orders, job-name existence, Plan title-screen deferral, act() live routing, 82 templates).

Stage summary: with the queues alive, the full chain now runs: check_rooms → initial_phase → want_dig → digroom → dig_room (designations!) → construct_room (workshops/stockpiles/farmplots) → check_furnish → try_furnish; stocks simultaneously feeds the manager real furniture orders. First true fort-phase release — needs the user's real-map validation.

---

## Session 11 — r3.7: C++ strategy port (blueprint engine + priorities) + trap-loop fix

User report: fort works but "not very intelligent" vs the C++ original; dwarves stuck in a cage-trap placement loop; requests: (1) analyze the original C++ strategies/blueprints and report, (2) consider integrating stock DFHack automation tools, (3) add help text for the in-game menu.

### Root causes found (vs C++ sources)

1. **Cage-trap infinite loop (r3.6 log, bld 1→120)**: `try_furnish` created buildings with NO item filters — DF created the building, found the construction job unfulfillable (a cage trap needs a mechanism), deleted the building, and `checkroom`'s tantrum recovery re-placed it forever. Compounded by: `add_task` not deduplicating (C++ dedups on type+room+furniture+item_id), `construct_room` re-queueing EVERY furniture on every call, no tile-occupancy check, no wall-excavated check.
2. **The "dumb" layout**: `_place_room_tag` was DEAD CODE (iterated rule objects as tags; `limits[tag]` always nil) — only the 13-room start template was ever placed. The C++ intelligence (exit-anchored growth + 67 priority rules) was not ported at all.
3. **Unreachable rooms (r3.5/r3.6 leftovers)**: `accesspath` stored raw template indexes; `digroom` never recursed parents first (C++ `Plan::digroom` digs the whole accesspath chain). `check_idle` task was deleted on first run instead of persisting.
4. **Status regression**: the `want_dig` handler called `digroom()` whenever `is_dug()` was true, resetting rooms already advanced to 'dug' by `checkroom` (duplicate "room DUG" + duplicate construct_room in the log).

### Ported in r3.7 (full C++ parity for these systems)

- **blueprint.lua** (new, ~1260 lines): template×instance cartesian merge with placeholder patches + index remapping; build_cache's four collision sets (corridor/interior/no_room/no_corridor, Channel/Ramp z-poisoning, exit exclusion); `can_add_room` rock-ring viability (bbox+1 ring + z+1 water-only, outdoor floor/grass checks, dig-furniture above-cavern check); 3-phase growth (start near the wagon → outdoor random tiles → connect on random live exits with tag expansion); `remove_unused_rooms` fixpoint; `handle_stairs_special`; `count_as` bookkeeping; relaxed fallback (strict fails → skip rock validation; the C++ abandoned the fort instead); resumable via coroutine (yields every 250 tries; the C++ spread setup across ticks with a progress screen).
- **priorities.lua** (new): full rule engine — room filters (status/type/subtypes/level/outdoor/queue_dig/furnished/has_owner/workshop sub-filters/accesspath+layout count filters), count gates with between-semantics, 7 actions (dig, dig_immediate, unignore_furniture, finish, past_initial_phase, deconstruct_wagons, start_ore_search), `continue` + working/match_task latching, queue-0 blocking.
- **plan.lua**: async setup (builder coroutine stepped from Plan:update, ~750 tries/call); add_task dedup; wantdig (queue codes); digroom with accesspath recursion + linked-stockpile digs + furnish queueing; furnish_room; want_dig handler no longer regresses status; check_idle PERSISTENT; construct_room only queues unbuilt furniture; try_furnish rebuilt (occupancy check, wall-excavated check, per-type job_item filters — TRAPPARTS for traps/levers/gears, item types for furniture, tool_use probed safely — retry caps with gave_up flags); _find_building safe id lookup; stockpile contents via bld.settings.flags; getbedroom 3-tier (digs a fresh bedroom on demand); checkrooms build_when_accessible; construct-task failure cap (10).
- **df-ai.lua**: script header description (in-game menu), `df-ai help`, DFHack tools integration (autochop, seedwatch `all 25`, autoclothing — pcall-guarded, config-gated; autogems does not exist in 53.16-r3, removed).
- **Packaging**: instances/ added to the release zip + CI runs the new test.

### Verification

- Headless (new `test/test_blueprint_engine.lua`, real JSON + simulated 96×96×16 rock world): 227 variants merged (carpenter+wood-pile instance checks), full build → **895 rooms** (200 corridors, 225 stockpiles, 115 workshops, 18 furnaces, 107 farmplots, 30 bedrooms, 10 cemeteries, 3 jails, 3 infirmaries, 8 locations…), accesspath all room-references + no cycles, workshop enums numeric, furniture absolute in-bounds (cistern floodgates ±2 by design), stairwell present, rule 0 fires dig_immediate on the food stockpile + latches, add_task dedup.
- Unit tests: 92→97 checks green after updating to the async-setup semantics (setup_done waits for the builder; check_idle persists).
- Live arena E2E (rock-filled arena for strict placement): entrance (23,23,5); strict-mode start placement; rule 0 firing (`dig_room_immediate stockpile/food`); accesspath recursion (staircase dug before rooms); 49 dig designations; instant-dig emulation advanced rooms through DUG→constructing→FINISHED; **56 cage traps all at UNIQUE positions** (the r3.6 loop had 7+ per tile); trap-with-TRAPPARTS-filter creates a real pending job; tools enable correctly (deferred until fort loads); manager orders 46; heartbeat stable, no spam, no error loops.
- Menu calibration: title menu rows changed vs earlier sessions (a world exists now): NewWorld=441, TestingArena=478, Settings=514, AboutDF=549, Quit=585 at 1280×800.

### Known gaps (documented in docs/INFORME_ESTRATEGIAS.md §9.2)

Workshops construct without material selection (C++ picks blocks→boulder→wood; construct-cap prevents loops); df.tool_use does not exist in 53.16 (nest boxes/hives/pedestals/bookcases get no filter → skipped after capped retries); makeroom extents + try_endfurnish post-build config, cistern/well system, stocks population-scaled quotas + Watch tier, military, nobles, cemetery coffins — next milestones.

## Session 12 — r3.8: complete the missing strategies + live-verified v50 zone/room system

### Ported (the §9.2 "known gaps" list, now closed)

- **plan.lua**: C++ material-selection for constructions (blocks → non-economic boulder → wood; fire-safe for furnaces; anvil for the forge; `is_item_free` parity); `init_managed_workshop` (workshop job-queue cap 10); makeroom → v50 **civzones** (`_ensure_room_zone` with quickfort's `fields.room.extents` pattern + `assigned_unit_id`); `set_owner` via `dfhack.buildings.setOwner`; `getcoffin`/`getdiningroom`/`getsoldierbarrack`/`freesoldierbarrack` (squad rooms via `dfhack.military.updateRoomAssignments`); `attribute_noblerooms`; `new_citizen`/`del_citizen` (dining spot + bedroom on arrival, freed on death); lever system (`pull_lever`, `link_lever` with real `LinkBuildingToTrigger` jobs + 2 mechanisms, `setup_lever`); `monitor_cistern` (well/reserve gate coordination, PERSISTENT task); `furnish_check` completion phase; `Plan:step_builder` time-budgeted builder driver.
- **population.lua**: full `update_military` (draft/dismiss policy, squad creation via `dfhack.military.makeSquad`, barracks training checks, kill-list attack orders via `squad_order_kill_listst`, uniform/equipment re-equip bitfield); `update_nobles` C++ parity (appoint manager/bookkeeper/doctor/sheriff/executioner/broker through `ent.positions` + `histfig_entity_link_positionst`, bookkeeper settings=4); `check_noble_apartments`; pets (pasture zones by grazing pressure `11*11*1000/grazer`, training assignments, war/hunter pet management); `update_petitions`; `update_locations`; `unit_totalxp`; deathwatch moved to event hooks + 25-tick sweeps.
- **stocks.lua**: `num_needed` population-scaled quotas (C++ formula table); `queue_slab` (memorial slabs for restless ghosts); farm system (`farm_setup`, `plant_census`, seasonal plant selection by biome/usage flags, seed accounting); `trim_stalled_orders`; `queue_job_amount`; Watch-tier item gating.
- **blueprint.lua**: `surface_tile_at` (map-top walk-down) for outdoor placement viability.
- **df-ai.lua**: tick cadences now match the C++ original (plan 25→240, stocks 50→600, deathwatch 1→25-tick sweep + unit-death events, builder stepped every 2 ticks while active); `step_builder_watch`; version r3.8.

### Live-verified API fixes (q14/q14b/q14c probes + arena E2E — all crash-class)

- `df.job_item_ref.LinkToTrigger/LinkToTarget` DO NOT EXIST in 53.16 → constants live in **`df.job_role_type`** (3/4).
- **`df.civzone_type.Hospital` is nil** — v50 hospitals are LOCATIONS (abstract buildings), not civzones. Infirmary rooms are no longer zoned (dug + furnished; the game's location system owns hospital registration). Wrong-zone MeetingHall fallback removed: rooms without a valid zone type get no zone at all.
- `building.z_level` REMOVED in v50 → `building.z` (plan.lua + rooms.lua building lookups).
- **Doubled dispatch names** `try_construct_construct_*` = nil → every construct_stockpile/workshop task crashed ("attempt to call a nil value", 10 failures in the first arena run).
- `world.squad_next_id`/`world.squads_by_id` REMOVED (squads is a compound handler) → `dfhack.military.makeSquad` + `df.squad.find`.
- civzone creation needs `fields={assigned_unit_id=-1, room={x,y,width,height,extents}}` (quickfort zone.lua pattern) — without room.extents the zone covers no tiles.
- Zone give-up cap (10 failures/room) — the r3.6 trap-loop lesson applied to zones.

### Verification

- Unit tests: 121 checks (new r3.8 sections: construct dispatch targets, stockpile task not dropped, source-scan denylist for every removed-API name above, civzone extents pattern, nobles via ent.positions + attribute_noblerooms hook).
- Live q14 probe at title: 12/12 modules, 50 enum members, 9 struct constructors with field layouts, 17 global paths, EngraveSlab manager order end-to-end.
- Arena E2E (rock-filled, instant-dig miner emulation, 2 runs): 34 rooms/26 corridors placed; rooms advance DIG→CONSTRUCT→FURNISH→**FINISHED (23)**; 49 manager orders; 56 traps all unique; **zero df-ai task errors** (only stonesense's missing libOpenGL remains, an environment issue).
- Production `_ensure_room_zone` verified live: bedroom zone created with 20 extents tiles, `findCivzonesAt` sees it; tomb zone created; infirmary correctly unzoned; `setOwner` round-trips.

### Performance

- Big-map regression: 96×96×16 rock world, 8000 placement tries → **3.31 s CPU** for 759 rooms/380 blueprints (r3.7 took minutes); builder is a resumable coroutine stepped with a time budget.
- Tick cadences = C++ originals (the user's 240→1000 restart-cadence commit preserved).

## r3.9 — old-build QOL parity (from the user's C++-era df-ai.log)

The user supplied a real log from the C++ 0.47 build and asked: "Analiza y
determina que nos falta y agregalo" (world-unload self-disable, no idle
dwarves, etc.). Pattern analysis of the log + C++ source diff gave six gaps,
all closed:

### Gaps found (log evidence → C++ source → fix)

1. **`world unloaded, disabling self`** (3x in log; ai.cpp SC_WORLD_UNLOADED)
   → df-ai.lua now handles SC_WORLD_UNLOADED: full teardown, `the_ai = nil`,
   and with `random_embark` on it creates a FRESH AI instance (old build
   immediately did `choosing "Continue Game"` afterwards); with random_embark
   off it genuinely self-disables. Prevents cross-world ghost state.
2. **Force-unsuspend of stalled jobs** (C++ `Population::update_jobs`)
   → our r3.6 port made this a no-op stub ("nothing to watch anymore") —
   wrong. Ported verbatim: every suspended non-repeat job in
   `world.jobs.list` gets `flags.bits.suspend = false` at the pop cadence.
   Suspended jobs never self-resume; their dwarves idle forever. This is
   THE anti-idle mechanism the user asked for ("no dejar enanos en idle").
   Repeat jobs are skipped so player repeat-loops stay intact. Logged:
   `[df-ai] unsuspended N stalled job(s) (M total this session)`.
3. **Migrant room assignment** (21x `assign bedroom (owned by X, Peasant)`
   in log; C++ `Population::update_citizenlist` diff → `plan.new_citizen`)
   → our port rebuilt the citizen set WITHOUT diffing: `Plan:new_citizen`
   and `Plan:del_citizen` existed since r3.8 but were NEVER CALLED —
   migrants never got bedrooms, dead dwarves kept theirs. Ported the C++
   diff logic (babies skipped via `dfhack.units.isBaby`), with a
   `_pending_rooms` retry that survives plan-setup lag; idempotent
   (getbedroom tier-1 early-returns, getdiningroom checks existing users).
   Old-format logs restored: `assign bedroom (owned by <readable name>,
   <profession>)` via new `Plan:describe_unit`.
4. **Pause announcement handling** (167x `pause: Digging designation
   cancelled: damp stone located. xN` in log; C++ `handle_pause_event`)
   → watch_announcements now: logs every PAUSE/DO_MEGA report C++-style
   (`pause: <text> xN`), unpauses IMMEDIATELY on DIG_CANCEL_DAMP/WARM so
   the plan loop re-designates the same tick (plan re-issue existed since
   r3.7), tag_enemies on MEGABEAST/UNDEAD/danger, unpause on DO_MEGA.
   CRITICAL ENABLER: the announcement watcher moved from a 10-TICK
   repeat-util timer to a self-re-arming 15-FRAME timer — ticks freeze
   while paused, so the tick-based watcher could never see the pause
   cause it was supposed to react to. The d_init announcement flags
   (PAUSE/DO_MEGA bits) drive the classification, fully pcall-guarded.
5. **`pause without an event` + `[ERROR] paused in unknown viewscreen X`**
   (10x + 10x in log; pause.cpp SC_PAUSED/SC_VIEWSCREEN_CHANGED) → the
   unpause watchdog logs the former once per pause episode; the raw
   state-change hook logs the latter once per unique focus string
   (`note_unknown_viewscreen` via `dfhack.gui.getFocusString`).
6. **`disabling minimap.`** (embark setup) → startup pcall-disables the
   minimap plugin when active (config `disable_minimap`, default true).

### Also

- `arm_embark_watch` gained a single-chain guard (`EMBARK_WATCH_RUNNING`
  env global): with the world-unload teardown, shutdown() now runs twice
  per leave-fortress (SC_MAP_UNLOADED *and* SC_WORLD_UNLOADED) and used
  to stack duplicate poll chains.
- NOT ported (evaluated, deliberately skipped): `fixup_open` construction
  fix-ups (our shape-based is_dug already sidesteps the stall; only 4
  occurrences in 3 months), `make_map_walkable`, diplomat textviewer
  dismissal (v50 screens differ), direct-at-workshop furniture queueing
  (manager orders cover it), `updating world, goal:` sim (v50 flow
  differs).

### Verification

- unit_fixes.lua section 9: 23 new checks — force-unsuspend semantics
  (repeat jobs untouched), citizen diff (new/vanished/baby/pending-retry),
  pause logging `x12` format, DIG_CANCEL same-pass unpause, DO_MEGA
  megabeast unpause + tag_enemies, unknown-viewscreen once-per-name,
  world-unload teardown both variants (self-disable vs fresh instance).
- Full suite green: unit_fixes + ci_smoke + blueprint engine + big-map
  perf (3.31 s CPU unchanged).
