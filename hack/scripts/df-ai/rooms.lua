--@module = true

local room = {}
room.__index = room

local furniture = {}
furniture.__index = furniture

-- Room statuses (matches C++ room_status)
local STATUS = {
    plan = 'plan',
    dig = 'dig',
    designated = 'designated',
    dug = 'dug',
    finished = 'finished',
}

-- Room types (matches C++ room_type)
local TYPE = {
    corridor = 'corridor',
    barracks = 'barracks',
    bedroom = 'bedroom',
    cemetery = 'cemetery',
    cistern = 'cistern',
    dininghall = 'dininghall',
    farmplot = 'farmplot',
    furnace = 'furnace',
    garbagedump = 'garbagedump',
    infirmary = 'infirmary',
    jail = 'jail',
    location = 'location',
    nobleroom = 'nobleroom',
    outpost = 'outpost',
    pasture = 'pasture',
    pitcage = 'pitcage',
    pond = 'pond',
    releasecage = 'releasecage',
    stockpile = 'stockpile',
    tradedepot = 'tradedepot',
    windmill = 'windmill',
    workshop = 'workshop',
}

-- Corridor subtypes (matches C++ corridor_type)
local CORRIDOR_TYPE = {
    corridor = 'corridor',
    veinshaft = 'veinshaft',
    aqueduct = 'aqueduct',
    outpost = 'outpost',
    walkable = 'walkable',
}

-- Farm subtypes (matches C++ farm_type)
local FARM_TYPE = {
    food = 'food',
    cloth = 'cloth',
}

-- Stockpile subtypes (matches C++ stockpile_type)
local STOCKPILE_TYPE = {
    food = 'food',
    furniture = 'furniture',
    wood = 'wood',
    stone = 'stone',
    refuse = 'refuse',
    animals = 'animals',
    corpses = 'corpses',
    gems = 'gems',
    finished_goods = 'finished_goods',
    cloth = 'cloth',
    bars_blocks = 'bars_blocks',
    leather = 'leather',
    ammo = 'ammo',
    armor = 'armor',
    weapons = 'weapons',
    coins = 'coins',
    sheets = 'sheets',
    fresh_raw_hide = 'fresh_raw_hide',
}

-- Noble room subtypes (matches C++ nobleroom_type)
local NOBLEROOM_TYPE = {
    tomb = 'tomb',
    dining = 'dining',
    bedroom = 'bedroom',
    office = 'office',
}

-- Outpost subtypes (matches C++ outpost_type)
local OUTPOST_TYPE = {
    cavern = 'cavern',
    mining = 'mining',
}

-- Location subtypes (matches C++ location_type)
local LOCATION_TYPE = {
    guildhall = 'guildhall',
    library = 'library',
    tavern = 'tavern',
    temple = 'temple',
}

-- Cistern subtypes (matches C++ cistern_type)
local CISTERN_TYPE = {
    well = 'well',
    reserve = 'reserve',
}

-- Layout types / furniture types (matches C++ layout_type)
local LAYOUT_TYPE = {
    none = 'none',
    archery_target = 'archery_target',
    armor_stand = 'armor_stand',
    bed = 'bed',
    bookcase = 'bookcase',
    cabinet = 'cabinet',
    cage = 'cage',
    cage_trap = 'cage_trap',
    chair = 'chair',
    chest = 'chest',
    coffin = 'coffin',
    door = 'door',
    floodgate = 'floodgate',
    gear_assembly = 'gear_assembly',
    hatch = 'hatch',
    hive = 'hive',
    lever = 'lever',
    nest_box = 'nest_box',
    offering_place = 'offering_place',
    pedestal = 'pedestal',
    restraint = 'restraint',
    roller = 'roller',
    statue = 'statue',
    table = 'table',
    track_stop = 'track_stop',
    traction_bench = 'traction_bench',
    vertical_axle = 'vertical_axle',
    weapon_rack = 'weapon_rack',
    well = 'well',
}

