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
-- Construction: Plan.new, Plan:startup, Plan:update
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
            df.workshop_type.Craftsdwarf,
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
    }
    setmetatable(o, Plan)
    return o
end

function Plan:startup()
    self:load_rooms_module()
    self:load_blueprint()
    self:add_task(TASK_TYPE.check_rooms)
    self.past_initial_phase = false
    self.should_search_for_metal = true
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
-- Blueprint loading
-- ============================================================

function Plan:load_blueprint()
    self.rooms = {}
    self.corridors = {}
    self.room_category = {}

    local ok, blueprint = pcall(json.decode_file, 'df-ai-blueprints/plans/generic01.json')
    if not ok or not blueprint then
        dfhack.println('[df-ai] Failed to load blueprint: ' .. tostring(blueprint))
        return
    end

    -- Load all room templates
    local templates = {}
    local instances = {}

    -- Build template file list from blueprint references
    -- The plan references room names like "generic01_start", "generic01_bedroom", etc.
    local function load_templates()
        local template_dirs = {
            'df-ai-blueprints/templates/generic01_start/',
            'df-ai-blueprints/templates/generic01_corridor/',
            'df-ai-blueprints/templates/generic01_corridor_stair/',
            'df-ai-blueprints/templates/generic01_bedroom/',
            'df-ai-blueprints/templates/generic01_dormitory/',
            'df-ai-blueprints/templates/generic01_dininghall/',
            'df-ai-blueprints/templates/generic01_nobleroom/',
            'df-ai-blueprints/templates/generic01_stockpile/',
            'df-ai-blueprints/templates/generic01_workshop_3x3/',
            'df-ai-blueprints/templates/generic01_workshop_5x5/',
            'df-ai-blueprints/templates/generic01_farmplot/',
            'df-ai-blueprints/templates/generic01_barracks/',
            'df-ai-blueprints/templates/generic01_infirmary/',
            'df-ai-blueprints/templates/generic01_jail/',
            'df-ai-blueprints/templates/generic01_cemetery/',
            'df-ai-blueprints/templates/generic01_location/',
            'df-ai-blueprints/templates/generic01_depot/',
            'df-ai-blueprints/templates/generic01_outpost_entrance/',
            'df-ai-blueprints/templates/generic01_mineshaft_segment/',
            'df-ai-blueprints/templates/generic01_pasture/',
            'df-ai-blueprints/templates/generic01_pitting_tower/',
            'df-ai-blueprints/templates/generic01_cage_trap/',
            'df-ai-blueprints/templates/generic01_outdoor_farm/',
            'df-ai-blueprints/templates/generic01_apiary/',
            'df-ai-blueprints/templates/generic01_well/',
            'df-ai-blueprints/templates/generic01_stair/',
        }
        -- Try each template dir
        for _, dir in ipairs(template_dirs) do
            local ok_dir, dir_handle = pcall(dfhack.filesystem.listdir, dir)
            if ok_dir then
                for _, fname in ipairs(dir_handle) do
                    if fname:match('%.json$') then
                        local ok_t, tmpl = pcall(json.decode_file, dir .. fname)
                        if ok_t and tmpl then
                            local name = fname:gsub('%.json$', '')
                            local key = dir:match('generic01_(%w+)') .. '/' .. name
                            templates[key] = tmpl
                        end
                    end
                end
            end
        end
    end

    pcall(load_templates)

    -- Load instance overrides
    local function load_instances()
        local instance_dirs = {
            'df-ai-blueprints/instances/generic01_start/',
            'df-ai-blueprints/instances/generic01_corridor_stair/',
            'df-ai-blueprints/instances/generic01_stair/',
            'df-ai-blueprints/instances/generic01_dormitory/',
            'df-ai-blueprints/instances/generic01_dininghall/',
            'df-ai-blueprints/instances/generic01_stockpile/',
            'df-ai-blueprints/instances/generic01_jail/',
            'df-ai-blueprints/instances/generic01_apiary/',
        }
        for _, dir in ipairs(instance_dirs) do
            local ok_dir, dir_handle = pcall(dfhack.filesystem.listdir, dir)
            if ok_dir then
                for _, fname in ipairs(dir_handle) do
                    if fname:match('%.json$') then
                        local ok_i, inst = pcall(json.decode_file, dir .. fname)
                        if ok_i and inst then
                            local name = fname:gsub('%.json$', '')
                            local key = dir:match('generic01_(%w+)') .. '/' .. name
                            instances[key] = inst
                        end
                    end
                end
            end
        end
    end

    pcall(load_instances)

    -- Now process the plan's rooms
    if blueprint.rooms then
        for _, r in ipairs(blueprint.rooms) do
            self:add_room_from_blueprint(r, templates, instances)
        end
    end

    dfhack.println('[df-ai] Loaded ' .. #self.rooms .. ' rooms from blueprint')
end

function Plan:add_room_from_blueprint(room_data, templates, instances)
    local room_type = room_data.type
    local pos = room_data.pos
    local size = room_data.size

    local rooms_mod = rooms_module
    if not rooms_mod then
        dfhack.println('[df-ai] rooms module not loaded')
        return
    end

    local r = rooms_mod.room.new(room_type,
        { x = pos.x, y = pos.y, z = pos.z },
        { x = pos.x + size.x - 1, y = pos.y + size.y - 1, z = pos.z + size.z - 1 },
        {
            level = room_data.level or 0,
            queue = room_data.queue or 0,
            comment = room_data.comment or '',
            outdoor = room_data.outdoor or false,
            temporary = room_data.temporary or false,
        }
    )

    -- Set subtype based on room type
    r.corridor_type = room_data.corridor_type or r.corridor_type
    r.farm_type = room_data.farm_type or r.farm_type
    r.stockpile_type = room_data.stockpile_type or r.stockpile_type
    r.nobleroom_type = room_data.nobleroom_type or r.nobleroom_type
    r.outpost_type = room_data.outpost_type or r.outpost_type
    r.location_type = room_data.location_type or r.location_type
    r.cistern_type = room_data.cistern_type or r.cistern_type
    r.workshop_type = room_data.workshop_type or r.workshop_type
    r.furnace_type = room_data.furnace_type or r.furnace_type

    -- Access path from blueprint
    if room_data.accesspath then
        r.accesspath = room_data.accesspath
    end

    -- Layout (furniture indices from blueprint)
    if room_data.layout then
        r.layout = room_data.layout
    end

    if r.type == 'corridor' then
        table.insert(self.corridors, r)
    end
    table.insert(self.rooms, r)
    if not self.room_category[r.type] then
        self.room_category[r.type] = {}
    end
    table.insert(self.room_category[r.type], r)
end

-- ============================================================
-- Task processing (generic queue, one per frame)
-- ============================================================

function Plan:start_processing_generic()
    -- Compute nrdig (max parallel dig operations per queue)
    self.nrdig = {}
    for _, t in ipairs(self.tasks_generic) do
        if (t.type == TASK_TYPE.dig_room or t.type == TASK_TYPE.dig_room_immediate) then
            local q = t.room.queue or 0
            self.nrdig[q] = (self.nrdig[q] or 0) + 1
        end
    end

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
                if t.room.is_dug and t.room:is_dug() then
                    self_ref:digroom(t.room)
                    del = true
                else
                    local q = t.room.queue or 0
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
            elseif t.type == TASK_TYPE.check_idle then
                -- pass
            end

            t.last_status = reason
            self_ref.bg_idx_generic = self_ref.bg_idx_generic + 1
        end
    end
end

function Plan:start_processing_furniture()
end

-- ============================================================
-- Plan setup / room placement
-- ============================================================

function Plan:initial_phase()
    local all_done = true
    for _, r in ipairs(self.rooms) do
        if r.status == 'plan' then
            -- Don't dig corridors yet; they connect AFTER rooms
            if r.type ~= 'corridor' then
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
    return true
end

-- ============================================================
-- Room checking
-- ============================================================

function Plan:checkrooms()
    if not self.past_initial_phase then
        self:initial_phase()
    end

    for _, r in ipairs(self.rooms) do
        self:checkroom(r)
    end
end

function Plan:checkroom(r)
    if r.status == 'designated' then
        if r:is_dug() then
            r.status = 'dug'
            self:construct_room(r)
        end
    elseif r.status == 'dug' then
        -- Check if construction is done
        if r:constructions_done() then
            r.status = 'finished'
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
            -- Special handling for walkable corridors
        end
    else
        -- Other room types: check for furniture
        self:add_task(TASK_TYPE.check_furnish, r)
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
            Craftsdwarf = df.workshop_type.Craftsdwarf,
            Masons = df.workshop_type.Masons,
            Carpenters = df.workshop_type.Carpenters,
            Smelters = df.workshop_type.Smelters,
            Forge = df.workshop_type.Forge,
            Bowyers = df.workshop_type.Bowyers,
            Jewelers = df.workshop_type.Jewelers,
            Tanners = df.workshop_type.Tanners,
            Dyers = df.workshop_type.Dyers,
            Mechanics = df.workshop_type.Mechanics,
            Siege = df.workshop_type.Siege,
            ScrewPress = df.workshop_type.ScrewPress,
            WoodFurnace = df.workshop_type.WoodFurnace,
            Ash = df.workshop_type.Ash,
            MagmaSmelter = df.workshop_type.MagmaSmelter,
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
            Kiln = df.furnace_type.Kiln,
        },
    },
}

