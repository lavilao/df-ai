--@module = true

local Population = {}
Population.__index = Population

local compat = dfhack.run_script_with_env(nil, 'df-ai/compat', {module = true})

-- Resolved lazily by update_crimes: true only when the 0.47-era
-- unit_flags1.prisoner/.criminal bits still exist on this DF version.
local JUSTICE_FLAGS_OK = nil

local LABOR_IMPORTANT = {
    [df.unit_labor.MINE] = true,
    [df.unit_labor.CARPENTER] = true,
    [df.unit_labor.MASON] = true,
    [df.unit_labor.ANIMALCARE] = true,
    [df.unit_labor.PLANT] = true,
    [df.unit_labor.COOK] = true,
    [df.unit_labor.BREWER] = true,
    [df.unit_labor.SMELT] = true,
    [df.unit_labor.ENGRAVER] = true,
    [df.unit_labor.MECHANIC] = true,
    [df.unit_labor.EXTRACT_STRAND] = true,
    [df.unit_labor.GLASSMAKER] = true,
    [df.unit_labor.LEATHER] = true,
    [df.unit_labor.TANNER] = true,
    [df.unit_labor.WEAVER] = true,
    [df.unit_labor.CLOTHESMAKER] = true,
    [df.unit_labor.SOAP_MAKER] = true,
    [df.unit_labor.POTASH_MAKING] = true,
    [df.unit_labor.LYE_MAKING] = true,
    [df.unit_labor.DYER] = true,
    [df.unit_labor.BUTCHER] = true,
    [df.unit_labor.PROCESS_PLANT] = true,
    [df.unit_labor.MILLER] = true,
    [df.unit_labor.CUTWOOD] = true,
    [df.unit_labor.STONECUTTER] = true,
}

local LABOR_BASIC = {
    [df.unit_labor.CARPENTER] = true,
    [df.unit_labor.MASON] = true,
    [df.unit_labor.MINE] = true,
    [df.unit_labor.CUTWOOD] = true,
    [df.unit_labor.PLANT] = true,
    [df.unit_labor.COOK] = true,
    [df.unit_labor.BREWER] = true,
    [df.unit_labor.HAUL_STONE] = true,
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
        -- uids still waiting for a bedroom/dining spot (r3.9 citizen diff)
        _pending_rooms = {},
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

-- r3.9: cached citizen count for the population-scaled stocks quotas
-- (Stocks::num_needed calls this on every Watch key; counting the
-- table with pairs() 60+ times per audit was wasteful). The cache is
-- invalidated by update_citizenlist.
function Population:citizen_count()
    if self._citizen_count == nil then
        local n = 0
        for _ in pairs(self.citizen) do n = n + 1 end
        self._citizen_count = n
    end
    return self._citizen_count
end

-- ============================================================
-- Citizen list
-- ============================================================

function Population:update_citizenlist()
    local world = df.global.world
    if not world then return end
    local all = world.units.all
    if not all then return end

    -- r3.9 (C++ update_citizenlist parity): DIFF the citizen set. Every
    -- newly-seen citizen goes through plan:new_citizen (dining spot +
    -- bedroom + jail cells), every vanished one through plan:del_citizen
    -- (frees the rooms). This was dropped in the r3.4 port — migrants
    -- NEVER got bedrooms and dead dwarves kept theirs forever. It is
    -- also what produces the old build's post-load
    -- "assign bedroom (owned by ...)" burst: the first scan after a
    -- (re)load treats every citizen as new and re-issues the rooms.
    local old = self.citizen or {}

    local new_citizens = {}
    local new_military = {}
    local new_pets = {}
    local new_visitors = {}
    local new_residents = {}

    for _, unit in ipairs(all) do
        if not dfhack.units.isAlive(unit) then
        elseif dfhack.units.isCitizen(unit, true) then
            -- C++ skips babies (they share the mother's room via the
            -- DF bug 5551 workaround); children DO get their own rooms
            local is_baby = false
            pcall(function()
                is_baby = dfhack.units.isBaby(unit)
                    or unit.profession == df.profession.BABY
            end)
            if not is_baby then
                new_citizens[unit.id] = true
                local squad_id = unit.military.squad_id
                if squad_id >= 0 then
                    new_military[unit.id] = squad_id
                end
            end
        elseif dfhack.units.isOwnGroup(unit) then
            new_pets[unit.id] = true
        elseif unit.relationship_ids then
            local r = unit.relationship_ids
            if r[df.unit_relationship_type.PetOwner] >= 0 then
                new_pets[unit.id] = true
            end
        end
    end

    -- room bookkeeping BEFORE overwriting the sets (plan:del_citizen
    -- needs to know who is gone)
    local plan = self.ai and self.ai.plan
    if plan then
        for uid in pairs(old) do
            if not new_citizens[uid] then
                pcall(function() plan:del_citizen(uid) end)
                self._pending_rooms[uid] = nil
            end
        end
        for uid in pairs(new_citizens) do
            if not old[uid] then
                self._pending_rooms[uid] = true
            end
        end
        -- (re)assign rooms for every citizen that still needs them.
        -- Retried each scan because the blueprint rooms may not exist
        -- yet on the very first scan after embark (plan setup still
        -- running). plan:new_citizen is idempotent: getbedroom returns
        -- early for an already-owned room, getdiningroom skips units
        -- that already have a table/chair/farm rights.
        local pending = self._pending_rooms
        for uid in pairs(pending) do
            if not new_citizens[uid] then
                pending[uid] = nil -- gone; nothing to assign anymore
            else
                local ok_a, got = pcall(function()
                    plan:new_citizen(uid)
                    -- consider it done once the dwarf owns a bedroom
                    for _, r in ipairs(plan.room_category['bedroom'] or {}) do
                        if r.owner == uid then return true end
                    end
                    return false
                end)
                if ok_a and got then
                    pending[uid] = nil
                elseif not ok_a then
                    dfhack.printerr('[df-ai:population] room assignment '
                        .. 'failed for unit ' .. tostring(uid) .. ': '
                        .. tostring(got))
                    pending[uid] = nil -- do not spam errors every scan
                end
            end
        end
    end

    self.citizen = new_citizens
    self._citizen_count = nil -- invalidate the stocks quota cache
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
            unit.status.labors[df.unit_labor.DIAGNOSE] = true
            unit.status.labors[df.unit_labor.SURGERY] = true
            unit.status.labors[df.unit_labor.BONE_SETTING] = true
            unit.status.labors[df.unit_labor.SUTURING] = true
            unit.status.labors[df.unit_labor.DRESSING_WOUNDS] = true
        end
    end
end

-- ============================================================
-- Military (population_military.cpp port, r3.8)
--
-- The C++ drove the military screen UI; the 53.16 port works on the
-- structs directly, using the DFHack Military module
-- (dfhack.military.makeSquad/addToSquad/removeFromSquad — verified
-- present in 53.16-r3) for the complex squad wiring.
--
-- Policy (identical to the C++):
--   * target: 25% of citizens under arms (military_limit [25, 75])
--   * squads sized 10/8/6/4 by the total soldier count
--   * every 3rd squad is ranged ("Heavy ranged" uniform; the rest
--     "Heavy melee": metal armor + shield + weapon, exact matches,
--     worn OVER clothing)
--   * draft the LOWEST-XP adults first (craftsmen keep working);
--     dismiss the HIGHEST-XP soldiers first
--   * exemptions: children/babies, strange moods, nobles, and dwarves
--     with the MINE/CUTWOOD/HUNT labors (tool conflicts)
--   * mercenary residents are ALWAYS welcome in squads
--   * kill orders: megabeasts → every squad; undead/invaders → the
--     least-busy squad (see df-ai.lua tag_enemies)
--   * constant-training routine once a barracks exists
-- ============================================================

-- the player's fort entity (dfhack.military.makeSquad's own lookup:
-- the site government entity; falls back to the fortress entity)
local function fort_entity()
    local ok, ent = pcall(function()
        local gid = df.global.plotinfo.group_id
        return df.historical_entity.find(gid)
    end)
    if ok and ent then return ent end
    local ok2, ent2 = pcall(function()
        return df.global.plotinfo.main.fortress_entity
    end)
    if ok2 then return ent2 end
    return nil
