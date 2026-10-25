-- test_perf_bigmap.lua — performance regression test for the r3.8 fix.
--
-- Reproduces the r3.7 freeze scenario reported by a real user
-- ("el juego se congela apenas activo df-ai"): a full-size embark map
-- (192x192, ~160 z-levels, surface near z=120) with rolling hills,
-- forests and pools. The r3.7 engine walked the z-column from the map
-- top for EVERY candidate tile with 5 pcalls + 7 boundary crossings per
-- tile, so the layout froze the main thread for minutes.
--
-- The SAME placement logic must now finish the whole layout in a few
-- seconds of CPU (it is spread across frames at runtime; this test
-- measures total CPU work synchronously).
--
-- Usage: lua5.3 test/test_perf_bigmap.lua   (from the repo root)

local MAP = { x = 192, y = 192, z = 160 }

-- ============================================================
-- Minimal pure-Lua JSON decoder (same as test_blueprint_engine.lua)
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
-- Simulated DF / DFHack — full-size hilly forested map
-- ============================================================

local TILE_ROCK, TILE_FLOOR, TILE_AIR, TILE_TREE, TILE_POOL = 1, 2, 3, 4, 5

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
    FEATURE = 7, FROZEN_LIQUID = 8, SOIL = 9, AIR = 10,
}
df.tiletype = {
    attrs = {
        [TILE_ROCK] = { shape = df.tiletype_shape.WALL,
            material = df.tiletype_material.STONE },
        [TILE_FLOOR] = { shape = df.tiletype_shape.FLOOR,
            material = df.tiletype_material.SOIL },
        [TILE_AIR] = { shape = df.tiletype_shape.OPEN_SPACE,
            material = df.tiletype_material.AIR },
        [TILE_TREE] = { shape = df.tiletype_shape.WALL,
            material = df.tiletype_material.TREE },
        [TILE_POOL] = { shape = df.tiletype_shape.FLOOR,
            material = df.tiletype_material.POOL },
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
    TOOL = 21, INSTRUMENT = 22,
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

-- deterministic terrain: SMOOTH rolling hills (quantized low-frequency
-- noise -> real plateaus like erosion produces; per-column independent
-- random would be a cliff checkerboard where nothing flat ever fits),
-- 15% forest columns (2-4 trunk tiles above ground), 1% pools
local surf = {}     -- [x][y] -> surface z
local treeh = {}    -- [x][y] -> trunk tiles above ground (0 = none)
local pool = {}     -- [x][y] -> true (rejected column)
do
    local function h(a, b, salt)
        local n = (a * 73856093 + b * 19349663 + salt * 83492791)
            % 2147483647
        n = (n * 1274126177) % 2147483647
        return n / 2147483647
    end
    for x = 0, MAP.x - 1 do
        surf[x], treeh[x], pool[x] = {}, {}, {}
        for y = 0, MAP.y - 1 do
            local nz = 2.5 * math.sin(x / 23 + 1.3)
                + 2.2 * math.cos(y / 19 + 0.7)
                + 1.6 * math.sin((x + y) / 31 + 2.1)
                + 1.2 * math.cos((x - y) / 17)
            surf[x][y] = 120 + math.floor(nz + 0.5)
            treeh[x][y] = h(x, y, 2) < 0.15
                and (2 + math.floor(h(x, y, 3) * 3)) or 0
            pool[x][y] = h(x, y, 4) < 0.01
        end
    end
end

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
                local ax, ay = bx * 16 + lx, by * 16 + ly
                local tile
                local s = surf[ax] and surf[ax][ay]
                if not s then
                    tile = TILE_AIR
                elseif z > s + (treeh[ax][ay] or 0) then
                    tile = TILE_AIR
                elseif z > s then
                    tile = TILE_TREE
                elseif z == s then
                    tile = pool[ax][ay] and TILE_POOL or TILE_FLOOR
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
package.preload['json'] = function() return json end
package.preload['utils'] = function()
    return { normalize = function() end }
end
package.preload['repeat-util'] = function()
    return { scheduleEvery = function() end }
end

-- ============================================================
-- Load modules and run the timed build
-- ============================================================

local rooms_mod = dofile('hack/scripts/df-ai/rooms.lua')
local blueprint = dofile('hack/scripts/df-ai/blueprint.lua')

local failures = 0
local function check(name, cond, detail)
    if cond then
        print('OK   ' .. name)
    else
        print('FAIL ' .. name .. (detail and (' — ' .. tostring(detail)) or ''))
        failures = failures + 1
    end
end

-- entrance: first non-pool column near the map center
local entrance
do
    local cx, cy = math.floor(MAP.x / 2), math.floor(MAP.y / 2)
    for r = 0, 32 do
        local found = false
        for dx = -r, r do
            for dy = -r, r do
                local x, y = cx + dx, cy + dy
                if x >= 0 and y >= 0 and x < MAP.x and y < MAP.y
                    and not pool[x][y] then
                    entrance = { x = x, y = y, z = surf[x][y] }
                    found = true
                    break
                end
            end
            if found then break end
        end
        if found then break end
    end
    check('found entrance column', entrance ~= nil)
end

math.randomseed(42)
local t0 = os.clock()
local ok, rooms, corridors, fort_entrance, stats = blueprint.build(rooms_mod, {
    entrance = entrance,
    map = MAP,
    z_top = MAP.z - 1,
})
local dt = os.clock() - t0

print(string.format('big-map build: %.2f s CPU, ok=%s, %d rooms, %d blueprints, %d tries',
    dt, tostring(ok), rooms and #rooms or -1,
    stats and stats.placed or -1, stats and stats.tries or -1))

check('big-map layout completes', ok == true)
check('big-map placed a real fortress',
    stats and stats.placed and stats.placed >= 100, stats and stats.placed)
check('big-map layout CPU under 15 s (r3.7 took minutes)',
    dt < 15, string.format('%.2f s', dt))

if failures > 0 then
    print(failures .. ' FAILURES')
    os.exit(1)
end
print('all perf checks OK')
