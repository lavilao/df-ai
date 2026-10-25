-- test_parity_r310.lua — r3.10 feature-parity tests
--
-- Runs with PLAIN lua5.3 (same Lua as DFHack 53.16-r3). Covers the
-- r3.10 parity wave:
--   1. persist.lua round-trip — rooms, corridors, furniture, tasks,
--      accesspath chains, lever->floodgate targets, priority latches,
--      military thresholds survive serialize/deserialize with identity
--      and cross-references intact
--   2. site discriminator — saved data from another site is rejected
--   3. restore_priority_state wiring
--
-- Usage: lua5.3 test/test_parity_r310.lua   (from the repository root)

local failures = 0

local function check(cond, msg)
    if cond then
        print('OK   ' .. msg)
    else
        failures = failures + 1
        print('FAIL ' .. msg)
    end
end

-- ============================================================
-- Mock rooms module (df-ai/rooms compatible constructors)
-- ============================================================

local function make_rooms_module()
    local room_mt = { __index = {} }
    local furn_mt = { __index = {} }
    return {
        room = {
            new = function(ty, mn, mx, kwargs)
                kwargs = kwargs or {}
                return {
                    status = 'plan', type = ty,
                    corridor_type = kwargs.corridor_type,
                    farm_type = kwargs.farm_type,
                    stockpile_type = kwargs.stockpile_type,
                    nobleroom_type = kwargs.nobleroom_type,
                    outpost_type = kwargs.outpost_type,
                    location_type = kwargs.location_type,
                    cistern_type = kwargs.cistern_type,
                    workshop_type = kwargs.workshop_type,
                    furnace_type = kwargs.furnace_type,
                    raw_type = kwargs.raw_type or '',
                    comment = kwargs.comment or '',
                    min = mn, max = mx,
                    accesspath = {}, layout = {},
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
                    data1 = 0, data2 = 0,
                }
            end,
        },
        furniture = {
            new = function(ty, pos, kwargs)
                kwargs = kwargs or {}
                return {
                    type = ty,
                    construction = kwargs.construction,
                    dig = kwargs.dig,
                    bld_id = kwargs.bld_id or -1,
                    pos = pos,
                    target = kwargs.target,
                    users = {},
                    has_users = 0,
                    ignore = kwargs.ignore or false,
                    makeroom = kwargs.makeroom or false,
                    internal = kwargs.internal or false,
                    comment = kwargs.comment or '',
                }
            end,
        },
    }
end

local rooms_module = make_rooms_module()

-- ============================================================
-- Load persist.lua headlessly (no dfhack: the module only touches
-- dfhack inside save()/load() — the tested core is pure)
-- ============================================================

local persist = dofile('hack/scripts/df-ai/persist.lua')
check(type(persist) == 'table' and persist.serialize and persist.deserialize,
    'persist module loads and exposes serialize/deserialize')

-- ============================================================
-- Build a realistic plan
-- ============================================================