end

-- all squads of the fort entity (C++ ui->main.fortress_entity->squads)
local function fort_squads(ent)
    if not ent then return {} end
    local out = {}
    local ok = pcall(function()
        for _, sid in ipairs(ent.squads) do
            local sq = df.squad.find(sid)
            if sq then table.insert(out, sq) end
        end
    end)
    return out
end

-- total XP of a unit (C++ unit_totalxp: 400*r + 100*r*(r+1)/2 + exp)
function Population.unit_totalxp(u)
    local ok, t = pcall(function()
        local sum = 0
        local soul = u.status and u.status.current_soul
        if not soul then return 0 end
        for _, sk in ipairs(soul.skills) do
            local r = sk.rating or 0
            sum = sum + 400 * r + 100 * r * (r + 1) / 2 + (sk.experience or 0)
        end
        return sum
    end)
    return ok and t or 0
end

-- noble positions of a unit (C++ Units::getNoblePositions)
local function unit_noble_positions(u)
    local out = {}
    local ok = pcall(function()
        local hf = df.historical_figure.find(u.hist_figure_id)
        if not hf then return end
        for _, link in ipairs(hf.entity_links) do
            if link:getType() == df.histfig_entity_link_type.POSITION then
                local ent = df.historical_entity.find(link.entity_id)
                if ent then
                    for _, asn in ipairs(ent.positions.assignments) do
                        if asn.id == link.assignment_id then
                            for _, pos in ipairs(ent.positions.own) do
                                if pos.id == asn.position_id then
                                    table.insert(out, { entity = ent, assignment = asn, position = pos })
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    return out
end

-- responsibility check for a unit's positions
local function unit_has_responsibility(u, resp)
    for _, np in ipairs(unit_noble_positions(u)) do
        local ok, has = pcall(function()
            return np.position.responsibilities[resp] == true
        end)
        if ok and has then return true end
    end
    return false
end

-- is a fresh migrant? (C++ skips the whole military update while
-- migrants are still arriving)
local function unit_is_new_migrant(u)
    local ok, res = pcall(function()
        for _, trait in ipairs(u.status.misc_traits) do
            if trait.id == df.misc_trait_type.Migrant then
                return true
            end
        end
        return false
    end)
    return ok and res or false
end

-- "Heavy melee"/"Heavy ranged" uniform (C++ SelectOrCreateUniform).
-- v50 uniforms live on each squad_position.equipment: one metal-armor
-- spec per slot + an individual-choice weapon, exact matches, worn
-- over clothing.
local function apply_squad_uniform(squad, ranged)
    local IT = df.item_type
    local UC = df.uniform_category
    local MC = df.entity_material_category
    local specs = {
        { UC.body,   IT.ARMOR },
        { UC.head,   IT.HELM },
        { UC.pants,  IT.PANTS },
        { UC.gloves, IT.GLOVES },
        { UC.shoes,  IT.SHOES },
        { UC.shield, IT.SHIELD },
    }
    pcall(function()
        squad.alias = ranged and 'Heavy ranged' or 'Heavy melee'
    end)
    for _, pos in ipairs(squad.positions or {}) do
        pcall(function()
            local eq = pos.equipment
            eq.flags.replace_clothing = false
            eq.flags.exact_matches = true
            for _, s in ipairs(specs) do
                local spec = df.squad_uniform_spec:new()
                spec.item_type = s[2]
                spec.item_subtype = -1
                spec.material_class = MC.Armor
                eq.uniform[s[1]]:insert('#', spec)
            end
            local wspec = df.squad_uniform_spec:new()
            wspec.item_type = IT.WEAPON
            wspec.item_subtype = -1
            wspec.material_class = MC.None
            if ranged then
                wspec.indiv_choice.ranged = true
            else
                wspec.indiv_choice.melee = true
            end
            eq.uniform[UC.weapon]:insert('#', wspec)
        end)
    end
    -- ranged squads carry combat ammo (C++ squad_ammo_spec; metal bolts)
    if ranged then
        pcall(function()
            local ammo = df.squad_ammo_spec:new()
            ammo.item_type = IT.AMMO
            ammo.item_subtype = -1
            ammo.material_class = MC.Ammo
            squad.ammo.ammunition:insert('#', ammo)
        end)
    end
end

-- find or create a vacant militia-captain-class assignment and build a
-- squad on it (dfhack.military.makeSquad does the heavy wiring:
-- positions, schedules for every routine incl. constant training,
-- world state). Returns the squad or nil.
function Population:create_squad(squad_size)
    local ent = fort_entity()
    if not ent then return nil end
    if not dfhack.military or not dfhack.military.makeSquad then
        return nil
    end

    -- a militia-leadership position (squad_size > 0) with a VACANT,
    -- squad-less assignment
    local function is_militia_position(pos)
        local ok, sz = pcall(function() return pos.squad_size end)
        return ok and sz and sz > 0
    end

    local candidate_asn = nil
    local ok_scan = pcall(function()
        for _, asn in ipairs(ent.positions.assignments) do
            if asn.squad_id == -1 and asn.histfig == -1 then
                for _, pos in ipairs(ent.positions.own) do
                    if pos.id == asn.position_id and is_militia_position(pos) then
                        candidate_asn = asn
                        break
                    end
                end
                if candidate_asn then break end
            end
        end
    end)
    if not ok_scan then return nil end

    -- no vacant assignment: clone a "militia captain" position + a
    -- fresh assignment (what the v50 military screen does when you
    -- create squad #2+). makeSquad only reads position.squad_size and
    -- ids from these, so a curated clone is sufficient.
    if not candidate_asn then
        local template
        pcall(function()
            for _, pos in ipairs(ent.positions.own) do
                if is_militia_position(pos) then
                    template = template or pos
                end
            end
        end)
        if not template then return nil end
        local ok_new = pcall(function()
            local pos = df.entity_position:new()
            pos.id = ent.positions.next_position_id
            ent.positions.next_position_id = ent.positions.next_position_id + 1
            pos.code = 'MILITARY_CAPTAIN'
            pos.name[0] = 'militia captain'
            pos.name[1] = 'militia captains'
            pos.squad[0] = 'squad'
            pos.squad[1] = 'squads'
            pos.squad_size = 10
            pos.precedence = 180
            pos.number = 2
            pos.execution_skill = df.job_skill.AXE
            pcall(function() pos.appointed_by:insert('#', template.id) end)
            ent.positions.own:insert('#', pos)

            local asn = df.entity_position_assignment:new()
            asn.id = ent.positions.next_assignment_id
            ent.positions.next_assignment_id = ent.positions.next_assignment_id + 1
            asn.histfig = -1
            asn.histfig2 = -1
            asn.position_id = pos.id
            asn.squad_id = -1
            asn.temp = -1
            ent.positions.assignments:insert('#', asn)
            candidate_asn = asn
        end)
        if not ok_new or not candidate_asn then return nil end
    end

    local ok_ms, squad = pcall(dfhack.military.makeSquad, candidate_asn.id)
    if not ok_ms or not squad then
        return nil
    end
    self:_log_military('created squad ' .. tostring(squad.id)
        .. ' (assignment ' .. candidate_asn.id .. ')')
    return squad
end

-- appoint a unit as a squad's LEADER (the captain/commander): wire the
-- position assignment + entity link + squad position 0 + unit fields.
-- (dfhack.military.addToSquad refuses position 0 — leaders are
-- appointed through their position assignment instead.)
local function appoint_squad_leader(ent, assignment, squad, unit)
    local ok = pcall(function()
        local hf = df.historical_figure.find(unit.hist_figure_id)
        if not hf then error('no historical figure') end
        if assignment.histfig ~= -1 and assignment.histfig ~= hf.id then
            error('assignment already held')
        end
        assignment.histfig = hf.id
        assignment.histfig2 = hf.id

        local link = df.histfig_entity_link_positionst:new()
        link.entity_id = ent.id
        link.assignment_id = assignment.id
        link.start_year = df.global.cur_year
        link.link_strength = 100
        hf.entity_links:insert('#', link)

        local pos0 = squad.positions[0]
        if pos0 then
            pos0.occupant = hf.id
        end
        unit.military.squad_id = squad.id
        unit.military.squad_position = 0

        -- equipment update flags (addToSquad parity)
        local F = df.equipment_update
        local mask = F.mask_weapon + F.mask_armor + F.mask_shoes
            + F.mask_shield + F.mask_helm + F.mask_gloves + F.mask_ammo
            + F.mask_pants + F.mask_backpack + F.mask_quiver + F.mask_flask
        squad.ammo.update.whole = squad.ammo.update.whole | mask
        df.global.plotinfo.equipment.update.whole =
            df.global.plotinfo.equipment.update.whole | mask
    end)
    return ok
end

-- squad the C++ Draft would pick: the first squad with a free position
-- (like find_good_squad). Ranged squads only take ranged drafts.
local function squad_free_positions(squad)
    local n = 0
    for _, pos in ipairs(squad.positions or {}) do
        if pos.occupant == -1 then n = n + 1 end
    end
    return n
end

-- C++ Draft::Run per unit — pick a squad (create when needed) and
-- draft the unit into it.
function Population:draft_unit(unit, squad_size, want_ranged)
    local ent = fort_entity()
    if not ent then return false end

    local squads = fort_squads(ent)
    local squad
    for _, sq in ipairs(squads) do
        local is_ranged = false
        pcall(function() is_ranged = sq.alias == 'Heavy ranged' end)
        if want_ranged == is_ranged and squad_free_positions(sq) > 0 then
            squad = sq
            break
        end
    end
    if not squad then
        -- any squad with room, regardless of flavor
        for _, sq in ipairs(squads) do
            if squad_free_positions(sq) > 0 then
                squad = sq
                break
            end
        end
    end

    local created = false
    if not squad then
        squad = self:create_squad(squad_size)
        if not squad then return false end
        created = true
    end

    local is_ranged = false
    pcall(function() is_ranged = squad.alias == 'Heavy ranged' end)
    if created or not squad.uniform_ready then
        apply_squad_uniform(squad, is_ranged or want_ranged)
        squad.uniform_ready = true
    end

    -- leader slot empty? the first draftee becomes the captain
    local pos0 = squad.positions and squad.positions[0]
    local leader_needed = pos0 and pos0.occupant == -1
    if leader_needed then
        local asn
        pcall(function()
            for _, a in ipairs(ent.positions.assignments) do
                if a.squad_id == squad.id then
                    asn = a
                    break
                end
            end
        end)
        if asn and appoint_squad_leader(ent, asn, squad, unit) then
            self:_log_military('unit ' .. unit.id .. ' now leads squad '
                .. squad.id)
            return true
        end
        -- fall through to a normal slot if the appointment failed
    end

    local ok_add, res = pcall(dfhack.military.addToSquad, unit.id, squad.id, -1)
    if ok_add and res then
        self:_log_military('unit ' .. unit.id .. ' drafted into squad '
            .. squad.id)
        return true
    end
    return false
end

-- C++ Dismiss::Run — remove a unit from its squad.
function Population:dismiss_unit(unit)
    local ok, res = pcall(dfhack.military.removeFromSquad, unit.id)
    if ok and res then
        self:_log_military('unit ' .. unit.id .. ' dismissed from the military')
        return true
    end
    return false
end

-- kill-order bookkeeping (C++ squad_order_changes + the
-- MilitarySquadAttackExclusive screen driver — replaced by direct
-- squad_order_kill_listst management, no UI needed)
function Population:military_squad_attack_unit(squad, unit, reason)
    if dfhack.units.isOwnCiv(unit) then
        return false
    end
    -- already ordered to kill this unit?
    for _, order in ipairs(squad.orders or {}) do
        if df.squad_order_kill_listst:is_instance(order) then
            for _, uid in ipairs(order.units) do
                if uid == unit.id then return false end
            end
        end
    end
    local ok, err = pcall(function()
        -- one consolidated kill list per squad (like the UI)
        local kill_order
        for _, order in ipairs(squad.orders) do
            if df.squad_order_kill_listst:is_instance(order) then
                kill_order = order
                break
            end
        end
        if not kill_order then
            kill_order = df.squad_order_kill_listst:new()
            kill_order.year = df.global.cur_year
            kill_order.year_tick = df.global.cur_year_tick
            squad.orders:insert('#', kill_order)
        end
        kill_order.units:insert('#', unit.id)
        local hf = unit.hist_figure_id
        if hf and hf >= 0 then
            kill_order.histfigs:insert('#', hf)
        end
    end)
    if ok then
        self:_log_military('squad ' .. squad.id .. ' ordered to kill unit '
            .. unit.id .. ' (' .. tostring(reason) .. ')')
        return true
    end
    dfhack.printerr('[df-ai] kill order failed: ' .. tostring(err))
    return false
end

function Population:military_cancel_attack_order(squad, unit, reason)
    local changed = false
    local ok, err = pcall(function()
        for li = #squad.orders - 1, 0, -1 do
            local order = squad.orders[li]
            if df.squad_order_kill_listst:is_instance(order) then
                for ui = #order.units - 1, 0, -1 do
                    if order.units[ui] == unit.id then
                        order.units:erase(ui)
                        if #order.histfigs > ui then
                            order.histfigs:erase(ui)
                        end
                        changed = true
                    end
                end
                -- drop empty kill orders entirely
                if #order.units == 0 then
                    squad.orders:erase(li)
                end
            end
        end
    end)
    if ok and changed then
        self:_log_military('squad ' .. squad.id .. ' kill order for unit '
            .. unit.id .. ' cancelled (' .. tostring(reason) .. ')')
    end
    return changed
end

-- C++ military_random_squad_attack_unit — the squad with the fewest
-- occupants busy, no existing order on this unit, and the smallest
-- total kill list.
function Population:military_random_squad_attack_unit(unit, reason)
    local ent = fort_entity()
    if not ent then return false end
    local best, best_score
    for _, sq in ipairs(fort_squads(ent)) do
        local score = 0
        local killing_this = false
        local total_targets = 0
        pcall(function()
            for _, pos in ipairs(sq.positions or {}) do
                if pos.occupant ~= -1 then score = score + 1 end
            end
            score = score - #sq.orders
            for _, order in ipairs(sq.orders) do
                if df.squad_order_kill_listst:is_instance(order) then
                    total_targets = total_targets + #order.units
                    for _, uid in ipairs(order.units) do
                        if uid == unit.id then killing_this = true end
                    end
                end
            end
        end)
        if killing_this then
            score = score - 100000
        end
        score = score - 10000 * total_targets
        if not best or score > best_score then
            best, best_score = sq, score
        end
    end
    if not best then return false end
    return self:military_squad_attack_unit(best, unit, reason)
end

function Population:military_all_squads_attack_unit(unit, reason)
    local ent = fort_entity()
    if not ent then return false end
    local any = false
    for _, sq in ipairs(fort_squads(ent)) do
        if self:military_squad_attack_unit(sq, unit, reason) then
            any = true
        end
    end
    return any
end

function Population:_log_military(msg)
    if self._mil_log == msg then return end
    self._mil_log = msg
    dfhack.println('[df-ai:military] ' .. msg)
end

-- C++ Population::update_military — the main policy pass.
function Population:update_military()
    local world = df.global.world
    if not world then return end
    if not dfhack.military or not dfhack.military.addToSquad then
        return -- Military module unavailable (should not happen on 53.16-r3)
    end

    local soldiers = {}    -- citizens currently in squads (dismiss pool)
    local want_draft = {}  -- residents to draft (mercenaries)
    local draft_pool = {}  -- eligible citizens

    for _, u in ipairs(world.units.active) do
        local ok_u, is_citizen = pcall(dfhack.units.isCitizen, u, true)
        if ok_u and is_citizen then
            -- wait for migrants to settle before shuffling the military
            if unit_is_new_migrant(u) then
                return
            end
            local in_squad = u.military.squad_id ~= -1
            if not in_squad then
                if self.military[u.id] then
                    self.military[u.id] = nil
                    if self.ai.plan then
                        self.ai.plan:freesoldierbarrack(u.id)
                    end
                end
                -- eligibility (C++ draft_pool): adults, no mood, no
                -- noble position, no tool-conflicting labor
                local ok_e, eligible = pcall(function()
                    if dfhack.units.isChild(u) or dfhack.units.isBaby(u) then
                        return false
                    end
                    if u.mood and u.mood ~= -1 and u.mood ~= df.mood_type.None then
                        return false
                    end
                    if #unit_noble_positions(u) > 0 then return false end
                    local L = df.unit_labor
                    return not u.status.labors[L.MINE]
                        and not u.status.labors[L.CUTWOOD]
                        and not u.status.labors[L.HUNT]
                end)
                if ok_e and eligible then
                    table.insert(draft_pool, u)
                end
            else
                if not self.military[u.id] then
                    self.military[u.id] = u.military.squad_id
                    if self.ai.plan then
                        self.ai.plan:getsoldierbarrack(u.id)
                    end
                end

                -- nobles with boss responsibilities leave the military
                -- (C++ dismisses: accounting / manage production / trade)
                local ok_r, boss = pcall(function()
                    local R = df.entity_position_responsibility
                    return unit_has_responsibility(u, R.ACCOUNTING)
                        or unit_has_responsibility(u, R.MANAGE_PRODUCTION)
                        or unit_has_responsibility(u, R.TRADE)
                end)
                if ok_r and boss then
                    self:dismiss_unit(u)
                else
                    table.insert(soldiers, u)
                end
            end
        else
            local ok_res, is_resident = pcall(function()
                return self.resident[u.id] == true
            end)
            if ok_res and is_resident then
                if u.military.squad_id == -1 then
                    if self.military[u.id] then
                        self.military[u.id] = nil
                        if self.ai.plan then
                            self.ai.plan:freesoldierbarrack(u.id)
                        end
                    end
                    -- mercenary residents are always recruited
                    local ok_m, is_merc = pcall(function()
                        for _, occ in ipairs(u.occupations or {}) do
                            if occ.type == df.occupation_type.MERCENARY then
                                return true
                            end
                        end
                        return false
                    end)
                    local ok_sa, sane = pcall(dfhack.units.isSane, u)
                    if ok_m and is_merc and ok_sa and sane then
                        table.insert(want_draft, u)
                    end
                elseif not self.military[u.id] then
                    self.military[u.id] = u.military.squad_id
                    if self.ai.plan then
                        self.ai.plan:getsoldierbarrack(u.id)
                    end
                end
            end
        end
    end

    -- C++ target math (blueprint.h defaults: military_limit [25, 75]):
    -- max_military from military_min (25%), min_military from
    -- military_max (75%). Steady state = 25% of citizens under arms.
    local citizens = self:citizen_count()
    local max_military = math.floor(citizens * self.military_min / 100)
    local min_military = math.floor(citizens * self.military_max / 100)
    local citizen_military = 0
    for uid in pairs(self.military) do
        if self.citizen[uid] then citizen_military = citizen_military + 1 end
    end

    if citizen_military > max_military then
        -- too many soldiers: dismiss the HIGHEST-XP first
        table.sort(soldiers, function(a, b)
            return Population.unit_totalxp(a) > Population.unit_totalxp(b)
        end)
        local n = math.min(citizen_military - max_military, #soldiers)
        for i = 1, n do
            self:dismiss_unit(soldiers[i])
        end
    elseif citizen_military < min_military then
        -- draft the LOWEST-XP first (protect the craftsmen)
        table.sort(draft_pool, function(a, b)
            return Population.unit_totalxp(a) < Population.unit_totalxp(b)
        end)
        local n = math.min(max_military - citizen_military, #draft_pool)
        for i = 1, n do
            table.insert(want_draft, draft_pool[i])
        end
    end

    if #want_draft > 0 then
        -- squad size by total soldier count (C++ Draft::Run):
        -- 10 default; 8 under 32; 6 under 24; 4 under 12
        local num_soldiers = citizen_military + #want_draft
        local squad_size = 10
        if num_soldiers < 32 then squad_size = 8 end
        if num_soldiers < 24 then squad_size = 6 end
        if num_soldiers < 12 then squad_size = 4 end

        -- every 3rd squad is ranged (C++ SelectOrCreateUniform:
        -- existing_squad_count % 3 == 1)
        local squad_count = #fort_squads(fort_entity())
        for _, u in ipairs(want_draft) do
            local want_ranged = (squad_count % 3) == 1
            if self:draft_unit(u, squad_size, want_ranged) then
                squad_count = #fort_squads(fort_entity())
            end
        end
    end

    self:check_squad_training()
end

-- C++ update_military barracks check: once a squad's barracks is dug
-- and its training equipment built, switch the squad to a training
-- routine (v50: find the "Constant training" routine index).
function Population:check_squad_training()
    local ok = pcall(function()
        local routines = df.global.plotinfo.alerts.routines
        if not routines or #routines == 0 then return end
        local train_idx
        for i, r in ipairs(routines) do
            if r.name == 'Constant training' then
                train_idx = i - 1
                break
            end
        end
        if train_idx == nil then return end
        for _, r in ipairs(self.ai.plan.room_category['barracks'] or {}) do
            if r.status ~= 'plan' and r.squad_id and r.squad_id >= 0 then
                local squad = df.squad.find(r.squad_id)
                if squad and squad.cur_routine_idx ~= train_idx then
                    squad.cur_routine_idx = train_idx
                    self:_log_military('squad ' .. squad.id
                        .. ' set to constant training')
                end
            end
        end
    end)
end

-- ============================================================
-- Nobles (population_nobles.cpp port, r3.8)
--
-- The C++ appointed nobles through the noble-list screen; the port
-- wires the structs directly: set the entity_position_assignment's
-- histfig + a histfig_entity_link_positionst on the historical figure
-- (the exact inverse of DFHack's remove_officer_entity_link).
-- Bookkeeper precision goes to plotinfo.nobles.bookkeeper_settings.
--
-- Appointments (C++ WANT_POS order):
--   MANAGE_PRODUCTION (manager) — validates workshop orders!
--   ACCOUNTING (bookkeeper, all-accurate precision)
--   HEALTH_MANAGEMENT (chief medical) once an infirmary exists
--   TRADE (broker)
--   LAW_ENFORCEMENT + EXECUTIONS once a jail is FINISHED
-- Candidates are ranked by XP DESCENDING and the LOWEST-XP dwarf is
-- appointed (nobles do not work — keep the craftsmen crafting).
-- ============================================================

local function fort_entity_nobles()
    local ent
    pcall(function()
        ent = df.historical_entity.find(df.global.plotinfo.group_id)
    end)
    if not ent then
        pcall(function()
            ent = df.global.plotinfo.main.fortress_entity
        end)
    end
    return ent
end

-- appoint unit into a vacant assignment for a position with the given
-- responsibility (C++ AssignNoblesExclusive, struct-based)
local function appoint_noble(ent, assignment, unit)
    local ok, err = pcall(function()
        local hf = df.historical_figure.find(unit.hist_figure_id)
        if not hf then error('unit has no historical figure') end
        if assignment.histfig ~= -1 and assignment.histfig ~= hf.id then
            error('assignment already held')
        end
        assignment.histfig = hf.id
        assignment.histfig2 = hf.id

        local link = df.histfig_entity_link_positionst:new()
        link.entity_id = ent.id
        link.assignment_id = assignment.id
        link.start_year = df.global.cur_year
        link.link_strength = 100
        hf.entity_links:insert('#', link)
    end)
    return ok, err
end

-- candidates for noble office (C++: adult, sane-ish, no mood, no
-- squad, no existing position; the bookkeeper additionally avoids
-- miners). Sorted XP-DESC; the caller pops from the back (lowest XP).
local function noble_candidates(pop, bookkeeper)
    local out = {}
    for uid in pairs(pop.citizen) do
        local u = df.unit.find(uid)
        if u then
            local ok, eligible = pcall(function()
                if dfhack.units.isChild(u) or dfhack.units.isBaby(u) then
                    return false
                end
                if u.mood and u.mood ~= -1 and u.mood ~= df.mood_type.None then
                    return false
                end
                if u.military.squad_id ~= -1 then return false end
                if #unit_noble_positions(u) > 0 then return false end
                if bookkeeper and u.status.labors[df.unit_labor.MINE] then
                    return false
                end
                return true
            end)
            if ok and eligible then
                table.insert(out, u)
            end
        end
    end
    table.sort(out, function(a, b)
        return Population.unit_totalxp(a) > Population.unit_totalxp(b)
    end)
    return out
end

-- appoint the first vacant assignment whose position carries `resp`
local function try_appoint(pop, ent, resp, label, bookkeeper)
    local changed = false
    local ok, err = pcall(function()
        -- already covered? (assignments_by_type holds the 53.16 layout)
        local covered = false
        pcall(function()
            local by_type = ent.assignments_by_type
            if by_type and by_type[resp] and #by_type[resp] > 0 then
                for _, asn in ipairs(by_type[resp]) do
                    if asn.histfig ~= -1 then
                        covered = true
                        break
                    end
                end
            end
        end)
        if covered then return end

        -- find the vacant assignment for a position with this duty
        local candidates = noble_candidates(pop, bookkeeper)
        for _, asn in ipairs(ent.positions.assignments) do
            if asn.histfig == -1 then
                local pos
                for _, p in ipairs(ent.positions.own) do
                    if p.id == asn.position_id then pos = p break end
                end
                if pos and pos.responsibilities[resp] == true then
                    -- pop the LOWEST-XP candidate (end of the desc list)
                    while #candidates > 0 do
                        local unit = table.remove(candidates)
                        local ok_a, err_a = appoint_noble(ent, asn, unit)
                        if ok_a then
                            dfhack.println('[df-ai:nobles] appointed unit '
                                .. unit.id .. ' as ' .. label)
                            changed = true
                            return
                        end
                    end
                    return -- no eligible candidates
                end
            end
        end
    end)
    if not ok then
        dfhack.printerr('[df-ai:nobles] ' .. label .. ' appointment failed: '
            .. tostring(err))
    end
    return changed
end

-- C++ check_noble_apartments — nobles whose position requires rooms
-- get their suites (plan:attribute_noblerooms)
function Population:check_noble_apartments()
    local ent = fort_entity_nobles()
    if not ent then return end
    if not self.ai.plan or not self.ai.plan.attribute_noblerooms then
        return
    end
    local ok, err = pcall(function()
        local noble_ids = {}
        for _, asn in ipairs(ent.positions.assignments) do
            if asn.histfig ~= -1 then
                local pos
                for _, p in ipairs(ent.positions.own) do
                    if p.id == asn.position_id then pos = p break end
                end
                if pos and (pos.required_office > 0 or pos.required_dining > 0
                    or pos.required_tomb > 0) then
                    local hf = df.historical_figure.find(asn.histfig)
                    if hf and hf.unit_id ~= -1 then
                        noble_ids[hf.unit_id] = true
                    end
                end
            end
        end
        local id_list = {}
        for uid in pairs(noble_ids) do
            table.insert(id_list, uid)
        end
        self.ai.plan:attribute_noblerooms(id_list)
    end)
    if not ok then
        dfhack.printerr('[df-ai:nobles] apartments failed: ' .. tostring(err))
    end
end

function Population:update_nobles()
    self:check_noble_apartments()

    if not self.ai.config.manage_nobles then return end
    local ent = fort_entity_nobles()
    if not ent then return end

    local R = df.entity_position_responsibility

    -- healthcare labors on the chief medical dwarf (C++ update_nobles)
    pcall(function()
        local by_type = ent.assignments_by_type
        local asns = by_type and by_type[R.HEALTH_MANAGEMENT]
        if asns then
            for _, asn in ipairs(asns) do
                if asn.histfig ~= -1 then
                    local hf = df.historical_figure.find(asn.histfig)
                    local doctor = hf and df.unit.find(hf.unit_id)
                    if doctor then
                        local L = df.unit_labor
                        doctor.status.labors[L.DIAGNOSE] = true
                        doctor.status.labors[L.SURGERY] = true
                        doctor.status.labors[L.BONE_SETTING] = true
                        doctor.status.labors[L.SUTURING] = true
                        doctor.status.labors[L.DRESSING_WOUNDS] = true
                        doctor.status.labors[L.FEED_WATER_CIVILIANS] = true
                    end
                end
            end
        end
    end)

    local changed = false
    changed = try_appoint(self, ent, R.MANAGE_PRODUCTION, 'manager', false) or changed
    changed = try_appoint(self, ent, R.ACCOUNTING, 'bookkeeper', true) or changed
    -- the bookkeeper counts everything to the last item (C++ settings 4)
    if changed then
        pcall(function()
            df.global.plotinfo.nobles.bookkeeper_settings = 4
        end)
    end

    if self.ai.plan then
        local infirmary = false
        for _, r in ipairs(self.ai.plan.room_category['infirmary'] or {}) do
            if r.status ~= 'plan' then infirmary = true break end
        end
        if infirmary then
            changed = try_appoint(self, ent, R.HEALTH_MANAGEMENT,
                'chief medical dwarf', false) or changed
        end
        local jail_ready = false
        for _, r in ipairs(self.ai.plan.room_category['jail'] or {}) do
            if r.status == 'finished' then jail_ready = true break end
        end
        if jail_ready then
            changed = try_appoint(self, ent, R.LAW_ENFORCEMENT, 'sheriff', false) or changed
            changed = try_appoint(self, ent, R.EXECUTIONS, 'executioner', false) or changed
        end
    end

    changed = try_appoint(self, ent, R.TRADE, 'broker', false) or changed
end

-- ============================================================
-- Justice / Crimes
-- ============================================================

function Population:update_crimes()
    -- C++ population_justice.cpp mostly LOGS discovered crimes (the
    -- game's own justice system convicts once a sheriff/cage exists).
    -- The old Lua sketch flipped prisoner/criminal flags that no
    -- longer exist in 53.16 — replaced with the C++ logging behavior.
    local world = df.global.world
    if not world or not world.crimes then return end

    local ok, err = pcall(function()
        local crimes = world.crimes.all
        local year = df.global.cur_year
        local tick = df.global.cur_year_tick
        local site_id = df.global.plotinfo.site_id
        local seen = self.last_crime_seen or 0
        for i = seen, #crimes - 1 do
            local crime = crimes[i]
            if crime then
                local ok_c, discovered, at_site = pcall(function()
                    return crime.flags.discovered == true,
                        crime.site == site_id
                end)
                if ok_c and discovered and at_site then
                    local ok_m, mode = pcall(function()
                        return tostring(crime.mode)
                    end)
                    dfhack.println('[df-ai:justice] crime discovered: '
                        .. (ok_m and mode or 'unknown'))
                end
            end
        end
        self.last_crime_seen = #crimes
        self.last_checked_crime_year = year
        self.last_checked_crime_tick = tick
    end)
    if not ok then
        -- crimes struct drifted — non-fatal, retry next pass
        self.last_crime_seen = nil
    end
end

-- ============================================================
-- Pets
-- ============================================================

function Population:update_pets()
    -- C++ population_pets.cpp port (r3.8): slaughter policy, training
    -- assignments, milking/shearing orders, pasture management, and
    -- fertile-egg protection.
    local world = df.global.world
    if not world then return end
    if not self.ai.plan or not self.ai.plan.pastures_ready then return end
    if not self.ai.plan:pastures_ready() then return end

    local needmilk, needshear = 0, 0
    local ok, err = pcall(function()
        -- count pending milk/shear orders (C++ subtracts amount_left)
        for _, mo in ipairs(world.manager_orders or {}) do
            if mo.job_type == df.job_type.MilkCreature then
                needmilk = needmilk - (mo.amount_left or 0)
            elseif mo.job_type == df.job_type.ShearCreature then
                needshear = needshear - (mo.amount_left or 0)
            end
        end

        local for_slaughter = {} -- [caste ptr] = { {age,unit}, ... } ascending
        local np = {}
        for uid in pairs(self.pet) do np[uid] = true end

        local function days_since(u)
            local ok_a, age = pcall(function()
                local dy = (df.global.cur_year - u.birth_year) * 336
                    + math.floor((df.global.cur_year_tick - u.birth_time) / 1200)
                return math.max(dy, 0)
            end)
            return ok_a and age or 0
        end

        local function caste_of(u)
            local ok_c, cst = pcall(function()
                local race = df.creature_raw.find(u.race)
                return race and race.caste[u.caste] or nil
            end)
            return ok_c and cst or nil
        end

        local function flag_set(cst, name)
            local ok_f, v = pcall(function()
                return cst.flags[name] == true
            end)
            return ok_f and v or false
        end

        for _, u in ipairs(world.units.active) do
            local cst = caste_of(u)
            if cst then
                if flag_set(cst, 'CAN_LEARN') then
                    -- sapient creatures are never livestock
                else
                    local ok_sk, skip = pcall(function()
                        local f1, f2 = u.flags1, u.flags2
                        if f1.inactive or f1.merchant or f1.forest then return true end
                        if f2.visitor or f2.slaughter then return true end
                        return false
                    end)
                    if not (ok_sk and skip) then
                        local ok_ow, own = pcall(function()
                            return dfhack.units.isOwnCiv(u)
                                and not dfhack.units.isOwnGroup(u)
                                and not dfhack.units.isOwnRace(u)
                        end)
                        if ok_ow and own then
                            local age = days_since(u)
                            local TL = df.animal_training_level

                            -- caged wild animals: assign a trainer
                            local ok_cg, caged_wild = pcall(function()
                                return u.flags1.caged and u.civ_id == -1
                                    and u.cultural_identity == -1
                                    and u.training_level == TL.WildUntamed
                            end)
                            if ok_cg and caged_wild then
                                pcall(function()
                                    local has = false
                                    for _, asn in ipairs(
                                        df.global.plotinfo.training.training_assignments) do
                                        if asn.animal_id == u.id then
                                            has = true break
                                        end
                                    end
                                    if not has then
                                        local asn = df.training_assignment:new()
                                        asn.animal_id = u.id
                                        asn.trainer_id = -1
                                        asn.flags.any_trainer = true
                                        df.global.plotinfo.training
                                            .training_assignments:insert('#', asn)
                                    end
                                end)
                            end

                            -- trained wild animals (not yet domesticated)
                            -- are slaughtered once grown
                            local ok_tl, trained_wild = pcall(function()
                                return u.training_level > TL.SemiWild
                                    and u.training_level < TL.Domesticated
                            end)
                            if ok_tl and trained_wild then
                                u.flags2.slaughter = true
                            elseif self.pet[u.id] then
                                np[u.id] = nil
                                local ok_gr, grown = pcall(function()
                                    return age >= (cst.body_size_2 and
                                        #cst.body_size_2 > 0 and
                                        cst.body_size_2[#cst.body_size_2 - 1] or 0)
                                end)
                                local ok_tr, not_trained = pcall(function()
                                    return u.profession ~= df.profession.TRAINED_HUNTER
                                        and u.profession ~= df.profession.TRAINED_WAR
                                end)
                                local ok_un, unowned = pcall(function()
                                    return u.relationship_ids[
                                        df.unit_relationship_type.Pet] == -1
                                end)
                                if ok_gr and grown and ok_tr and not_trained
                                    and ok_un and unowned then
                                    u.flags2.slaughter = true -- can't reproduce / too many
                                else
                                    for_slaughter[cst] = for_slaughter[cst] or {}
                                    table.insert(for_slaughter[cst], { age, u })
                                end

                                -- milking / shearing census
                                local pf = self.pet[u.id]
                                if pf == 'milkable' then
                                    local ok_b, baby = pcall(function()
                                        return dfhack.units.isBaby(u)
                                            or dfhack.units.isChild(u)
                                    end)
                                    local ok_mc, have = pcall(function()
                                        for _, mt in ipairs(u.status.misc_traits) do
                                            if mt.id == df.misc_trait_type.MilkCounter then
                                                return true
                                            end
                                        end
                                        return false
                                    end)
                                    if not (ok_b and baby) and not (ok_mc and have) then
                                        needmilk = needmilk + 1
                                    end
                                elseif pf == 'shearable' then
                                    local ok_b2, baby2 = pcall(function()
                                        return dfhack.units.isBaby(u)
                                            or dfhack.units.isChild(u)
                                    end)
                                    if not (ok_b2 and baby2) then
                                        local ok_sh, ready = pcall(function()
                                            for _, stl in ipairs(cst.shearable_tissue_layer) do
                                                for _, bpi in ipairs(stl.bp_modifiers_idx) do
                                                    if (u.appearance.bp_modifiers[bpi] or 0)
                                                        >= (stl.length or 0) then
                                                        return true
                                                    end
                                                end
                                            end
                                            return false
                                        end)
                                        if ok_sh and ready then
                                            needshear = needshear + 1
                                        end
                                    end
                                end
                            else
                                -- new animal: classify (C++ pet_flags)
                                local class
                                if flag_set(cst, 'MILKABLE') then
                                    class = 'milkable'
                                elseif #(cst.shearable_tissue_layer or {}) > 0 then
                                    class = 'shearable'
                                end
                                self.pet[u.id] = class

                                if flag_set(cst, 'GRAZER') then
                                    local zone = self.ai.plan:getpasture(u.id)
                                    if zone then
                                        self:assign_unit_to_zone(u, zone)
                                    else
                                        local ok_up, unowned2 = pcall(function()
                                            return u.relationship_ids[
                                                df.unit_relationship_type.Pet] == -1
                                        end)
                                        if ok_up and unowned2 then
                                            u.flags2.slaughter = true
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        -- released pets (dead/sold/gone): free their pasture slots
        for uid in pairs(np) do
            self.pet[uid] = nil
            self.ai.plan:freepasture(uid)
        end

        -- keep-youngest-3 breeding policy: per caste, slaughter every
        -- adult beyond the 3 youngest
        for cst, list in pairs(for_slaughter) do
            if #list > 3 then
                table.sort(list, function(a, b) return a[1] < b[1] end)
                for i = 4, #list do
                    list[i][2].flags2.slaughter = true
                end
            end
        end
    end)
    if not ok then
        dfhack.printerr('[df-ai:pets] update failed: ' .. tostring(err))
    end

    if needmilk > 0 and self.ai.stocks then
        self.ai.stocks:queue_job_amount(df.job_type.MilkCreature,
            math.min(needmilk, 30))
    end
    if needshear > 0 and self.ai.stocks then
        self.ai.stocks:queue_job_amount(df.job_type.ShearCreature,
            math.min(needshear, 30))
    end

    -- fertile eggs are for hatching, not cooking (C++ forbids them)
    pcall(function()
        local NB = df.buildings_other_id.NEST_BOX
        for _, bld in ipairs(df.global.world.buildings.other[NB] or {}) do
            if df.building_nest_boxst:is_instance(bld) then
                local ok_st, ready = pcall(function()
                    return bld:getBuildStage() == bld:getMaxBuildStage()
                        and bld.claimed_by ~= -1
                end)
                if ok_st and ready then
                    for _, ci in ipairs(bld.contained_items or {}) do
                        if df.item_eggst:is_instance(ci.item) then
                            if ci.item.egg_flags.fertile then
                                ci.item.flags.forbid = true
                            end
                        end
                    end
                end
            end
        end
    end)
end

-- v50 zone assignment: the civzone's assigned_units vector + a
-- BUILDING_CIVZONE_ASSIGNED general_ref on the unit (the C++ drove
-- the pen/pasture UI; the structs are equivalent)
function Population:assign_unit_to_zone(u, zone)
    local ok, err = pcall(function()
        if df.building_civzonest:is_instance(zone) then
            local there = false
            for _, uid in ipairs(zone.assigned_units) do
                if uid == u.id then there = true break end
            end
            if not there then
                zone.assigned_units:insert('#', u.id)
            end
            local has_ref = false
            for _, ref in ipairs(u.general_refs or {}) do
                if ref:getType() == df.general_ref_type.BUILDING_CIVZONE_ASSIGNED then
                    has_ref = true break
                end
            end
            if not has_ref then
                local ref = df.general_ref_building_civzone_assignedst:new()
                ref.building_id = zone.id
                u.general_refs:insert('#', ref)
            end
        end
    end)
    return ok
end

-- C++ population_occupations.cpp petitions: the unapproved agreements
-- in plotinfo.petitions. Approving via structs risks save corruption
-- (the UI does agreement bookkeeping we cannot fully replicate), so
-- the port LOGS what arrives and leaves the decision to the player.
function Population:update_petitions()
    local ok, count = pcall(function()
        return #df.global.plotinfo.petitions
    end)
    if not ok or not count or count == 0 then return end
    if self._last_petition_count == count then return end
    self._last_petition_count = count
    dfhack.println('[df-ai] ' .. count
        .. ' petition(s) awaiting review (approve them in the petitions screen)')
end

-- ============================================================
-- Locations / Occupations
-- ============================================================

function Population:update_locations()
    local world = df.global.world
    if not world then return end

    local tavern_count = 0
    local library_count = 0
    local temple_count = 0

    -- v50 removed location preferences entirely; count actual locations
    -- from the fortress's abstract buildings instead.
    local site = dfhack.world.getCurrentSite()
    if site then
        for _, loc in ipairs(site.buildings or {}) do
            local ok, t = pcall(function()
                if df.abstract_building_libraryst:is_instance(loc) then
                    return 'library'
                elseif df.abstract_building_inn_tavernst:is_instance(loc) then
                    return 'tavern'
                elseif df.abstract_building_templest:is_instance(loc) then
                    return 'temple'
                end
                return nil
            end)
            if ok and t == 'tavern' then
                tavern_count = tavern_count + 1
            elseif ok and t == 'library' then
                library_count = library_count + 1
            elseif ok and t == 'temple' then
                temple_count = temple_count + 1
            end
        end
    end
    self.location_counts = {
        tavern = tavern_count,
        library = library_count,
        temple = temple_count,
    }
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
            -- Check if unit is in a cage (release path is version-fragile:
            -- unit.cage / cage:removeUnit are not guaranteed on 53.16, so
            -- it is fully pcall-wrapped — worst case the citizen waits)
            local ok_c, caged = pcall(function() return unit.flags1.caged end)
            if ok_c and caged then
                pcall(function()
                    local cage = unit.cage
                    if cage then
                        cage:removeUnit(unit)
                        unit.cage = nil
                        unit.flags1.caged = false
                    end
                end)
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
-- Jobs
-- ============================================================

-- r3.9 anti-idle (C++ Population::update_jobs parity): FORCE-unsuspend
-- every suspended non-repeat job. This was ported as a no-op stub in
-- r3.6 ("nothing to watch here anymore") — that was wrong. A suspended
-- job (a building task whose dwarf got interrupted, a construction
-- cancelled once by a stray item...) never resumes by itself, its dwarf
-- stands idle, and at any given time a busy fort has several of them.
-- The old C++ build swept them every pop update; that is precisely why
-- it "never left dwarves idle". Repeat jobs ( workshops on repeat) are
-- skipped so the player's intentional repeat loops stay untouched.
function Population:update_jobs()
    local world = df.global.world
    if not world or not world.jobs then return end
    local unsuspended = 0
    for _, job in ipairs(world.jobs.list) do
        local ok, unsusp = pcall(function()
            -- NOTE: 'repeat' is a Lua keyword — index it as a string!
            if job and job.flags and job.flags.bits.suspend
                and not job.flags.bits['repeat'] then
                job.flags.bits.suspend = false
                return true
            end
            return false
        end)
        if ok and unsusp then
            unsuspended = unsuspended + 1
        end
    end
    if unsuspended > 0 then
        -- visible but throttled: these are exactly the "why was my dwarf
        -- standing there" moments
        self._unsuspend_total = (self._unsuspend_total or 0) + unsuspended
        dfhack.println(('[df-ai] unsuspended %d stalled job(s) (%d total this session)')
            :format(unsuspended, self._unsuspend_total))
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
    local ok_s, nsq = pcall(function()
        local ent = df.historical_entity.find(df.global.plotinfo.group_id)
        return ent and #ent.squads or 0
    end)
    table.insert(parts, '  Squads: ' .. tostring(ok_s and nsq or 0))

    return table.concat(parts, '\n')
end

return Population
