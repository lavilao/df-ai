--@module = true

local json = require('json')
local rooms_module = nil
local blueprint_module = nil
local priorities_module = nil
-- forward declaration: the dig-pipeline block below runs before the
-- logging helpers are (lexically) defined — without this the upvalue
-- resolves to a nil global at runtime
local describe_room

-- Task types
local TASK_TYPE = {
    check_rooms = 'check_rooms',
    want_dig = 'want_dig',
    dig_room = 'dig_room',
    dig_room_immediate = 'dig_room_immediate',
    construct_tradedepot = 'construct_tradedepot',
    construct_workshop = 'construct_workshop',
    construct_farmplot = 'construct_farmplot',
    construct_furnace = 'construct_furnace',
    construct_stockpile = 'construct_stockpile',
    construct_activityzone = 'construct_activityzone',
    construct_windmill = 'construct_windmill',
    monitor_farm_irrigation = 'monitor_farm_irrigation',
    setup_farmplot = 'setup_farmplot',
    furnish = 'furnish',
    check_furnish = 'check_furnish',
    check_construct = 'check_construct',
    dig_cistern = 'dig_cistern',
    dig_garbage = 'dig_garbage',
    check_idle = 'check_idle',
    monitor_cistern = 'monitor_cistern',
    monitor_room_value = 'monitor_room_value',
    rescue_caged = 'rescue_caged',
}

local Plan = {}
Plan.__index = Plan

-- ============================================================
-- Construction
-- ============================================================

function Plan.new(ai)
    local o = {
        ai = ai,
        tasks_generic = {},
        tasks_furniture = {},
        bg_idx_generic = nil,
        bg_idx_furniture = nil,
        rooms = {},
        corridors = {},
        room_category = {},
        important_workshops = {
            df.workshop_type.Butchers,
            df.workshop_type.Quern,
            df.workshop_type.Farmers,
            df.workshop_type.Mechanics,
            df.workshop_type.Still,
        },
        important_workshops2 = {
            df.furnace_type.Smelter,
            df.furnace_type.WoodFurnace,
        },
        important_workshops3 = {
            df.workshop_type.Loom,
            df.workshop_type.Craftsdwarfs,
            df.workshop_type.Tanners,
            df.workshop_type.Kitchen,
        },
        fort_entrance = nil,
        past_initial_phase = false,
        should_search_for_metal = false,
        last_update_year = -1,
        last_update_tick = -1,
        checkroom_idx = 0,
        nrdig = {},
        plan_config = nil,
        templates = {},
        setup_done = false,
        builder = nil,
        builder_started = false,
        priority_rules = {},
    }
    setmetatable(o, Plan)
    return o
end

function Plan:startup()
    self:load_rooms_module()
    self:load_blueprint()
    if self.builder_started then return end
    if self:plan_setup() then
        self.builder_started = true
        -- rooms are installed by _finish_setup() once the resumable
        -- placement builder completes (Plan:update steps it)
    else
        -- setup stays pending: Plan:update retries (map blocks may not
        -- be loaded yet on the very first ticks after embark)
        self.setup_attempts = (self.setup_attempts or 0) + 1
        dfhack.println('[df-ai] plan setup deferred (attempt ' .. self.setup_attempts .. ')')
    end
end

function Plan:load_rooms_module()
    local ok, mod = pcall(dfhack.run_script_with_env, nil, 'df-ai/rooms', {module=true})
    if ok then
        rooms_module = mod
    end
    local okb, modb = pcall(dfhack.run_script_with_env, nil, 'df-ai/blueprint', {module=true})
    if okb then blueprint_module = modb end
    local okp, modp = pcall(dfhack.run_script_with_env, nil, 'df-ai/priorities', {module=true})
    if okp then priorities_module = modp end
end

function Plan:update()
    self.last_update_year = df.global.cur_year
    self.last_update_tick = df.global.cur_year_tick

    if not self.setup_done then
        if self.builder then
            -- r3.8: the builder has its OWN repeating task (every 2
            -- ticks, time-budgeted) — see step_builder(). Plan:update
            -- runs at the C++ 240-tick cadence and must not gate the
            -- layout progress.
            return
        end
        -- bounded retry: setup failed at startup (e.g. map not ready);
        -- after 10 attempts the plan stays off but everything else keeps
        -- running (stocks, population, camera)
        self.setup_attempts = self.setup_attempts or 0
        if self.setup_attempts < 10 then
            self:startup()
        end
        return
    end

    -- r3.5: the task queues are processed HERE, from the update loop.
    -- r3.4 registered dfhack.onStateChange handlers keyed on
    -- SC_VIEWSCREEN_CHANGED — one task per viewscreen CHANGE. With the
    -- fort running at rest no viewscreen ever changes, so the queues
    -- never advanced a single task: rooms were placed, then nothing.
    -- No dig designations, no constructions, no furnishing —
    -- "the dwarves don't seem to do anything".
    self:process_tasks_generic(2)
    self:process_tasks_furniture(1)
end

-- r3.8: dedicated time-budgeted driver for the resumable placement
-- builder. Registered from df-ai.lua at a 2-tick cadence while a
-- layout is running; each call does at most ~8 ms of placement work so
-- the game keeps rendering at full speed (the r3.7 engine did up to
-- 750 tries per call — seconds of blocking per 25 ticks on a real
-- 192x192 map, freezing the game the moment df-ai was enabled).
function Plan:step_builder()
    if not self.builder or self.builder.done then return end
    self.builder:step_ms(8)
    if self.builder.done then
        self:_finish_setup()
    end
end

function Plan:add_task(task_type, room, furniture, item_id)
    -- C++ Plan::add_task is deduplicating on (type, room, furniture,
    -- item_id) — without this, construct_room + checkroom + check_furnish
    -- re-queue the same furniture every pass and one cage trap ends up
    -- with a dozen live furnish tasks (the r3.6 trap spam loop).
    local target = task_type == TASK_TYPE.furnish
        and self.tasks_furniture or self.tasks_generic
    for _, t in ipairs(target) do
        if t.type == task_type and t.room == room
            and t.furniture == furniture
            and (t.item_id or -1) == (item_id or -1) then
            return
        end
    end
    local t = {
        type = task_type,
        room = room,
        furniture = furniture,
        item_id = item_id or -1,
        last_status = '',
    }
    table.insert(target, t)
end

-- ============================================================
-- Blueprint loading — loads plan JSON + all templates
-- ============================================================

function Plan:load_blueprint()
    self.rooms = {}
    self.corridors = {}
    self.room_category = {}
    self.templates = {}
    self.plan_config = nil

    local plan = nil
    -- release layout, nested-zip layout, repo checkout layout
    for _, path in ipairs({
        'df-ai-blueprints/plans/generic01.json',
        'df-ai-53.16-r3/df-ai-blueprints/plans/generic01.json',
        'plans/generic01.json',
    }) do
        local ok_p, p = pcall(json.decode_file, path)
        if ok_p and p then
            plan = p
            break
        end
    end
    if not plan then
        dfhack.println('[df-ai] Failed to load plan: make sure the df-ai-blueprints/ folder is inside your Dwarf Fortress directory.')
        return
    end
    self.plan_config = plan

    -- Load all templates from standard directories
    local template_bases = {
        'generic01_start', 'generic01_corridor', 'generic01_corridor_stair',
        'generic01_bedroom', 'generic01_bedrooms', 'generic01_dormitory',
        'generic01_dininghall', 'generic01_nobleroom', 'generic01_stockpile',
        'generic01_workshop_3x3', 'generic01_workshop_5x5', 'generic01_workshop_1x1',
        'generic01_farmplot', 'generic01_barracks', 'generic01_infirmary',
        'generic01_jail', 'generic01_cemetery', 'generic01_location',
        'generic01_depot', 'generic01_outpost_entrance', 'generic01_mineshaft',
        'generic01_mineshaft_segment', 'generic01_pasture', 'generic01_pitting_tower',
        'generic01_cage_trap', 'generic01_outdoor_farm', 'generic01_apiary',
        'generic01_well', 'generic01_stair', 'generic01_underground_farm_start',
        'generic01_underground_farm_extension',
    }

    for _, base in ipairs(template_bases) do
        -- Three supported layouts, tried in order:
        --   1. Release package: df-ai-blueprints/templates/<base>/
        --   2. Release zip extracted without merging the top folder:
        --      df-ai-53.16-r3/df-ai-blueprints/templates/<base>/
        --   3. Repo checkout:    df-ai-blueprints/rooms/templates/<base>/
        -- NOTE: dfhack.filesystem.listdir on a missing dir does NOT error —
        -- it returns nil. Always type-check the result.
        local loaded_any = false
        for _, dir in ipairs({
            'df-ai-blueprints/templates/' .. base .. '/',
            'df-ai-53.16-r3/df-ai-blueprints/templates/' .. base .. '/',
            'df-ai-blueprints/rooms/templates/' .. base .. '/',
        }) do
            local ok_list, result = pcall(dfhack.filesystem.listdir, dir)
            if ok_list and type(result) == 'table' then
                for _, fname in ipairs(result) do
                    if fname:match('%.json$') then
                        local ok_t, tmpl = pcall(json.decode_file, dir .. fname)
                        if ok_t and tmpl then
                            local key = base .. '/' .. fname:gsub('%.json$', '')
                            self.templates[key] = tmpl
                            loaded_any = true
                        else
                            dfhack.println('[df-ai] warning: bad template JSON: ' .. dir .. fname)
                        end
                    end
                end
                break -- first layout that exists wins
            end
        end
        if not loaded_any then
            dfhack.println('[df-ai] note: no templates for ' .. base .. ' (skipped)')
        end
    end

    local n_templates = self:_count_templates()
    dfhack.println('[df-ai] Loaded plan config + ' .. n_templates .. ' templates')
    if n_templates == 0 then
        dfhack.println('[df-ai] WARNING: no room templates found. Make sure the df-ai-blueprints/ folder is inside your Dwarf Fortress directory.')
    end
end

function Plan:_count_templates()
    local n = 0
    for _ in pairs(self.templates) do n = n + 1 end
    return n
end

function Plan:_template_orientations(base_name)
    -- Return list of template keys matching base_name
    local matches = {}
    for key in pairs(self.templates) do
        if key:find(base_name .. '/') == 1 then
            table.insert(matches, key)
        end
    end
    return matches
end

-- ============================================================
-- Plan setup — find embark, place rooms, connect corridors
-- ============================================================

function Plan:plan_setup()
    -- Returns true when the placement BUILDER was started; the rooms
    -- themselves are installed by _finish_setup() when it completes.
    if not self.plan_config then
        dfhack.println('[df-ai] No plan config loaded, skipping setup')
        return false
    end

    if not rooms_module then
        self:load_rooms_module()
        if not rooms_module then
            dfhack.println('[df-ai] Rooms module not available, skipping setup')
            return false
        end
    end
    if not blueprint_module then
        dfhack.println('[df-ai] Blueprint module not available, skipping setup')
        return false
    end

    -- Find the embark surface position
    local entrance = self:find_fort_entrance()
    if not entrance then
        dfhack.println('[df-ai] Could not find fort entrance location')
        return false
    end
    self.fort_entrance = entrance
    dfhack.println('[df-ai] Fort entrance at ' .. entrance.x .. ',' .. entrance.y .. ',' .. entrance.z)

    -- The wagon building overlaps the start blueprint's outdoor room;
    -- the plan deconstructs wagons anyway (priority rule), so exempt
    -- its tiles from the building checks.
    local wagon_tiles = {}
    pcall(function()
        for _, bld in ipairs(df.global.world.buildings.all) do
            local ok_w, is_wagon = pcall(function()
                return df.building_wagonst:is_instance(bld)
            end)
            if ok_w and is_wagon then
                for x = bld.x1, bld.x2 do
                    for y = bld.y1, bld.y2 do
                        wagon_tiles[x .. ',' .. y .. ',' .. bld.z] = true
                    end
                end
            end
        end
    end)

    local ok, builder = pcall(blueprint_module.start_build, rooms_module, {
        entrance = entrance,
        log = function(msg) self:_log(msg) end,
        wagon_tiles = wagon_tiles,
    })
    if not ok or not builder then
        dfhack.printerr('[df-ai] blueprint builder failed to start: ' .. tostring(builder))
        return false
    end
    self.builder = builder
    return true
end

