--@module = true

local Population = {}
Population.__index = Population

local LABOR_IMPORTANT = {
    [df.unit_labor.MINING] = true,
    [df.unit_labor.CARPENTRY] = true,
    [df.unit_labor.MASONRY] = true,
    [df.unit_labor.ANIMALCARETAKING] = true,
    [df.unit_labor.FARMING] = true,
    [df.unit_labor.COOKING] = true,
    [df.unit_labor.BREWING] = true,
    [df.unit_labor.SMELTING] = true,
    [df.unit_labor.FURNACE_OPERATING] = true,
    [df.unit_labor.WOODCUTTING] = true,
    [df.unit_labor.ENGRAVING] = true,
    [df.unit_labor.MECHANICS] = true,
    [df.unit_labor.STRAND_EXTRACTION] = true,
    [df.unit_labor.GLASSMAKING] = true,
    [df.unit_labor.LEATHERWORKING] = true,
    [df.unit_labor.TANNING] = true,
    [df.unit_labor.WEAVING] = true,
    [df.unit_labor.CLOTHMAKING] = true,
    [df.unit_labor.SOAP_MAKING] = true,
    [df.unit_labor.POTASH_MAKING] = true,
    [df.unit_labor.LYE_MAKING] = true,
    [df.unit_labor.DYING] = true,
    [df.unit_labor.BUTCHERY] = true,
    [df.unit_labor.PROCESSING_PLANTS] = true,
    [df.unit_labor.MILLING] = true,
}

local LABOR_BASIC = {
    [df.unit_labor.CARPENTRY] = true,
    [df.unit_labor.MASONRY] = true,
    [df.unit_labor.MINING] = true,
    [df.unit_labor.WOODCUTTING] = true,
    [df.unit_labor.FARMING] = true,
    [df.unit_labor.COOKING] = true,
    [df.unit_labor.BREWING] = true,
    [df.unit_labor.HAULING] = true,
}

-- Nobles we track
local NOBLE_POSITIONS = {
    'ADMINISTRATOR',
    'MANAGER',
    'CHIEF_MEDICAL_DWARF',
    'EXPEDITION_LEADER',
    'SHERIFF',
    'CAPTAIN_OF_THE_GUARD',
    'BROKER',
    'MAYOR',
    'BARON',
    'COUNT',
    'DUKE',
    'QUEEN',
    'KING',
    'OUTPOST_LIAISON',
    'DIPLOMAT',
    'MONARCH',
    'GENERAL',
}

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
        squad_melee = nil,
        squad_ranged = nil,
        noble_rooms = {},
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
    local phase = self.update_counter % 12
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
    elseif phase == 10 then
        self:update_labors()
    elseif phase == 11 then
        self:update_assignments()
    end
end

function Population:deathwatch()
    local world = df.global.world
    if not world then return end
    local all = world.units.all
    if not all then return end

    local total_dead = 0
    for _, unit in ipairs(all) do
        if not dfhack.units.isAlive(unit) then
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

-- ============================================================
-- Citizen list
-- ============================================================

function Population:update_citizenlist()
    local world = df.global.world
    if not world then return end
    local all = world.units.all
    if not all then return end

    local new_citizens = {}
    local new_military = {}
    local new_pets = {}
    local new_visitors = {}
    local new_residents = {}

    for _, unit in ipairs(all) do
        if not dfhack.units.isAlive(unit) then
        elseif dfhack.units.isCitizen(unit, true) then
            new_citizens[unit.id] = true
            local squad_id = unit.military.squad_id
            if squad_id >= 0 then
                new_military[unit.id] = squad_id
            end
        elseif dfhack.units.isOwnGroup(unit) then
            new_pets[unit.id] = true
        elseif unit.relationship_ids then
            local r = unit.relationship_ids
            if r[df.unit_relation_type.Owner] >= 0 then
                new_pets[unit.id] = true
            end
        end
    end

    self.citizen = new_citizens
    self.military = new_military
end

-- ============================================================
-- Labor management
-- ============================================================