-- Task types (matches C++ task_type)
local TASK_TYPE = {
    check_construct = 'check_construct',
    check_furnish = 'check_furnish',
    check_idle = 'check_idle',
    check_rooms = 'check_rooms',
    construct_activityzone = 'construct_activityzone',
    construct_farmplot = 'construct_farmplot',
    construct_furnace = 'construct_furnace',
    construct_stockpile = 'construct_stockpile',
    construct_tradedepot = 'construct_tradedepot',
    construct_windmill = 'construct_windmill',
    construct_workshop = 'construct_workshop',
    dig_cistern = 'dig_cistern',
    dig_garbage = 'dig_garbage',
    dig_room = 'dig_room',
    dig_room_immediate = 'dig_room_immediate',
    furnish = 'furnish',
    monitor_cistern = 'monitor_cistern',
    monitor_farm_irrigation = 'monitor_farm_irrigation',
    monitor_room_value = 'monitor_room_value',
    rescue_caged = 'rescue_caged',
    setup_farmplot = 'setup_farmplot',
    want_dig = 'want_dig',
}

local function coord_new(x, y, z)
    return { x = x, y = y, z = z }
end

local function coord_add(a, b)
    return coord_new(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function coord_sub(a, b)
    return coord_new(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function coord_size(a, b)
    return coord_new(b.x - a.x + 1, b.y - a.y + 1, b.z - a.z + 1)
end

local function coord_center(min, max)
    local s = coord_size(min, max)
    return coord_new(
        min.x + math.floor(s.x / 2),
        min.y + math.floor(s.y / 2),
        min.z + math.floor(s.z / 2)
    )
end

local function coord_in_range(c, min, max)
    return c.x >= min.x and c.x <= max.x
        and c.y >= min.y and c.y <= max.y
        and c.z >= min.z and c.z <= max.z
end

--- Create a new room.
-- @param room_type  Room type string
-- @param min        {x,y,z} min coord
-- @param max        {x,y,z} max coord
-- @param kwargs     Optional fields table
function room.new(room_type, min, max, kwargs)
    kwargs = kwargs or {}
    local o = {
        status = STATUS.plan,
        type = room_type,
        corridor_type = kwargs.corridor_type or nil,
        farm_type = kwargs.farm_type or nil,
        stockpile_type = kwargs.stockpile_type or nil,
        nobleroom_type = kwargs.nobleroom_type or nil,
        outpost_type = kwargs.outpost_type or nil,
        location_type = kwargs.location_type or nil,
        cistern_type = kwargs.cistern_type or nil,
        workshop_type = kwargs.workshop_type or nil,
        furnace_type = kwargs.furnace_type or nil,
        raw_type = kwargs.raw_type or '',
        comment = kwargs.comment or '',
        min = min,
        max = max,
        accesspath = {},
        layout = {},
        owner = kwargs.owner or -1,
        bld_id = kwargs.bld_id or -1,
        squad_id = kwargs.squad_id or -1,
        level = kwargs.level or 0,
        noblesuite = kwargs.noblesuite or -1,
        queue = kwargs.queue or 0,
        workshop = kwargs.workshop or nil,
        stock_disable = {},
        stock_specific1 = false,
        stock_specific2 = false,
        has_users = 0,
        furnished = false,
        queue_dig = kwargs.queue_dig or false,
        temporary = kwargs.temporary or false,
        outdoor = kwargs.outdoor or false,
        channeled = kwargs.channeled or false,
        build_when_accessible = kwargs.build_when_accessible or false,
        required_value = kwargs.required_value or 0,
        data1 = kwargs.data1 or 0,
        data2 = kwargs.data2 or 0,
    }
    setmetatable(o, room)
    return o
end

function room:size()
    return coord_size(self.min, self.max)
end

function room:pos()
    return coord_center(self.min, self.max)
end

function room:include(c)
    return coord_in_range(c, self.min, self.max)
end

function room:safe_include(c)
    -- includes a 1-tile buffer around the room
    return coord_in_range(c,
        coord_sub(self.min, coord_new(1, 1, 1)),
        coord_add(self.max, coord_new(1, 1, 1))
    )
end

function room:dig_mode(c)
    -- Determine what dig designation to use for a given tile in this room.
    -- Multi-z corridors (stairwells) need UpDownStair so dwarves can
    -- actually walk between the levels once dug — a Default-dug vertical
    -- shaft is an un-walkable pit.
    if self.channeled then
        return df.tile_dig_designation.Channel
    end
    if self.type == TYPE.corridor and (self.max.z > self.min.z) then
        return df.tile_dig_designation.UpDownStair
    end
    return df.tile_dig_designation.Default
end

local TTS = df.tiletype_shape

-- Tile shape for (x, y, z) — df.tiletype.attrs[tile].shape. Returns nil
-- when the tile/block cannot be read.
local function tile_shape(x, y, z)
    local ok_t, tt = pcall(function()
        local b = dfhack.maps.getTileBlock(x, y, z)
        if not b then return nil end
        return b.tiletype[x % 16][y % 16]
    end)
    if not ok_t or tt == nil then return nil end
    local ok_s, shape = pcall(function() return df.tiletype.attrs[tt].shape end)
    if not ok_s then return nil end
    return shape
end

local SHAPE_IS_WALL = {}
local SHAPE_KNOWN = {}
local function ensure_shape_tables()
    if next(SHAPE_IS_WALL) then return end
    -- Shapes whose basic_shape is Wall block a room from being "dug".
    -- (Explicit table: no df.tiletype_shape.attrs exists in 53.16.)
    local walls = {
        'WALL', 'FORTIFICATION', 'TREE', 'TWIG', 'BRANCH',
        'TRUNK_BRANCH', 'ROOT',
    }
    local known = {
        'WALL', 'FORTIFICATION', 'TREE', 'TWIG', 'BRANCH',
        'TRUNK_BRANCH', 'ROOT', 'FLOOR', 'BOULDER', 'PEBBLES', 'RAMP',
        'STAIR_UP', 'STAIR_DOWN', 'STAIR_UPDOWN', 'RAMP_TOP',
        'BROOK_TOP', 'BROOK_BED', 'RIVER_BED', 'SAPLING', 'SHRUB',
        'OPEN_SPACE', 'ENDLESS_PIT',
    }
    for _, name in ipairs(walls) do
        local v = TTS[name]
        if v ~= nil then SHAPE_IS_WALL[v] = true end
    end
    for _, name in ipairs(known) do
        local v = TTS[name]
        if v ~= nil then SHAPE_KNOWN[v] = true end
    end
end

local function shape_is_wall(shape)
    if shape == nil then return false end
    ensure_shape_tables()
    if SHAPE_KNOWN[shape] then
        return SHAPE_IS_WALL[shape] == true
    end
    -- unknown shape: only the literal WALL/FORTIFICATION shapes block a room
    return shape == TTS.WALL or shape == TTS.FORTIFICATION
end

local function tile_is_wall(x, y, z)
    local shape = tile_shape(x, y, z)
    return shape ~= nil and shape_is_wall(shape)
end

-- ============================================================
-- dig() — C++ room::dig parity (r3.6)
--
-- The r3.5 version set `des.dig = Default` on EVERY tile in the room's
-- bounds — including open air, floors, shrubs and constructions. Those
-- designations are invalid: DF generates no job for them, nothing ever
-- clears them, and the old is_dug() (which checked designations instead
-- of tile shapes) therefore NEVER returned true. Rooms stayed 'dig'
-- forever, nrdig filled every dig slot, and the whole plan pipeline
-- deadlocked — the dwarves stood idle next to a fully-designated map.
--
-- The C++ original (room.cpp) only designates:
--   * tiles whose shape is WALL (Default designation), or
--   * non-open tiles when the designation is DownStair/Channel
--   * skips CONSTRUCTION-material tiles
-- plus the per-furniture digs (stairs for layout items with f.dig).
-- It also runs dig_tile() which marks the block as designated.
-- ============================================================
function room:dig()
    local designated = 0
    local cleared = 0
    for z = self.min.z, self.max.z do
        for x = self.min.x, self.max.x do
            for y = self.min.y, self.max.y do
                local block = dfhack.maps.getTileBlock(x, y, z)
                if block then
                    local lx, ly = x % 16, y % 16
                    local tt = block.tiletype[lx][ly]
                    local des = block.designation[lx][ly]
                    if tt ~= nil and des ~= nil then
                        local shape = df.tiletype.attrs[tt].shape
                        local dm = self:dig_mode(coord_new(x, y, z))
                        local is_wall = shape ~= nil and shape_is_wall(shape)
                        local is_open = (shape == TTS.OPEN_SPACE
                            or shape == TTS.RAMP_TOP)
                        local stair_needed = (dm == df.tile_dig_designation.UpDownStair
                            or dm == df.tile_dig_designation.Channel
                            or dm == df.tile_dig_designation.DownStair)
                        local wants = (is_wall and dm ~= df.tile_dig_designation.Channel)
                            or (stair_needed and not is_open and not is_wall)
                        if wants and des.dig == df.tile_dig_designation.No then
                            des.dig = dm
                            block.flags.designated = true
                            designated = designated + 1
                        elseif not wants and des.dig ~= df.tile_dig_designation.No then
                            -- self-heal: clear invalid designations left by
                            -- older df-ai builds (r3.4/r3.5 wrote Default on
                            -- floors/open air; those never clear by themselves)
                            local cur = des.dig
                            if cur == df.tile_dig_designation.Default and not is_wall then
                                des.dig = df.tile_dig_designation.No
                                cleared = cleared + 1
                            end
                        end
                    end
                end
            end
        end
    end

    -- Per-furniture digs (stairs down into the room, channels, ...)
    -- C++ AI::dig_tile OVERWRITES the designation (des->bits.dig = dig
    -- unconditionally) — the room loop above may have put Default on the
    -- wall already; the furniture's explicit dig wins.
    for _, f in ipairs(self.layout) do
        local p = f.pos
        if p and f.dig and f.dig ~= df.tile_dig_designation.No then
            local block = dfhack.maps.getTileBlock(p.x, p.y, p.z)
            if block then
                local lx, ly = p.x % 16, p.y % 16
                local tt = block.tiletype[lx][ly]
                local des = block.designation[lx][ly]
                if tt ~= nil and des ~= nil then
                    local shape = df.tiletype.attrs[tt].shape
                    local is_wall = shape ~= nil and shape_is_wall(shape)
                    local is_open = (shape == TTS.OPEN_SPACE or shape == TTS.RAMP_TOP)
                    if (f.dig ~= df.tile_dig_designation.Default and (is_wall
                        or (f.dig == df.tile_dig_designation.Channel and not is_open)))
                        or (f.dig == df.tile_dig_designation.Default and is_wall) then
                        des.dig = f.dig
                        block.flags.designated = true
                        designated = designated + 1
                    end
                end
            end
        end
    end

    return designated, cleared
end

-- ============================================================
-- is_dug() — C++ room::is_dug parity (r3.6): SHAPE-based.
-- A room is dug when no interior tile is still a WALL (ignoring
-- furniture holes whose dig is No). The old version checked
-- `des.dig ~= No`, which never became true while invalid floor
-- designations sat on the map.
-- ============================================================
function room:is_dug()
    local reason = nil
    local holes = {}
    for _, f in ipairs(self.layout) do
        local p = f.pos
        if p and not f.ignore and f.dig == df.tile_dig_designation.No then
            holes[p.x .. ',' .. p.y .. ',' .. p.z] = true
        end
    end
    for z = self.min.z, self.max.z do
        for x = self.min.x, self.max.x do
            for y = self.min.y, self.max.y do
                if not holes[x .. ',' .. y .. ',' .. z] then
                    if tile_is_wall(x, y, z) then
                        reason = 'wall at ' .. x .. ',' .. y .. ',' .. z
                        return false, reason
                    end
                end
            end
        end
    end
    return true, nil
end

-- Count of still-undug interior tiles (for progress logging)
function room:dig_remaining()
    local n = 0
    for z = self.min.z, self.max.z do
        for x = self.min.x, self.max.x do
            for y = self.min.y, self.max.y do
                if tile_is_wall(x, y, z) then
                    n = n + 1
                end
            end
        end
    end
    return n
end

function room:constructions_done()
    if self.type == 'corridor' then
        return true
    end
    if self.bld_id >= 0 then
        local bld = df.building.find(self.bld_id)
        if bld then
            return true
        end
        self.bld_id = -1
    end
    -- Fallback: scan buildings at our position
    local pos = self:pos()
    for _, bld in ipairs(df.global.world.buildings.all) do
        if bld.z == pos.z and bld.centerx == pos.x and bld.centery == pos.y then
            self.bld_id = bld.id
            return true
        end
    end
    return false
end

function room:dfbuilding()
    if self.bld_id >= 0 then
        return df.building.find(self.bld_id)
    end
    return nil
end

function room:compute_value()
    -- Simplified room value calculation
    -- The C++ version checks all furniture items' values
    local val = 0
    local bld = self:dfbuilding()
    if bld then
        -- Basic room value from building
        val = val + 100
    end
    for _, f in ipairs(self.layout) do
        if f.bld_id >= 0 then
            local fbld = df.building.find(f.bld_id)
            if fbld then
                -- Could iterate contained items for more precise value
                val = val + 50
            end
        end
    end
    return val
end

function room:distance_to(other)
    -- r3.5: `other` may be a room object OR a plain {x,y,z} coord table —
    -- plan.lua passes find_fort_entrance()'s result (a plain table) here,
    -- and with the old `other:pos()` call that crashed with
    -- "attempt to call a nil value (method 'pos')", which aborted the
    -- whole corridor-connection pass in plan_setup.
    local p1 = self:pos()
    local p2 = nil
    if type(other) == 'table' then
        if type(other.pos) == 'function' then
            local ok, p = pcall(other.pos, other)
            p2 = (ok and type(p) == 'table') and p or other
        else
            p2 = other
        end
    end
    if not p2 or p2.x == nil or p2.y == nil or p2.z == nil then
        return math.huge
    end
    return math.abs(p1.x - p2.x) + math.abs(p1.y - p2.y) + math.abs(p1.z - p2.z) * 10
end

function room:low_grass()
    -- Check if pasture has low grass (simplified)
    return false
end

--- Create a new furniture item.
-- @param layout_type  Layout type string
-- @param pos          {x,y,z} position
-- @param kwargs       Optional fields
function furniture.new(layout_type, pos, kwargs)
    kwargs = kwargs or {}
    local o = {
        type = layout_type,
        construction = kwargs.construction or nil,
        dig = kwargs.dig or df.tile_dig_designation.Default,
        bld_id = kwargs.bld_id or -1,
        pos = pos,
        target = kwargs.target or nil,
        users = {},
        has_users = 0,
        ignore = kwargs.ignore or false,
        makeroom = kwargs.makeroom or false,
        internal = kwargs.internal or false,
        comment = kwargs.comment or '',
    }
    setmetatable(o, furniture)
    return o
end

return {
    room = room,
    furniture = furniture,
    STATUS = STATUS,
    TYPE = TYPE,
    CORRIDOR_TYPE = CORRIDOR_TYPE,
    FARM_TYPE = FARM_TYPE,
    STOCKPILE_TYPE = STOCKPILE_TYPE,
    NOBLEROOM_TYPE = NOBLEROOM_TYPE,
    OUTPOST_TYPE = OUTPOST_TYPE,
    LOCATION_TYPE = LOCATION_TYPE,
    CISTERN_TYPE = CISTERN_TYPE,
    LAYOUT_TYPE = LAYOUT_TYPE,
    TASK_TYPE = TASK_TYPE,
    coord_new = coord_new,
    coord_add = coord_add,
    coord_sub = coord_sub,
    coord_size = coord_size,
    coord_center = coord_center,
    coord_in_range = coord_in_range,
}