-- The builder finished: install rooms, wire the priority rules, and
-- start the task pipeline (check_rooms + check_idle are PERSISTENT
-- tasks — the C++ never deletes them).
function Plan:_finish_setup()
    local ok, rooms, corridors, fort_entrance, stats = self.builder:result()
    self.builder = nil
    if not ok then
        dfhack.printerr('[df-ai] fortress placement failed: ' .. tostring(rooms))
        self.setup_attempts = 99 -- stop retrying; stocks/population still run
        return
    end

    self.rooms = rooms
    self.corridors = corridors
    self.fort_entrance = fort_entrance
    self.room_category = {}
    for _, r in ipairs(rooms) do
        local cat = self.room_category[r.type] or {}
        table.insert(cat, r)
        self.room_category[r.type] = cat
    end

    if priorities_module and self.plan_config
        and self.plan_config.priorities then
        self.priority_rules = priorities_module.prepare(self.plan_config.priorities)
    end

    self:add_task(TASK_TYPE.check_rooms)
    self:add_task(TASK_TYPE.check_idle)
    self.past_initial_phase = false
    self.should_search_for_metal = false
    self.setup_done = true

    -- layout summary (one line per room type)
    local by_type = {}
    for _, r in ipairs(self.rooms) do
        local key = r.type
        if r.workshop_type ~= nil then
            local ok2, name = pcall(function()
                return df.workshop_type[r.workshop_type]
            end)
            if ok2 and name then key = key .. '/' .. tostring(name) end
        elseif r.stockpile_type then
            key = key .. '/' .. tostring(r.stockpile_type)
        elseif r.location_type then
            key = key .. '/' .. tostring(r.location_type)
        end
        by_type[key] = (by_type[key] or 0) + 1
    end
    local summary = {}
    for k, n in pairs(by_type) do
        table.insert(summary, n .. 'x ' .. k)
    end
    table.sort(summary)
    self:_log('layout: ' .. table.concat(summary, ', '))
    self:_log('placement stats: ' .. (stats and stats.placed or 0)
        .. ' blueprints, ' .. (stats and stats.tries or 0) .. ' tries'
        .. (stats and stats.relaxed and ', RELAXED (no rock validation)' or ''))
    dfhack.println('[df-ai] Setup complete: ' .. #self.rooms .. ' rooms, '
        .. #self.corridors .. ' corridors, '
        .. #self.priority_rules .. ' priority rules')
end

-- Ground shapes for the surface scan. Enum-table lookups are plain table
-- indexing (a missing name yields nil, no throw) — unlike struct FIELD
-- reads, which throw on anything that does not exist in 53.16.
local GROUND_SHAPES
local function is_ground_shape(shape)
    if not GROUND_SHAPES then
        GROUND_SHAPES = {}
        for _, name in ipairs({ 'FLOOR', 'WALL', 'RAMP', 'STAIR_UP',
            'STAIR_DOWN', 'STAIR_UPDOWN', 'BROOK_TOP' }) do
            local v = df.tiletype_shape[name]
            if v ~= nil then GROUND_SHAPES[v] = true end
        end
    end
    return GROUND_SHAPES[shape] == true
end

-- Walk down from the top of the map at (x, y) until solid ground is found
-- (skips trees, shrubs, and open air). Returns the z of the first ground
-- tile, or nil. Every DF field read is pcall-wrapped: the 53.16 wrapper
-- THROWS on any field that does not exist.
local function ground_z_at(x, y, z_top)
    for z = z_top, 0, -1 do
        local ok_b, block = pcall(dfhack.maps.getTileBlock, x, y, z)
        if ok_b and block then
            local ok_t, tile = pcall(function()
                return block.tiletype[x % 16][y % 16]
            end)
            if ok_t and tile then
                local ok_a, shape = pcall(function()
                    return df.tiletype.attrs[tile].shape
                end)
                if ok_a and is_ground_shape(shape) then
                    return z
                end
            end
        end
    end
    return nil
end

function Plan:find_fort_entrance()
    -- v50 REMOVED plotinfo.embark_pos entirely, and reading a struct field
    -- that does not exist THROWS in the DFHack Lua wrapper — that single
    -- read is what crashed AI startup ("startup failed: ...embark_pos:
    -- not found") and left the dwarves doing nothing.
    -- Also NOTE: dfhack.maps.getMapSize does NOT exist in 53.16 (it is
    -- getTileSize, and it returns x, y, z as THREE values — not a table).
    -- The original df-ai anchors the plan where the embark wagon stands:
    --   1. the wagon building (placed by the game at every new embark)
    --   2. the citizen centroid (reclaims, or the wagon already gone)
    --   3. a surface scan at the map center (last resort)
    local ok_s, mw, mh, md = pcall(function()
        return dfhack.maps.getTileSize()
    end)
    -- NOTE: 0 is truthy in Lua — at the title screen getTileSize returns
    -- 0,0,0, and those must count as "no map"
    if not ok_s or not mw or not mh or not md
        or mw <= 0 or mh <= 0 or md <= 0 then
        return nil
    end
    local world = df.global.world

    -- 1) the embark wagon
    local ok_bld, buildings = pcall(function()
        return world and world.buildings and world.buildings.all or nil
    end)
    if ok_bld and buildings then
        for _, b in ipairs(buildings) do
            local ok_w, is_wagon = pcall(function()
                return df.building_wagonst:is_instance(b)
            end)
            if ok_w and is_wagon and b then
                local ok_c, wx, wy = pcall(function()
                    return math.floor((b.x1 + b.x2) / 2), math.floor((b.y1 + b.y2) / 2)
                end)
                if ok_c and wx and wx >= 0 then
                    local wz = ground_z_at(wx, wy, b.z) or b.z
                    return { x = wx, y = wy, z = wz }
                end
            end
        end
    end

    -- 2) the citizen centroid
    local ok_u, units = pcall(function()
        return world and world.units and world.units.all or nil
    end)
    if ok_u and units then
        local sx, sy, sz, n = 0, 0, 0, 0
        for _, u in ipairs(units) do
            local ok_c, is_c = pcall(function()
                return dfhack.units.isCitizen(u, true) and dfhack.units.isAlive(u)
            end)
            if ok_c and is_c then
                -- 53.16: getPosition returns x, y, z as three values
                local ok_p, ux, uy, uz = pcall(function()
                    return dfhack.units.getPosition(u)
                end)
                if ok_p and ux and ux >= 0 and uy and uz then
                    sx, sy, sz, n = sx + ux, sy + uy, sz + uz, n + 1
                end
            end
        end
        if n > 0 then
            return {
                x = math.floor(sx / n + 0.5),
                y = math.floor(sy / n + 0.5),
                z = math.floor(sz / n + 0.5),
            }
        end
    end

    -- 3) map-center surface scan (integer coordinates: (size - 1) / 2
    -- avoids x.5 on odd maps; non-integer tile indices throw)
    local center_x = math.floor((mw - 1) / 2)
    local center_y = math.floor((mh - 1) / 2)
    local z = ground_z_at(center_x, center_y, md - 1)
    if z then
        return { x = center_x, y = center_y, z = z }
    end
    -- last resort: top of the map (a plan anchored in a tree beats no plan)
    return { x = center_x, y = center_y, z = md - 1 }
end

-- ============================================================
-- C++-parity dig pipeline (r3.7): wantdig -> want_dig -> digroom
-- (recursive over accesspath) -> dig_room -> is_dug -> construct.
--
-- The OLD code here placed rooms in a radial ring around the entrance
-- with no rock checks and BFS'd corridors afterwards — rooms ended up
-- sealed in rock and unreachable (the "no veo movimiento" fort). The
-- blueprint engine (blueprint.lua) now guarantees reachability
-- structurally: every room's accesspath chains to the entrance
-- stairwell, and digroom() below digs PARENTS FIRST.
-- ============================================================

-- Plan::wantdig — request a room to be dug (queue codes: 0 = default,
-- 1 = outdoor, -1 bedroom, -2 dining/barracks/noble, -3 farmplot,
-- -4 pasture). Adds a want_dig task; the actual dig waits for a free
-- slot (nrdig < wantdig_max) unless immediate.
function Plan:wantdig(r, queue)
    if not r or r.status ~= 'plan' then return false end
    if r.queue_dig then return false end
    if queue ~= nil then r.queue = queue end
    r.queue_dig = true
    self:add_task(TASK_TYPE.want_dig, r)
    return true
end

-- Plan::digroom — start digging NOW (status plan -> dig), then
-- recursively dig the whole accesspath chain (parents first!), the
-- linked input stockpiles, and queue furnish tasks for the layout.
function Plan:digroom(room, immediate)
    if not room then return false end
    if room.status ~= 'plan' then return false end
    room.queue_dig = false
    room.status = 'dig'
    local designated = room:dig()
    self:add_task(immediate and TASK_TYPE.dig_room_immediate
        or TASK_TYPE.dig_room, room)

    for _, ap in ipairs(room.accesspath or {}) do
        self:digroom(ap, immediate)
    end
    -- linked input stockpiles (e.g. wood pile next to the carpenter)
    for _, r2 in ipairs(self.rooms) do
        if r2.workshop_room == room then
            self:digroom(r2, immediate)
        end
    end

    if designated and designated > 0 then
        self:_log('digging ' .. describe_room(room) .. ' (queue '
            .. tostring(room.queue) .. ', ' .. designated .. ' tiles designated)')
    else
        self:_log('digging ' .. describe_room(room) .. ' (queue '
            .. tostring(room.queue) .. ', ' .. room:dig_remaining() .. ' tiles of rock)')
    end
    return true
end

-- Plan::furnish_room — queue furnish tasks for every unbuilt,
-- non-ignored furniture item of a room.
function Plan:furnish_room(r)
    if not r then return end
    for _, f in ipairs(r.layout or {}) do
        if not f.ignore and f.bld_id < 0 then
            self:add_task(TASK_TYPE.furnish, r, f)
        end
    end
end


-- ============================================================
-- Task queue processing (r3.5)
--
-- r3.4 drove both queues from dfhack.onStateChange[SC_VIEWSCREEN_CHANGED]
-- handlers — one task per viewscreen CHANGE. With the fort running at
-- rest no viewscreen ever changes, so the queues never advanced: the
-- plan placed its rooms and then sat there forever. No dig, no
-- constructions, no furnishing, no manager-driven work.
--
-- The C++ original (plan_task.cpp) processes both queues from
-- Plan::update, which the event manager calls every 1000 ticks: when a
-- queue is drained, the next update restarts it from the top, and a
-- per-frame once-callback walks one task per frame until drained
-- again. This port processes a bounded batch per Plan:update call
-- (the AI wires plan updates every 25 ticks) with the same 1000-tick
-- restart cadence.
-- ============================================================

local TICKS_PER_YEAR = 12 * 28 * 24 * 50

-- ============================================================
-- Logging (r3.6): every phase of the plan pipeline reports to the
-- console so a stuck fort is diagnosable from the log alone.
-- - one-time events log immediately
-- - recurring "waiting" reasons are throttled per task (once / 1200
--   ticks) so the log stays readable
-- ============================================================

describe_room = function(r)
    if not r then return '<nil>' end
    local t = tostring(r.type)
    if r.workshop_type ~= nil then
        local ok, name = pcall(function()
            local wt = df.workshop_type
            for v = wt._first_item or 0, wt._last_item or 999 do
                if v == r.workshop_type then return wt[v] end
            end
        end)
        if ok and name then t = t .. '/' .. name end
    elseif r.stockpile_type then
        t = t .. '/' .. tostring(r.stockpile_type)
    elseif r.corridor_type then
        t = t .. '/' .. tostring(r.corridor_type)
    end
    return t .. ' ' .. tostring(r.min.x) .. ',' .. tostring(r.min.y) .. ','
        .. tostring(r.min.z) .. ' q' .. tostring(r.queue)
end

function Plan:_log(msg)
    dfhack.println('[df-ai:plan] ' .. msg)
end

function Plan:_log_task(t, msg)
    -- throttle recurring per-task messages
    t._last_log = t._last_log or {}
    local now = self:_tick_now()
    if t._last_log[msg] and (now - t._last_log[msg]) < 1200 then
        return
    end
    t._last_log[msg] = now
    self:_log('task ' .. tostring(t.type) .. ' [' .. describe_room(t.room) .. ']: ' .. msg)
end

local function task_log_once(self, t, msg)
    if t._logged_once == nil then t._logged_once = {} end
    if t._logged_once[msg] then return end
    t._logged_once[msg] = true
    self:_log('task ' .. tostring(t.type) .. ' [' .. describe_room(t.room) .. ']: ' .. msg)
end
function Plan:_tick_now()
    local y = df.global.cur_year or 0
    local t = df.global.cur_year_tick or 0
    return y * TICKS_PER_YEAR + t
end

-- Concurrent-dig cap (C++ wantdig_max: max(stock pick count, 2)).
function Plan:_wantdig_max()
    local n = 2
    if self.ai and self.ai.stocks and self.ai.stocks.count_total then
        local picks = self.ai.stocks.count_total['pick']
        if picks and picks > n then n = picks end
    end
    return n
end

-- construct tasks retry until the building is placed; cap the retries
-- so a room that can never be built (no materials on the map, blocked
-- tile, missing raws) does not spin the queue forever
local function construct_attempt(self, t, method)
    local del = method(self, t.room)
    if del then
        if t.room then t.room._construct_fails = nil end
        return true, ''
    end
    if t.room then
        t.room._construct_fails = (t.room._construct_fails or 0) + 1
        if t.room._construct_fails > 10 then
            t.room._construct_fails = nil
            t.room.status = 'finished'
            task_log_once(self, t, 'gave up constructing after 10 failed attempts')
            return true, ''
        end
    end
    return false, 'construction not ready'
end