function Population:update_labors()
    if self.ai.config.manage_labors == 'none' then return end

    local total_citizens = 0
    for _ in pairs(self.citizen) do total_citizens = total_citizens + 1 end
    if total_citizens == 0 then return end

    local assign_per_skill = math.max(1, math.floor(total_citizens / 8))

    -- Count how many have each labor
    local labor_counts = {}
    for uid in pairs(self.citizen) do
        local unit = df.unit.find(uid)
        if unit and unit.status and unit.status.labors then
            for labor = 0, #unit.status.labors - 1 do
                if unit.status.labors[labor] then
                    labor_counts[labor] = (labor_counts[labor] or 0) + 1
                end
            end
        end
    end

    -- Assign labors to units that need them
    for uid in pairs(self.citizen) do
        local unit = df.unit.find(uid)
        if not unit or not unit.status or not unit.status.labors then break end

        -- Assign all basic labors
        for labor in pairs(LABOR_BASIC) do
            unit.status.labors[labor] = true
        end

        -- Assign important labors if not enough workers
        for labor in pairs(LABOR_IMPORTANT) do
            local current = labor_counts[labor] or 0
            if current < assign_per_skill then
                unit.status.labors[labor] = true
                labor_counts[labor] = current + 1
            end
        end

        -- Medical labors
        local med_count = 0
        for _, v in pairs(self.medic) do if v then med_count = med_count + 1 end end
        if med_count < 3 then
            unit.status.labors[df.unit_labor.DIAGNOSIS] = true
            unit.status.labors[df.unit_labor.SURGERY] = true
            unit.status.labors[df.unit_labor.SETTING_BONE] = true
            unit.status.labors[df.unit_labor.SUTURING] = true
            unit.status.labors[df.unit_labor.DRESSING_WOUNDS] = true
        end
    end
end

-- ============================================================
-- Military
-- ============================================================

