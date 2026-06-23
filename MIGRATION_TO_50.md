# Migration Guide: df-ai from DFHack 0.47.05 to DFHack 53.14

This document catalogs ALL breaking changes, removed APIs, renamed structures,
and new APIs needed to port df-ai from DFHack 0.47.05-r8 to DFHack 53.14-r2.

Target DF version: **53.14** (Steam/Itch/Classic, 64-bit only).

---

## Table of Contents

1. [Overview](#overview)
2. [Build System Changes](#build-system-changes)
3. [Structure Renames (Global Variables)](#structure-renames-global-variables)
4. [Structure Field Renames](#structure-field-renames)
5. [Structure Path Changes](#structure-path-changes)
6. [Viewscreen Changes](#viewscreen-changes)
7. [Removed/Changed DFHack APIs](#removedchanged-dfhack-apis)
8. [New DFHack APIs](#new-dfhack-apis)
9. [Plugin ABI Changes](#plugin-abi-changes)
10. [Renderer/Hook Changes (CRITICAL)](#rendererhook-changes-critical)
11. [df-ai File-by-File Impact](#df-ai-file-by-file-impact)
12. [Migration Strategy](#migration-strategy)

---

## 1. Overview

DF 50.x is a **complete rewrite** of Dwarf Fortress (64-bit, Steam release).
DFHack was also substantially restructured. Key differences:

- **64-bit only**: DF 0.47 was 32-bit; DF 50+ is 64-bit
- **New UI system**: Most viewscreens were rewritten or renamed
- **Structure renames**: Most `unk`/`anon` fields have been renamed to Bay12 names
- **Global variable renames**: `ui` → `plotinfo`, `ui_sidebar_menus` → `game`, etc.
- **Plugin ABI**: Binary interface changed (recompile required)
- **Rendering**: New rendering pipeline; old lockstep renderer hacking is incompatible
- **Steam integration**: DFHack distributed via Steam, auto-updates

---

## 2. Build System Changes

### CMake Changes
- DFHack 50+ uses 64-bit builds exclusively
- `DFHACK_PLUGIN()` macro still exists but plugin ABI changed
- `#ifdef DFHACK64` may need updating
- Boost dependency may have changed (check DFHack 53.x CMakeLists)

### Platform
- Windows: 64-bit only
- Linux: 64-bit only (gcc 11+ recommended for 53.x)
- Mac: Not officially supported in 50.x (wine recommended)

---

## 3. Structure Renames (Global Variables)

These REQUIRE_GLOBAL references must be updated:

| Old (0.47) | New (50+) | Files Affected |
|------------|-----------|----------------|
| `ui` | `plotinfo` | Nearly every file (20+) |
| `ui_advmode` | `adventure` | (if used) |
| `ui_build_selector` | `buildreq` | (if used) |
| `ui_sidebar_menus` | `game` | plan_construct.cpp, population_pets.cpp |
| `ui_building_assign_units` | (renamed, check new name) | population_pets.cpp |
| `ui_building_item_cursor` | (renamed, check new name) | population_pets.cpp |

**Note**: `ui` → `plotinfo` is the most impactful change. df-ai uses `ui->main.fortress_entity` extensively.

---

## 4. Structure Field Renames

### `world_site`
- `is_mountain_halls` → `min_depth`
- `is_fortress` → `max_depth`

### `job`
- `item_category` → `specflag` (now a union of flag fields, depends on job type)

### `plant_flags`
- `is_burning` → `unused_01`
- `is_drowning` → `season_dead`
- `is_dead` → `dead`

### `building_stockpilest`
- `max_*` / `container_*` → `storage.max_*` / `storage.container_*`

### `building_civzonest`
- `zone_settings.pen` → `zone_settings.pen.flags`
- `zone_settings.tomb` → `zone_settings.tomb.flags`

### `building_bridgest`
- `gate_flags.closed/closing/opening` → `raised/raising/lowering`

### `building_weaponst`
- `gate_flags.closed/closing/opening` → `retracted/retracting/unretracting`

### `building` (base)
- `.builder1/builder1_civ/builder2` → `.worker/worker_create_event/curworker`

### `stockpile_settings`
- `allow_organic/allow_inorganic` → `misc.allow_organic/allow_inorganic`

### `historical_entity`
- `relations.diplomacy[]` → `relations.diplomacy.state[]`
- `conquered_site_group_flags` → `law.conquered_site_group_flags`
- `events[]` → `rumor_info.events`
- `unkarmy_reeling_defense` → `army_reeling_defense`

### `unit`
- `curse.interaction_id/interaction_time/interaction_delay/time_on_site/own_interaction/own_interaction_delay` → `curse.interaction.*`
- `cached_glowtile_type` → `cache.cached_glowtile_type`
- `pool_index` → `pool_id`
- `job.siege_boulder` → `job.siege_builder`
- `enemy.rumor[]` → `enemy.rumor_info.events[]`
- `unit_preference.active` → `unit_preference.flags.visible`

### `unit_personality`
- `habit` now uses `habit_type` enum

### `gps` (graphicst)
- `color[x][y]` → `default_palette.color[x*16+y]`

### `squad`
- `schedule[x][y]` → `schedule.routine[x].month[y]`

### `world`
- `busy_buildings[]` → `building_uses.buildings[]`
- `coin_batches` → `coin_batches.all`
- `effects` → `effects.all`
- `mandates[]` → `mandates.all[]`
- `proj_list` → `projectiles.all`
- `unit_chunks` → `unit_chunks.all`
- `populations` → `populations.all`
- `selected_direction` → `selected_direction[0]` (plus 3 additional entries)
- `family_info[]` → `family_info.family[]`
- `fake_world_info[]` → `fake_world_info.language[]`
- `enemy_status_cache.rel_map[x][y]` → `enemy_status_cache.rel_map[x][y].ur`

### `world.raws`
- `inorganics` → `inorganics.all`
- `inorganics_subset` → `inorganics.cheap`
- `entities` → `entities.all`
- `interactions[]` → `interactions.all[]`
- `material_templates` → `material_templates.all`
- `syndromes` → `mat_table.syndromes`
- `effects` → `mat_table.effects`
- `body_templates` / `bodyglosses` → `creaturebody.*`
- `tissue_templates` / `body_detail_plans` / `creature_variations` → `*.all`

### `world_data`
- `constructions.map[x][y][N]` → `constructions.map[x][y].square[N]`

### `world_region_details`
- `edges.(split_x/split_y)[][].x/y` → `.break_one/break_two`

### `world_population_ref`
- `depth` → `layer_depth` (now integer instead of enum)

### `entity_activity_statistics`
- `discovered_*` → `knowledge.*`

### `itemdef_ammost`, `itemdef_siegeammost`, `itemdef_toolst`, `itemdef_trapcompst`, `itemdef_weaponst`
- `texpos` / `texpos2` → longer lists of specific fields (e.g., `texpos_normal`, `texpos_credit`, etc.)

### `item` vmethods changed
- `getGloveHandedness`: return type `int8_t` → `uint32_t`
- `getAmmoType`: no parameters, returns `std::string` by value
- `getDyeAmount`: added integer parameter
- `getCreatureTile`: added boolean parameter

---

## 5. Structure Path Changes

### `plotinfo` (formerly `ui`)
- `plotinfo.main.selected_hotkey/in_rename_hotkey` → `plotinfo.main.hotkey_interface.*`

### `dipscript_info`
- `script_steps/script_vars` → `script.steps/vars`

### `knowledge_profilest`
- `known_locations.ab_review[]` → `.reports[]`
- `known_events[]` → `rumor_info.events[]`

### `entity_activity_statistics`
- `discovered_*` → `knowledge.*`

### `minimap`
- `game.minimap.minimap[x][y]` → `game.minimap.minimap[x][y].tile`

### `abstract_building_contents`
- `countHospitalSupplies` now returns `abstract_building_contents` instead of `hospital_supplies`

---

## 6. Viewscreen Changes

**CRITICAL**: Most viewscreens from 0.47 are renamed, restructured, or removed in 50+.

### Viewscreens df-ai depends on (all likely changed):

| Old (0.47) | Status in 50+ |
|------------|---------------|
| `viewscreen_dwarfmodest` | Still exists but focus strings changed |
| `viewscreen_titlest` | Likely renamed/restructured |
| `viewscreen_optionst` | Likely renamed/restructured |
| `viewscreen_movieplayerst` | Likely renamed |
| `viewscreen_tradegoodsst` | Likely renamed/restructured |
| `viewscreen_tradelistst` | Likely renamed |
| `viewscreen_layer_assigntradest` | Likely renamed |
| `viewscreen_choose_start_sitest` | Still exists, structure fixed |
| `viewscreen_setupdwarfgamest` | Likely renamed |
| `viewscreen_new_regionst` | Likely renamed |
| `viewscreen_adopt_regionst` | Likely renamed |
| `viewscreen_update_regionst` | Likely renamed |
| `viewscreen_export_regionst` | Likely renamed |
| `viewscreen_loadgamest` | Likely renamed |
| `viewscreen_textviewerst` | Likely renamed |
| `viewscreen_topicmeetingst` | Likely renamed |
| `viewscreen_topicmeeting_takerequestsst` | Likely renamed |
| `viewscreen_topicmeeting_fill_land_holder_positionsst` | Likely renamed |
| `viewscreen_requestagreementst` | Likely renamed |
| `viewscreen_layer_stockpilest` | Likely renamed |
| `viewscreen_layer_militaryst` | Likely renamed |
| `viewscreen_layer_noblelistst` | Likely renamed |
| `viewscreen_overallstatusst` | Likely renamed |
| `viewscreen_justicest` | Likely renamed |
| `viewscreen_petitionsst` | Likely renamed |
| `viewscreen_locationsst` | Likely renamed |
| `viewscreen_createquotast` | Likely renamed |
| `viewscreen_joblistst` | Likely renamed |
| `viewscreen_jobmanagementst` | Likely renamed |

### Focus String Changes
- `dwarfmode/CustomStockpile` → `dwarfmode/Stockpile/Some/Customize`
- `dwarfmode/StockpileTools` → similar rename
- `dwarfmode/StockpileLink` → similar rename

### `gui.FramedScreen`
- **Deprecated**: Use `gui.ZScreen` and `widgets.Window` instead

---

## 7. Removed/Changed DFHack APIs

### Units Module

| Old API | New API | Change |
|---------|---------|--------|
| `Units::getPhysicalDescription` | Removed | No replacement available |
| `Units::MAX_COLORS` | `DFHack::COLOR_MAX` | Renamed |
| `Units::findIndexById` | Generated `get_vector` functions | Replaced |
| `Units::getNumUnits` | Generated `get_vector` functions | Replaced |
| `Units::getUnit` | Generated `get_vector` functions | Replaced |
| `Units::isUndead(u, include_vamps)` | `Units::isUndead(u, hiding_curse)` | Parameter renamed |
| `Units::isCitizen(u, ignore_sanity)` | `Units::isCitizen(u, ignore_sanity)` | Same in 50+ (unchanged) |
| `Units::isDanger(u)` | `Units::isDanger(u, hiding_curse)` | Added parameter |
| `Units::isGreatDanger(u)` | Now includes forgotten beasts | Behavior change |
| `Units::isNaked(u)` | `Units::isNaked(u, no_items)` | Added parameter |
| `Units::isUnitInBox` | Now accepts cuboid range | Signature change |
| `Units::getUnitsInBox` | Now accepts cuboid range + filter fn | Signature change |
| `Units::getCasteRaw(u)` | New function | Added |
| `Units::getProfessionName(u)` | `Units::getProfessionName(u, land_title, ignore_noble)` | Added params |
| `Units::getReadableName` | Changed to return untranslated name | Behavior change |
| `Units::create(u)` | New function | Added |
| `Units::makeown(u)` | New function | Added |
| `Units::assignTrainer` | New function | Added |
| `Units::unassignTrainer` | New function | Added |

### Items Module

| Old API | New API | Change |
|---------|---------|--------|
| `Items::createItem(..., growth_print)` | `Items::createItem(...)` | `growth_print` removed |
| `Items::getValue(item, caravan_buying)` | `Items::getValue(item)` | `caravan_buying` removed |
| `Items::remove(item, MapCache)` | `Items::remove(item)` | `MapCache` param removed |
| `Items::moveToGround(item, MapCache)` | `Items::moveToGround(item)` | `MapCache` param removed |
| `Items::moveToContainer(item, MapCache)` | `Items::moveToContainer(item)` | `MapCache` param removed |
| `Items::moveToBuilding(item, MapCache)` | `Items::moveToBuilding(item)` | `MapCache` param removed |
| `Items::moveToInventory(item, MapCache)` | `Items::moveToInventory(item)` | `MapCache` param removed |
| `Items::makeProjectile(item, MapCache)` | `Items::makeProjectile(item)` | `MapCache` param removed |
| `Items::canMelt(item)` | New function | Added |
| `Items::markForMelting(item)` | New function | Added |
| `Items::cancelMelting(item)` | New function | Added |
| `Items::getCapacity(item)` | New function | Added |
| `Items::getDescription(item)` | Fixed quality display | Behavior change |

### Job Module

| Old API | New API | Change |
|---------|---------|--------|
| `Job::linkIntoWorld(job)` | Still exists | Unchanged |
| `Job::attachJobItem(job, item, mode)` | `Job::attachJobItem(job, item, mode)` | Unchanged |
| `Job::addGeneralRef(job, ref)` | New function | Added |
| `Job::addWorker(job, unit)` | New function | Added |
| `Job::createLinked(...)` | New function | Added |
| `Job::assignToWorkshop(...)` | New function | Added |

### Buildings Module

| Old API | New API | Change |
|---------|---------|--------|
| `Buildings::containsTile(bld, room)` | `Buildings::containsTile(bld)` | `room` param removed |
| `Buildings::checkFreeTiles(bld, extents)` | `Buildings::checkFreeTiles(bld, allow_flow)` | Now takes building ptr |
| `Buildings::setOwner(bld, unit)` | Updated for 51.11 changes | Signature change |
| `Buildings::getOwner(bld)` | New function | Added |
| `Buildings::getName(bld)` | New function | Added |
| `Buildings::completebuild(bld)` | New function | Added |
| `Buildings::allocInstance(...)` | Check new signature | May have changed |
| `Buildings::constructWithItems(...)` | Check new signature | May have changed |

### Maps Module

| Old API | New API | Change |
|---------|---------|--------|
| `Maps::GetBiomeType(...)` | `Maps::getBiomeType(...)` | Renamed (lowercase) |
| `Maps::GetBiomeTypeRef(...)` | `Maps::getBiomeTypeRef(...)` | Renamed (lowercase) |
| `Maps::getWalkableGroup(coord)` | New function | Added |
| `Maps::isTileAquifer(...)` | New function | Added |
| `Maps::isTileHeavyAquifer(...)` | New function | Added |
| `Maps::setTileAquifer(...)` | New function | Added |
| `Maps::removeTileAquifer(...)` | New function | Added |
| `Maps::addItemSpatter(...)` | New function | Added |
| `Maps::addMaterialSpatter(...)` | New function | Added |

### Military Module

| Old API | New API | Change |
|---------|---------|--------|
| `Military::getSquadName(id)` | Changed to take squad identifier | Signature change |
| `Military::makeSquad(...)` | New function | Added |
| `Military::updateRoomAssignments(...)` | New function | Added |
| `Military::addToSquad(...)` | New function (51.11+) | Added |
| `Military::removeFromSquad(...)` | New function | Added |

### Gui Module

| Old API | New API | Change |
|---------|---------|--------|
| `Gui::getDwarfmodeDims` | Now only returns map viewport dimensions | Behavior change |
| `Gui::getDFViewscreen(inhibit)` | New function | Added |
| `Gui::getAnyJob(view)` | New function | Added |
| `Gui::getAnyWorkshopJob(view)` | New function | Added |
| `Gui::getAnyCivZone(view)` | New function | Added |
| `Gui::getAnyStockpile(view)` | New function | Added |
| `Gui::getWidget(...)` | New function | Added |
| `Gui::getMousePos(allow_out_of_bounds)` | Added parameter | Signature change |
| `Gui::revealInDwarfmodeMap(coord, highlight)` | Added parameter | Signature change |
| `Gui::addCombatReport(report*)` | New overload | Added |

### Screen Module

| Old API | New API | Change |
|---------|---------|--------|
| `Screen::Pen(char, color, bold)` | `Screen::Pen(...)` with new properties | Now supports `top_of_text`, `bottom_of_text`, `keep_lower`, `write_to_lower` |

### Persistence Module

| Old API | New API | Change |
|---------|---------|--------|
| `World::AddPersistentData(...)` | `World::AddPersistentSiteData(...)` / `World::AddPersistentWorldData(...)` | Replaced |
| `Persistence` module | New plugin API for persistent data | Rebuilt |

### World Module

| Old API | New API | Change |
|---------|---------|--------|
| `World::getAdventurer()` | New function | Added |
| `World::ReadPauseState()` | Now returns true when large panel obscures map | Behavior change |
| `World::GetCurrentSiteId()` | New function | Added |
| `World::IsSiteLoaded()` | New function | Added |

### MiscUtils

| Old | New | Change |
|-----|-----|--------|
| `toUpper` / `toLower` | `toUpper_cp437` / `toLower_cp437` | Renamed |

### Constructor Changes
- `MaterialInfo(...)` constructor may have changed
- `ItemTypeInfo(...)` constructor may have changed
- `cuboid` class has new constructors and methods

### `virtual_cast` / `strict_virtual_cast`
- Still exist but RTTI mechanism may have changed
- `virtual_identity::get(ptr)` still exists

---

## 8. New DFHack APIs

### Useful new APIs for df-ai

```cpp
// Unit management
Units::create(color_ostream &out, int16_t race, int16_t caste, ...)
Units::makeown(color_ostream &out, df::unit *unit)
Units::assignTrainer(color_ostream &out, df::unit *unit)
Units::unassignTrainer(color_ostream &out, df::unit *unit)
Units::getCasteRaw(df::unit *unit)
Units::getCasteRaw(int race, int caste)
Units::get_cached_unit_by_global_id(int32_t id)
Units::getUnitByNobleRole(df::unit *out, df::historical_entity *ent, const std::string &role)
Units::getUnitsByNobleRole(std::vector<df::unit *> *out, df::historical_entity *ent, const std::string &role)

// Item management
Items::canMelt(df::item *item)
Items::markForMelting(df::item *item)
Items::cancelMelting(df::item *item)
Items::getCapacity(df::item *item)
Items::pickGrowthPrint(df::material_common *mat, int growth_idx)
Items::useStandardMaterial(df::item_type type)

// Job management
Job::addGeneralRef(df::job *job, df::general_ref *ref)
Job::addWorker(df::job *job, df::unit *unit)
Job::createLinked(df::job *job)
Job::assignToWorkshop(df::job *job)

// Building management
Buildings::getOwner(df::building *bld)
Buildings::getName(df::building *bld)
Buildings::completebuild(df::building *bld)
Buildings::checkFreeTiles(df::building *bld, bool allow_flow)

// Military
Military::addToSquad(color_ostream &out, df::unit *unit, df::squad *squad)
Military::removeFromSquad(color_ostream &out, df::unit *unit)

// Aquifer management
Maps::isTileAquifer(df::coord pos)
Maps::isTileHeavyAquifer(df::coord pos)
Maps::setTileAquifer(df::coord pos, bool heavy)
Maps::removeTileAquifer(df::coord pos)

// New module APIs
Burrows::getName(df::burrow *burrow)
Hotkey module (53.07+)

// Cuboid
dfhack::cuboid::clampMap(bool block) // renamed from clamp(bool)
dfhack::cuboid::clamp(cuboid other)
dfhack::cuboid::clampNew(cuboid other)
```

---

## 9. Plugin ABI Changes

- Plugin ABI version bumped in 50.11-r5
- Any external plugins must be recompiled
- `PRELOAD_LIB` env var renamed to `DF_PRELOAD`

---

## 10. Renderer/Hook Changes (CRITICAL)

**The entire hooks.cpp lockstep system is INCOMPATIBLE with DF 50+.**

### What breaks:
- `df::renderer` struct layout completely different (Vulkan-based rendering in 50+)
- `gps->screen` buffer layout changed (was 4 bytes per cell)
- `gps->screen_old`, `screentexpos*` fields changed
- `gview` struct layout completely different
- `enabler` struct layout completely different
- `init->display.grid_x/grid_y` may have changed
- SDL function hooking (GetTickCount, SDL_GetTicks) may not work
- x86 instruction patching (0xE9 JMP) may not work on 64-bit

### What to do:
1. **Disable hooks.cpp entirely** for 50+ build (or rewrite from scratch)
2. The lockstep system is not essential for df-ai operation
3. Camera system in camera.cpp directly accesses renderer fields - needs rewrite
4. Trade screen automation in trade_helpers.cpp uses renderer fields - needs rewrite

---

## 11. df-ai File-by-File Impact

### EXTREME REWRITE NEEDED

| File | Reason |
|------|--------|
| `hooks.cpp` | Direct renderer/gps/gview/enabler manipulation, x86 hooking |
| `camera.cpp` | Direct gps/gview/renderer access |
| `embark.cpp` | 17 viewscreen types navigated |
| `plan_construct.cpp` | 40+ Buildings:: calls, all building types |

### HIGH IMPACT (many changes)

| File | Reason |
|------|--------|
| `plan_setup_screen.cpp` | Custom viewscreen with DataStaticsFields.cpp |
| `population.cpp` | Unit/job/activity/crime/death processing |
| `population_military.cpp` | Squad management, UI navigation |
| `population_nobles.cpp` | Noble position management |
| `population_occupations.cpp` | Occupation handling |
| `stocks_find.cpp` | 30+ item type headers |
| `stocks_equipment.cpp` | Equipment detection |
| `exclusive_callback.cpp` | Core UI interaction framework |
| `trade_manager.cpp` | Trade depot UI automation |
| `trade_helpers.cpp` | Trade helper functions |
| `plan_task.cpp` | Task management |
| `plan_priorities.cpp` | Priority system |
| `plan_assign.cpp` | Building assignment |
| `plan_cistern.cpp` | Cistern logic |
| `plan_find.cpp` | Finding functions |
| `plan_smooth.cpp` | Smoothing logic |

### MEDIUM IMPACT

| File | Reason |
|------|--------|
| `ai.cpp` | Main AI logic, viewscreen handling |
| `df-ai.cpp` | Plugin entry point, event registration |
| `event_manager.cpp` | Event system |
| `pause.cpp` | Pause handling |
| `log.cpp` | Logging |
| `stocks.cpp` | Stock management |
| `stocks_farm.cpp` | Farm management |
| `stocks_manager.cpp` | Stock management |
| `stocks_queue.cpp` | Queue management |
| `stocks_update.cpp` | Stock updates |
| `stocks_forge.cpp` | Forge management |
| `stocks_detect.cpp` | Stock detection |
| `stocks_trade.cpp` | Trade stocks |

### LOW IMPACT

| File | Reason |
|------|--------|
| `room.h` / `room.cpp` | Room structure (may still compile) |
| `blueprint.h` / `blueprint_*.cpp` | Blueprint system (mostly internal) |
| `apply.h` | Enum application (template-based) |
| `config.h` | Configuration |
| `debug.h` | Debug output |
| `dfhack_shared.h` | Shared utilities |

---

## 12. Migration Strategy

### Phase 0: Preparation
1. Create `port-dfhack-50` branch (DONE)
2. Document all changes (THIS FILE)
3. Clone DFHack 53.14 source with submodules
4. Set up DF 53.14 installation

### Phase 1: Build System
1. Update CMakeLists.txt for 64-bit
2. Fix any Boost/compiler compatibility issues
3. Verify plugin loads in DFHack 53.14

### Phase 2: Structure Renames (Mechanical)
1. Replace all `ui->` with `plotinfo->` (or whatever the new global is)
2. Replace all `ui_sidebar_menus->` with `game->`
3. Update `world->raws.inorganics` → `world->raws.inorganics.all`
4. Update all field renames listed in Section 4
5. Update all path changes listed in Section 5

### Phase 3: API Updates
1. Update `Units::isCitizen(u, true)` if signature changed
2. Update `Items::getValue(item)` (remove caravan_buying param)
3. Update `Buildings::containsTile(bld)` (remove room param)
4. Update `Buildings::checkFreeTiles` (new signature)
5. Update all other API changes listed in Section 7

### Phase 4: Viewscreen Updates (HARDEST)
1. Identify new viewscreen type names in DF 53.14
2. Update `Gui::getCurViewscreen` calls
3. Update `Screen::isDismissed` calls
4. Update `strict_virtual_cast` calls
5. Rewrite exclusive_callback system for new UI

### Phase 5: Renderer/Hooks
1. Disable hooks.cpp lockstep system
2. Rewrite camera.cpp renderer access
3. Remove direct gps/gview/enabler access
4. Implement alternative screen capture if needed

### Phase 6: Testing
1. Compile against DFHack 53.14
2. Load plugin in DF 53.14
3. Test basic AI operations
4. Test trading
5. Test military
6. Test blueprint system

---

## Appendix A: Quick Reference - Search & Replace

```
# Global variable renames
ui->                      plotinfo->
ui_sidebar_menus->        game->
ui_advmode->              adventure->
ui_build_selector->       buildreq->

# Common field renames
world->raws.inorganics[   world->raws.inorganics.all[
world->raws.entities[     world->raws.entities.all[
world->effects            world->effects.all
world->busy_buildings     world.building_uses.buildings
world->coin_batches       world->coin_batches.all
world->mandates           world->mandates.all
world->proj_list          world->projectiles.all
world->unit_chunks        world->unit_chunks.all
world->populations        world->populations.all

# API renames
Maps::GetBiomeType        Maps::getBiomeType
Maps::GetBiomeTypeRef     Maps::getBiomeTypeRef
toUpper(                  toUpper_cp437(
toLower(                  toLower_cp437(
```

## Appendix B: Key DFHack 53.x Documentation URLs

- Changelog: https://docs.dfhack.org/en/53.14-r2/docs/NEWS.html
- API Reference: https://docs.dfhack.org/en/53.14-r2/docs/dev/
- Structures: https://github.com/DFHack/df-structures
- Building DFHack: https://docs.dfhack.org/en/53.14-r2/docs/dev/Build.html
- Plugin Development: https://docs.dfhack.org/en/53.14-r2/docs/dev/PluginInit.html
