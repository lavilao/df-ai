--@module = true

local Population = {}
Population.__index = Population

function Population.new(ai)
    local o = {
        ai = ai,
        citizen = {},
        military = {},
        pet = {},
        pet_check = {},
        visitor = {},
        resident = {},
        military_min = 25,
        military_max = 75,
        update_counter = 0,
        seen_death = 0,
        medic = {},
        workers = {},
        seen_badwork = {},
        last_checked_crime_year = -1,
        last_checked_crime_tick = -1,
        did_trade = false,
        squad_order_changes = {},
    }
    setmetatable(o, Population)
    return o
end

function Population:startup()
    pcall(function()
        df.global.standing_orders_forbid_used_ammo = 0
    end)
end

function Population:update()
    self.update_counter = self.update_counter + 1
    local phase = self.update_counter % 10
    if phase == 0 then
        self:update_trading()
    elseif phase == 1 then
        self:update_citizenlist()
    elseif phase == 2 then
        self:update_jobs()
    elseif phase == 3 then
        self:update_deads()
    elseif phase == 4 then
        self:update_caged()
    elseif phase == 5 then
        self:update_military()
    elseif phase == 6 then
        self:update_crimes()
    elseif phase == 7 then
        self:update_nobles()
    elseif phase == 8 then
        self:update_pets()
    elseif phase == 9 then
        self:update_locations()
    end
end

function Population:deathwatch()
    local world = df.global.world
    if not world then return end
    local all = world.units.all
    if not all then return end

    local total_dead = 0
    for _, unit in ipairs(all) do
        if unit.flags1.dead then
            total_dead = total_dead + 1
        end
    end

    if total_dead ~= self.seen_death then
        self.seen_death = total_dead
        if self.ai.plan then
            self.ai.plan:getcoffin()
        end
    end
end

function Population:update_trading()
    local world = df.global.world
    if not world then return end
    local caravan = world.caravans
    if not caravan then return end
    for _, c in ipairs(caravan) do
        if c.time_remaining and c.time_remaining > 0 then
            if not self.did_trade then
                self.did_trade = true
                self:set_up_trading(true)
            end
            return
        end
    end
    if self.did_trade then
        self.did_trade = false
    end
end

function Population:update_citizenlist()
    local world = df.global.world
    if not world then return end
    local all = world.units.all
    if not all then return end

    local new_citizens = {}
    local new_military = {}

    for _, unit in ipairs(all) do
        if dfhack.units.isCitizen(unit, true) and dfhack.units.isAlive(unit) then
            if not dfhack.units.isActive(unit) then
                new_citizens[unit.id] = true
            end
            local squad_id = unit.military.squad_id
            if squad_id >= 0 then
                new_military[unit.id] = squad_id
            end
        end
    end

    self.citizen = new_citizens
    self.military = new_military
end

function Population:update_jobs()
    local world = df.global.world
    if not world then return end
    local jobs = world.jobs.list
    if not jobs then return end
    for _, job in ipairs(jobs) do
        if job.job_type == df.job_type.CollectWeapons or
           job.job_type == df.job_type.CollectArmor then
            local ref = dfhack.job.getGeneralRef(job, df.general_ref_type.CONTAINED_IN_ITEM)
            if ref then
                local item = ref:getItem()
                if item and item.flags.trader then
                    dfhack.run_command('forceremove')
                    break
                end
            end
        end
    end
end

function Population:update_deads()
end

function Population:update_caged()
end

function Population:update_military()
end

function Population:update_crimes()
end

function Population:update_nobles()
    if not self.ai.config.manage_nobles then return end
    if self.ai.plan then
        -- Assign nobles to rooms
    end
end

function Population:update_pets()
end

function Population:update_locations()
end

function Population:set_up_trading(should_trade)
    if not should_trade then
        return true
    end
    if self.ai.trade then
        return self.ai.trade:setup()
    end
    return false
end

function Population:perform_trade()
    if self.ai.trade then
        return self.ai.trade:perform()
    end
    return false
end

function Population:status()
    local parts = {}
    local citizen_count = 0
    for _ in pairs(self.citizen) do
        citizen_count = citizen_count + 1
    end
    table.insert(parts, '  Citizens: ' .. citizen_count)

    local mil_count = 0
    for _ in pairs(self.military) do
        mil_count = mil_count + 1
    end
    table.insert(parts, '  Military: ' .. mil_count)

    return table.concat(parts, '\n')
end

return Population
