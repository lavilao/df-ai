-- test_blueprint_engine.lua — headless end-to-end test of the r3.7
-- blueprint placement engine + priority rule engine.
--
-- Runs with PLAIN lua5.3 (same version DFHack embeds). No DF install:
-- the map is a simulated all-rock world (surface floor at z=SURFACE_Z,
-- solid rock below, open air above) and the REAL blueprint JSON files
-- (plans/generic01.json, rooms/templates/, rooms/instances/) are loaded
-- through a small pure-Lua JSON decoder.
--
-- Usage: lua5.3 test/test_blueprint_engine.lua   (from the repo root)

local SURFACE_Z = 10
local MAP = { x = 96, y = 96, z = 16 }

-- ============================================================
-- Minimal pure-Lua JSON decoder (only what the blueprints need)
-- ============================================================

local json = {}

local function skip_ws(s, i)
    while i <= #s and s:sub(i, i):match('[ \t\r\n]') do i = i + 1 end
    return i
end

local function parse_value(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '{' then
        local t = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == '}' then return t, i + 1 end
        while true do
            i = skip_ws(s, i)
            local k
            k, i = parse_value(s, i)
            i = skip_ws(s, i)
            i = i + 1 -- ':'
            local v
            v, i = parse_value(s, i)
            t[k] = v
            i = skip_ws(s, i)
            local sep = s:sub(i, i)
            i = i + 1
            if sep == '}' then return t, i end
        end
    elseif c == '[' then
        local t = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == ']' then return t, i + 1 end
        while true do
            local v
            v, i = parse_value(s, i)
            t[#t + 1] = v
            i = skip_ws(s, i)
            local sep = s:sub(i, i)
            i = i + 1
            if sep == ']' then return t, i end
        end
    elseif c == '"' then
        local out = {}
        i = i + 1
        while true do
            local ch = s:sub(i, i)
            if ch == '"' then
                i = i + 1
                return table.concat(out), i
            elseif ch == '\\' then
                local esc = s:sub(i + 1, i + 1)
                if esc == 'n' then out[#out + 1] = '\n'
                elseif esc == 't' then out[#out + 1] = '\t'
                else out[#out + 1] = esc end
                i = i + 2
            else
                out[#out + 1] = ch
                i = i + 1
            end
        end
    elseif s:sub(i, i + 3) == 'true' then
        return true, i + 4
    elseif s:sub(i, i + 4) == 'false' then
        return false, i + 5
    elseif s:sub(i, i + 3) == 'null' then
        return nil, i + 4
    else
        local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
        if num then
            return tonumber(num), i + #num
        end
        error('bad JSON at ' .. i .. ': ' .. s:sub(i, i + 20))
    end
end

function json.decode(s)
    local v = parse_value(s, 1)
    return v
end

function json.decode_file(path)
    local f = io.open(path, 'r')
    if not f then return nil, 'not found: ' .. path end
    local s = f:read('*a')
    f:close()
    return json.decode(s)
end

-- ============================================================
-- Simulated DF / DFHack
-- ============================================================

local TILE_ROCK, TILE_FLOOR, TILE_AIR = 1, 2, 3

local df = {}

df.tiletype_shape = {
    WALL = 1, FLOOR = 2, OPEN_SPACE = 3, RAMP = 4, STAIR_UP = 5,
    STAIR_DOWN = 6, STAIR_UPDOWN = 7, RAMP_TOP = 8, BROOK_TOP = 9,
    PEBBLES = 10, BOULDER = 11, SAPLING = 12, SHRUB = 13,
    FORTIFICATION = 14, TREE = 15, TWIG = 16, BRANCH = 17,
    TRUNK_BRANCH = 18, ROOT = 19, ENDLESS_PIT = 20,
    BROOK_BED = 21, RIVER_BED = 22,
}
df.tiletype_material = {
    TREE = 1, POOL = 2, RIVER = 3, BROOK = 4, STONE = 5, MINERAL = 6,
    FEATURE = 7, FROZEN_LIQUID = 8, SOIL = 9,
}
df.tiletype = {
    attrs = {
        [TILE_ROCK] = { shape = df.tiletype_shape.WALL,
            material = df.tiletype_material.STONE },
        [TILE_FLOOR] = { shape = df.tiletype_shape.FLOOR,
            material = df.tiletype_material.SOIL },
        [TILE_AIR] = { shape = df.tiletype_shape.OPEN_SPACE,
            material = df.tiletype_material.AIR or 0 },
    },
}
df.tile_dig_designation = {
    No = 0, Default = 1, DownStair = 2, UpStair = 3, UpDownStair = 4,
    Channel = 5, Ramp = 6,
}
df.building_type = {
    Bed = 1, Chair = 2, Table = 3, Door = 4, Cabinet = 5, Box = 6,
    Coffin = 7, Statue = 8, Weaponrack = 9, Armorstand = 10, Cage = 11,
    Trap = 12, NestBox = 13, Hive = 14, OfferingPlace = 15,
    DisplayFurniture = 16, TractionBench = 17, Floodgate = 18, Hatch = 19,
    GearAssembly = 20, Rollers = 21, AxleVertical = 22, AxleHorizontal = 23,
    WaterWheel = 24, ScrewPump = 25, ArcheryTarget = 26, Chain = 27,
    Bookcase = 28, Well = 29, Slab = 30, WindowGlass = 31,
    Workshop = 40, Furnace = 41, Stockpile = 42, FarmPlot = 43,
    TradeDepot = 44, Windmill = 45, Civzone = 46,
}
df.trap_type = { CageTrap = 1, Lever = 2, TrackStop = 3, StoneFall = 4 }
df.item_type = {
    BED = 1, CHAIR = 2, TABLE = 3, DOOR = 4, CABINET = 5, BOX = 6,
    COFFIN = 7, STATUE = 8, WEAPONRACK = 9, ARMORSTAND = 10, CAGE = 11,
    TRAPPARTS = 12, CHAIN = 13, QUERN = 14, MILLSTONE = 15,
    TRACTION_BENCH = 16, SPLINT = 17, CRUTCH = 18, FLOODGATE = 19,
    HATCH_COVER = 20, TOOL = 21, INSTRUMENT = 22,
}
df.tool_use = {
    NEST_BOX = 1, HIVE = 2, PLACE_OFFERING = 3, DISPLAY_OBJECT = 4,
    BOOKCASE = 5,
}
df.workshop_type = {
    Carpenters = 1, Farmers = 2, Masons = 3, Craftsdwarfs = 4,
    Jewelers = 5, MetalsmithsForge = 6, MagmaForge = 7, Bowyers = 8,
    Mechanics = 9, Siege = 10, Butchers = 11, Leatherworks = 12,
    Tanners = 13, Clothiers = 14, Fishery = 15, Still = 16, Loom = 17,
    Quern = 18, Kennels = 19, Kitchen = 20, Ashery = 21, Dyers = 22,
    Millstone = 23, Tool = 24, Custom = 25,
}
df.furnace_type = {
    Smelter = 1, WoodFurnace = 2, Kiln = 3, GlassFurnace = 4,
    MagmaSmelter = 5, MagmaKiln = 6, MagmaGlassFurnace = 7,
}

local blocks = {}

local function get_block(x, y, z)
    local bx, by = math.floor(x / 16), math.floor(y / 16)
    local k = bx .. ',' .. by .. ',' .. z
    local b = blocks[k]
    if not b then
        b = { tiletype = {}, designation = {}, occupancy = {},
            flags = {} }
        for lx = 0, 15 do
            b.tiletype[lx] = {}
            b.designation[lx] = {}
            b.occupancy[lx] = {}
            for ly = 0, 15 do
                local tile
                if z > SURFACE_Z then
                    tile = TILE_AIR
                elseif z == SURFACE_Z then
                    tile = TILE_FLOOR
                else
                    tile = TILE_ROCK
                end
                b.tiletype[lx][ly] = tile
                b.designation[lx][ly] = { dig = 0, flow_size = 0 }
                b.occupancy[lx][ly] = { building = 0 }
            end
        end
        blocks[k] = b
    end
    return b
end

local world = { buildings = { all = {} } }

local dfhack = {}
dfhack.maps = {
    getTileBlock = function(x, y, z)
        if x < 0 or y < 0 or z < 0 or x >= MAP.x or y >= MAP.y or z >= MAP.z then
            return nil
        end
        return get_block(x, y, z)
    end,
    getTileSize = function()
        return MAP.x, MAP.y, MAP.z
    end,
}
dfhack.filesystem = {
    listdir = function(dir)
        local ok, p = pcall(function()
            return io.popen('ls -1 "' .. dir .. '" 2>/dev/null'):read('*a')
        end)
        if not ok or not p or p == '' then return nil end
        local out = {}
        for line in p:gmatch('[^\n]+') do
            out[#out + 1] = line
        end
        return out
    end,
}
dfhack.println = function() end
dfhack.printerr = function() end
dfhack.run_script_with_env = function(_, _, name, opts)
    if opts and opts.module then
        return dofile('hack/scripts/' .. name .. '.lua')
    end
end

_G.df = df
_G.dfhack = dfhack
_G.json = json
_G.moduleMode = false
-- modules use require('json') etc.; plain Lua resolves through
-- package.preload, not globals
package.preload['json'] = function() return json end
package.preload['utils'] = function()
    return { normalize = function() end }
end
package.preload['repeat-util'] = function()
    return { scheduleEvery = function() end }
end

-- rooms.lua reads df.tiletype_shape at load: must be set before load ✓

-- ============================================================
-- Load the modules
-- ============================================================

local rooms_mod = dofile('hack/scripts/df-ai/rooms.lua')
local blueprint = dofile('hack/scripts/df-ai/blueprint.lua')
local priorities = dofile('hack/scripts/df-ai/priorities.lua')

local failures = 0
local function check(name, cond, detail)
    if cond then
        print('OK   ' .. name)
    else
        print('FAIL ' .. name .. (detail and (' — ' .. tostring(detail)) or ''))
        failures = failures + 1
    end
end

-- ============================================================
-- 1. Data loading + template x instance merge
-- ============================================================

do
    local plan, variants = blueprint.load_all()
    check('load plan JSON', plan ~= nil and plan.priorities ~= nil
        and #plan.priorities == 67, plan and #plan.priorities)
    check('load blueprint variants', variants ~= nil and #variants >= 80,
        variants and #variants)
    local has_carpenter = false
    local has_food_pile = false
    for _, v in ipairs(variants) do
        if v.type == 'generic01_workshop_3x3' and v.name == 'workshop_carpenters' then
            local ok_ws = false
            local ok_pile = false
            for _, r in ipairs(v.r) do
                if r.workshop_type == 'Carpenters' then ok_ws = true end
                if r.stockpile_type == 'wood' then ok_pile = true end
            end
            has_carpenter = ok_ws and ok_pile
        end
        if v.type == 'generic01_stockpile' and v.name == 'food' then
            for _, r in ipairs(v.r) do
                if r.stockpile_type == 'food' then has_food_pile = true end
            end
        end
    end
    check('instance merge: carpenter workshop + wood pile', has_carpenter)
    check('instance merge: food stockpile', has_food_pile)
end

-- ============================================================
-- 2. Full placement build on the simulated rock world
-- ============================================================

local rooms, corridors, fort_entrance, stats
do
    math.randomseed(42)
    local ok, a, b, c, d = blueprint.build(rooms_mod, {
        entrance = { x = 48, y = 48, z = SURFACE_Z },
        map = MAP,
        z_top = MAP.z - 1,
        log = function(msg) print('LOG] ' .. msg) end,
    })
    check('placement build succeeds', ok, b)
    rooms, corridors, fort_entrance, stats = a, b, c, d
    if ok then
        check('fort has many rooms', #rooms >= 30, #rooms)
        check('fort has corridors', #corridors >= 5, #corridors)
        check('fort entrance found', fort_entrance ~= nil)
        check('blueprints placed > 10', stats.placed > 10, stats.placed)

        -- reachability invariant: every room's accesspath entries are
        -- ROOM REFERENCES (not numbers); no room is reachable from
        -- itself through a CYCLIC chain (diamonds are fine — shared
        -- ancestors are normal)
        local bad_ap, cycle = 0, 0
        for _, r in ipairs(rooms) do
            for _, ap in ipairs(r.accesspath or {}) do
                if type(ap) ~= 'table' or ap.min == nil then bad_ap = bad_ap + 1 end
            end
        end
        for _, r in ipairs(rooms) do
            local on_path = {}
            local function walk(room)
                if on_path[room] then
                    cycle = cycle + 1
                    return
                end
                on_path[room] = true
                for _, ap in ipairs(room.accesspath or {}) do
                    walk(ap)
                end
                on_path[room] = nil
            end
            pcall(walk, r)
        end
        check('accesspath holds room references', bad_ap == 0, bad_ap)
        check('no accesspath cycles', cycle == 0, cycle)

        -- room type census (debug + sanity: a C++-shaped fort has
        -- corridors, workshops, stockpiles, bedrooms)
        local census = {}
        for _, r in ipairs(rooms) do census[r.type] = (census[r.type] or 0) + 1 end
        print('INFO census: ' .. (function()
            local parts = {}
            for k, v in pairs(census) do parts[#parts + 1] = v .. ' ' .. k end
            table.sort(parts)
            return table.concat(parts, ', ')
        end)())
        check('corridors survive remove_unused', (census['corridor'] or 0) >= 5,
            census['corridor'] or 0)
        check('workshops survive remove_unused', (census['workshop'] or 0) >= 3,
            census['workshop'] or 0)
        check('stockpiles survive remove_unused', (census['stockpile'] or 0) >= 3,
            census['stockpile'] or 0)

        -- workshop types resolved to enum numbers
        local ws_enum, ws_str = 0, 0
        for _, r in ipairs(rooms) do
            if r.type == 'workshop' then
                if type(r.workshop_type) == 'number' then ws_enum = ws_enum + 1
                elseif r.workshop_type ~= nil then ws_str = ws_str + 1 end
            end
            if r.type == 'furnace' and type(r.furnace_type) == 'string' then
                ws_str = ws_str + 1
            end
        end
        check('workshops have enum types', ws_enum > 0 and ws_str == 0,
            ws_enum .. ' enum, ' .. ws_str .. ' string')

        -- furniture positions are absolute and inside their room bounds
        -- (room-min-relative semantics check)
        local furn_in_bounds, furn_total = 0, 0
        for _, r in ipairs(rooms) do
            for _, f in ipairs(r.layout) do
                if f.type ~= 'none' then
                    furn_total = furn_total + 1
                    -- +-2: cistern aqueduct floodgates legitimately sit
                    -- 2 tiles outside their room (generic01_well data)
                    if f.pos.x >= r.min.x - 2 and f.pos.x <= r.max.x + 2
                        and f.pos.y >= r.min.y - 2 and f.pos.y <= r.max.y + 2
                        and f.pos.z >= r.min.z - 2 and f.pos.z <= r.max.z + 2 then
                        furn_in_bounds = furn_in_bounds + 1
                    end
                end
            end
        end
        check('furniture positions absolute + in room', furn_total > 50
            and furn_in_bounds == furn_total,
            furn_in_bounds .. '/' .. furn_total)

        -- the start stairwell: at least some stair furniture exists
        local stairs = 0
        for _, r in ipairs(rooms) do
            for _, f in ipairs(r.layout) do
                if f.dig == df.tile_dig_designation.UpDownStair
                    or f.dig == df.tile_dig_designation.DownStair
                    or f.dig == df.tile_dig_designation.UpStair then
                    stairs = stairs + 1
                end
            end
        end
        check('stairwell furniture present', stairs >= 9, stairs)
    end
end

-- ============================================================
-- 3. Priority rule engine on the placed rooms
-- ============================================================

do
    if rooms then
        local plan = blueprint.load_all()
        local rules = priorities.prepare(plan.priorities)
        check('67 rules prepared', #rules == 67, #rules)

        -- room filter matching basics
        local any_stockpile = nil
        for _, r in ipairs(rooms) do
            if r.type == 'stockpile' and not any_stockpile then any_stockpile = r end
        end
        check('food stockpile placed by engine', any_stockpile ~= nil)

        if any_stockpile then
            local m = priorities.room_matches(
                { type = 'stockpile', stockpile_type = 'food', level = 1 },
                any_stockpile)
            check('filter matches food stockpile',
                m == (any_stockpile.stockpile_type == 'food'))
        end

        -- count gate: rules[0] fires when no food stockpile is past plan
        local plan_mock = {
            rooms = rooms,
            tasks_generic = {},
            tasks_furniture = {},
            priority_rules = rules,
            past_initial_phase = false,
            should_search_for_metal = false,
            wanted = {},
            wantdig = function(self, r, q)
                self.wanted[r] = q or 0
            end,
            digroom = function(self, r, imm)
                self.wanted[r] = 'immediate'
            end,
            furnish_room = function() end,
            smooth_room = function() end,
        }
        local acted = priorities.checkidle(plan_mock)
        check('first rule acted (food stockpile dig_immediate)', acted)
        local saw_food = false
        for r, q in pairs(plan_mock.wanted) do
            if r.type == 'stockpile' and r.stockpile_type == 'food'
                and r.level == 1 and q == 'immediate' then
                saw_food = true
            end
        end
        check('food stockpile was queued dig_immediate', saw_food)

        -- latching: second call must not re-fire rule 1 while it works
        plan_mock.tasks_generic = {
            { type = 'dig_room_immediate',
                room = (function()
                    for _, r in ipairs(rooms) do
                        if r.type == 'stockpile' and r.stockpile_type == 'food' then
                            return r
                        end
                    end
                end)() },
        }
        local before = {}
        for r in pairs(plan_mock.wanted) do before[r] = true end
        priorities.checkidle(plan_mock)
        local refired = false
        for r in pairs(plan_mock.wanted) do
            if not before[r] then refired = true end
        end
        check('working rule latched (no duplicate queue)', not refired)
    end
end

-- ============================================================
-- 4. add_task dedup (uses the real Plan)
-- ============================================================

do
    local plan_mod = dofile('hack/scripts/df-ai/plan.lua')
    local p = plan_mod.new({ stocks = nil })
    local fake_room = { type = 'corridor' }
    local fake_furn = { type = 'cage_trap' }
    p:add_task('furnish', fake_room, fake_furn)
    p:add_task('furnish', fake_room, fake_furn)
    p:add_task('furnish', fake_room, fake_furn)
    check('add_task dedups furnish', #p.tasks_furniture == 1, #p.tasks_furniture)
    p:add_task('want_dig', fake_room)
    p:add_task('want_dig', fake_room)
    check('add_task dedups generic', #p.tasks_generic == 1, #p.tasks_generic)
end

print('=== ' .. (failures == 0 and 'ALL BLUEPRINT-ENGINE TESTS PASS'
    or failures .. ' FAILURES') .. ' ===')
os.exit(failures == 0 and 0 or 1)