local function build_plan()
    local plan = {
        rooms = {}, corridors = {},
        tasks_generic = {}, tasks_furniture = {},
        priority_rules = {},
        past_initial_phase = false,
        should_search_for_metal = true,
        setup_done = false,
    }

    -- entrance corridor
    local corr = rooms_module.room.new('corridor',
        { x = 10, y = 10, z = 10 }, { x = 12, y = 10, z = 10 },
        { corridor_type = 'corridor' })
    corr.status = 'dug'
    table.insert(plan.corridors, corr)

    -- bedroom with furniture (bed + door)
    local bed = rooms_module.furniture.new('bed',
        { x = 20, y = 20, z = 10 }, {})
    local door = rooms_module.furniture.new('door',
        { x = 19, y = 20, z = 10 }, { construction = 'Wall' })
    local bedroom = rooms_module.room.new('bedroom',
        { x = 19, y = 19, z = 10 }, { x = 22, y = 22, z = 10 },
        { owner = 1234, bld_id = 77, noblesuite = -1 })
    bedroom.status = 'finished'
    bedroom.furnished = true
    bedroom.accesspath = { corr }
    table.insert(bedroom.layout, bed)
    table.insert(bedroom.layout, door)
    table.insert(plan.rooms, bedroom)

    -- stockpile linked to a workshop room (workshop ref)
    local workshop = rooms_module.room.new('workshop',
        { x = 30, y = 30, z = 10 }, { x = 32, y = 32, z = 10 },
        { workshop_type = 4 }) -- Still-ish
    workshop.status = 'dig'
    table.insert(plan.rooms, workshop)
    local stock = rooms_module.room.new('stockpile',
        { x = 34, y = 30, z = 10 }, { x = 36, y = 32, z = 10 },
        { stockpile_type = 'food' })
    stock.workshop = workshop
    stock.status = 'dug'
    stock.accesspath = { corr }
    table.insert(plan.rooms, stock)

    -- well room: lever -> floodgate target (cross-room furniture ref)
    local floodgate = rooms_module.furniture.new('floodgate',
        { x = 40, y = 40, z = 9 }, { dig = 0 })
    local lever = rooms_module.furniture.new('lever',
        { x = 41, y = 41, z = 10 }, {})
    lever.target = floodgate
    local well = rooms_module.room.new('cistern',
        { x = 39, y = 39, z = 10 }, { x = 42, y = 42, z = 10 },
        { cistern_type = 'well' })
    table.insert(well.layout, floodgate)
    table.insert(well.layout, lever)
    well.accesspath = { corr }
    table.insert(plan.rooms, well)

    -- noble room with required_value
    local office = rooms_module.room.new('nobleroom',
        { x = 50, y = 50, z = 10 }, { x = 52, y = 52, z = 10 },
        { nobleroom_type = 'office', noblesuite = 3, owner = 999 })
    office.required_value = 500
    table.insert(plan.rooms, office)

    -- tasks: generic (check_rooms, dig stockpile) + furnish (bed)
    table.insert(plan.tasks_generic, { type = 'check_rooms', room = nil,
        furniture = nil, item_id = -1, last_status = '' })
    table.insert(plan.tasks_generic, { type = 'dig_room', room = stock,
        furniture = nil, item_id = -1, last_status = 'queued' })
    table.insert(plan.tasks_furniture, { type = 'furnish', room = bedroom,
        furniture = bed, item_id = -1, last_status = '' })

    plan.priority_rules = {
        { id = 'rule-a', working = true, keep_going = false },
        { id = 'rule-b', working = false, keep_going = true },
        { id = 'rule-c', working = true, keep_going = true },
    }

    plan.fort_entrance = { x = 11, y = 10, z = 10 }

    return plan
end

-- ============================================================
-- 1. Round-trip
-- ============================================================

local plan = build_plan()
local data = persist.serialize(plan, { military_min = 30, military_max = 80 })