-- Execute ONE generic task. Returns (del, reason); del=true removes the
-- task from the queue. check_rooms is NEVER deleted: it recurs on every
-- queue restart, exactly like the C++ switch (checkrooms re-designates
-- cancelled digs and advances room status each pass).
function Plan:_run_generic_task(t)
    local del = false
    local reason = ''

    if t.type == TASK_TYPE.want_dig then
        -- r3.7: the OLD handler called digroom() whenever is_dug() was
        -- true — but checkroom may have already advanced the room to
        -- 'dug' + construct_room, and digroom RESET it to 'dig',
        -- re-running construct_room forever (the duplicate "room DUG"
        -- lines in the r3.6 log). Only start digging rooms still in
        -- 'plan'; anything else is stale.
        if not t.room or t.room.status ~= 'plan' then
            del = true
            reason = 'room already past planning'
        else
            local wantdig_max = self:_wantdig_max()
            local any_immediate = false
            for _, tt in ipairs(self.tasks_generic) do
                if tt.type == TASK_TYPE.dig_room_immediate then
                    any_immediate = true
                    break
                end
            end
            if any_immediate then
                reason = 'waiting for more important room to be dug'
            elseif t.room:is_dug() then
                self:digroom(t.room)
                del = true
            else
                local q = t.room.queue or 0
                local nrd = self.nrdig[q] or 0
                if nrd < wantdig_max then
                    self:digroom(t.room)
                    del = true
                else
                    reason = 'dig queue ' .. q .. ' full (' .. nrd .. '/' .. wantdig_max .. ')'
                end
            end
        end
    elseif t.type == TASK_TYPE.dig_room or t.type == TASK_TYPE.dig_room_immediate then
        if t.room then
            -- Dig accesspath corridors first (accesspath holds ROOM
            -- REFERENCES since r3.7 — the blueprint engine resolves the
            -- parent chain; the old raw-index lookup never found them)
            if t.room.accesspath and #t.room.accesspath > 0 then
                for _, ap_room in ipairs(t.room.accesspath) do
                    if ap_room and ap_room.status == 'plan' then
                        self:digroom(ap_room)
                    end
                end
            end

            -- C++ order: check is_dug FIRST, then (re-)designate. The
            -- old port designated first, so a freshly-designated room
            -- always looked "not dug" on the same pass.
            local dug, why = t.room:is_dug()
            if dug then
                t.room.status = 'dug'
                self:_log('room DUG: ' .. describe_room(t.room))
                self:construct_room(t.room)
                del = true
            else
                local designated, cleared = t.room:dig()
                if designated > 0 then
                    task_log_once(self, t, 'designated ' .. designated
                        .. ' tiles for digging' .. (cleared > 0
                            and (' (cleared ' .. cleared .. ' stale designations)')
                            or ''))
                end
                local remaining = t.room:dig_remaining()
                reason = why or ('still ' .. remaining .. ' tiles of rock')
                -- If nothing is designated and nothing remains but is_dug
                -- said false, something is off: log it loudly ONCE.
                if designated == 0 and remaining == 0 then
                    task_log_once(self, t, 'no diggable tiles and no walls left — '
                        .. 'waiting for miners (reason: ' .. tostring(why) .. ')')
                end
            end
        else
            del = true
        end
    elseif t.type == TASK_TYPE.construct_workshop then
        del, reason = construct_attempt(self, t, self.try_construct_workshop)
    elseif t.type == TASK_TYPE.construct_furnace then
        del, reason = construct_attempt(self, t, self.try_construct_furnace)
    elseif t.type == TASK_TYPE.construct_stockpile then
        del, reason = construct_attempt(self, t, self.try_construct_stockpile)
    elseif t.type == TASK_TYPE.construct_farmplot then
        del, reason = construct_attempt(self, t, self.try_construct_farmplot)
    elseif t.type == TASK_TYPE.construct_activityzone then
        del, reason = construct_attempt(self, t, self.try_construct_activityzone)
    elseif t.type == TASK_TYPE.construct_tradedepot then
        del, reason = construct_attempt(self, t, self.try_construct_tradedepot)
    elseif t.type == TASK_TYPE.construct_windmill then
        del, reason = construct_attempt(self, t, self.try_construct_windmill)
    elseif t.type == TASK_TYPE.check_rooms then
        self:checkrooms()
    elseif t.type == TASK_TYPE.check_construct then
        if t.room and t.room.bld_id >= 0 then
            if not df.building.find(t.room.bld_id) then
                t.room.bld_id = -1
                self:construct_room(t.room)
            end
        end
        del = true
    elseif t.type == TASK_TYPE.check_furnish then
        if t.room then
            local any_furnish = false
            local done_count = 0
            for _, f in ipairs(t.room.layout) do
                if f.ignore or f.gave_up or f.type == 'none' then
                    done_count = done_count + 1
                elseif f.bld_id < 0 then
                    -- not placed yet
                    self:add_task(TASK_TYPE.furnish, t.room, f)
                    any_furnish = true
                elseif not f._checked then
                    -- placed but the completion phase (furnish_check:
                    -- door flags, coffin burial, makeroom zones) has not
                    -- run yet — queue it through the same task type
                    self:add_task(TASK_TYPE.furnish, t.room, f)
                    any_furnish = true
                else
                    done_count = done_count + 1
                end
            end
            if any_furnish then
                self:_log('furnishing ' .. describe_room(t.room) .. ' ('
                    .. #t.room.layout .. ' furniture)')
            end
            if not any_furnish and t.room.status == 'finished'
                and done_count >= #t.room.layout then
                t.room.furnished = true
            end
        end
        del = true
    elseif t.type == TASK_TYPE.check_idle then
        -- PERSISTENT task (C++ never deletes it): drives the priority
        -- rule engine every pass. The r3.6 code deleted it on the first
        -- run, so the staged build order never executed.
        if priorities_module then
            priorities_module.checkidle(self)
        end
    elseif t.type == TASK_TYPE.monitor_cistern then
        -- PERSISTENT task (C++ plan_cistern.cpp never deletes it):
        -- coordinates the well-cistern input/output floodgates. Returns
        -- (false, reason) — the reason lands in the task status.
        local ok_m, keep, why = pcall(function()
            return self:monitor_cistern()
        end)
        if not ok_m then
            dfhack.printerr('[df-ai] cistern monitor failed: '
                .. tostring(keep))
            del = true
        else
            del = keep
            reason = why
        end
    elseif t.type == TASK_TYPE.furnish then
        if t.room and t.furniture then
            del = self:try_furnish(t.room, t.furniture)
            if not del then
                reason = 'furniture not placeable yet'
            end
        else
            del = true
        end
    else
        -- task types without a ported handler (monitor_room_value,
        -- setup_farmplot, rescue_caged, ...) must not clog the queue
        -- forever.
        del = true
    end
    return del, reason
end

function Plan:_run_furniture_task(t)
    if t.type == TASK_TYPE.furnish then
        if t.room and t.furniture then
            return self:try_furnish(t.room, t.furniture), ''
        end
    end
    return true, ''
end

-- Walk a task queue. `which` is 'generic' or 'furniture'. Processes at
-- most `budget` tasks per call; a drained queue restarts from the top
-- no more often than every 1000 ticks (the C++ Plan::update cadence).
function Plan:_process_queue(which, budget)
    local tasks = which == 'generic' and self.tasks_generic or self.tasks_furniture
    local idxfield = 'bg_idx_' .. which
    local waitfield = 'queue_wait_' .. which
    if self[idxfield] == nil or self[idxfield] < 1 then self[idxfield] = 1 end

    local n = 0
    while n < budget do
        if self[idxfield] > #tasks then
            -- drained: wait out the restart cadence, then begin a new pass
            local now = self:_tick_now()
            if self[waitfield] == nil then
                self[waitfield] = now + 1000
            end
            if now < self[waitfield] then
                return
            end
            self[waitfield] = nil
            self[idxfield] = 1
        end

        local t = tasks[self[idxfield]]
        if not t then
            self[idxfield] = self[idxfield] + 1
        else
            local runner = which == 'generic'
                and function(tt) return self:_run_generic_task(tt) end
                or function(tt) return self:_run_furniture_task(tt) end
            -- one throwing task must not kill the queue
            local ok, del, reason = pcall(runner, t)
            if not ok then
                dfhack.printerr('[df-ai] task "' .. tostring(t.type) .. '" failed: ' .. tostring(del))
                del = true -- drop the broken task, keep the queue moving
                reason = ''
            end
            t.last_status = reason or ''
            if del then
                -- next task slides into this index; do NOT advance
                table.remove(tasks, self[idxfield])
            else
                self[idxfield] = self[idxfield] + 1
            end
            n = n + 1
        end
    end
end

function Plan:process_tasks_generic(budget)
    self:_process_queue('generic', budget or 2)
end

function Plan:process_tasks_furniture(budget)
    self:_process_queue('furniture', budget or 1)
end

-- ============================================================
-- Plan setup / room placement
-- ============================================================

function Plan:initial_phase()
    local all_done = true
    local queued_rooms, queued_corridors = 0, 0
    for _, r in ipairs(self.rooms) do
        if r.status == 'plan' then
            if r.type ~= 'corridor' then
                r.status = 'dig'
                self:add_task(TASK_TYPE.want_dig, r)
                queued_rooms = queued_rooms + 1
                all_done = false
            end
        end
    end
    if all_done then
        -- Now dig corridors
        for _, r in ipairs(self.corridors) do
            if r.status == 'plan' then
                r.status = 'dig'
                self:add_task(TASK_TYPE.want_dig, r)
                queued_corridors = queued_corridors + 1
                all_done = false
            end
        end
    end
    if queued_rooms > 0 or queued_corridors > 0 then
        self:_log('initial phase: queued ' .. queued_rooms .. ' rooms and '
            .. queued_corridors .. ' corridors for digging')
    end
    if all_done then
        if not self.past_initial_phase then
            self:_log('initial phase complete — all rooms dug')
        end
        self.past_initial_phase = true
    end
end

-- (r3.7) digroom/wantdig/furnish_room live next to the placement
-- code at the top of this file — the old local copy here silently
-- OVERRODE them (Lua: last definition wins), which is why accesspath
-- recursion never ran.

-- ============================================================
-- Room checking
-- ============================================================

function Plan:checkrooms()
    -- r3.7: the priority rule engine (check_idle task) drives WHICH
    -- rooms get dug and in what order. initial_phase() is only a
    -- fallback when no rules loaded (broken plan JSON).
    if not self.past_initial_phase and #self.priority_rules == 0 then
        self:initial_phase()
    end

    -- Recompute nrdig
    self.nrdig = {}
    for _, t in ipairs(self.tasks_generic) do
        if t.type == TASK_TYPE.dig_room or t.type == TASK_TYPE.dig_room_immediate then
            if t.room then
                local q = t.room.queue or 0
                local size = t.room:size()
                if t.room.type ~= 'corridor' or size.z > 1 then
                    self.nrdig[q] = (self.nrdig[q] or 0) + 1
                end
                if t.room.type ~= 'corridor' and size.x * size.y >= 10 then
                    self.nrdig[q] = (self.nrdig[q] or 0) + 1
                end
            end
        end
    end

    local ncheck = 0
    for i = 1, #self.rooms * 4 do
        if ncheck >= 8 then break end
        if self.checkroom_idx > #self.rooms then
            self.checkroom_idx = 0
        end
        local r = self.rooms[self.checkroom_idx + 1]
        if not r then
            self.checkroom_idx = self.checkroom_idx + 1
        else
            -- build_when_accessible rooms (extra doors, releasecages)
            -- wait until their whole accesspath chain is dug (C++)
            if r.status == 'plan' and r.build_when_accessible then
                local all_ready = true
                for _, ap in ipairs(r.accesspath or {}) do
                    if ap.status == 'plan' or ap.status == 'dig' then
                        all_ready = false
                        break
                    end
                end
                if all_ready then
                    self:wantdig(r, 2)
                end
            end
            if r.status ~= 'plan' then
                self:checkroom(r)
                ncheck = ncheck + 1
            end
            self.checkroom_idx = self.checkroom_idx + 1
        end
    end
end

function Plan:checkroom(r)
    -- Redig any cancelled designations
    if r.status == 'dig' or r.status == 'designated' then
        r:dig()
    end

    if r.status == 'designated' then
        if r:is_dug() then
            r.status = 'dug'
            self:_log('room DUG: ' .. describe_room(r))
            self:construct_room(r)
        end
    elseif r.status == 'dig' then
        if r:is_dug() then
            r.status = 'dug'
            self:_log('room DUG: ' .. describe_room(r))
            self:construct_room(r)
        end
    elseif r.status == 'dug' then
        if r:constructions_done() then
            r.status = 'finished'
            self:_log('room FINISHED: ' .. describe_room(r))
        end
    end

    -- Tantrum recovery: a furniture building vanished (deconstructed,
    -- destroyed, or — the r3.6 bug — auto-removed by DF because it was
    -- created without item filters and could never be built). Re-place
    -- it, but only while the tile is actually free, and only a bounded
    -- number of times (give-up flag) so a bad spot can never loop.
    for _, f in ipairs(r.layout) do
        if f.bld_id >= 0 and not f.gave_up then
            local fb = self:_find_building(f.bld_id)
            if not fb then
                f.bld_id = -1
                f._vanish = (f._vanish or 0) + 1
                if f._vanish > 3 then
                    f.gave_up = true
                    self:_log('gave up re-placing ' .. tostring(f.type)
                        .. ' at ' .. f.pos.x .. ',' .. f.pos.y .. ',' .. f.pos.z
                        .. ' (building kept vanishing — no buildable item?)')
                else
                    self:add_task(TASK_TYPE.furnish, r, f)
                end
            end
        end
    end

    -- Room value monitoring: queue smoothing if value too low
    if r.status == 'finished' and r.required_value > 0 then
        local val = r:compute_value()
        if val < r.required_value then
            self:smooth_room(r)
        end
    end

    -- Furnish check: queue furnishing for dug rooms
    if r.status == 'dug' or r.status == 'finished' then
        if not r.furnished and #r.layout > 0 then
            self:furnish_room(r)
            r.furnished = true
        end
    end
end

function Plan:smooth_room(r)
    if not r then return end
    -- Queue smoothing jobs for all diggable tiles in the room
    for x = r.min.x, r.max.x do
        for y = r.min.y, r.max.y do
            for z = r.min.z, r.max.z do
                local block = dfhack.maps.getTileBlock(x, y, z)
                if block then
                    local tile = block.tiletype[x % 16][y % 16]
                    local attrs = df.tiletype.attrs[tile]
                    if attrs and attrs.shape == df.tiletype_shape.WALL then
                        -- Queue smooth designation
                        local des = block.designation[x % 16][y % 16]
                        if des then
                            des.smooth = true
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================
-- Construction
-- ============================================================

function Plan:construct_room(r)
    self:_log('constructing ' .. describe_room(r))
    if r.type == 'workshop' then
        self:add_task(TASK_TYPE.construct_workshop, r)
    elseif r.type == 'furnace' then
        self:add_task(TASK_TYPE.construct_furnace, r)
    elseif r.type == 'stockpile' then
        self:add_task(TASK_TYPE.construct_stockpile, r)
    elseif r.type == 'farmplot' then
        self:add_task(TASK_TYPE.construct_farmplot, r)
    elseif r.type == 'tradedepot' then
        self:add_task(TASK_TYPE.construct_tradedepot, r)
    elseif r.type == 'windmill' then
        self:add_task(TASK_TYPE.construct_windmill, r)
    elseif r.type == 'corridor' then
        -- corridors have no building; furnishing was queued by digroom
    else
        self:add_task(TASK_TYPE.check_furnish, r)
    end
    -- Verify construction after placement
    self:add_task(TASK_TYPE.check_construct, r)
    -- Queue furnishing (dedup happens in add_task; placed items are
    -- skipped by furnish_room — the r3.6 code re-queued EVERY item on
    -- every construct_room call: 120 cage traps for 60 template slots)
    self:furnish_room(r)
end

local BUILDING_TYPES = {
    workshop = {
        type_name = 'workshop',
        types = {
            Butchers = df.workshop_type.Butchers,
            Quern = df.workshop_type.Quern,
            Farmers = df.workshop_type.Farmers,
            Kitchen = df.workshop_type.Kitchen,
            Still = df.workshop_type.Still,
            Loom = df.workshop_type.Loom,
            Clothiers = df.workshop_type.Clothiers,
            Leatherworks = df.workshop_type.Leatherworks,
            Craftsdwarf = df.workshop_type.Craftsdwarfs,
            Masons = df.workshop_type.Masons,
            Carpenters = df.workshop_type.Carpenters,
            Bowyers = df.workshop_type.Bowyers,
            Jewelers = df.workshop_type.Jewelers,
            Tanners = df.workshop_type.Tanners,
            Dyers = df.workshop_type.Dyers,
            Mechanics = df.workshop_type.Mechanics,
            Siege = df.workshop_type.Siege,
            Ashery = df.workshop_type.Ashery,
            Millstone = df.workshop_type.Millstone,
            MagmaForge = df.workshop_type.MagmaForge,
        },
    },
    furnace = {
        type_name = 'furnace',
        types = {
            Smelter = df.furnace_type.Smelter,
            WoodFurnace = df.furnace_type.WoodFurnace,
            Kiln = df.furnace_type.Kiln,
            MagmaSmelter = df.furnace_type.MagmaSmelter,
            MagmaKiln = df.furnace_type.MagmaKiln,
            GlassFurnace = df.furnace_type.GlassFurnace,
            MagmaGlassFurnace = df.furnace_type.MagmaGlassFurnace,
        },
    },
}

local WORKSHOP_TYPES_BY_SIZE = {
    ['generic01_workshop_1x1'] = {
        df.workshop_type.Butchers,
        df.workshop_type.Quern,
        df.workshop_type.Tanners,
        df.workshop_type.Bowyers,
    },
    ['generic01_workshop_3x3'] = {
        df.workshop_type.Farmers,
        df.workshop_type.Kitchen,
        df.workshop_type.Still,
        df.workshop_type.Loom,
        df.workshop_type.Clothiers,
        df.workshop_type.Leatherworks,
        df.workshop_type.Craftsdwarfs,
        df.workshop_type.Masons,
        df.workshop_type.Carpenters,
        df.workshop_type.Jewelers,
        df.workshop_type.Dyers,
        df.workshop_type.Mechanics,
    },
    ['generic01_workshop_5x5'] = {
        df.workshop_type.Siege,
    },
    -- Screw press is a raw-defined CUSTOM workshop in v50+
    -- (built via workshop_type.Custom + raws index, handled in
    -- try_construct_workshop). No static enum entry exists.
}

local FURNACE_TYPES_LIST = {
    df.furnace_type.Smelter,
    df.furnace_type.WoodFurnace,
    df.furnace_type.Kiln,
    df.furnace_type.GlassFurnace,
    df.furnace_type.MagmaSmelter,
    df.furnace_type.MagmaKiln,
    df.furnace_type.MagmaGlassFurnace,
}

function Plan:find_building_at(pos, building_type_name)
    for _, bld in ipairs(df.global.world.buildings.all) do
        if bld.z == pos.z and bld.centerx == pos.x and bld.centery == pos.y then
            return bld.id, bld
        end
    end
    return -1, nil
end

-- ============================================================
-- Building construction (53.16: dfhack.buildings.constructBuilding)
-- ============================================================

-- Generic building constructor. `r` is a room object providing min/max
-- extents; falls back to canonical building size when they are equal.
-- `abstract` marks material-less buildings (stockpiles, farm plots) —
-- constructBuilding REQUIRES one of items/filters/abstract in 53.16.
-- `items` is an optional list of df.item (constructWithItems — the
-- C++ material-selection path: workshops get blocks→boulder→wood,
-- furnaces fire-safe boulders, forges anvil+fire-safe boulder).
local function construct_at(r, btype, subtype, custom, fields, width, height, abstract, items)
    local pos = { x = r.min.x, y = r.min.y, z = r.min.z }
    local w = width or ((r.max.x - r.min.x) + 1)
    local h = height or ((r.max.y - r.min.y) + 1)
    local spec = {
        type = btype,
        subtype = subtype or -1,
        custom = custom or -1,
        pos = pos,
        width = w,
        height = h,
        fields = fields,
        abstract = abstract or nil,
    }
    if items and #items > 0 then
        spec.items = items
    end
    local ok, bld, err = pcall(dfhack.buildings.constructBuilding, spec)
    if not ok or not bld then
        dfhack.println('[df-ai] construct failed at ('
            .. pos.x .. ',' .. pos.y .. ',' .. pos.z .. '): ' .. tostring(err or bld))
        return nil
    end
    return bld
end

-- ============================================================
-- Construction material selection (C++ plan_construct.cpp find_item)
-- ============================================================
-- Blocks first (efficient), then NON-ECONOMIC boulders (never burn
-- flux/ore), then wood. Furnaces additionally need FIRE-SAFE material
-- (isTemperatureSafe(1)); the forge needs a fire-safe ANVIL too.

-- items.other category ids (built lazily — the pure-Lua test mocks
-- have no items_other_id enum)
local ITEMS_OTHER
local function other_id(name)
    if not ITEMS_OTHER then
        ITEMS_OTHER = {}
    end
    local v = ITEMS_OTHER[name]
    if v == nil then
        local ok, id = pcall(function() return df.items_other_id[name] end)
        v = (ok and id) or false
        ITEMS_OTHER[name] = v
    end
    return v or nil
end

-- is this item usable as a building material right now? (mirrors the
-- C++ Stocks::is_item_free: not in a job, not forbidden, on the map)
local function item_free_for_build(item)
    local ok, res = pcall(function()
        if not dfhack.items.isOnMap(item) then return false end
        if dfhack.items.getGeneralRef(item, df.general_ref_type.BUILDING_HOLDER) then
            return false
        end
        -- items hauled by an active job are reserved
        for _, ref in ipairs(item.general_refs) do
            local rt = ref:getType()
            if rt == df.general_ref_type.IS_ARTIFACT then -- ignore
            elseif rt == df.general_ref_type.UNIT_HOLDER then return false end
        end
        local job = dfhack.items.getJob(item, 0, false)
        if job then return false end
        return true
    end)
    return ok and res or false
end

-- one fire-safe check per item (vmethod: 1 = fire, 2 = magma)
local function item_temperature_safe(item)
    local ok, res = pcall(function() return item:isTemperatureSafe(1) end)
    return ok and res or false
end

-- economic-stone gate: boulders of economic stone (flux/ore) are never
-- spent on walls (C++ checks ui->economic_stone[mat_index])
local function boulder_is_economic(item)
    local ok, res = pcall(function()
        if item.mat_type ~= 0 then return false end
        local eco = df.global.plotinfo.economic_stone
        if not eco then return false end
        return eco[item.mat_index] == true
    end)
    return ok and res or false
end

-- find up to `n` free items of an items.other category with the C++
-- gates: fire_safe → isTemperatureSafe(1); non_economic → skip
-- economic boulders. Returns a list of df.item.
local function find_build_materials(category, n, fire_safe, non_economic)
    local out = {}
    local others = df.global.world.items.other
    local cid = category and other_id(category)
    local vec = cid and others and others[cid]
    if not vec then return out end
    for _, item in ipairs(vec) do
        if #out >= n then break end
        if item_free_for_build(item)
            and (not fire_safe or item_temperature_safe(item))
            and (not non_economic or not boulder_is_economic(item)) then
            table.insert(out, item)
        end
    end
    return out
end

-- count of free items in a category (for logging / skip decisions)
local function count_free_materials(category, fire_safe, non_economic)
    local n = 0
    local others = df.global.world.items.other
    local cid = category and other_id(category)
    local vec = cid and others and others[cid]
    if not vec then return 0 end
    for _, item in ipairs(vec) do
        if item_free_for_build(item)
            and (not fire_safe or item_temperature_safe(item))
            and (not non_economic or not boulder_is_economic(item)) then
            n = n + 1
        end
    end
    return n
end

-- Find a custom workshop def (e.g. SCREW_PRESS) in the raws; returns index or -1
local function custom_workshop_index(code)
    local raws = df.global.world.raws
    if not raws or not raws.buildings then return -1 end
    -- raws.buildings.all is a DFHack vector: ipairs is 0-based, so i IS
    -- the raw index (the old i-1 returned the wrong custom workshop)
    for i, def in ipairs(raws.buildings.all) do
        if def.code == code then
            return i
        end
    end
    return -1
end

-- Workshop room type -> (building_type, subtype, custom)
local WORKSHOP_BUILD = {
    [df.workshop_type.Carpenters]    = { df.building_type.Workshop, df.workshop_type.Carpenters, -1 },
    [df.workshop_type.Farmers]       = { df.building_type.Workshop, df.workshop_type.Farmers, -1 },
    [df.workshop_type.Masons]        = { df.building_type.Workshop, df.workshop_type.Masons, -1 },
    [df.workshop_type.Craftsdwarfs]  = { df.building_type.Workshop, df.workshop_type.Craftsdwarfs, -1 },
    [df.workshop_type.Jewelers]      = { df.building_type.Workshop, df.workshop_type.Jewelers, -1 },
    [df.workshop_type.MetalsmithsForge] = { df.building_type.Workshop, df.workshop_type.MetalsmithsForge, -1 },
    [df.workshop_type.MagmaForge]    = { df.building_type.Workshop, df.workshop_type.MagmaForge, -1 },
    [df.workshop_type.Bowyers]       = { df.building_type.Workshop, df.workshop_type.Bowyers, -1 },
    [df.workshop_type.Mechanics]     = { df.building_type.Workshop, df.workshop_type.Mechanics, -1 },
    [df.workshop_type.Siege]         = { df.building_type.Workshop, df.workshop_type.Siege, -1, 5, 5 },
    [df.workshop_type.Butchers]      = { df.building_type.Workshop, df.workshop_type.Butchers, -1 },
    [df.workshop_type.Leatherworks]  = { df.building_type.Workshop, df.workshop_type.Leatherworks, -1 },
    [df.workshop_type.Tanners]       = { df.building_type.Workshop, df.workshop_type.Tanners, -1 },
    [df.workshop_type.Clothiers]     = { df.building_type.Workshop, df.workshop_type.Clothiers, -1 },
    [df.workshop_type.Fishery]       = { df.building_type.Workshop, df.workshop_type.Fishery, -1 },
    [df.workshop_type.Still]         = { df.building_type.Workshop, df.workshop_type.Still, -1 },
    [df.workshop_type.Loom]          = { df.building_type.Workshop, df.workshop_type.Loom, -1 },
    [df.workshop_type.Quern]         = { df.building_type.Workshop, df.workshop_type.Quern, -1, 1, 1 },
    [df.workshop_type.Kennels]       = { df.building_type.Workshop, df.workshop_type.Kennels, -1, 5, 5 },
    [df.workshop_type.Kitchen]       = { df.building_type.Workshop, df.workshop_type.Kitchen, -1 },
    [df.workshop_type.Ashery]        = { df.building_type.Workshop, df.workshop_type.Ashery, -1 },
    [df.workshop_type.Dyers]         = { df.building_type.Workshop, df.workshop_type.Dyers, -1 },
    [df.workshop_type.Millstone]     = { df.building_type.Workshop, df.workshop_type.Millstone, -1 },
    [df.workshop_type.Tool]          = { df.building_type.Workshop, df.workshop_type.Tool, -1 },
    [df.workshop_type.Custom]        = { df.building_type.Workshop, df.workshop_type.Custom, nil }, -- custom resolved by caller
}

-- C++ init_managed_workshop: cap the workshop's own job queue at 10 so
-- one shop cannot hoard every order (workshop_profile.max_general_orders)
local function init_managed_workshop(bld)
    if not bld then return end
    pcall(function() bld.profile.max_general_orders = 10 end)
end

-- C++ Plan::try_construct_workshop material matrix (plan_construct.cpp):
--   Dyers        barrel + bucket
--   Ashery       block + barrel + bucket
--   Forge        fire-safe anvil + fire-safe non-economic boulder
--   Quern        a quern tool
--   everything   blocks → non-economic boulder → wood
--   else
-- Returns the item list, or nil + a missing-parts description.
local WORKSHOP_MATERIAL_MISS = {
    rate_limit = {},
}
local function workshop_materials(wt)
    local WT = df.workshop_type
    local miss = function(what)
        local last = WORKSHOP_MATERIAL_MISS.rate_limit[what]
        local now = df.global.cur_year_tick or 0
        if not last or now - last > 6000 then
            WORKSHOP_MATERIAL_MISS.rate_limit[what] = now
            dfhack.println('[df-ai:plan] waiting for ' .. what)
        end
        return nil, what
    end

    if wt == WT.Dyers then
        local barrel = find_build_materials('BARREL', 1)
        local bucket = find_build_materials('BUCKET', 1)
        if #barrel == 1 and #bucket == 1 then
            return { barrel[1], bucket[1] }
        end
        local what = (#barrel == 0) and 'barrel' or 'bucket'
        return miss(what)
    elseif wt == WT.Ashery then
        local block = find_build_materials('BLOCKS', 1)
        local barrel = find_build_materials('BARREL', 1)
        local bucket = find_build_materials('BUCKET', 1)
        if #block == 1 and #barrel == 1 and #bucket == 1 then
            return { block[1], barrel[1], bucket[1] }
        end
        local what = (#block == 0) and 'blocks'
            or (#barrel == 0) and 'barrel' or 'bucket'
        return miss(what)
    elseif wt == WT.MetalsmithsForge then
        local anvil = find_build_materials('ANVIL', 1, true)
        local bould = find_build_materials('BOULDER', 1, true, true)
        if #anvil == 1 and #bould == 1 then
            return { anvil[1], bould[1] }
        end
        local what = (#anvil == 0) and 'anvil'
            or 'fire-safe boulder'
        return miss(what)
    elseif wt == WT.Quern then
        local quern = find_build_materials('QUERN', 1)
        if #quern == 1 then return { quern[1] } end
        return miss('quern')
    end

    -- generic: blocks → non-economic boulder → wood (C++ find_item chain)
    local blocks = find_build_materials('BLOCKS', 1)
    if #blocks == 1 then return blocks end
    local bould = find_build_materials('BOULDER', 1, false, true)
    if #bould == 1 then return bould end
    local wood = find_build_materials('WOOD', 1)
    if #wood == 1 then return wood end
    return miss('building material (blocks/boulder/wood)')
end

function Plan:try_construct_workshop(r)
    if not r then return false end
    local wt = r.workshop_type
    if not wt then return false end

    if r.bld_id and r.bld_id >= 0 and df.building.find(r.bld_id) then
        return true
    end

    local spec = WORKSHOP_BUILD[wt]
    if not spec then
        dfhack.println('[df-ai] unknown workshop type: ' .. tostring(wt))
        return false
    end
    local custom = spec[3]
    if custom == nil then
        -- Custom workshop: resolve raws index (e.g. SCREW_PRESS for screwpress rooms)
        local code = r.raw_type or r.custom_workshop_code or 'SCREW_PRESS'
        custom = custom_workshop_index(code)
        if custom < 0 then
            dfhack.println('[df-ai] custom workshop not in raws: ' .. code)
            return false
        end
    end

    -- r3.8: C++ material selection (never burns economic stone, fire-safe
    -- anvil for the forge, blocks before boulders before wood). Falls back
    -- to the auto-filters when the specific items are not available yet —
    -- the stocks Watch keeps ordering more in the background.
    local items, missing = workshop_materials(wt)
    if not items then
        return false, missing
    end

    local bld = construct_at(r, spec[1], spec[2], custom, nil, spec[4], spec[5], nil, items)
    if bld then
        r.bld_id = bld.id
        init_managed_workshop(bld)
        return true
    end
    return false
end

function Plan:try_construct_furnace(r)
    if not r then return false end
    local ft = r.furnace_type
    if not ft then return false end

    if r.bld_id and r.bld_id >= 0 and df.building.find(r.bld_id) then
        return true
    end

    -- C++: every standard furnace needs FIRE-SAFE NON-ECONOMIC boulders
    -- (smelter/forge line); wood furnaces are the cheapest fire-safe build.
    local FT = df.furnace_type
    local bould = find_build_materials('BOULDER', 1, true, true)
    if #bould == 0 then
        local last = WORKSHOP_MATERIAL_MISS.rate_limit['fire-safe boulder']
        local now = df.global.cur_year_tick or 0
        if not last or now - last > 6000 then
            WORKSHOP_MATERIAL_MISS.rate_limit['fire-safe boulder'] = now
            dfhack.println('[df-ai:plan] waiting for fire-safe boulder')
        end
        return false, 'fire-safe boulder'
    end

    local bld = construct_at(r, df.building_type.Furnace, ft, -1, nil, nil, nil, nil, bould)
    if bld then
        r.bld_id = bld.id
        init_managed_workshop(bld)
        return true
    end
    return false
end

function Plan:try_construct_stockpile(r)
    if not r then return false end

    if r.bld_id and r.bld_id >= 0 and df.building.find(r.bld_id) then
        return true
    end

    local width = (r.max.x - r.min.x) + 1
    local height = (r.max.y - r.min.y) + 1
    -- Stockpiles are ABSTRACT buildings (no construction materials):
    -- constructBuilding without `abstract` looks for item filters and
    -- fails with "one of items, filters or abstract is required"
    -- (live-verified in the object testing arena, r3.6).
    local bld = construct_at(r, df.building_type.Stockpile, -1, -1, nil, width, height, true)
    if bld then
        r.bld_id = bld.id
        self:configure_stockpile(bld, r.stockpile_type)
        self:_log('stockpile built at ' .. tostring(r.min.x) .. ','
            .. tostring(r.min.y) .. ',' .. tostring(r.min.z)
            .. ' (bld ' .. bld.id .. ')')
        return true
    end
    return false
end

function Plan:configure_stockpile(bld, stype)
    if not bld or not stype then return end
    -- r3.7: stockpile CONTENTS. The C++ drove the stockpile settings
    -- UI with synthetic keys; in 53.16 we write bld.settings directly:
    -- turn OFF every group, then turn ON exactly the wanted group.
    local GROUP = {
        animals = 'animals', food = 'food', furniture = 'furniture',
        corpses = 'corpses', refuse = 'refuse', stone = 'stone',
        wood = 'wood', cloth = 'cloth', gems = 'gems',
        leather = 'leather', ammo = 'ammo', coins = 'coins',
        bars_blocks = 'bars', weapons = 'weapons', armor = 'armor',
        sheets = 'sheets',
        -- finished goods are grouped under furniture in 53.16's
        -- stockpile_group_set; fresh raw hides are a refuse sub-group
        finished_goods = 'furniture',
        fresh_raw_hide = 'refuse',
    }
    local want = GROUP[stype]
    local ok = pcall(function()
        local flags = bld.settings.flags
        for name in pairs(flags) do
            if type(flags[name]) == 'boolean' then
                flags[name] = false
            end
        end
        if want then flags[want] = true end
    end)
    if not ok then
        -- older/newer field layout: keep the default (all allowed)
        pcall(function() bld.name = tostring(stype) end)
    else
        pcall(function() bld.name = tostring(stype) end)
    end
end

function Plan:try_construct_farmplot(r)
    if not r then return false end

    if r.bld_id and r.bld_id >= 0 and df.building.find(r.bld_id) then
        return true
    end

    local width = (r.max.x - r.min.x) + 1
    local height = (r.max.y - r.min.y) + 1
    -- farm plots are abstract too (no materials, live-verified r3.6)
    local bld = construct_at(r, df.building_type.FarmPlot, -1, -1, nil, width, height, true)
    if bld then
        r.bld_id = bld.id
        self:_log('farm plot built at ' .. tostring(r.min.x) .. ','
            .. tostring(r.min.y) .. ',' .. tostring(r.min.z)
            .. ' (bld ' .. bld.id .. ')')
        -- v50 farmplots plant via plant_id[season]; stocks module fills the crop
        return true
    end
    return false
end

function Plan:try_construct_activityzone(r)
    if not r then return false end
    local pos = r:pos()

    local bld_id = r.bld_id
    if bld_id and bld_id >= 0 and df.building.find(bld_id) then
        return true
    end

    -- v50+: activity zones are civzone buildings; civzone type is the subtype.
    local zone_types = {
        pasture = df.civzone_type.Pen,
        pond = df.civzone_type.Pond,
        gathering = df.civzone_type.PlantGathering,
        fishing = df.civzone_type.FishingArea,
        meeting = df.civzone_type.MeetingHall,
        watersource = df.civzone_type.WaterSource,
        training = df.civzone_type.AnimalTraining,
    }
    local subtype = zone_types[r.type] or df.civzone_type.MeetingHall

    local width = (r.max.x - r.min.x) + 1
    local height = (r.max.y - r.min.y) + 1
    local bld, err = dfhack.buildings.constructBuilding{
        type = df.building_type.Civzone,
        subtype = subtype,
        abstract = true,
        pos = { x = r.min.x, y = r.min.y, z = pos.z },
        width = width,
        height = height,
        fields = {
            assigned_unit_id = -1,
            room = { x = r.min.x, y = r.min.y, width = width, height = height },
        },
    }
    if not bld then
        dfhack.println('[df-ai] failed to create zone ' .. r.type .. ': ' .. tostring(err))
        return false
    end

    r.bld_id = bld.id
    return true
end

function Plan:try_construct_tradedepot(r)
    if not r then return false end

    if r.bld_id and r.bld_id >= 0 and df.building.find(r.bld_id) then
        return true
    end

    -- C++: the depot is built from exactly 3 blocks (constructWithItems)
    local blocks = find_build_materials('BLOCKS', 3)
    if #blocks < 3 then
        local last = WORKSHOP_MATERIAL_MISS.rate_limit['depot blocks']
        local now = df.global.cur_year_tick or 0
        if not last or now - last > 6000 then
            WORKSHOP_MATERIAL_MISS.rate_limit['depot blocks'] = now
            dfhack.println('[df-ai:plan] waiting for depot blocks ('
                .. #blocks .. '/3)')
        end
        return false, 'depot blocks'
    end

    local bld = construct_at(r, df.building_type.TradeDepot, -1, -1, nil,
        nil, nil, nil, blocks)
    if bld then
        r.bld_id = bld.id
        return true
    end
    return false
end

function Plan:try_construct_windmill(r)
    if not r then return false end

    if r.bld_id and r.bld_id >= 0 and df.building.find(r.bld_id) then
        return true
    end

    local bld = construct_at(r, df.building_type.Windmill)
    if bld then
        r.bld_id = bld.id
        return true
    end
    return false
end

-- ============================================================
-- Furniture placement helpers
-- ============================================================

-- Safe building lookup by id: df.building.find is a binary search over
-- world.buildings.all (sorted by id) — correct while no buildings are
-- removed, but the wagon deconstructs and canceled constructions get
-- culled early in fort life. Scan-compare never lies.
function Plan:_find_building(id)
    if id == nil or id < 0 then return nil end
    local ok, bld = pcall(df.building.find, id)
    if ok and bld and bld.id == id then return bld end
    local ok2, all = pcall(function() return df.global.world.buildings.all end)
    if ok2 and all then
        for _, b in ipairs(all) do
            if b.id == id then return b end
        end
    end
    return nil
end

-- job_item filter per furniture type. The r3.6 bug: buildings were
-- created with NO items and NO filters, so DF created them, found the
-- construction job unfulfillable, deleted the building, and checkroom
-- "recovered" it — the 120-cage-trap loop. With a filter the job is
-- real and dwarves fetch the item themselves.
-- Built lazily: enum names are probed once (53.16-safe, no throws).
local FURNITURE_FILTERS

local function tool_use_filter(use_name)
    local ok, v = pcall(function() return df.tool_use[use_name] end)
    if not ok or v == nil then return nil end
    return { item_type = df.item_type.TOOL, has_tool_use = v }
end

local function item_type_filter(tname)
    local ok, v = pcall(function() return df.item_type[tname] end)
    if not ok or v == nil then return nil end
    return { item_type = v }
end

local function furniture_filters()
    if FURNITURE_FILTERS ~= nil then return FURNITURE_FILTERS end
    local IT = df.item_type
    local f = {}
    local function add(name, filter)
        if filter then f[name] = filter end
    end
    add('bed', { item_type = IT.BED })
    add('chair', { item_type = IT.CHAIR })
    add('table', { item_type = IT.TABLE })
    add('door', { item_type = IT.DOOR })
    add('cabinet', { item_type = IT.CABINET })
    add('chest', { item_type = IT.BOX })
    add('coffin', { item_type = IT.COFFIN })
    add('statue', { item_type = IT.STATUE })
    add('weapon_rack', { item_type = IT.WEAPONRACK })
    add('armor_stand', { item_type = IT.ARMORSTAND })
    add('cage', { item_type = IT.CAGE })
    add('restraint', { item_type = IT.CHAIN })
    add('quern', { item_type = IT.QUERN })
    add('millstone', { item_type = IT.MILLSTONE })
    add('traction_bench', { item_type = IT.TRACTION_BENCH })
    add('splint', { item_type = IT.SPLINT })
    add('crutch', { item_type = IT.CRUTCH })
    add('floodgate', { item_type = IT.FLOODGATE })
    add('hatch', { item_type = IT.HATCH_COVER })
    -- TRAPPARTS = mechanisms (the confusingly-named "trap parts" item
    -- type — NOT weapon-trap components, which are TRAPCOMP)
    add('cage_trap', item_type_filter('TRAPPARTS'))
    add('lever', item_type_filter('TRAPPARTS'))
    add('gear_assembly', item_type_filter('TRAPPARTS'))
    add('track_stop', item_type_filter('TRAPPARTS'))
    add('pressure_plate', item_type_filter('TRAPPARTS'))
    add('nest_box', tool_use_filter('NEST_BOX'))
    add('hive', tool_use_filter('HIVE'))
    add('offering_place', tool_use_filter('PLACE_OFFERING'))
    add('pedestal', tool_use_filter('DISPLAY_OBJECT'))
    add('bookcase', tool_use_filter('BOOKCASE'))
    add('instrument', item_type_filter('INSTRUMENT'))
    FURNITURE_FILTERS = f
    return f
end

function Plan:try_furnish(r, f)
    if not r or not f then return false end
    -- 'none' furniture are layout placeholders from the templates, not
    -- real buildings — complete silently (they were spamming the log:
    -- "furniture has no building mapping: none", live-verified r3.6)
    if f.type == 'none' then return true end

    -- already placed (and the building still exists) → run the C++
    -- furnish_check completion phase once, then done
    if f.bld_id and f.bld_id >= 0 then
        local fb = self:_find_building(f.bld_id)
        if fb then
            if not f._checked then
                local ok_c, done = pcall(function()
                    return self:_furnish_check(r, f, fb)
                end)
                if not ok_c then
                    dfhack.printerr('[df-ai] furnish check failed: '
                        .. tostring(done))
                    return true
                end
                if not done then return false end
                f._checked = true
            end
            return true
        end
        f.bld_id = -1
    end
    -- ignored furniture (activation gates: cage-trap rings, optional
    -- doors/statues) complete without building — priority rules flip
    -- the ignore flag later
    if f.ignore then return true end
    if f.gave_up then return true end

    local pos = f.pos
    if not pos then
        pos = r:pos()
    end

    local BT = df.building_type
    local name_map = {
        bed = { BT.Bed },
        chair = { BT.Chair },
        table = { BT.Table },
        door = { BT.Door },
        cabinet = { BT.Cabinet },
        chest = { BT.Box },
        coffin = { BT.Coffin },
        statue = { BT.Statue },
        weapon_rack = { BT.Weaponrack },
        armor_stand = { BT.Armorstand },
        cage = { BT.Cage },
        cage_trap = { BT.Trap, df.trap_type.CageTrap },
        nest_box = { BT.NestBox },
        hive = { BT.Hive },
        offering_place = { BT.OfferingPlace },
        pedestal = { BT.DisplayFurniture },
        traction_bench = { BT.TractionBench },
        floodgate = { BT.Floodgate },
        hatch = { BT.Hatch },
        gear_assembly = { BT.GearAssembly },
        lever = { BT.Trap, df.trap_type.Lever },
        roller = { BT.Rollers },
        track_stop = { BT.Trap, df.trap_type.TrackStop },
        vertical_axle = { BT.AxleVertical },
        horizontal_axle = { BT.AxleHorizontal },
        water_wheel = { BT.WaterWheel },
        screw_pump = { BT.ScrewPump },
        archery_target = { BT.ArcheryTarget },
        restraint = { BT.Chain },
        bookcase = { BT.Bookcase },
        well = { BT.Well },
        slab = { BT.Slab },
        window = { BT.WindowGlass },
    }

    local spec = name_map[f.type]
    if not spec then
        task_log_once(self, { room = r, type = 'furnish' },
            'furniture has no building mapping: ' .. tostring(f.type))
        f.gave_up = true
        return true
    end

    -- never furnish into solid rock (C++: "waiting for wall to be
    -- excavated")
    local block = dfhack.maps.getTileBlock(pos.x, pos.y, pos.z)
    if block then
        local lx, ly = pos.x % 16, pos.y % 16
        local ok_t, tt = pcall(function() return block.tiletype[lx][ly] end)
        local shape = nil
        if ok_t and tt ~= nil then
            pcall(function() shape = df.tiletype.attrs[tt].shape end)
        end
        if shape ~= nil and (shape == df.tiletype_shape.WALL
            or shape == df.tiletype_shape.TREE) then
            f._wait_reason = 'waiting for excavation'
            return false
        end
        -- tile already has a building (ours tracked above): a foreign
        -- building means this spot is permanently taken
        local ok_o, occ = pcall(function() return block.occupancy[lx][ly] end)
        if ok_o and occ and occ.building and occ.building ~= 0 then
            f._attempts = (f._attempts or 0) + 1
            if f._attempts > 3 then
                f.gave_up = true
                task_log_once(self, { room = r, type = 'furnish' },
                    'tile occupied by another building: ' .. tostring(f.type)
                    .. ' at ' .. pos.x .. ',' .. pos.y .. ',' .. pos.z)
                return true
            end
            f._wait_reason = 'tile occupied'
            return false
        end
    end

    -- the filter: without one DF deletes the building almost
    -- immediately (unfulfillable job) — THE r3.6 trap-loop cause
    local filters = furniture_filters()[f.type]
    if filters == nil and f.type ~= 'well' and f.type ~= 'window'
        and f.type ~= 'roller' and f.type ~= 'vertical_axle'
        and f.type ~= 'horizontal_axle' and f.type ~= 'water_wheel'
        and f.type ~= 'screw_pump' and f.type ~= 'archery_target' then
        -- no filter mapping and the type needs materials: skip for now
        -- (retry-capped) instead of creating a doomed building
        f._attempts = (f._attempts or 0) + 1
        if f._attempts > 6 then
            f.gave_up = true
            task_log_once(self, { room = r, type = 'furnish' },
                'no item filter known for ' .. tostring(f.type) .. ' — skipped')
            return true
        end
        f._wait_reason = 'no item filter for ' .. tostring(f.type)
        return false
    end

    local spec_table = {
        type = spec[1],
        subtype = spec[2] or -1,
        custom = -1,
        pos = { x = pos.x, y = pos.y, z = pos.z },
    }
    if filters then spec_table.filters = { filters } end

    local ok, bld = pcall(dfhack.buildings.constructBuilding, spec_table)
    if ok and bld then
        f.bld_id = bld.id
        f._wait_reason = nil
        self:_log('placed ' .. tostring(f.type) .. ' at '
            .. pos.x .. ',' .. pos.y .. ',' .. pos.z
            .. ' (bld ' .. bld.id .. ')')
        return true
    end
    f.bld_id = -1
    f._attempts = (f._attempts or 0) + 1
    if f._attempts > 6 then
        f.gave_up = true
        task_log_once(self, { room = r, type = 'furnish' },
            'placement kept failing: ' .. tostring(f.type) .. ' at '
            .. pos.x .. ',' .. pos.y .. ',' .. pos.z .. ': ' .. tostring(bld))
        return true
    end
    f._wait_reason = 'construct failed: ' .. tostring(bld)
    return false
end

-- C++ Plan::furnish_check — the completion phase after a furniture
-- building exists: wait for construction, then apply the type-specific
-- configuration (door flags, hatch behavior, jail justice, archery
-- target) and finally makeroom (v50: create the room's civzone).
-- Returns true when this furniture is fully DONE.
function Plan:_furnish_check(r, f, bld)
    -- destroyed building? try_furnish's caller resets bld_id
    if not bld then return true end

    -- wait for the construction job to finish
    local ok_s, stage, max = pcall(function()
        return bld:getBuildStage(), bld:getMaxBuildStage()
    end)
    if ok_s and stage and max and stage < max then
        f._wait_reason = 'waiting for construction (' .. tostring(stage)
            .. '/' .. tostring(max) .. ')'
        return false
    end

    -- type-specific post-construct configuration (C++ furnish_check)
    if f.type == 'archery_target' then
        f.makeroom = true
    elseif f.type == 'door' then
        if df.building_doorst:is_instance(bld) then
            pcall(function()
                bld.door_flags.pet_passable = true
                bld.door_flags.internal = f.internal == true
            end)
        end
    elseif f.type == 'hatch' then
        if df.building_hatchst:is_instance(bld) then
            pcall(function()
                if r.type == 'pitcage' then
                    bld.door_flags.forbidden = true
                    bld.door_flags.pet_passable = false
                else
                    bld.door_flags.pet_passable = true
                end
                bld.door_flags.internal = f.internal == true
            end)
        end
    end

    -- jail cages/restraints: justice buildings (C++ sets a 1x1 room +
    -- justice flag; v50 keeps the flag on the building)
    if r.type == 'jail' and (f.type == 'cage' or f.type == 'restraint') then
        pcall(function() bld.flags.justice = true end)
    end

    -- r3.8 C++ furnish_check: coffins allow burial, no pets (the
    -- cemetery zone flags handle the rest; without allow_burial DF
    -- never buries anyone in them)
    if f.type == 'coffin' and df.building_coffinst:is_instance(bld) then
        pcall(function()
            bld.burial_mode.allow_burial = true
            bld.burial_mode.no_citizens = false
            bld.burial_mode.no_pets = true
        end)
    end

    -- r3.8 C++ setup_lever: once the lever is BUILT, link it to its
    -- target (floodgate), pull it once (neutral state), and start the
    -- cistern monitor for input levers.
    if f.type == 'lever' and f.target then
        local ok_l, done = pcall(function()
            return self:setup_lever(r, f)
        end)
        if not ok_l then
            dfhack.printerr('[df-ai] lever setup failed: ' .. tostring(done))
            return true
        end
        if not done then
            f._wait_reason = 'lever link pending'
            return false
        end
        return true
    end

    -- makeroom (v50: zone the room once dug)
    if f.makeroom and r.status ~= 'plan' then
        local reason
        if not r:is_dug(reason) then
            f._wait_reason = 'waiting to make room'
            return false
        end
        -- rooms with no v50 civzone equivalent (infirmary → location,
        -- not zone) are done once dug — do not block on a zone that
        -- will never exist
        if room_zone_subtype(r.type) then
            local zb = self:_ensure_room_zone(r)
            if not zb then
                f._wait_reason = 'zone creation pending'
                return false
            end
            -- barracks zones get their squad flags when a squad claims the
            -- room (getsoldierbarrack); bedroom zones get owners via
            -- set_owner. Dining halls are communal — the zone alone is it.
        end
    end

    return true
end

-- ============================================================
-- Levers & cisterns (plan_cistern.cpp port, r3.8)
--
-- The well template places two levers: `internal` = the INPUT gate
-- (river → reserve), non-internal = the OUTPUT gate (reserve → the
-- cistern under the well). setup_lever links each lever to its
-- floodgate with a real LinkBuildingToTrigger job (2 mechanisms);
-- monitor_cistern then coordinates the gates so the cistern fills
-- without flooding the fort. The C++ channel_enable/test-gate block
-- (0.47 river aqueducts) has no template data in generic01 and is
-- intentionally not ported.
-- ============================================================

-- C++ Plan::pull_lever: queue a PullLever job on the lever building
-- (same shape as DFHack's own lever.lua leverPullJob).
function Plan:pull_lever(f)
    local bld = self:_find_building(f.bld_id or -1)
    if not bld then return false, 'lever missing' end
    for _, job in ipairs(bld.jobs or {}) do
        if job.job_type == df.job_type.PullLever then
            return true, 'waiting for someone to pull the lever'
        end
    end
    if #(bld.jobs or {}) >= 10 then
        return false, 'lever job list is full'
    end
    local ok, err = pcall(function()
        local ref = df.general_ref_building_holderst:new()
        ref.building_id = bld.id
        local job = df.job:new()
        job.job_type = df.job_type.PullLever
        job.pos = { x = bld.x1, y = bld.y1, z = bld.z }
        job.general_refs:insert('#', ref)
        bld.jobs:insert('#', job)
        dfhack.job.linkIntoWorld(job, true)
        dfhack.job.checkBuildingsNow()
    end)
    if not ok then
        dfhack.printerr('[df-ai] pull lever failed: ' .. tostring(err))
        return false, 'pull lever failed'
    end
    return true, 'waiting for someone to pull the lever'
end

-- C++ Plan::link_lever: queue a LinkBuildingToTrigger job wiring the
-- lever building to its target floodgate. Idempotent: returns true
-- once linked (or a link job is pending returns false-wait).
function Plan:link_lever(src, dst)
    local bld = self:_find_building(src.bld_id or -1)
    if not bld then return false, 'lever not constructed' end
    local ok_s, stage, max = pcall(function()
        return bld:getBuildStage(), bld:getMaxBuildStage()
    end)
    if not ok_s or not stage or not max or stage < max then
        return false, 'lever not constructed'
    end

    local tbld = self:_find_building(dst.bld_id or -1)
    if not tbld then return false, 'lever target not constructed' end
    local ok_t, tstage, tmax = pcall(function()
        return tbld:getBuildStage(), tbld:getMaxBuildStage()
    end)
    if not ok_t or not tstage or not tmax or tstage < tmax then
        return false, 'lever target not constructed'
    end

    -- already linked? (mechanisms inside the lever reference the target)
    local already = false
    pcall(function()
        for _, ci in ipairs(bld.contained_items or {}) do
            for _, ref in ipairs(ci.item.general_refs or {}) do
                if ref:getType() == df.general_ref_type.BUILDING_TRIGGERTARGET
                    and ref.building_id == tbld.id then
                    already = true
                end
            end
        end
    end)
    if already then return true, 'linked' end

    -- link job already queued for this target?
    for _, job in ipairs(bld.jobs or {}) do
        if job.job_type == df.job_type.LinkBuildingToTrigger then
            for _, ref in ipairs(job.general_refs or {}) do
                if ref:getType() == df.general_ref_type.BUILDING_TRIGGERTARGET
                    and ref.building_id == tbld.id then
                    return false, 'waiting for lever to be linked to target'
                end
            end
        end
    end

    if #(bld.jobs or {}) >= 10 then
        return false, 'lever job list is full'
    end

    local mechas = find_build_materials('TRAPPARTS', 2)
    if #mechas < 2 then
        return false, 'need 2 mechanisms'
    end

    local ok, err = pcall(function()
        local reflink = df.general_ref_building_triggertargetst:new()
        reflink.building_id = tbld.id
        local refhold = df.general_ref_building_holderst:new()
        refhold.building_id = bld.id

        local job = df.job:new()
        job.job_type = df.job_type.LinkBuildingToTrigger
        job.general_refs:insert('#', reflink)
        job.general_refs:insert('#', refhold)
        bld.jobs:insert('#', job)
        dfhack.job.linkIntoWorld(job, true)

        -- role constants live in job_role_type in 53.16 (live-verified:
        -- df.job_item_ref has no LinkToTrigger/LinkToTarget members)
        dfhack.job.attachJobItem(job, mechas[1],
            df.job_role_type.LinkToTarget, -1, 0)
        dfhack.job.attachJobItem(job, mechas[2],
            df.job_role_type.LinkToTrigger, -1, 0)
    end)
    if not ok then
        dfhack.printerr('[df-ai] lever link failed: ' .. tostring(err))
        return false, 'lever link failed'
    end
    return false, 'waiting for lever to be linked to target'
end

-- C++ Plan::setup_lever — called from furnish_check when a lever with
-- a target finishes construction.
function Plan:setup_lever(r, f)
    if not f.target then return true end
    local linked = self:link_lever(f, f.target)
    if not linked then
        return false
    end
    self:pull_lever(f)
    if f.internal then
        self:add_task(TASK_TYPE.monitor_cistern)
    end
    return true
end

-- floodgate state helpers (C++ gate_flags: closed/closing/opening)
local function gate_closed(bld)
    if not bld then return true end
    local ok, res = pcall(function()
        local gf = bld.gate_flags
        local shut = gf.closed or gf.closing
        return shut and not gf.opening
    end)
    return ok and res or true
end

local function lever_linked(bld)
    if not bld then return false end
    local ok, res = pcall(function()
        return #bld.linked_mechanisms > 0
    end)
    return ok and res or false
end

local function flow_size_at(pos)
    local ok, res = pcall(function()
        local des = dfhack.maps.getTileDesignation(pos)
        return des and des.flow_size or 0
    end)
    return ok and res or 0
end

-- C++ Plan::monitor_cistern — PERSISTENT task coordinating the well
-- cistern gates. Simplified r3.8 port: the channel_enable/test-gate
-- phase (0.47 river probing) is omitted — generic01 has no data for
-- it; the fill coordination is faithful.
function Plan:monitor_cistern()
    if not self._mc then
        local cist, reserve
        for _, r in ipairs(self.rooms) do
            if r.type == 'cistern' then
                if r.cistern_type == 'well' and not cist then cist = r end
                if r.cistern_type == 'reserve' and not reserve then reserve = r end
            end
        end
        if not cist or not reserve then
            return false, 'no well cistern pair'
        end
        local lever_in, lever_out
        for _, r in ipairs(self.rooms) do
            for _, f in ipairs(r.layout or {}) do
                if f.type == 'lever' and f.target then
                    if f.internal then
                        lever_in = lever_in or f
                    else
                        lever_out = lever_out or f
                    end
                end
            end
        end
        if not lever_in or not lever_out then
            return false, 'cistern levers not found'
        end
        self._mc = {
            cistern = cist, reserve = reserve,
            lever_in = lever_in, lever_out = lever_out,
        }
        self:_log('cistern monitor started (well cistern)')
    end
    local mc = self._mc

    local l_in = self:_find_building(mc.lever_in.bld_id or -1)
    local f_in = mc.lever_in.target
        and self:_find_building(mc.lever_in.target.bld_id or -1) or nil
    local l_out = self:_find_building(mc.lever_out.bld_id or -1)
    local f_out = mc.lever_out.target
        and self:_find_building(mc.lever_out.target.bld_id or -1) or nil

    -- phase 1 (C++): input linked and open → activate the reserve's
    -- furniture (floodgates were ignore=true so workers could not be
    -- walled in before the input gate existed)
    if l_in and f_in and not f_out and lever_linked(l_in) then
        if gate_closed(f_in) then
            self:pull_lever(mc.lever_in)
            return false, 'opening input floodgate'
        end
        local changed = false
        for _, f in ipairs(mc.reserve.layout or {}) do
            if f.ignore then
                f.ignore = false
                changed = true
            end
        end
        if changed then
            self:furnish_room(mc.reserve)
        end
    end

    if not l_in or not f_in or not l_out or not f_out then
        return false, 'waiting for mechanic'
    end
    if not lever_linked(l_in) or not lever_linked(l_out) then
        return false, 'waiting for levers to be linked'
    end
    if #(l_in.jobs or {}) > 0 or #(l_out.jobs or {}) > 0 then
        return false, 'lever waiting to be pulled'
    end

    -- mechanisms are flowing again: activate the entrance cage traps
    -- (C++ defers them until the cistern levers are linked)
    if self.fort_entrance and not self._mc_entrance_done then
        local changed = false
        for _, f in ipairs(self.fort_entrance.layout or {}) do
            if f.ignore then
                f.ignore = false
                changed = true
            end
        end
        if changed then
            self:furnish_room(self.fort_entrance)
        end
        self._mc_entrance_done = true
    end

    local f_in_closed = gate_closed(f_in)
    local f_out_closed = gate_closed(f_out)

    -- water levels (C++: cistern pos z+1 = top floor; reserve pos)
    local cpos = mc.cistern:pos()
    local cistlvl = flow_size_at({ x = cpos.x, y = cpos.y, z = cpos.z + 1 })
    local rpos = mc.reserve:pos()
    local resvlvl = flow_size_at(rpos)

    if resvlvl <= 1 then
        -- reserve empty: close the output, open the input
        if not f_out_closed then
            self:pull_lever(mc.lever_out)
            return false, 'reserve empty; closing output'
        elseif f_in_closed then
            self:pull_lever(mc.lever_in)
            return false, 'reserve empty; opening input'
        end
        return false, 'reserve empty; filling'
    elseif resvlvl >= 7 then
        -- reserve full: close the input, drain into the cistern
        if not f_in_closed then
            self:pull_lever(mc.lever_in)
            return false, 'reserve full; closing input'
        end
        if cistlvl < 7 then
            if f_out_closed then
                self:pull_lever(mc.lever_out)
                return false, 'cistern filling (' .. cistlvl .. '/7); opening output'
            end
            return false, 'cistern filling (' .. cistlvl .. '/7)'
        end
        if not f_out_closed then
            self:pull_lever(mc.lever_out)
            return false, 'cistern full; closing output'
        end
        return false, 'cistern full'
    end

    -- mid-fill: ensure exactly one gate is open
    if f_in_closed and f_out_closed then
        if resvlvl >= 6 and cistlvl < 7 then
            self:pull_lever(mc.lever_out)
            return false, 'opening output'
        end
        self:pull_lever(mc.lever_in)
        return false, 'opening input'
    end
    return false, ('cistern %d/7, reserve %d/7'):format(cistlvl, resvlvl)
end

-- ============================================================
-- Room assignment (plan_assign.cpp port, v50 civzone-based rooms)
--
-- v50/53.16 has no building.is_room / bld.owner any more: "rooms" are
-- CIVZONE buildings (Bedroom / DiningHall / Office / Barracks / Tomb
-- / Dungeon zones) with assigned_unit_id + squad_room_info. The C++
-- makeroom(set_extents + is_room) translates to "create the matching
-- zone over the dug room". dfhack.buildings.setOwner(zone, unit)
-- handles owned_buildings + spouse sharing.
-- ============================================================

local ROOM_ZONE_TYPE = {
    bedroom = 'Bedroom',
    dormitory = 'Dormitory',
    dininghall = 'DiningHall',
    nobleroom = 'Office',
    office = 'Office',
    barracks = 'Barracks',
    cemetery = 'Tomb',
    tomb = 'Tomb',
    jail = 'Dungeon',
    -- infirmary intentionally absent: v50 hospitals are LOCATIONS
    -- (abstract buildings), not civzones — df.civzone_type has no
    -- Hospital member on 53.16 (live-verified). The room is still
    -- dug and furnished with beds/restraints; hospital registration
    -- belongs to the game's location system.
    meeting = 'MeetingHall',
    location = 'MeetingHall',
}

-- does this room type get a v50 civzone at all? (invalid/missing enum
-- members must NOT fall through to a wrong-zone default)
local function room_zone_subtype(rtype)
    local zt = ROOM_ZONE_TYPE[rtype]
    if not zt then return nil end
    local ok, sub = pcall(function() return df.civzone_type[zt] end)
    if not ok or not sub then return nil end
    return sub
end

-- create (or find) the civzone covering a dug room. Returns the
-- building or nil. One zone per room (tracked on the room itself).
-- Rooms whose type has no v50 civzone (infirmary, corridors, ...) get
-- no zone at all — never a wrong-zone fallback.
function Plan:_ensure_room_zone(r)
    if not r or r.status == 'plan' then return nil end
    if r.zone_id and r.zone_id >= 0 then
        local zb = df.building.find(r.zone_id)
        if zb then return zb end
        r.zone_id = -1
    end
    local subtype = room_zone_subtype(r.type)
    if not subtype then return nil, 'no zone type for ' .. tostring(r.type) end
    -- permanent give-up: a room whose zone cannot be created must not
    -- retry forever (the r3.6 trap-loop lesson, applied to zones)
    if r.zone_gave_up then return nil, 'zone creation gave up' end
    -- the room must be dug before zoning it (C++ makeroom waited for
    -- is_dug the same way)
    local reason
    if not r:is_dug(reason) then return nil end

    local pos = r:pos()
    local width = (r.max.x - r.min.x) + 1
    local height = (r.max.y - r.min.y) + 1
    -- quickfort's zone.lua pattern: a civzone needs room.extents to
    -- cover tiles, plus assigned_unit_id (live-verified DFHack API)
    local bld, err
    local ok_c = pcall(function()
        local area = width * height
        local extents = df.reinterpret_cast(df.building_extents_type,
            df.new('uint8_t', area))
        for i = 0, area - 1 do extents[i] = 1 end
        bld, err = dfhack.buildings.constructBuilding{
            type = df.building_type.Civzone,
            subtype = subtype,
            abstract = true,
            pos = { x = r.min.x, y = r.min.y, z = pos.z },
            width = width,
            height = height,
            fields = {
                assigned_unit_id = -1,
                room = { x = r.min.x, y = r.min.y, width = width,
                    height = height, extents = extents },
            },
        }
    end)
    if not ok_c then err = err or 'constructBuilding threw' end
    if not bld then
        r.zone_fail = (r.zone_fail or 0) + 1
        if r.zone_fail <= 3 or r.zone_fail % 20 == 0 then
            dfhack.println('[df-ai] zone creation failed for ' .. r.type
                .. ': ' .. tostring(err))
        end
        if r.zone_fail >= 10 then
            r.zone_gave_up = true
            self:_log('giving up zoning ' .. r.type .. ' room at '
                .. r.min.x .. ',' .. r.min.y .. ',' .. pos.z)
        end
        return nil, tostring(err)
    end
    r.zone_id = bld.id
    -- tomb zones: citizens allowed, pets not (C++ coffin burial_mode)
    if df.building_civzonest:is_instance(bld) and subtype == df.civzone_type.Tomb then
        pcall(function()
            bld.type_data.flags.no_pets = true
            bld.type_data.flags.no_citizens = false
        end)
    end
    self:_log('zoned ' .. r.type .. ' room at ' .. r.min.x .. ',' .. r.min.y
        .. ',' .. pos.z .. ' (bld ' .. bld.id .. ')')
    return bld
end

-- C++ Plan::set_owner — assign/release a room's owner (v50: zone
-- assigned_unit_id via dfhack.buildings.setOwner)
function Plan:set_owner(r, uid)
    r.owner = uid
    local zb = self:_ensure_room_zone(r)
    if not zb then return end
    local u = uid and uid >= 0 and df.unit.find(uid) or nil
    pcall(function() dfhack.buildings.setOwner(zb, u) end)
end

function Plan:getbedroom(unit_id)
    if not self.ai.population then return end
    local rooms = self.room_category['bedroom']
    if not rooms then return end
    -- C++ three-tier search: (1) already mine, (2) any dug unowned
    -- room, (3) dig a FRESH planned bedroom on demand — without tier 3
    -- migrants stayed homeless forever once pre-dug rooms ran out.
    for _, r in ipairs(rooms) do
        if r.owner == unit_id then
            return r
        end
    end
    for _, r in ipairs(rooms) do
        if r.owner < 0 and r.status ~= 'plan' then
            self:set_owner(r, unit_id)
            self:_log('assigned bedroom to unit ' .. unit_id)
            if r.status == 'finished' then self:furnish_room(r) end
            return r
        end
    end
    for _, r in ipairs(rooms) do
        if r.owner < 0 and r.status == 'plan' and not r.queue_dig then
            self:wantdig(r, -1)
            self:set_owner(r, unit_id)
            self:_log('digging new bedroom for unit ' .. unit_id)
            return r
        end
    end
    return nil
end

-- shared-furniture user count helper (must be declared before the
-- functions below use it as an upvalue)
local function count_users(o)
    local n = 0
    for _ in pairs(o.users or {}) do n = n + 1 end
    return n
end

-- C++ Plan::getcoffin — claim the next unused coffin of a cemetery
-- room that still has unclaimed has_users coffins, and dig that room.
-- Population::update_deads calls this once per NEEDED coffin after its
-- own census (3 + unburied - free - planned).
function Plan:getcoffin()
    if not self.ai.population then return end
    for _, r in ipairs(self.room_category['cemetery'] or {}) do
        local has_free = false
        for _, f in ipairs(r.layout) do
            if f.has_users and count_users(f) == 0 then
                has_free = true break
            end
        end
        if has_free then
            self:wantdig(r, -1)
            for _, f in ipairs(r.layout) do
                if f.type == 'coffin' and count_users(f) == 0 then
                    f.users = f.users or {}
                    f.users[-1] = true -- claimed (C++ inserts -1)
                    f.ignore = false
                    self:_log('claimed a coffin in the cemetery')
                    break
                end
            end
            if r.status == 'finished' then
                self:furnish_room(r)
            end
            return
        end
    end
end

-- C++ Plan::getdiningroom — shared-furniture users: farm work rights +
-- one table + one chair per dwarf in the dining hall.
function Plan:getdiningroom(unit_id)
    if not self.ai.population then return end

    -- already has a spot?
    for _, r in ipairs(self.room_category['dininghall'] or {}) do
        for _, f in ipairs(r.layout) do
            if f.users and f.users[unit_id] then return end
        end
    end

    -- farm work rights (C++: 4 farmplot slots, indoor food/cloth first)
    local farm_specs = {
        { 'food', false }, { 'cloth', false },
        { 'food', true }, { 'cloth', true },
    }
    for _, spec in ipairs(farm_specs) do
        for _, r in ipairs(self.room_category['farmplot'] or {}) do
            if (r.farm_type or 'food') == spec[1]
                and r.outdoor == spec[2]
                and (not r.users or count_users(r) < (r.has_users or 1)) then
                self:wantdig(r, -3)
                r.users = r.users or {}
                r.users[unit_id] = true
                break
            end
        end
    end

    for _, r in ipairs(self.room_category['dininghall'] or {}) do
        local free_table, free_chair
        for _, f in ipairs(r.layout) do
            if f.type == 'table' and f.has_users
                and (not f.users or count_users(f) < f.has_users) then
                free_table = f
            end
            if f.type == 'chair' and f.has_users
                and (not f.users or count_users(f) < f.has_users) then
                free_chair = f
            end
        end
        if free_table or free_chair then
            self:wantdig(r, -2)
            for _, f in ipairs { free_table, free_chair } do
                if f then
                    f.users = f.users or {}
                    f.users[unit_id] = true
                    f.ignore = false
                end
            end
            if r.status == 'finished' then
                self:furnish_room(r)
            end
            return
        end
    end
end

-- C++ Plan::getsoldierbarrack — squad barracks + furniture users
-- (weapon_rack/armor_stand/bed/cabinet/chest/archery_target per dwarf)
function Plan:getsoldierbarrack(unit_id)
    if not self.ai.population then return nil end
    local u = df.unit.find(unit_id)
    if not u then return nil end
    local ok_s, squad_id = pcall(function() return u.military.squad_id end)
    if not ok_s or not squad_id or squad_id < 0 then return nil end

    local rooms = self.room_category['barracks']
    if not rooms then return nil end
    local r
    for _, rr in ipairs(rooms) do
        if rr.squad_id == squad_id then r = rr break end
    end
    if not r then
        for _, rr in ipairs(rooms) do
            if rr.squad_id < 0 then
                r = rr
                r.squad_id = squad_id
                self:wantdig(r, -2)
                self:_log('squad ' .. squad_id .. ' assigned a barracks')
                break
            end
        end
    end
    if not r then return nil end

    -- squad room use flags (C++ assign_barrack_squad: sleep+train+eq).
    -- r3.8: dfhack.military.updateRoomAssignments wires BOTH sides
    -- (zone.squad_room_info AND squad.rooms) — the manual write only
    -- did the zone side, so the game did not register the barracks.
    local zb = self:_ensure_room_zone(r)
    if zb then
        pcall(function()
            local flags = df.squad_use_flags:new()
            flags.sleep = true
            flags.train = true
            flags.indiv_eq = true
            flags.squad_eq = true
            dfhack.military.updateRoomAssignments(squad_id, zb.id, flags)
            flags:delete()
        end)
    end

    -- per-dwarf barracks furniture users
    local wanted = { 'weapon_rack', 'armor_stand', 'bed', 'cabinet',
        'chest', 'archery_target' }
    for _, wtype in ipairs(wanted) do
        local mine
        for _, f in ipairs(r.layout) do
            if f.type == wtype and f.users and f.users[unit_id] then
                mine = f break
            end
        end
        if not mine then
            for _, f in ipairs(r.layout) do
                if f.type == wtype and f.has_users
                    and (not f.users or count_users(f) < f.has_users) then
                    f.users = f.users or {}
                    f.users[unit_id] = true
                    f.ignore = false
                    break
                end
            end
        end
    end

    if r.status == 'finished' then
        self:furnish_room(r)
    end
    return r
end

-- C++ Plan::freesoldierbarrack — release a soldier's per-dwarf
-- barracks furniture users (the squad keeps the room).
function Plan:freesoldierbarrack(unit_id)
    for _, r in ipairs(self.room_category['barracks'] or {}) do
        for _, f in ipairs(r.layout or {}) do
            if f.users and f.users[unit_id] then
                f.users[unit_id] = nil
            end
        end
    end
end

-- C++ Plan:attribute_noblerooms — noble suites for position holders
-- (office/dining/bedroom/tomb per required_* of the position)
function Plan:attribute_noblerooms(id_list)
    if not id_list or #id_list == 0 then return end
    local rooms = self.room_category['nobleroom']
    if not rooms then return end

    -- free suites owned by now-removed nobles
    local keep = {}
    for _, uid in ipairs(id_list) do keep[uid] = true end
    for _, r in ipairs(rooms) do
        if r.owner >= 0 and not keep[r.owner] then
            self:set_owner(r, -1)
        end
    end

    for _, uid in ipairs(id_list) do
        local base
        for _, r in ipairs(rooms) do
            if r.owner == uid then base = r break end
        end
        if not base then
            for _, r in ipairs(rooms) do
                if r.owner < 0 then
                    base = r
                    self:set_owner(r, uid)
                    break
                end
            end
        end
        if base then
            -- claim the whole suite (same noblesuite number)
            for _, r in ipairs(rooms) do
                if r.noblesuite == base.noblesuite and r.owner < 0 then
                    self:set_owner(r, uid)
                    self:wantdig(r, -2)
                end
            end
        end
    end
end

-- C++ Plan::new_citizen — rooms for a fresh citizen: dining spot +
-- bedroom + jail cells for citizens/10.
function Plan:new_citizen(uid)
    self:add_task(TASK_TYPE.check_idle)
    self:getdiningroom(uid)
    self:getbedroom(uid)

    local pop = self.ai.population
    local required_jail_cells = pop and math.floor(pop:citizen_count() / 10) or 0
    if required_jail_cells > 0 then
        for _, r in ipairs(self.room_category['jail'] or {}) do
            if r.status ~= 'plan' then
                for _, f in ipairs(r.layout) do
                    if (f.type == 'cage' or f.type == 'restraint')
                        and required_jail_cells > 0 then
                        if f.ignore then
                            f.ignore = false
                            if r.status == 'finished' then
                                self:furnish_room(r)
                            end
                        end
                        required_jail_cells = required_jail_cells - 1
                    end
                end
            end
        end
    end
end

-- C++ Plan::del_citizen — free the bedroom/dining spot of a lost dwarf
function Plan:del_citizen(uid)
    for _, r in ipairs(self.room_category['bedroom'] or {}) do
        if r.owner == uid then
            self:set_owner(r, -1)
        end
    end
    for _, r in ipairs(self.room_category['dininghall'] or {}) do
        for _, f in ipairs(r.layout) do
            if f.users and f.users[uid] then
                f.users[uid] = nil
            end
        end
    end
    for _, r in ipairs(self.room_category['farmplot'] or {}) do
        if r.users and r.users[uid] then
            r.users[uid] = nil
        end
    end
    for _, r in ipairs(self.room_category['barracks'] or {}) do
        for _, f in ipairs(r.layout) do
            if f.users and f.users[uid] then
                f.users[uid] = nil
            end
        end
    end
end

-- C++ room::low_grass — a pasture is exhausted when fewer than 20% of
-- its tiles still carry grass (GRASS_LIGHT / GRASS_DARK materials).
local function pasture_low_grass(r)
    local w = (r.max.x - r.min.x) + 1
    local h = (r.max.y - r.min.y) + 1
    local total = w * h
    if total <= 0 then return true end
    local grass = 0
    local TM = df.tiletype_material
    for dx = 0, w - 1 do
        for dy = 0, h - 1 do
            local ok, tt = pcall(dfhack.maps.getTileType,
                r.min.x + dx, r.min.y + dy, r.min.z)
            if ok and tt ~= nil then
                local okm, mat = pcall(function()
                    return df.tiletype.attrs[tt].material
                end)
                if okm and (mat == TM.GRASS_LIGHT or mat == TM.GRASS_DARK) then
                    grass = grass + 1
                end
            end
        end
    end
    return grass < math.floor(total / 5)
end

-- grazing pressure of a unit (C++: 11*11*1000/grazer; non-grazers are
-- effectively free — their grazer is 0 → pcall-guarded to a huge value)
local function grazing_pressure(unit)
    local ok, p = pcall(function()
        local race = df.creature_raw.find(unit.race)
        local caste = race and race.caste[unit.caste]
        local grazer = caste and caste.misc.grazer or 0
        if grazer <= 0 then return math.huge end
        return 11 * 11 * 1000 / grazer
    end)
    return ok and p or math.huge
end

local function unit_is_grazer(unit)
    local ok, p = pcall(function()
        local race = df.creature_raw.find(unit.race)
        local caste = race and race.caste[unit.caste]
        return caste and (caste.misc.grazer or 0) > 0 or false
    end)
    return ok and p or false
end

-- C++ Plan::getpasture — capacity-managed pasture assignment. Each
-- pasture holds grazing pressure < 1000 (a grazer 1000 animal costs
-- 121; ~8 large grazers per 11x11 pasture). Returns the zone building
-- or nil.
function Plan:getpasture(pet_id)
    local pet = df.unit.find(pet_id)
    if not pet then return nil end

    -- already assigned to one of OUR pastures? (keep it unless the
    -- grass ran out — then the pet is released to find a fresh field)
    local ok_r, cur_zone = pcall(function()
        local ref = dfhack.units.getGeneralRef(pet,
            df.general_ref_type.BUILDING_CIVZONE_ASSIGNED)
        return ref and ref:getBuilding() or nil
    end)
    if ok_r and cur_zone then
        for _, r in ipairs(self.room_category['pasture'] or {}) do
            if r.bld_id == cur_zone.id then
                if pasture_low_grass(r) then
                    r.users = r.users or {}
                    r.users[pet_id] = nil
                else
                    return cur_zone
                end
            end
        end
    end

    local pressure = grazing_pressure(pet)
    if pressure == math.huge then return nil end
    local limit = 1000 - pressure

    for _, r in ipairs(self.room_category['pasture'] or {}) do
        if r.status ~= 'plan' and not pasture_low_grass(r) then
            local sum = 0
            for uid in pairs(r.users or {}) do
                local u = df.unit.find(uid)
                if u then
                    sum = sum + grazing_pressure(u)
                end
            end
            if sum < limit then
                r.users = r.users or {}
                r.users[pet_id] = true
                if not r.bld_id or r.bld_id < 0 then
                    self:construct_room(r)
                end
                local bld = r.bld_id and self:_find_building(r.bld_id) or nil
                return bld
            end
        end
    end
    return nil
end

-- C++ Plan::freepasture
function Plan:freepasture(pet_id)
    for _, r in ipairs(self.room_category['pasture'] or {}) do
        if r.users and r.users[pet_id] then
            r.users[pet_id] = nil
        end
    end
end

-- C++ Plan::pastures_ready — true when every non-plan pasture has its
-- zone building; kicks off digging for still-planned pastures.
function Plan:pastures_ready()
    local any_dig = false
    for _, r in ipairs(self.room_category['pasture'] or {}) do
        if r.status ~= 'plan' then
            if not r.bld_id or r.bld_id < 0
                or not self:_find_building(r.bld_id) then
                return false
            end
        end
    end
    for _, r in ipairs(self.room_category['pasture'] or {}) do
        if r.status == 'plan' then
            r.queue = -4
            self:wantdig(r, -4)
            any_dig = true
        end
    end
    return not any_dig
end

-- ============================================================
-- Misc utilities
-- ============================================================

function Plan:dig_tile(x, y, z, dig_type)
    local dt = dig_type or df.tile_dig_designation.Default
    local block = dfhack.maps.getTileBlock(x, y, z)
    if block then
        local des = block.designation[x % 16][y % 16]
        if des and des.dig == df.tile_dig_designation.No then
            des.dig = dt
            block.flags.designated = true
        end
    end
end

function Plan:find_building(bld)
    for _, r in ipairs(self.rooms) do
        if r.bld_id >= 0 then
            local rb = r:dfbuilding()
            if rb == bld then
                return r, nil
            end
        end
        for _, f in ipairs(r.layout) do
            if f.bld_id >= 0 then
                local fb = df.building.find(f.bld_id)
                if fb == bld then
                    return r, f
                end
            end
        end
    end
    return nil, nil
end

-- ============================================================
-- Status
-- ============================================================

function Plan:status()
    local parts = {}
    local room_counts = {}
    for _, r in ipairs(self.rooms) do
        room_counts[r.type] = (room_counts[r.type] or 0) + 1
    end
    for t, c in pairs(room_counts) do
        table.insert(parts, '  ' .. t .. ': ' .. c)
    end
    table.insert(parts, '  Tasks: ' .. #self.tasks_generic .. ' generic, ' .. #self.tasks_furniture .. ' furniture')
    table.insert(parts, '  Priority rules: ' .. #self.priority_rules
        .. (self.plan_config and self.plan_config.priorities
            and (' (' .. #self.plan_config.priorities .. ' loaded)') or ''))
    local working_rules = {}
    for _, rule in ipairs(self.priority_rules) do
        if rule.working then table.insert(working_rules, rule.name) end
    end
    if #working_rules > 0 then
        table.insert(parts, '  Rules in progress: ' .. table.concat(working_rules, ', '))
    end
    if self.builder and not self.builder.done then
        table.insert(parts, '  Placement: ' .. self.builder.status)
    end
    table.insert(parts, '  Past initial phase: ' .. tostring(self.past_initial_phase))
    table.insert(parts, '  Setup done: ' .. tostring(self.setup_done))
    table.insert(parts, '  Fort entrance: ' .. tostring(self.fort_entrance))
    return table.concat(parts, '\n')
end

return Plan
