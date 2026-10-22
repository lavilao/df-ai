--@module = true

local json = require('json')
local rooms_module = nil

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
    }
    setmetatable(o, Plan)
    return o
end

function Plan:startup()
    self:load_rooms_module()
    self:load_blueprint()
    self:plan_setup()
    self:add_task(TASK_TYPE.check_rooms)
    self.past_initial_phase = false
    self.should_search_for_metal = true
    self.setup_done = true
end

function Plan:load_rooms_module()
    local ok, mod = pcall(dfhack.run_script_with_env, nil, 'df-ai/rooms', {module=true})
    if ok then
        rooms_module = mod
    end
end

function Plan:update()
    self.last_update_year = df.global.cur_year
    self.last_update_tick = df.global.cur_year_tick

    if not self.setup_done then return end

    if self.bg_idx_generic == nil then
        self.bg_idx_generic = 1
        self:start_processing_generic()
    end

    if self.bg_idx_furniture == nil then
        self.bg_idx_furniture = 1
        self:start_processing_furniture()
    end
end

function Plan:add_task(task_type, room, furniture, item_id)
    local t = {
        type = task_type,
        room = room,
        furniture = furniture,
        item_id = item_id or -1,
        last_status = '',
    }
    if task_type == TASK_TYPE.furnish then
        table.insert(self.tasks_furniture, t)
    else
        table.insert(self.tasks_generic, t)
    end
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
    if not self.plan_config then
        dfhack.println('[df-ai] No plan config loaded, skipping setup')
        return
    end

    if not rooms_module then
        self:load_rooms_module()
        if not rooms_module then
            dfhack.println('[df-ai] Rooms module not available, skipping setup')
            return
        end
    end

    -- Find the embark surface position
    local entrance = self:find_fort_entrance()
    if not entrance then
        dfhack.println('[df-ai] Could not find fort entrance location')
        return
    end
    self.fort_entrance = entrance
    dfhack.println('[df-ai] Fort entrance at ' .. entrance.x .. ',' .. entrance.y .. ',' .. entrance.z)

    -- Create the start room at entrance
    self:_place_start(entrance)

    -- Place other rooms based on plan priorities
    local priorities = self.plan_config.priorities
    if priorities then
        for _, tag in ipairs(priorities) do
            if tag ~= 'generic01_start' then
                self:_place_room_tag(tag, entrance)
            end
        end
    end

    -- Connect all rooms with corridors (BFS pathfinding)
    self:_connect_all_corridors()

    -- Sort rooms by distance from entrance for priority
    table.sort(self.rooms, function(a, b)
        return a:distance_to(self.fort_entrance) < b:distance_to(self.fort_entrance)
    end)

    dfhack.println('[df-ai] Setup complete: ' .. #self.rooms .. ' rooms, ' .. #self.corridors .. ' corridors')
end

function Plan:find_fort_entrance()
    -- Try to find the embark position from plotinfo
    local ok, plotinfo = pcall(function() return df.global.plotinfo end)
    if ok and plotinfo then
        local pos = plotinfo.embark_pos
        if pos then
            return { x = pos.x, y = pos.y, z = pos.z }
        end
    end

    -- Fallback: find surface at map center
    local maps = dfhack.maps
    if not maps then return nil end

    local center_x = maps.getMapSize().x / 2
    local center_y = maps.getMapSize().y / 2

    for z = maps.getMapSize().z - 1, 0, -1 do
        local block = maps.getTileBlock(center_x, center_y, z)
        if block then
            local tile = block.tiletype[center_x % 16][center_y % 16]
            local tt = df.tiletype.attrs[tile]
            if tt and tt.shape ~= df.tiletype_shape.EMPTY then
                return { x = center_x, y = center_y, z = z }
            end
        end
    end
    return nil
end

function Plan:_place_start(entrance)
    -- Place the start room at the entrance position
    local start_templates = self:_template_orientations('generic01_start')
    if #start_templates == 0 then
        -- Fallback: create a simple 3x3 starter room
        local rm = rooms_module.room.new('corridor',
            { x = entrance.x - 2, y = entrance.y - 2, z = entrance.z },
            { x = entrance.x + 2, y = entrance.y + 2, z = entrance.z },
            { corridor_type = 'corridor', outdoor = true, level = 0 }
        )
        table.insert(self.rooms, rm)
        table.insert(self.corridors, rm)
        self.fort_entrance = rm
        return
    end

    -- Pick the first start template
    local tmpl_key = start_templates[1]
    local tmpl = self.templates[tmpl_key]

    if not tmpl or not tmpl.r then return end

    for _, r_data in ipairs(tmpl.r) do
        local min_local = r_data.min
        local max_local = r_data.max
        if min_local and max_local then
            local rm = rooms_module.room.new(r_data.type or 'corridor',
                { x = entrance.x + min_local[1], y = entrance.y + min_local[2], z = entrance.z + min_local[3] },
                { x = entrance.x + max_local[1], y = entrance.y + max_local[2], z = entrance.z + max_local[3] },
                {
                    corridor_type = r_data.corridor_type,
                    outdoor = r_data.outdoor or false,
                    level = min_local[3],
                }
            )
            if r_data.accesspath then rm.accesspath = r_data.accesspath end

            -- Load furniture layout from template[ f ] referenced by indices in r_data.layout
            if tmpl.f and r_data.layout then
                for _, fi in ipairs(r_data.layout) do
                    if tmpl.f[fi + 1] then
                        local f_data = tmpl.f[fi + 1]
                        local f = rooms_module.furniture.new(
                            f_data.type or 'none',
                            { x = entrance.x + f_data.x, y = entrance.y + f_data.y, z = entrance.z + (f_data.z or 0) },
                            {
                                dig = f_data.dig,
                                construction = f_data.construction,
                                makeroom = f_data.makeroom or false,
                            }
                        )
                        table.insert(rm.layout, f)
                    end
                end
            end

            if rm.type == 'corridor' then
                table.insert(self.corridors, rm)
            end
            table.insert(self.rooms, rm)
            if not self.room_category[rm.type] then
                self.room_category[rm.type] = {}
            end
            table.insert(self.room_category[rm.type], rm)
        end
    end
end

function Plan:_place_room_tag(tag, entrance)
    -- Place rooms matching a plan tag (e.g., "generic01_bedrooms", "generic01_workshop_3x3")
    -- Uses limits from plan config to determine how many to place

    -- Determine base template name from tag
    local limits = self.plan_config.limits
    if not limits or not limits[tag] then return end

    local min_count, max_count = limits[tag][1], limits[tag][2]

    -- Map tag to template base name
    local template_base = tag

    -- For each template variant, try to place a room
    local orientations = self:_template_orientations(template_base)
    if #orientations == 0 then return end

    -- Count existing rooms of this type
    local existing = #(self.room_category[self:_tag_to_type(tag)] or {})
    local target = math.max(min_count or 1, math.min(max_count or 10, 10))
    target = target - existing
    if target <= 0 then return end

    -- Place rooms in a radial pattern around entrance
    local ws_type_idx = 0
    local f_type_idx = 0
    for i = 1, math.min(target, #orientations) do
        local angle = (i - 1) * (2 * math.pi / math.min(target, 8)) + 0.1
        local radius = 12 + (i // 8) * 12
        local offset_x = math.floor(radius * math.cos(angle))
        local offset_y = math.floor(radius * math.sin(angle))
        local oz = 0
        -- Underground rooms go one level down
        if tag ~= 'generic01_apiary' and tag ~= 'generic01_outdoor_farm'
            and tag ~= 'generic01_cage_trap' and tag ~= 'generic01_depot'
            and tag ~= 'generic01_pasture' and tag ~= 'generic01_outpost_entrance'
            and tag ~= 'generic01_mineshaft' then
            oz = -1
        end

        local tmpl_key = orientations[(i - 1) % #orientations + 1]
        local tmpl = self.templates[tmpl_key]
        if tmpl and tmpl.r then
            -- Assign workshop/furnace type for this batch
            local ws_types = WORKSHOP_TYPES_BY_SIZE[template_base]
            ws_type_idx = ws_type_idx + 1
            f_type_idx = f_type_idx + 1

            for _, r_data in ipairs(tmpl.r) do
                if r_data.min and r_data.max then
                    local min_l, max_l = r_data.min, r_data.max
                    local room_type = r_data.type
                    if room_type == nil or room_type == 'None' then
                        room_type = self:_tag_to_type(tag)
                    end
                    local kwargs = {
                        corridor_type = r_data.corridor_type,
                        outdoor = r_data.outdoor or false,
                        level = oz + min_l[3],
                    }
                    if room_type == 'workshop' and r_data.stockpile_type == nil then
                        if ws_types and #ws_types > 0 then
                            kwargs.workshop_type = ws_types[((ws_type_idx - 1) % #ws_types) + 1]
                        end
                    elseif room_type == 'furnace' then
                        kwargs.furnace_type = FURNACE_TYPES_LIST[((f_type_idx - 1) % #FURNACE_TYPES_LIST) + 1]
                    elseif room_type == 'stockpile' and r_data.stockpile_type then
                        kwargs.stockpile_type = r_data.stockpile_type
                    elseif r_data.farm_type then
                        kwargs.farm_type = r_data.farm_type
                    end
                    local rm = rooms_module.room.new(room_type,
                        { x = entrance.x + offset_x + min_l[1], y = entrance.y + offset_y + min_l[2], z = entrance.z + oz + min_l[3] },
                        { x = entrance.x + offset_x + max_l[1], y = entrance.y + offset_y + max_l[2], z = entrance.z + oz + max_l[3] },
                        kwargs
                    )
                    if r_data.accesspath then rm.accesspath = r_data.accesspath end

                    -- Load furniture
                    if tmpl.f and r_data.layout then
                        for _, fi in ipairs(r_data.layout) do
                            if tmpl.f[fi + 1] then
                                local f_data = tmpl.f[fi + 1]
                                local f = rooms_module.furniture.new(
                                    f_data.type or 'none',
                                    { x = entrance.x + offset_x + f_data.x, y = entrance.y + offset_y + f_data.y, z = entrance.z + oz + (f_data.z or 0) },
                                    {
                                        dig = f_data.dig,
                                        construction = f_data.construction,
                                        makeroom = f_data.makeroom or false,
                                    }
                                )
                                table.insert(rm.layout, f)
                            end
                        end
                    end

                    if rm.type == 'corridor' then
                        table.insert(self.corridors, rm)
                    end
                    table.insert(self.rooms, rm)
                    if not self.room_category[rm.type] then
                        self.room_category[rm.type] = {}
                    end
                    table.insert(self.room_category[rm.type], rm)
                end
            end
        end
    end
end

function Plan:_tag_to_type(tag)
    -- Map a template tag to a room type string
    local mapping = {
        generic01_start = 'corridor',
        generic01_bedroom = 'bedroom',
        generic01_bedrooms = 'bedroom',
        generic01_dormitory = 'bedroom',
        generic01_dininghall = 'dininghall',
        generic01_nobleroom = 'nobleroom',
        generic01_stockpile = 'stockpile',
        generic01_workshop_3x3 = 'workshop',
        generic01_workshop_5x5 = 'workshop',
        generic01_workshop_1x1 = 'workshop',
        generic01_farmplot = 'farmplot',
        generic01_barracks = 'barracks',
        generic01_infirmary = 'infirmary',
        generic01_jail = 'jail',
        generic01_cemetery = 'cemetery',
        generic01_location = 'location',
        generic01_depot = 'tradedepot',
        generic01_pasture = 'pasture',
        generic01_apiary = 'apiary',
        generic01_well = 'cistern',
        generic01_corridor = 'corridor',
        generic01_corridor_stair = 'corridor',
        generic01_mineshaft = 'outpost',
        generic01_outdoor_farm = 'farmplot',
        generic01_cage_trap = 'pitcage',
        generic01_pitting_tower = 'pitcage',
        generic01_outpost_entrance = 'outpost',
        generic01_underground_farm_start = 'farmplot',
        generic01_underground_farm_extension = 'farmplot',
        generic01_stair = 'corridor',
    }
    return mapping[tag] or tag
end

-- ============================================================
-- Corridor BFS pathfinding — connects rooms through rock
-- ============================================================

function Plan:_connect_all_corridors()
    if #self.rooms < 2 then return end

    -- Connect each non-corridor room to the nearest corridor or the fort entrance
    local connected = {}
    for _, r in ipairs(self.corridors) do
        connected[r] = true
    end

    if #self.corridors == 0 then
        -- Use the first room as the spine
        connected[self.rooms[1]] = true
    end

    local entrance = self.fort_entrance
    local iter_rooms = {}
    for _, r in ipairs(self.rooms) do
        table.insert(iter_rooms, r)
    end
    -- Sort by distance to entrance
    table.sort(iter_rooms, function(a, b)
        return a:distance_to(entrance) < b:distance_to(entrance)
    end)

    for _, r in ipairs(iter_rooms) do
        if not connected[r] and r.type ~= 'corridor' then
            -- Find the nearest connected room
            local nearest = nil
            local nearest_dist = 999999
            for c in pairs(connected) do
                local d = r:distance_to(c)
                if d < nearest_dist then
                    nearest_dist = d
                    nearest = c
                end
            end
            if nearest then
                self:_dig_corridor_between(r, nearest)
                connected[r] = true
            end
        end
    end
end

function Plan:_dig_corridor_between(room_a, room_b)
    -- BFS through rock from room_a's position to room_b's position
    local pos_a = room_a:pos()
    local pos_b = room_b:pos()

    local function coord_key(c)
        return c.x .. ',' .. c.y .. ',' .. c.z
    end

    local source = {}
    local check_0 = {}
    local check_1 = {}
    local check_2 = {}

    -- Start from room_a's position
    local start = { x = pos_a.x, y = pos_a.y, z = pos_a.z }
    local target = { x = pos_b.x, y = pos_b.y, z = pos_b.z }
    table.insert(check_0, start)
    source[coord_key(start)] = start

    local directions = {
        { x = 1, y = 0, z = 0 },
        { x = -1, y = 0, z = 0 },
        { x = 0, y = 1, z = 0 },
        { x = 0, y = -1, z = 0 },
        { x = 0, y = 0, z = 1 },
        { x = 0, y = 0, z = -1 },
    }

    local found = false
    local target_key = coord_key(target)

    while #check_0 > 0 or #check_1 > 0 or #check_2 > 0 do
        if #check_0 == 0 then
            check_0 = check_1
            check_1 = check_2
            check_2 = {}
        end

        local cur = table.remove(check_0, 1)
        local cur_key = coord_key(cur)

        if cur_key == target_key then
            found = true
            -- Backtrack to create corridor segments
            local path = {}
            local node = cur
            while node do
                table.insert(path, 1, node)
                local nk = coord_key(node)
                local prev = source[nk]
                if prev == node then break end
                node = prev
            end

            -- Create corridor rooms along the path (merge collinear segments)
            local seg_start = path[1]
            local i = 2
            while i <= #path do
                local seg_end = path[i]
                -- Extend in the same direction as long as possible
                local dx = seg_end.x - seg_start.x
                local dy = seg_end.y - seg_start.y
                local dz = seg_end.z - seg_start.z
                local axis = dx ~= 0 and 'x' or (dy ~= 0 and 'y' or 'z')
                local j = i + 1
                while j <= #path do
                    local next_dx = path[j].x - path[j-1].x
                    local next_dy = path[j].y - path[j-1].y
                    local next_dz = path[j].z - path[j-1].z
                    local next_axis = next_dx ~= 0 and 'x' or (next_dy ~= 0 and 'y' or 'z')
                    if next_axis ~= axis then break end
                    j = j + 1
                end
                seg_end = path[j - 1]

                local min_c = { x = math.min(seg_start.x, seg_end.x), y = math.min(seg_start.y, seg_end.y), z = math.min(seg_start.z, seg_end.z) }
                local max_c = { x = math.max(seg_start.x, seg_end.x), y = math.max(seg_start.y, seg_end.y), z = math.max(seg_start.z, seg_end.z) }

                -- Check if this corridor segment would overlap with existing rooms
                local overlap = false
                for _, existing in ipairs(self.corridors) do
                    if existing:include(min_c) or existing:include(max_c) then
                        overlap = true
                        break
                    end
                end

                if not overlap then
                    local cr = rooms_module.room.new('corridor',
                        min_c, max_c,
                        { corridor_type = 'corridor', level = min_c.z }
                    )
                    table.insert(self.rooms, cr)
                    table.insert(self.corridors, cr)
                    if not self.room_category['corridor'] then
                        self.room_category['corridor'] = {}
                    end
                    table.insert(self.room_category['corridor'], cr)
                end

                seg_start = seg_end
                i = j
            end
            break
        end

        -- Expand in all directions
        for _, dir in ipairs(directions) do
            local nx = cur.x + dir.x
            local ny = cur.y + dir.y
            local nz = cur.z + dir.z
            local nk = coord_key({ x = nx, y = ny, z = nz })

            if not source[nk] then
                -- Check if tile is diggable (in rock / not open space)
                local block = dfhack.maps.getTileBlock(nx, ny, nz)
                local diggable = false
                if block then
                    local tile = block.tiletype[nx % 16][ny % 16]
                    local attrs = df.tiletype.attrs[tile]
                    if attrs then
                        local shape = attrs.shape
                        if shape == df.tiletype_shape.WALL then
                            diggable = true
                        end
                    end
                end

                if diggable then
                    source[nk] = cur
                    -- Same direction gets lower priority (straight preferred)
                    if cur.x == nx or cur.y == ny or cur.z == nz then
                        -- Check if moving in same direction as parent
                        local parent = source[coord_key(cur)]
                        if parent and (nx - cur.x == cur.x - parent.x)
                            and (ny - cur.y == cur.y - parent.y)
                            and (nz - cur.z == cur.z - parent.z) then
                            table.insert(check_2, { x = nx, y = ny, z = nz })
                        else
                            table.insert(check_1, { x = nx, y = ny, z = nz })
                        end
                    else
                        table.insert(check_0, { x = nx, y = ny, z = nz })
                    end
                end
            end
        end
    end

    if not found then
        -- Simple direct corridor if BFS fails
        local min_c = { x = math.min(pos_a.x, pos_b.x), y = math.min(pos_a.y, pos_b.y), z = math.min(pos_a.z, pos_b.z) }
        local max_c = { x = math.max(pos_a.x, pos_b.x), y = math.max(pos_a.y, pos_b.y), z = math.max(pos_a.z, pos_b.z) }
        local cr = rooms_module.room.new('corridor', min_c, max_c, { corridor_type = 'corridor', level = min_c.z })
        table.insert(self.rooms, cr)
        table.insert(self.corridors, cr)
        if not self.room_category['corridor'] then
            self.room_category['corridor'] = {}
        end
        table.insert(self.room_category['corridor'], cr)
    end
end

-- ============================================================
-- Task processing (generic queue, one per frame)
-- ============================================================

function Plan:start_processing_generic()
    local self_ref = self
    dfhack.onStateChange['df-ai-plan-bg'] = function(sc)
        if sc == SC_VIEWSCREEN_CHANGED then
            if self_ref.bg_idx_generic == nil then return end
            if self_ref.bg_idx_generic > #self_ref.tasks_generic then
                self_ref.bg_idx_generic = nil
                return
            end
            local t = self_ref.tasks_generic[self_ref.bg_idx_generic]
            if not t then
                self_ref.bg_idx_generic = self_ref.bg_idx_generic + 1
                return
            end

            local reason = ''
            local del = false

            if t.type == TASK_TYPE.want_dig then
                local wantdig_max = 2
                if t.room and t.room:is_dug() then
                    self_ref:digroom(t.room)
                    del = true
                else
                    local q = (t.room and t.room.queue) or 0
                    local nrd = self_ref.nrdig[q] or 0
                    if nrd < wantdig_max then
                        self_ref:digroom(t.room)
                        del = true
                    else
                        reason = 'dig queue ' .. q .. ' full (' .. nrd .. '/' .. wantdig_max .. ')'
                    end
                end
            elseif t.type == TASK_TYPE.dig_room or t.type == TASK_TYPE.dig_room_immediate then
                if t.room then
                    -- Dig accesspath corridors first
                    if t.room.accesspath and #t.room.accesspath > 0 then
                        for _, ap_idx in ipairs(t.room.accesspath) do
                            local ap_room = self_ref.rooms[ap_idx + 1]
                            if ap_room and ap_room.status == 'plan' then
                                ap_room:dig()
                            end
                        end
                    end

                    t.room:dig()
                    if t.room:is_dug() then
                        t.room.status = 'dug'
                        self_ref:construct_room(t.room)
                        del = true
                    end
                else
                    del = true
                end
            elseif t.type == TASK_TYPE.construct_workshop then
                del = self_ref:try_construct_workshop(t.room)
            elseif t.type == TASK_TYPE.construct_furnace then
                del = self_ref:try_construct_furnace(t.room)
            elseif t.type == TASK_TYPE.construct_stockpile then
                del = self_ref:try_construct_stockpile(t.room)
            elseif t.type == TASK_TYPE.construct_farmplot then
                del = self_ref:try_construct_farmplot(t.room)
            elseif t.type == TASK_TYPE.construct_activityzone then
                del = self_ref:try_construct_activityzone(t.room)
            elseif t.type == TASK_TYPE.construct_tradedepot then
                del = self_ref:try_construct_tradedepot(t.room)
            elseif t.type == TASK_TYPE.construct_windmill then
                del = self_ref:try_construct_windmill(t.room)
            elseif t.type == TASK_TYPE.check_rooms then
                self_ref:checkrooms()
            elseif t.type == TASK_TYPE.check_construct then
                if t.room and t.room.bld_id >= 0 then
                    if not df.building.find(t.room.bld_id) then
                        t.room.bld_id = -1
                        self_ref:construct_room(t.room)
                    end
                end
                del = true
            elseif t.type == TASK_TYPE.check_furnish then
                if t.room then
                    local any_furnish = false
                    for _, f in ipairs(t.room.layout) do
                        if f.bld_id < 0 and not f.ignore then
                            self_ref:add_task(TASK_TYPE.furnish, t.room, f)
                            any_furnish = true
                        end
                    end
                    if not any_furnish and t.room.status == 'finished' then
                        t.room.furnished = true
                    end
                end
                del = true
            elseif t.type == TASK_TYPE.check_idle then
            elseif t.type == TASK_TYPE.furnish then
                if t.room and t.furniture then
                    del = self_ref:try_furnish(t.room, t.furniture)
                else
                    del = true
                end
            end

            t.last_status = reason
            self_ref.bg_idx_generic = self_ref.bg_idx_generic + 1
        end
    end
end

function Plan:start_processing_furniture()
    local self_ref = self
    dfhack.onStateChange['df-ai-furn-bg'] = function(sc)
        if sc == SC_VIEWSCREEN_CHANGED then
            if self_ref.bg_idx_furniture == nil then return end
            if self_ref.bg_idx_furniture > #self_ref.tasks_furniture then
                self_ref.bg_idx_furniture = nil
                return
            end
            local t = self_ref.tasks_furniture[self_ref.bg_idx_furniture]
            if not t then
                self_ref.bg_idx_furniture = self_ref.bg_idx_furniture + 1
                return
            end
            if t.type == TASK_TYPE.furnish then
                if t.room and t.furniture then
                    self_ref:try_furnish(t.room, t.furniture)
                end
            end
            self_ref.bg_idx_furniture = self_ref.bg_idx_furniture + 1
        end
    end
end

-- ============================================================
-- Plan setup / room placement
-- ============================================================

function Plan:initial_phase()
    local all_done = true
    for _, r in ipairs(self.rooms) do
        if r.status == 'plan' then
            if r.type ~= 'corridor' then
                r.status = 'dig'
                self:add_task(TASK_TYPE.want_dig, r)
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
                all_done = false
            end
        end
    end
    if all_done then
        self.past_initial_phase = true
    end
end

function Plan:digroom(room)
    if not room then return false end
    room.status = 'dig'
    self:add_task(TASK_TYPE.dig_room, room)
    self:add_task(TASK_TYPE.monitor_room_value, room)

    -- Update nrdig counter
    local q = room.queue or 0
    local size = room:size()
    self.nrdig[q] = (self.nrdig[q] or 0) + 1
    if size.x * size.y >= 10 then
        self.nrdig[q] = (self.nrdig[q] or 0) + 1
    end

    return true
end

-- ============================================================
-- Room checking
-- ============================================================

function Plan:checkrooms()
    if not self.past_initial_phase then
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
    for i = 1, #self.rooms do
        if ncheck >= 8 then break end
        if self.checkroom_idx > #self.rooms then
            self.checkroom_idx = 0
        end
        local r = self.rooms[self.checkroom_idx + 1]
        if not r then
            self.checkroom_idx = self.checkroom_idx + 1
        else
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
            self:construct_room(r)
        end
    elseif r.status == 'dug' then
        if r:constructions_done() then
            r.status = 'finished'
        end
    end

    -- Tantrum recovery: check furniture
    for _, f in ipairs(r.layout) do
        if f.bld_id >= 0 then
            local fb = df.building.find(f.bld_id)
            if not fb then
                f.bld_id = -1
                self:add_task(TASK_TYPE.furnish, r, f)
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
            for _, f in ipairs(r.layout) do
                if f.bld_id < 0 and not f.ignore then
                    self:add_task(TASK_TYPE.furnish, r, f)
                end
            end
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
        if r.corridor_type == 'walkable' then
        end
    else
        self:add_task(TASK_TYPE.check_furnish, r)
    end
    -- Verify construction after placement
    self:add_task(TASK_TYPE.check_construct, r)
    -- Queue furnishing
    if r.layout and #r.layout > 0 then
        for _, f in ipairs(r.layout) do
            if not f.ignore then
                self:add_task(TASK_TYPE.furnish, r, f)
            end
        end
    end
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
local function construct_at(r, btype, subtype, custom, fields, width, height)
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
    for i, def in ipairs(raws.buildings.all) do
        if def.code == code then
            return i - 1
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
        local code = r.custom_workshop_code or 'SCREW_PRESS'
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
    local fields = {
        room = { x = r.min.x, y = r.min.y, width = width, height = height },
    }
    local bld = construct_at(r, df.building_type.Stockpile, -1, -1, fields, width, height)
    if bld then
        r.bld_id = bld.id
        self:configure_stockpile(bld, r.stockpile_type)
        return true
    end
    return false
end

function Plan:configure_stockpile(bld, stype)
    if not bld or not stype then return end
    -- Stockpile category config in 53.16 lives in bld.settings with deeply
    -- nested typed vectors; the default (all allowed) is a sane base for AI
    -- fortresses, so we only record the intended type here.
    bld.name = tostring(stype)
end

function Plan:try_construct_farmplot(r)
    if not r then return false end

    if r.bld_id and r.bld_id >= 0 and df.building.find(r.bld_id) then
        return true
    end

    local width = (r.max.x - r.min.x) + 1
    local height = (r.max.y - r.min.y) + 1
    local fields = {
        room = { x = r.min.x, y = r.min.y, width = width, height = height },
    }
    local bld = construct_at(r, df.building_type.FarmPlot, -1, -1, fields, width, height)
    if bld then
        r.bld_id = bld.id
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

function Plan:try_furnish(r, f)
    if not r or not f then return false end
    local pos = f.pos
    if not pos then
        pos = r:pos()
    end

    if f.bld_id and f.bld_id >= 0 and df.building.find(f.bld_id) then
        return true
    end

    local BT = df.building_type
    -- furniture name -> { building_type, subtype, size } ; size defaults 1x1
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
    if not spec then return false end

    local pseudo = { min = pos, max = pos }
    local ok, bld = pcall(dfhack.buildings.constructBuilding, {
        type = spec[1],
        subtype = spec[2] or -1,
        custom = -1,
        pos = { x = pos.x, y = pos.y, z = pos.z },
    })
    if ok and bld then
        f.bld_id = bld.id
        return true
    end
    f.bld_id = -1
    return false
end

-- ============================================================
-- Room assignment
-- ============================================================

function Plan:getbedroom(unit_id)
    if not self.ai.population then return end
    local rooms = self.room_category['bedroom']
    if not rooms then return end
    for _, r in ipairs(rooms) do
        if r.owner == unit_id then
            return r
        end
    end
    for _, r in ipairs(rooms) do
        if r.owner < 0 and r.status == 'finished' then
            r.owner = unit_id
            local bld = r:dfbuilding()
            if bld then
                bld.room.owner = df.unit.find(unit_id)
            end
            return r
        end
    end
    return nil
end

function Plan:getcoffin()
    dfhack.println('[df-ai] Need a coffin')
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
    table.insert(parts, '  Past initial phase: ' .. tostring(self.past_initial_phase))
    table.insert(parts, '  Setup done: ' .. tostring(self.setup_done))
    table.insert(parts, '  Fort entrance: ' .. tostring(self.fort_entrance))
    return table.concat(parts, '\n')
end

return Plan
