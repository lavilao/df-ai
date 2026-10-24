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
            -- resumable placement: ~750 tries per update tick batch
            self.builder:step(3)
            if self.builder.done then
                self:_finish_setup()
            end
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
        del, reason = construct_attempt(self, t, self.try_construct_construct_workshop)
    elseif t.type == TASK_TYPE.construct_furnace then
        del, reason = construct_attempt(self, t, self.try_construct_construct_furnace)
    elseif t.type == TASK_TYPE.construct_stockpile then
        del, reason = construct_attempt(self, t, self.try_construct_construct_stockpile)
    elseif t.type == TASK_TYPE.construct_farmplot then
        del, reason = construct_attempt(self, t, self.try_construct_construct_farmplot)
    elseif t.type == TASK_TYPE.construct_activityzone then
        del, reason = construct_attempt(self, t, self.try_construct_construct_activityzone)
    elseif t.type == TASK_TYPE.construct_tradedepot then
        del, reason = construct_attempt(self, t, self.try_construct_construct_tradedepot)
    elseif t.type == TASK_TYPE.construct_windmill then
        del, reason = construct_attempt(self, t, self.try_construct_construct_windmill)
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
            for _, f in ipairs(t.room.layout) do
                if f.bld_id < 0 and not f.ignore then
                    self:add_task(TASK_TYPE.furnish, t.room, f)
                    any_furnish = true
                end
            end
            if any_furnish then
                self:_log('furnishing ' .. describe_room(t.room) .. ' (+'
                    .. #t.room.layout .. ' furniture)')
            end
            if not any_furnish and t.room.status == 'finished' then
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
        -- monitor_cistern, setup_farmplot, rescue_caged, ...) must not
        -- clog the queue forever.
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
        if bld.z_level == pos.z and bld.centerx == pos.x and bld.centery == pos.y then
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
local function construct_at(r, btype, subtype, custom, fields, width, height, abstract)
    local pos = { x = r.min.x, y = r.min.y, z = r.min.z }
    local w = width or ((r.max.x - r.min.x) + 1)
    local h = height or ((r.max.y - r.min.y) + 1)
    local ok, bld, err = pcall(dfhack.buildings.constructBuilding, {
        type = btype,
        subtype = subtype or -1,
        custom = custom or -1,
        pos = pos,
        width = w,
        height = h,
        fields = fields,
        abstract = abstract or nil,
    })
    if not ok or not bld then
        dfhack.println('[df-ai] construct failed at ('
            .. pos.x .. ',' .. pos.y .. ',' .. pos.z .. '): ' .. tostring(err or bld))
        return nil
    end
    return bld
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

    local bld = construct_at(r, spec[1], spec[2], custom, nil, spec[4], spec[5])
    if bld then
        r.bld_id = bld.id
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

    local bld = construct_at(r, df.building_type.Furnace, ft)
    if bld then
        r.bld_id = bld.id
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

    local bld = construct_at(r, df.building_type.TradeDepot)
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

    -- already placed (and the building still exists) → done
    if f.bld_id and f.bld_id >= 0 then
        local fb = self:_find_building(f.bld_id)
        if fb then return true end
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

-- ============================================================
-- Room assignment
-- ============================================================

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
            r.owner = unit_id
            local bld = r:dfbuilding()
            if bld then
                pcall(function() bld.room.owner = df.unit.find(unit_id) end)
            end
            return r
        end
    end
    for _, r in ipairs(rooms) do
        if r.owner < 0 and r.status == 'plan' and not r.queue_dig then
            r.owner = unit_id
            self:wantdig(r, -1)
            return r
        end
    end
    return nil
end

function Plan:getcoffin()
    -- rate-limit: population calls this for every unburied corpse on
    -- every update; without a limit it printed "Need a coffin" per tick
    self._coffin_log = self._coffin_log or 0
    local now = self:_tick_now()
    if now - self._coffin_log > 1200 then
        self._coffin_log = now
        dfhack.println('[df-ai] Need a coffin (cemetery not ready yet)')
    end
end

function Plan:getdiningroom(unit_id)
    if not self.ai.population then return end
    local rooms = self.room_category['dininghall']
    if not rooms then return end
    for _, r in ipairs(rooms) do
        if r.owner < 0 and r.status == 'finished' then
            r.owner = unit_id
            return r
        end
    end
    return nil
end

function Plan:getsoldierbarrack(squad_id)
    if not self.ai.population then return end
    local rooms = self.room_category['barracks']
    if not rooms then return end
    for _, r in ipairs(rooms) do
        if r.squad_id == squad_id then
            return r:dfbuilding()
        end
    end
    for _, r in ipairs(rooms) do
        if r.squad_id < 0 and r.status == 'finished' then
            r.squad_id = squad_id
            return r:dfbuilding()
        end
    end
    return nil
end

function Plan:getpasture(pet_id)
    local rooms = self.room_category['pasture']
    if not rooms then return end
    for _, r in ipairs(rooms) do
        if r.status == 'finished' then
            return r:dfbuilding()
        end
    end
    return nil
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
