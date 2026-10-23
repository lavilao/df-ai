--@module = true
--
-- df-ai priority rule engine — Lua port of plan_priorities.cpp.
--
-- The plan JSON (plans/generic01.json) carries an ORDERED list of rules.
-- Each evaluation scans them in order; the first rule that acts blocks
-- the rest for that tick (unless "continue": true). A rule that already
-- queued work is latched (working=true) until no live task matches its
-- filters any more. This is what makes df-ai dig the food stockpile
-- BEFORE the tavern, and unignore the entrance cage traps only after
-- the cistern levers are linked in the original C++.
--
-- Rule schema (JSON):
--   { "name": "...", "action": "dig" | "dig_immediate" |
--       "unignore_furniture" | "finish" | "past_initial_phase" |
--       "deconstruct_wagons" | "start_ore_search",
--     "continue": true,
--     "match": { <room filter> }, "match_not": [ { ... } ],
--     "count": { "match": {...}, "is": 0 | [min, max] } }
--
-- Room filter fields (string or array of strings; *_not inverts):
--   status, type, corridor_type, farm_type, stockpile_type,
--   workshop_type, furnace_type, location_type, nobleroom_type,
--   outpost_type, cistern_type, raw_type, comment,
--   outdoor, queue_dig, furnished, has_owner, has_squad,
--   level (number or [min,max]), workshop / workshop_not (sub-filter
--   on the room's linked workshop), accesspath / layout (count filter)
--

local M = {}

-- ============================================================
-- Filter evaluation
-- ============================================================

local function as_list(v)
    if v == nil then return nil end
    if type(v) == 'table' then return v end
    return { v }
end

-- between_t: 5 (exact) | [5, 10] | [null, 10] | [5, null]
local function between_check(spec, value)
    if spec == nil then return true end
    if type(spec) ~= 'table' then return value == spec end
    local lo, hi = spec[1], spec[2]
    if lo ~= nil and lo ~= false and value < lo then return false end
    if hi ~= nil and hi ~= false and value > hi then return false end
    return true
end

-- enum value -> name ("Carpenters"), cached; DFHack enum tables index
-- both ways, but pcall: mocks / removed members must not throw
local enum_name_cache = {}
local function enum_name(enum_tbl, value)
    local cache = enum_name_cache[enum_tbl]
    if cache == nil then
        cache = {}
        enum_name_cache[enum_tbl] = cache
    end
    local n = cache[value]
    if n ~= nil then return n end
    local ok, name = pcall(function() return enum_tbl[value] end)
    if ok and type(name) == 'string' then
        cache[value] = name
        return name
    end
    cache[value] = false
    return false
end

-- one room-filter table vs one room
function M.room_matches(filter, r)
    if not filter or not r then return false end

    -- *_not set properties: fail if the room's value is in the set
    local function set_check(field, value)
        local nots = as_list(filter[field .. '_not'])
        if nots then
            for _, nv in ipairs(nots) do
                if value == nv then return false end
            end
        end
        local pos = as_list(filter[field])
        if not pos then return true end
        for _, pv in ipairs(pos) do
            if value == pv then return true end
        end
        return false
    end

    if not set_check('status', r.status) then return false end
    if not set_check('type', r.type) then return false end
    if not set_check('corridor_type', r.corridor_type) then return false end
    if not set_check('farm_type', r.farm_type) then return false end
    if not set_check('stockpile_type', r.stockpile_type) then return false end
    if not set_check('nobleroom_type', r.nobleroom_type) then return false end
    if not set_check('outpost_type', r.outpost_type) then return false end
    if not set_check('location_type', r.location_type) then return false end
    if not set_check('cistern_type', r.cistern_type) then return false end
    if not set_check('raw_type', r.raw_type) then return false end
    if not set_check('comment', r.comment) then return false end

    -- enum-numbered properties: compare by NAME (workshop_type etc.)
    if filter.workshop_type ~= nil or filter.workshop_type_not ~= nil then
        local wt = enum_name(df.workshop_type, r.workshop_type) or false
        if not set_check('workshop_type', wt) then return false end
    end
    if filter.furnace_type ~= nil or filter.furnace_type_not ~= nil then
        local ft = enum_name(df.furnace_type, r.furnace_type) or false
        if not set_check('furnace_type', ft) then return false end
    end

    if filter.outdoor ~= nil and r.outdoor ~= filter.outdoor then return false end
    if filter.queue_dig ~= nil and r.queue_dig ~= filter.queue_dig then return false end
    if filter.furnished ~= nil and r.furnished ~= filter.furnished then return false end
    if filter.has_owner ~= nil and ((r.owner or -1) >= 0) ~= filter.has_owner then return false end
    if filter.has_squad ~= nil and ((r.squad_id or -1) >= 0) ~= filter.has_squad then return false end

    if filter.level ~= nil and not between_check(filter.level, r.level or 0) then
        return false
    end

    -- workshop / workshop_not: sub-filter on the linked workshop room
    if filter.workshop ~= nil then
        if not r.workshop_room or not M.room_matches(filter.workshop, r.workshop_room) then
            return false
        end
    end
    if filter.workshop_not ~= nil then
        if r.workshop_room and M.room_matches(filter.workshop_not, r.workshop_room) then
            return false
        end
    end

    -- count filters over related objects
    if filter.accesspath ~= nil then
        local n = 0
        for _, ap in ipairs(r.accesspath or {}) do
            if M.filter_list_matches(filter.accesspath.match, ap) then
                n = n + 1
            end
        end
        if not between_check(filter.accesspath.is, n) then return false end
    end
    if filter.layout ~= nil then
        local n = 0
        for _, f in ipairs(r.layout or {}) do
            if M.furniture_matches(filter.layout.match, f) then
                n = n + 1
            end
        end
        if not between_check(filter.layout.is, n) then return false end
    end

    return true
end

-- match may be a single filter or a list; ANY passing filter counts
function M.filter_list_matches(match, r)
    if match == nil then return true end
    if match[1] ~= nil and type(match[1]) == 'table' and match[1].type == nil
        and match[1].status == nil and match[1].outdoor == nil then
        -- a list of filters (heuristics: a filter always carries at
        -- least one recognizable property)
        for _, f in ipairs(match) do
            if M.room_matches(f, r) then return true end
        end
        return false
    end
    return M.room_matches(match, r)
end

function M.furniture_matches(match, f)
    if match == nil then return true end
    local list = match[1] ~= nil and type(match[1]) == 'table' and match
        or { match }
    for _, ff in ipairs(list) do
        local ok = true
        if ff.type ~= nil and f.type ~= ff.type then ok = false end
        if ff.ignore ~= nil and f.ignore ~= ff.ignore then ok = false end
        if ff.makeroom ~= nil and f.makeroom ~= ff.makeroom then ok = false end
        if ff.internal ~= nil and f.internal ~= ff.internal then ok = false end
        if ff.comment ~= nil and f.comment ~= ff.comment then ok = false end
        if ok then return true end
    end
    return false
end

-- ============================================================
-- Rule preparation (JSON -> runtime)
-- ============================================================

function M.prepare(rules_json)
    local rules = {}
    for _, rj in ipairs(rules_json or {}) do
        table.insert(rules, {
            name = rj.name or '(unnamed)',
            action = rj.action or 'dig',
            keep_going = rj['continue'] or false,
            match = rj.match,
            match_not = rj.match_not,
            count = rj.count,
            working = false,
        })
    end
    return rules
end

local function count_gate(plan, c)
    local n = 0
    for _, r in ipairs(plan.rooms) do
        if M.filter_list_matches(c.match, r) then
            n = n + 1
        end
    end
    return between_check(c.is, n)
end

local function all_count_gates(plan, rule)
    if rule.count == nil then return true end
    local list = rule.count[1] ~= nil and rule.count or { rule.count }
    for _, c in ipairs(list) do
        if not count_gate(plan, c) then return false end
    end
    return true
end

-- a rule is "working" while live tasks reference rooms it matches
local function match_task(plan, rule)
    local function check(t)
        return t.room ~= nil and M.room_matches(rule.match or {}, t.room)
    end
    for _, t in ipairs(plan.tasks_generic) do
        if check(t) then return true end
    end
    for _, t in ipairs(plan.tasks_furniture) do
        if check(t) then return true end
    end
    return false
end

local function not_matches(rule, r)
    local mn = rule.match_not
    if mn == nil then return false end
    local list = mn[1] ~= nil and mn or { mn }
    for _, f in ipairs(list) do
        if M.room_matches(f, r) then return true end
    end
    return false
end

-- ============================================================
-- Rule actions
-- ============================================================

local Actions = {}

function Actions.dig(plan, r)
    plan:wantdig(r, r.outdoor and 1 or 0)
    return true
end

function Actions.dig_immediate(plan, r)
    plan:digroom(r, true)
    return true
end

function Actions.unignore_furniture(plan, r)
    local any = false
    for _, f in ipairs(r.layout or {}) do
        if f.ignore then
            f.ignore = false
            any = true
        end
    end
    if any then
        plan:furnish_room(r)
    end
    return any
end

function Actions.finish(plan, r)
    r.furnished = true
    for _, f in ipairs(r.layout or {}) do
        f.ignore = false
    end
    plan:furnish_room(r)
    plan:smooth_room(r)
    return true
end

function Actions.past_initial_phase(plan)
    plan.past_initial_phase = true
    return true
end

function Actions.deconstruct_wagons(plan)
    local n = 0
    local ok_all, buildings = pcall(function()
        return df.global.world.buildings.all
    end)
    if ok_all and buildings then
        for _, bld in ipairs(buildings) do
            local ok_w, is_wagon = pcall(function()
                return df.building_wagonst:is_instance(bld)
            end)
            if ok_w and is_wagon then
                local ok_d = pcall(dfhack.buildings.deconstruct, bld)
                if ok_d then n = n + 1 end
            end
        end
    end
    return n > 0
end

function Actions.start_ore_search(plan)
    plan.should_search_for_metal = true
    return true
end

-- ============================================================
-- plan_priority_t::act + Plan::checkidle
-- ============================================================

local function act(plan, rule)
    if not all_count_gates(plan, rule) then return false end

    local action = Actions[rule.action]
    if not action then return false end

    if rule.action == 'dig' or rule.action == 'dig_immediate' then
        for _, r in ipairs(plan.rooms) do
            if r.status == 'plan' and not not_matches(rule, r)
                and M.room_matches(rule.match or {}, r) then
                rule.working = true
                action(plan, r)
                if not rule.keep_going then return true end
                if not all_count_gates(plan, rule) then return false end
            end
        end
        return false
    elseif rule.action == 'unignore_furniture' then
        for _, r in ipairs(plan.rooms) do
            local has_ignored = false
            for _, f in ipairs(r.layout or {}) do
                if f.ignore then has_ignored = true break end
            end
            if has_ignored and not not_matches(rule, r)
                and M.room_matches(rule.match or {}, r) then
                rule.working = true
                action(plan, r)
                if not rule.keep_going then return true end
                if not all_count_gates(plan, rule) then return false end
            end
        end
        return false
    elseif rule.action == 'finish' then
        for _, r in ipairs(plan.rooms) do
            if r.status == 'finished' and not r.furnished
                and not not_matches(rule, r)
                and M.room_matches(rule.match or {}, r) then
                rule.working = true
                action(plan, r)
                if not rule.keep_going then return true end
                if not all_count_gates(plan, rule) then return false end
            end
        end
        return false
    else
        -- one-shot global actions
        local did = action(plan)
        if did then
            rule.working = true
            return not rule.keep_going
        end
        return false
    end
end

-- Plan::checkidle — called from the persistent check_idle task.
-- Returns true when a rule acted (the C++ caller uses this to stop).
function M.checkidle(plan)
    if not plan.priority_rules or #plan.priority_rules == 0 then
        return false
    end

    -- don't run priorities while a queue-0 room is being dug
    for _, t in ipairs(plan.tasks_generic) do
        if (t.type == 'want_dig' or t.type == 'dig_room_immediate')
            and t.room and (t.room.queue or 0) == 0 then
            return false
        end
    end

    for _, rule in ipairs(plan.priority_rules) do
        if rule.working and not match_task(plan, rule) then
            rule.working = false
        end
        if not rule.working then
            local ok, acted = pcall(act, plan, rule)
            if not ok then
                dfhack.printerr('[df-ai] priority rule "' .. rule.name
                    .. '" failed: ' .. tostring(acted))
            elseif acted then
                return true
            end
        end
    end
    return false
end

return M