check(#data.rooms == 5, 'serialize: 5 rooms (bedroom, workshop, stockpile, cistern, nobleroom)')
check(#data.corridors == 1, 'serialize: 1 corridor')
check(data.military_min == 30 and data.military_max == 80,
    'serialize: military thresholds captured')
check(data.fe and data.fe.x == 11 and data.fe.z == 10,
    'serialize: fort_entrance coord captured')
check(data.priorities and #data.priorities == 3
    and data.priorities[1].w == 1 and data.priorities[2].w == 0,
    'serialize: priority latches captured')

-- restore into a fresh plan object
local restored = {}
local ok = persist.deserialize(restored, data, rooms_module,
    { military_min = 25, military_max = 75 })
check(ok == true, 'deserialize: succeeds')
check(restored.setup_done == true and restored.builder_started == true,
    'deserialize: setup flags set (AI will not re-plan)')
check(#restored.rooms == 5 and #restored.corridors == 1,
    'deserialize: room/corridor counts preserved')
check(restored.military_min == nil, 'deserialize: population thresholds go to the population table')

local function find_room(tbl, ty, extra)
    for _, r in ipairs(tbl) do
        if r.type == ty and (extra == nil or extra(r)) then return r end
    end
end

local r_bedroom = find_room(restored.rooms, 'bedroom')
local r_corr = find_room(restored.corridors, 'corridor')
local r_stock = find_room(restored.rooms, 'stockpile')
local r_well = find_room(restored.rooms, 'cistern')
local r_office = find_room(restored.rooms, 'nobleroom')

check(r_bedroom ~= nil and r_bedroom.owner == 1234 and r_bedroom.bld_id == 77,
    'deserialize: bedroom identity preserved')
check(r_bedroom.status == 'finished' and r_bedroom.furnished == true,
    'deserialize: bedroom status/furnished preserved')
check(r_bedroom.min.x == 19 and r_bedroom.max.z == 10,
    'deserialize: bedroom coords preserved')
check(#r_bedroom.layout == 2 and r_bedroom.layout[1].type == 'bed'
    and r_bedroom.layout[1].pos.x == 20,
    'deserialize: bedroom furniture + positions preserved')
check(r_bedroom.layout[2].construction == 'Wall',
    'deserialize: furniture construction preserved')
check(#r_bedroom.accesspath == 1 and r_bedroom.accesspath[1] == r_corr,
    'deserialize: accesspath cross-reference rebuilt to the SAME object')

check(r_stock ~= nil and r_stock.workshop ~= nil
    and r_stock.workshop.type == 'workshop',
    'deserialize: stockpile->workshop link rebuilt')
check(r_stock.workshop.workshop_type == 4,
    'deserialize: workshop_type enum preserved')

check(r_well ~= nil and #r_well.layout == 2
    and r_well.layout[2].type == 'lever'
    and r_well.layout[2].target == r_well.layout[1],
    'deserialize: lever->floodgate target rebuilt to the SAME object')

check(r_office ~= nil and r_office.required_value == 500
    and r_office.noblesuite == 3 and r_office.owner == 999,
    'deserialize: noble required_value/suite/owner preserved')

-- tasks rebuilt with live object refs
check(#restored.tasks_generic == 2, 'deserialize: generic task count')
local t_dig = restored.tasks_generic[2]
check(t_dig.type == 'dig_room' and t_dig.room == r_stock
    and t_dig.last_status == 'queued',
    'deserialize: dig task references the rebuilt stockpile object')
check(#restored.tasks_furniture == 1
    and restored.tasks_furniture[1].furniture == r_bedroom.layout[1],
    'deserialize: furnish task references the rebuilt bed object')

check(restored.fort_entrance ~= nil and restored.fort_entrance.x == 11,
    'deserialize: fort_entrance coord restored')
check(restored.past_initial_phase == false
    and restored.should_search_for_metal == true,
    'deserialize: phase flags restored')

-- population thresholds restored
local population = { military_min = 25, military_max = 75 }
local restored2 = {}
data.military_min = 30
data.military_max = 80
check(persist.deserialize(restored2, data, rooms_module, population) == true
    and population.military_min == 30 and population.military_max == 80,
    'deserialize: population thresholds written back')

-- ============================================================
-- 2. Site discriminator
-- ============================================================

-- emulate a different site: site_id in data + mismatching df.global
data.site_id = 42
local rejected = {}
local ok_rej = persist.deserialize(rejected, data, rooms_module, nil)
check(ok_rej == false and rejected.setup_done ~= true,
    'deserialize: saved plan from another site is REJECTED (fresh setup)')

-- ============================================================
-- 3. Priority latch restore
-- ============================================================

local plan3 = build_plan()
plan3._persist_priorities = {
    { w = 1, k = 0 }, { w = 0, k = 1 }, { w = 1, k = 1 },
}
persist.restore_priority_state(plan3)
check(plan3.priority_rules[1].working == true
    and plan3.priority_rules[2].working == false
    and plan3.priority_rules[3].keep_going == true
    and plan3._persist_priorities == nil,
    'restore_priority_state: latches re-applied and consumed')

-- ============================================================
-- 4. Empty/nil tolerance
-- ============================================================

check(persist.deserialize({}, nil, rooms_module) == false,
    'deserialize: nil data rejected')
check(persist.deserialize({}, {}, rooms_module) == false,
    'deserialize: data without rooms rejected')
check(persist.deserialize({}, { rooms = {} }, nil) == false,
    'deserialize: missing rooms_module rejected')

print(('\ntest_parity_r310: %d failure(s)'):format(failures))
os.exit(failures == 0 and 0 or 1)