function Plan:try_construct_workshop(r)
    if not r then return false end
    local pos = r:pos()
    local wt = r.workshop_type
    if not wt then return false end

    local type_name = nil
    for name, enum_val in pairs(BUILDING_TYPES.workshop.types) do
        if enum_val == wt then
            type_name = name
            break
        end
    end
    if not type_name then return false end

    local cmd = string.format('building/create-building %s %d %d %d', type_name, pos.x, pos.y, pos.z)
    dfhack.run_command(cmd)
    return true
end

function Plan:try_construct_furnace(r)
    if not r then return false end
    local pos = r:pos()
    local ft = r.furnace_type
    if not ft then return false end

    local type_name = nil
    for name, enum_val in pairs(BUILDING_TYPES.furnace.types) do
        if enum_val == ft then
            type_name = name
            break
        end
    end
    if not type_name then return false end

    local cmd = string.format('building/create-building %s %d %d %d', type_name, pos.x, pos.y, pos.z)
    dfhack.run_command(cmd)
    return true
end

function Plan:try_construct_stockpile(r)
    if not r then return false end
    local pos = r:pos()
    local cmd = string.format('building/create-building Stockpile %d %d %d', pos.x, pos.y, pos.z)
    dfhack.run_command(cmd)
    -- TODO: Set stockpile settings based on r.stockpile_type
    return true