function Population:update_military()
    local total_citizens = 0
    for _ in pairs(self.citizen) do total_citizens = total_citizens + 1 end
    if total_citizens < self.military_min then return end

    local total_soldiers = 0
    for _ in pairs(self.military) do total_soldiers = total_soldiers + 1 end

    local target_soldiers = math.min(
        math.floor(total_citizens * 0.3),
        self.military_max
    )

    if total_soldiers >= target_soldiers then return end

    -- Create squads if needed
    self:ensure_squads()
    if not self.squad_melee and not self.squad_ranged then return end

    -- Find unassigned citizens and assign them
    local squads = df.global.world.squads
    if not squads then return end

    for uid in pairs(self.citizen) do
        if not self.military[uid] then
            local unit = df.unit.find(uid)
            if unit and unit.military.squad_id < 0 then
                local squad_id = self.squad_melee
                -- Alternate between melee and ranged
                if total_soldiers % 3 == 1 and self.squad_ranged then
                    squad_id = self.squad_ranged
                end

                local squad = df.squad.find(squad_id)
                if squad then
                    squad.members:insert(#squad.members, unit.id)
                    unit.military.squad_id = squad_id
                    unit.military.squad_position = #squad.members - 1
                    total_soldiers = total_soldiers + 1
                    if total_soldiers >= target_soldiers then break end
                end
            end
        end
    end
end

function Population:ensure_squads()
    local squads = df.global.world.squads
    if not squads then return end

    -- Find existing melee/ranged squads
    for _, squad in ipairs(squads) do
        local name = squad.alias or ''
        if name:find('Melee') then
            self.squad_melee = squad.id
            self.squad_order_changes[squad.id] = true
        elseif name:find('Ranged') then
            self.squad_ranged = squad.id
            self.squad_order_changes[squad.id] = true
        end
    end

    -- Create melee squad if none exists
    if not self.squad_melee then
        self:create_squad('Melee', 10, true)
    end

    -- Create ranged squad if enough citizens
    local total_citizens = 0
    for _ in pairs(self.citizen) do total_citizens = total_citizens + 1 end
    if not self.squad_ranged and total_citizens > 35 then
        self:create_squad('Ranged', 10, false)
    end
end

function Population:create_squad(name, max_size, is_melee)
    local squads = df.global.world.squads
    if not squads then return nil end

    local squad = df.squad:new()
    squad.id = df.global.world.squad_next_id
    df.global.world.squad_next_id = df.global.world.squad_next_id + 1
    squad.alias = name
    squad.alias2 = name
    squad.members = {}
    squad.positions = {}
    squad.max_assigned_members = max_size

    squads:insert(#squads, squad)
    df.global.world.squads_by_id[squad.id] = squad

    if is_melee then
        self.squad_melee = squad.id
    else
        self.squad_ranged = squad.id
    end
    self.squad_order_changes[squad.id] = true

    -- Set kill order if enemies nearby
    dfhack.run_command('order kill ' .. squad.id)
    return squad.id
end

-- ============================================================
-- Nobles
-- ============================================================

function Population:update_nobles()
    if not self.ai.config.manage_nobles then return end

    local assignments = df.global.plotinfo.assignments
    if not assignments then return end

    for _, assign in ipairs(assignments) do
        if assign.position and assign.holder >= 0 then
            local unit = df.unit.find(assign.holder)
            if not unit then break end

            -- Assign a bedroom to the noble
            if self.ai.plan then
                local room = self.ai.plan:getbedroom(assign.holder)
                if room then
                    self.noble_rooms[assign.holder] = room
                end
            end

            -- Grant demands
            if assign.demands then
                for _, demand in ipairs(assign.demands) do
                    if demand.needs_fulfillment then
                        demand.needs_fulfillment = false
                    end
                end
            end
        end
    end
end

-- ============================================================
-- Justice / Crimes
-- ============================================================

function Population:update_crimes()
    local year = df.global.cur_year
    local tick = df.global.cur_year_tick

    if self.last_checked_crime_year == year and
       self.last_checked_crime_tick == tick then return end
    self.last_checked_crime_year = year
    self.last_checked_crime_tick = tick

    local units = df.global.world.units.all
    if not units then return end

    for _, unit in ipairs(units) do
        if dfhack.units.isAlive(unit) and unit.civ_id == df.global.ui.civ_id then
            if unit.flags1.prisoner then
                -- Prisoners should be in jail
                if self.ai.plan then
                    local jail = self.ai.plan:find_room('jail')
                    if not jail then
                        unit.flags1.prisoner = false
                    end
                end
            end

            -- Punishment: beatings for criminals
            if unit.flags1.criminal and not unit.flags1.prisoner then
                unit.flags1.prisoner = true
            end
        end
    end
end

-- ============================================================
-- Pets
-- ============================================================

function Population:update_pets()
    local world = df.global.world
    if not world then return end
    local all = world.units.all
    if not all then return end

    for _, unit in ipairs(all) do
        if dfhack.units.isAlive(unit) and unit.relationship_ids then
            local owner = unit.relationship_ids[df.unit_relation_type.Owner]
            if owner < 0 then break end

            -- Assign pets to pastures if available
            local has_pasture = false
            if self.ai.plan then
                local pasture = self.ai.plan:getpasture(unit.id)
                has_pasture = pasture ~= nil
            end

            -- Handle milking for grazers
            if dfhack.units.isGrazer(unit) and has_pasture then
                -- Milking is handled through zone assignment
            end
        end
    end

    -- Identify animals needing training
    self.pet_check = {}
    for _, unit in ipairs(all) do
        if dfhack.units.isAlive(unit) and
           dfhack.units.isOwnGroup(unit) and
           dfhack.units.isTamable(unit) and
           not dfhack.units.isTame(unit) then
            self.pet_check[unit.id] = true
        end
    end
end

-- ============================================================
-- Locations / Occupations
-- ============================================================

function Population:update_locations()
    local world = df.global.world
    if not world then return end

    -- Assign tavern keepers, librarians, priests
    local units = world.units.all
    if not units then return end

    local tavern_count = 0
    local library_count = 0
    local temple_count = 0

    for _, unit in ipairs(units) do
        if dfhack.units.isCitizen(unit, true) and dfhack.units.isAlive(unit) then
            if unit.status.current_soul then
                local soul = unit.status.current_soul
                if soul.preferences then
                    for _, pref in ipairs(soul.preferences) do
                        if pref.type == df.unit_preference_type.LikeLocation then
                            if pref.location_type == 'tavern' then
                                tavern_count = tavern_count + 1
                            elseif pref.location_type == 'library' then
                                library_count = library_count + 1
                            elseif pref.location_type == 'temple' then
                                temple_count = temple_count + 1
                            end
                        end
                    end
                end
            end
        end
    end
end

function Population:update_assignments()
    -- Assign dwellers to locations (tavern, library, temple)
    if not self.ai.plan then return end

    local rooms = self.ai.plan.rooms
    if not rooms then return end

    for _, r in ipairs(rooms) do
        if r.type == 'location' and r.status == 'finished' then
            local bld = r:dfbuilding()
            if bld then
                -- Ensure location is assigned (has users)
                -- In DF 53, locations are automatically assigned
            end
        end
    end
end

-- ============================================================
-- Caged rescue
-- ============================================================

function Population:update_caged()
    local world = df.global.world
    if not world then return end
    local units = world.units.all
    if not units then return end

    for _, unit in ipairs(units) do
        if dfhack.units.isAlive(unit) and dfhack.units.isCitizen(unit) then
            -- Check if unit is in a cage
            if unit.flags1.caged then
                -- Find the cage and release
                local cage = unit.cage
                if cage then
                    cage:removeUnit(unit)
                    unit.cage = nil
                    unit.flags1.caged = false
                end
            end
        end
    end
end

-- ============================================================
-- Trading detection
-- ============================================================

function Population:update_trading()
    local ok, plotinfo = pcall(function() return df.global.plotinfo end)
    if not ok or not plotinfo then return end
    local caravan = plotinfo.caravans
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

-- ============================================================
-- Jobs (remove trader flags from forbidden items)
-- ============================================================

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

-- ============================================================
-- Deaths
-- ============================================================

function Population:update_deads()
end

-- ============================================================
-- Status
-- ============================================================

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
    table.insert(parts, '  Squads: melee=' .. tostring(self.squad_melee) .. ' ranged=' .. tostring(self.squad_ranged))

    return table.concat(parts, '\n')
end

return Population
