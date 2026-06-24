local Plan = {}
Plan.__index = Plan

local TASK_TYPES = {
    check_rooms = 0,
    dig = 1,
    construct = 2,
    furnish = 3,
    smooth = 4,
    cistern = 5,
}

function Plan.new(ai)
    local o = {
        ai = ai,
        tasks = {},
        rooms = {},
        corridors = {},
        room_category = {},
        important_workshops = {
            df.workshop_type.Butchers,
            df.workshop_type.Quern,
            df.workshop_type.Farmers,
            df.workshop_type.Kitchen,
            df.workshop_type.Still,
            df.workshop_type.Loom,
            df.workshop_type.Clothiers,
            df.workshop_type.Leatherworks,
            df.workshop_type.Craftsdwarf,
            df.workshop_type.Masons,
            df.workshop_type.Carpenters,
            df.workshop_type.Smelters,
            df.workshop_type.Forge,
            df.workshop_type.Bowyers,
            df.workshop_type.Jewelers,
            df.workshop_type.Tanners,
            df.workshop_type.Dyers,
            df.workshop_type.WoodFurnace,
            df.workshop_type.Ash,
            df.workshop_type.ScrewPress,
            df.workshop_type.Siege,
            df.workshop_type.Mechanics,
            df.workshop_type.Still,
            df.workshop_type.MagmaSmelter,
            df.workshop_type.MagmaForge,
        },
        past_initial_phase = false,
        should_search_for_metal = false,
    }
    setmetatable(o, Plan)
    return o
end

function Plan:startup()
    self:load_blueprint()
    self.past_initial_phase = false
    self.should_search_for_metal = true
end

function Plan:load_blueprint()
    local ok, blueprint = pcall(require('json').decode_file, 'df-ai-blueprints/plans/generic01.json')
    if ok and blueprint then
        -- Process blueprint rooms
        if blueprint.rooms then
            for _, r in ipairs(blueprint.rooms) do
                self:add_room(r)
            end
        end
    end
end

function Plan:add_room(room_data)
    local room = {
        type = room_data.type,
        pos = room_data.pos,
        size = room_data.size,
        min = { x = room_data.pos.x, y = room_data.pos.y, z = room_data.pos.z },
        max = {
            x = room_data.pos.x + room_data.size.x - 1,
            y = room_data.pos.y + room_data.size.y - 1,
            z = room_data.pos.z + room_data.size.z - 1,
        },
        status = 'plan',
        owner = -1,
        bld_id = -1,
        squad_id = -1,
        level = room_data.level or 0,
        queue = room_data.queue or 0,
        comment = room_data.comment or '',
        furnished = false,
        temporary = false,
        outdoor = false,
        channeled = false,
    }
    table.insert(self.rooms, room)
    if not self.room_category[room.type] then
        self.room_category[room.type] = {}
    end
    table.insert(self.room_category[room.type], room)
end

function Plan:update()
    if not self.past_initial_phase then
        self:initial_phase()
    end
    self:check_rooms()
    self:process_tasks()
end

function Plan:initial_phase()
    local all_done = true
    for _, room in ipairs(self.rooms) do
        if room.status == 'plan' then
            room.status = 'dig'
            self:add_dig_task(room)
            all_done = false
        end
    end
    if all_done then
        self.past_initial_phase = true
    end
end

function Plan:add_dig_task(room)
    local task = {
        type = TASK_TYPES.dig,
        room = room,
        status = 'pending',
    }
    table.insert(self.tasks, task)
end

function Plan:check_rooms()
    for _, room in ipairs(self.rooms) do
        self:check_room(room)
    end
end

function Plan:check_room(room)
    if room.status == 'dig' then
        -- Check if digging is complete
        local all_dug = true
        for x = room.min.x, room.max.x do
            for y = room.min.y, room.max.y do
                local tile = dfhack.maps.getTileBlock({x = x, y = y, z = room.min.z})
                if tile then
                    local designation = tile.designation[x % 16][y % 16]
                    if designation and designation.dig ~= df.tile_dig_designation.No then
                        all_dug = false
                        break
                    end
                end
            end
            if not all_dug then break end
        end
        if all_dug then
            room.status = 'finished'
        end
    end
end

function Plan:process_tasks()
    local tasks_to_remove = {}
    for i, task in ipairs(self.tasks) do
        if task.type == TASK_TYPES.dig then
            self:execute_dig(task)
            tasks_to_remove[i] = true
        end
    end
    for i in pairs(tasks_to_remove) do
        self.tasks[i] = nil
    end
end

function Plan:execute_dig(task)
    local room = task.room
    if not room then return end

    for x = room.min.x, room.max.x do
        for y = room.min.y, room.max.y do
            local pos = { x = x, y = y, z = room.min.z }
            local tile = dfhack.maps.getTileBlock(pos)
            if tile then
                local des = tile.designation[x % 16][y % 16]
                if des and des.dig == df.tile_dig_designation.No then
                    des.dig = df.tile_dig_designation.Default
                end
            end
        end
    end
    task.status = 'done'
end

function Plan:getcoffin()
    -- Placeholder: will be expanded
end

function Plan:getbedroom(id)
    -- Placeholder: find or create a bedroom for unit id
end

function Plan:status()
    local parts = {}
    table.insert(parts, '  Rooms: ' .. #self.rooms)
    table.insert(parts, '  Tasks: ' .. #self.tasks)
    table.insert(parts, '  Past initial phase: ' .. tostring(self.past_initial_phase))
    return table.concat(parts, '\n')
end

return Plan