end

function Plan:try_construct_farmplot(r)
    if not r then return false end
    local pos = r:pos()
    local cmd = string.format('building/create-building FarmPlot %d %d %d', pos.x, pos.y, pos.z)
    dfhack.run_command(cmd)
    return true
end

function Plan:try_construct_activityzone(r)
    if not r then return false end
    -- Activity zones: gather, pond, pit/pond, water source, pasture
    local pos = r:pos()
    -- Use zone plugin via DFHack command
    if r.type == 'pasture' or r.type == 'pond' then
        dfhack.run_command('zone set ' .. pos.x .. ' ' .. pos.y .. ' ' .. pos.z)
    end
    return true
end

function Plan:try_construct_tradedepot(r)
    if not r then return false end
    local pos = r:pos()
    local cmd = string.format('building/create-building TradeDepot %d %d %d', pos.x, pos.y, pos.z)
    dfhack.run_command(cmd)
    return true
end

function Plan:try_construct_windmill(r)
    if not r then return false end
    local pos = r:pos()
    local cmd = string.format('building/create-building Windmill %d %d %d', pos.x, pos.y, pos.z)
    dfhack.run_command(cmd)
    return true
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

    -- Map layout_type to building/create-building type name
    local name_map = {
        bed = 'Bed',
        chair = 'Chair',
        table = 'Table',
        door = 'Door',
        cabinet = 'Cabinet',
        chest = 'Chest',
        coffin = 'Coffin',
        statue = 'Statue',
        weapon_rack = 'WeaponRack',
        armor_stand = 'ArmorStand',
        cage = 'Cage',
        cage_trap = 'CageTrap',
        nest_box = 'NestBox',
        hive = 'Hive',
        offering_place = 'OfferingPlace',
        pedestal = 'Pedestal',
        traction_bench = 'TractionBench',
        floodgate = 'Floodgate',
        hatch = 'Hatch',
        gear_assembly = 'GearAssembly',
        lever = 'Lever',
        roller = 'Roller',
        track_stop = 'TrackStop',
        vertical_axle = 'VerticalAxle',
        archery_target = 'ArcheryTarget',
        restraint = 'Restraint',
        bookcase = 'Bookcase',
        well = 'Well',
    }

    local type_name = name_map[f.type]
    if not type_name then return false end

    local cmd = string.format('building/create-building %s %d %d %d', type_name, pos.x, pos.y, pos.z)
    dfhack.run_command(cmd)
    f.bld_id = -1  -- Will be updated by monitoring
    return true
end

-- ============================================================
-- Room assignment
-- ============================================================

function Plan:getbedroom(unit_id)
    -- Find or create a bedroom for unit
    if not self.ai.population then return end
    local rooms = self.room_category['bedroom']
    if not rooms then return end
    for _, r in ipairs(rooms) do
        if r.owner == unit_id then
            return r
        end
    end
    -- Find an unowned bedroom
    for _, r in ipairs(rooms) do
        if r.owner < 0 and r.status == 'finished' then
            r.owner = unit_id
            -- Assign room to unit via DF
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
    return table.concat(parts, '\n')
end

return Plan
