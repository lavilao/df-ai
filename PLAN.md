# df-ai Lua Port — Implementation Plan

## Goal
Feature parity with the original C++ df-ai (29,430 lines across 70 files → Lua, targeting DFHack 53.14-r2).

## Dependency Order

Each phase depends on the previous one. Within a phase, items can be done in parallel.

```
Phase 0  Core Infrastructure
  └─► Phase 1  Blueprint + Room Digging
       └─► Phase 2  Construction + Furnishing
            └─► Phase 3  Stock Management (Manager Orders)
                 └─► Phase 4  Population Management
                      └─► Phase 5  Trading + Embark
                           └─► Phase 6  Refinements
```

## Phase 0: Core Infrastructure

| Component | Description | File |
|---|---|---|
| Room struct (Lua) | `room` table with all 20+ room types, status lifecycle `plan→dig→designated→dug→finished`, `is_dug()`, `dig()`, `constructions_done()` | `rooms.lua` |
| Furniture struct (Lua) | `furniture` table with 28+ layout types, position, building ID, linkage | `rooms.lua` |
| Task system | Task queue with one-per-tick processing, 21 task types | `plan.lua` |
| Spiral search | `AI:spiral_search(coord, max, min, fn)` — find tiles by predicate | `df-ai.lua` |
| Find room helpers | `find_room(type)`, `find_room(type, filter)`, `find_room_at(coord)` | `df-ai.lua` |
| dig_tile | Set dig designation with tree detection, duplicate-job guard | `plan.lua` |
| Exclusive callback base | Lua state machine for UI automation (coroutine-based) | `exclusive.lua` |

## Phase 1: Blueprint + Digging

| Component | Description | File |
|---|---|---|
| Blueprint loader | Parse template+instance JSON, resolve placeholders, merge into room_blueprint | `plan.lua` |
| Plan setup | Place rooms from blueprint: site selection, corridor connection, constraint checking | `plan.lua` |
| Room digging | `digroom()` with queue management, `wantdig()` rate limiting | `plan.lua` |
| Priority system | Ordered priority actions from blueprint (dig, finish, start_ore_search, etc.) | `plan.lua` |
| Corridor pathfinding | Find path to surface, connect rooms with corridors | `plan.lua` |

## Phase 2: Construction + Furnishing

| Component | File |
|---|---|
| Workshop construction (all types) | `plan.lua` |
| Furnace construction | `plan.lua` |
| Stockpile construction | `plan.lua` |
| Farm plot construction + irrigation | `plan.lua` |
| Activity zone creation | `plan.lua` |
| Trade depot | `plan.lua` |
| Windmill | `plan.lua` |
| Furniture placement (28 types) | `plan.lua` |
| Material validation (fire-safe, economic stone) | `stocks.lua` |

## Phase 3: Stock Management

| Component | File |
|---|---|
| Watch system (target quantities for 80 item categories) | `stocks.lua` |
| Manager order creation + dedup | `stocks.lua` |
| Queue need (weapons, armor, ammo, tools, furniture, crafts, clothes, food) | `stocks.lua` |
| Forge management (ore selection, smelting, bar counting) | `stocks.lua` |
| Farm management (seasonal crops, planting) | `stocks.lua` |
| Equipment tracking | `stocks.lua` |
| Unforbid + stall trimming | `stocks.lua` |
| Corpse/slab management | `stocks.lua` |

## Phase 4: Population Management

| Component | File |
|---|---|
| Labor management (autolabor integration) | `population.lua` |
| Occupation assignment (tavern, library, temple) | `population.lua` |
| Military (squad management, kill orders, equipment) | `population.lua` |
| Nobles (mandates, apartment requirements) | `population.lua` |
| Pets (milking, shearing, eggs, training, pasture) | `population.lua` |
| Justice (crime monitoring, punishment) | `population.lua` |
| Caged rescue | `population.lua` |
| Location assignment | `population.lua` |

## Phase 5: Trading + Embark

| Component | File |
|---|---|
| Trade setup (UI automation: broker selection, trade screen) | `trade.lua` |
| Trade execution (value calculation, deal optimization) | `trade.lua` |
| Embark (world selection, site scroll, dwarf/items config) | `embark.lua` |
| Abandon (UI navigation to abandon fortress) | `df-ai.lua` |
| Restart (wait for unload → re-embark) | `embark.lua` |

## Phase 6: Refinements

| Component | File |
|---|---|
| Cistern (reservoir, well, floodgate, lever, channel) | `plan.lua` |
| Vein mining (ore scanning, selective digging) | `plan.lua` |
| Smoothing/engraving | `plan.lua` |
| Room value monitoring | `plan.lua` |
| Walkable corridor (river crossing) | `plan.lua` |
| Announcement watching | `df-ai.lua` |
| Enemy tagging | `df-ai.lua` |
| Camera follow history | `camera.lua` |
| Persist/unpersist | `plan.lua` |
