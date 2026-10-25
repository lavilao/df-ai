--@module = true
-- persist.lua — plan state persistence (C++ plan_persist.cpp parity)
--
-- The C++ plugin serializes the ENTIRE plan (rooms, furniture, tasks,
-- fort entrance, priority-rule latches, military population thresholds)
-- into the save folder on every autosave / world unload / save-menu, and
-- restores it on startup instead of re-running the blueprint placement.
-- Without this, every save+reload made the AI re-plan rooms over an
-- existing fortress (duplicate bedrooms, doubled traps, re-dug corridors).
--
-- Storage: dfhack.persistent.saveWorldData('df-ai-plan', data) — a JSON
-- string inside the world save, so it travels with saves the same way
-- data/save/<world>/df-ai-plan.dat did in C++.
--
-- The serialize/restore core is pure Lua (no dfhack access) so the unit
-- tests can exercise full round-trips headlessly; only save()/load()
-- touch DFHack.

local M = {}

local PERSIST_KEY = 'df-ai-plan'
local FORMAT = 2

local function log_err(msg)
    if dfhack and dfhack.printerr then
        dfhack.printerr(msg)
    else
        io.stderr:write(msg .. '\n')
    end
end

-- ============================================================
-- Serialization core (pure Lua)
-- ============================================================

local function serial_coord(c)
    if not c then return nil end
    return { x = c.x, y = c.y, z = c.z }
end

--- Serialize the whole plan + population thresholds.
-- plan: the Plan object (rooms, corridors, fort_entrance, tasks_*,
--       priority_rules, setup flags).
-- population: optional (military_min / military_max).
--
-- Layout of the flat room index (must match M.deserialize exactly):
--   [1..#rooms, #rooms+1..#rooms+#corridors, fort_entrance (if a room
--   object not already in either list)]
-- Cross references (accesspath, workshop, furniture targets, task rooms)
-- are indices into that flat list, so the pass order is:
--   1) allocate every index, 2) serialize contents, 3) tasks.
function M.serialize(plan, population)
    local rooms = plan.rooms or {}
    local corridors = plan.corridors or {}
    local room_index = {}   -- room object -> flat index
    local rooms_flat = {}   -- flat index -> room object

    local function alloc(r)
        if r and not room_index[r] then
            room_index[r] = #rooms_flat + 1
            table.insert(rooms_flat, r)
        end
    end

    for _, r in ipairs(rooms) do alloc(r) end
    for _, r in ipairs(corridors) do alloc(r) end

    -- fort entrance: room object (builder result) or plain coord table
    local fe = plan.fort_entrance
    local fe_is_room = fe and fe.min and fe.max and fe.type
    local fe_extra = false
    if fe_is_room then
        if not room_index[fe] then
            alloc(fe)
            fe_extra = true
        end
    end

    -- furniture -> owning room map (targets live in any room's layout)
    local furn_room = {}
    for _, r in ipairs(rooms_flat) do
        for _, f in ipairs(r.layout or {}) do
            furn_room[f] = r
        end
    end

    local function serial_furniture(f)
        local t = {
            ty = f.type,
            co = f.construction,
            dg = f.dig,
            bld = f.bld_id,
            p = f.pos and { x = f.pos.x, y = f.pos.y, z = f.pos.z } or nil,
            us = f.users or {},
            hu = f.has_users or 0,
            ig = f.ignore or false,
            mk = f.makeroom or false,
            it = f.internal or false,
            cm = f.comment or '',
        }
        -- lever -> floodgate (or similar) target furniture: another
        -- room's layout, addressed as (flat room index, layout index)
        if f.target and furn_room[f.target] then
            local tr = furn_room[f.target]
            local tri = room_index[tr]
            local fi = nil
            for i, ff in ipairs(tr.layout or {}) do
                if ff == f.target then fi = i - 1 break end
            end
            if fi then
                t.tgr = tri
                t.tfi = fi
            end
        end
        return t
    end

    local function serial_room_full(r)
        local ly = {}
        for _, f in ipairs(r.layout or {}) do
            table.insert(ly, serial_furniture(f))
        end
        local ap = {}
        for _, pr in ipairs(r.accesspath or {}) do
            if room_index[pr] then table.insert(ap, room_index[pr]) end
        end
        return {
            st = r.status, ty = r.type,
            ct = r.corridor_type, ft = r.farm_type, spt = r.stockpile_type,
            nrt = r.nobleroom_type, ot = r.outpost_type, lt = r.location_type,
            cit = r.cistern_type, wt = r.workshop_type, fct = r.furnace_type,
            rt = r.raw_type, cm = r.comment,
            mn = serial_coord(r.min), mx = serial_coord(r.max),
            ap = ap, ly = ly,
            own = r.owner, bld = r.bld_id, sq = r.squad_id, lv = r.level,
            ns = r.noblesuite, q = r.queue,
            wk = r.workshop and room_index[r.workshop] or nil,
            sd = r.stock_disable or {}, s1 = r.stock_specific1 or false,
            s2 = r.stock_specific2 or false,
            hu = r.has_users or 0, fu = r.furnished or false,
            qd = r.queue_dig or false, tp = r.temporary or false,
            od = r.outdoor or false, ch = r.channeled or false,
            ba = r.build_when_accessible or false, rv = r.required_value or 0,
            d1 = r.data1 or 0, d2 = r.data2 or 0,
        }
    end

    local out = { v = FORMAT }

    out.rooms = {}
    for _, r in ipairs(rooms) do table.insert(out.rooms, serial_room_full(r)) end
    out.corridors = {}
    for _, r in ipairs(corridors) do table.insert(out.corridors, serial_room_full(r)) end
    out.fe_room_extra = nil
    if fe_extra then
        out.fe_room_extra = serial_room_full(fe)
        out.fe_room = room_index[fe]
    elseif fe_is_room then
        out.fe_room = room_index[fe]
        out.fe = nil
    else
        out.fe = serial_coord(fe)
        out.fe_room = nil
    end

    -- tasks reference (room, furniture) by flat index / layout index
    local function serial_tasks(list)
        local t = {}
        for _, task in ipairs(list or {}) do
            local ri = task.room and room_index[task.room] or -1
            local fi = -1
            if task.furniture and task.room then
                for i, ff in ipairs(task.room.layout or {}) do
                    if ff == task.furniture then fi = i - 1 break end
                end
            end
            table.insert(t, {
                ty = task.type, ri = ri, fi = fi,
                id = task.item_id or -1, ls = task.last_status or '',
            })
        end
        return t
    end
    out.tasks_generic = serial_tasks(plan.tasks_generic)
    out.tasks_furniture = serial_tasks(plan.tasks_furniture)

    -- priority-rule latches (prepare() rebuilds the rules from the plan
    -- JSON in the same order; we restore only the mutable state)
    if plan.priority_rules and #plan.priority_rules > 0 then
        local pr = {}
        for _, rule in ipairs(plan.priority_rules) do
            table.insert(pr, {
                w = rule.working and 1 or 0,
                k = rule.keep_going and 1 or 0,
            })
        end
        out.priorities = pr
    end

    out.past_initial_phase = plan.past_initial_phase or false
    out.should_search_for_metal = plan.should_search_for_metal or false

    if population then
        out.military_min = population.military_min
        out.military_max = population.military_max
    end

    return out
end

--- Restore serialized data into the plan. rooms_module supplies the
-- room/furniture constructors (df-ai/rooms at runtime, a mock in tests).
-- Returns true when the plan was restored, false when the data does not
-- match this site (or is corrupt) and setup should proceed from scratch.
function M.deserialize(plan, data, rooms_module, population)
    if not data or type(data) ~= 'table' or not data.rooms
        or not rooms_module or not rooms_module.room then
        return false
    end

    -- site discriminator: a re-embark in the same world gets a fresh
    -- site_id; restoring the old fort's plan there would resurrect ghost
    -- rooms (the C++ deleted the .dat file on fort loss instead)
    if data.site_id ~= nil then
        local ok, cur = pcall(function() return df.global.plotinfo.site_id end)
        if not ok or cur ~= data.site_id then
            return false
        end
    end

    local ok_r, err = pcall(function()
        -- pass 1: build all room + furniture objects in flat-index order
        local by_idx = {}
        local serials = {}
        local function rebuild(s)
            local rm = rooms_module.room.new(s.ty,
                { x = s.mn.x, y = s.mn.y, z = s.mn.z },
                { x = s.mx.x, y = s.mx.y, z = s.mx.z },
                {
                    corridor_type = s.ct, farm_type = s.ft,
                    stockpile_type = s.spt, nobleroom_type = s.nrt,
                    outpost_type = s.ot, location_type = s.lt,
                    cistern_type = s.cit, workshop_type = s.wt,
                    furnace_type = s.fct, raw_type = s.rt,
                    comment = s.cm, level = s.lv, noblesuite = s.ns,
                    queue = s.q, outdoor = s.od, temporary = s.tp,
                    build_when_accessible = s.ba,
                    has_users = s.hu, stock_disable = s.sd,
                    stock_specific1 = s.s1, stock_specific2 = s.s2,
                    owner = s.own, bld_id = s.bld, squad_id = s.sq,
                    queue_dig = s.qd,
                })
            rm.status = s.st
            rm.furnished = s.fu
            rm.channeled = s.ch
            rm.required_value = s.rv or 0
            rm.data1 = s.d1 or 0
            rm.data2 = s.d2 or 0
            for _, fs in ipairs(s.ly or {}) do
                local f = rooms_module.furniture.new(fs.ty,
                    fs.p and { x = fs.p.x, y = fs.p.y, z = fs.p.z }
                        or { x = s.mn.x, y = s.mn.y, z = s.mn.z },
                    {
                        construction = fs.co, dig = fs.dg, bld_id = fs.bld,
                        users = fs.us or {}, has_users = fs.hu or 0,
                        ignore = fs.ig, makeroom = fs.mk, internal = fs.it,
                        comment = fs.cm,
                    })
                f._persist_tgr = fs.tgr
                f._persist_tfi = fs.tfi
                table.insert(rm.layout, f)
            end
            table.insert(by_idx, rm)
            table.insert(serials, s)
            return rm
        end

        for _, s in ipairs(data.rooms or {}) do rebuild(s) end
        for _, s in ipairs(data.corridors or {}) do rebuild(s) end
        if data.fe_room_extra then rebuild(data.fe_room_extra) end

        -- pass 2: cross-references
        local function room_at(i)
            return (i and i >= 1 and by_idx[i]) or nil
        end
        for i, s in ipairs(serials) do
            local rm = by_idx[i]
            rm.accesspath = {}
            for _, api in ipairs(s.ap or {}) do
                local pr = room_at(api)
                if pr then table.insert(rm.accesspath, pr) end
            end
            if s.wk then rm.workshop = room_at(s.wk) end
            for fi, f in ipairs(rm.layout) do
                if f._persist_tgr then
                    local tr = room_at(f._persist_tgr)
                    if tr and tr.layout then
                        f.target = tr.layout[(f._persist_tfi or 0) + 1]
                    end
                end
                f._persist_tgr = nil
                f._persist_tfi = nil
            end
        end

        -- install into the plan
        local nrooms = #data.rooms
        plan.rooms = {}
        for i = 1, nrooms do table.insert(plan.rooms, by_idx[i]) end
        plan.corridors = {}
        for i = nrooms + 1, nrooms + #data.corridors do
            table.insert(plan.corridors, by_idx[i])
        end
        plan.room_category = {}
        for _, r in ipairs(plan.rooms) do
            local cat = plan.room_category[r.type] or {}
            table.insert(cat, r)
            plan.room_category[r.type] = cat
        end

        -- fort entrance
        if data.fe_room then
            plan.fort_entrance = room_at(data.fe_room)
        elseif data.fe then
            plan.fort_entrance = { x = data.fe.x, y = data.fe.y, z = data.fe.z }
        else
            plan.fort_entrance = nil
        end

        -- tasks
        local function rebuild_tasks(list)
            local tasks = {}
            for _, ts in ipairs(list or {}) do
                local room = ts.ri and ts.ri >= 1 and by_idx[ts.ri] or nil
                local furn = nil
                if room and ts.fi and ts.fi >= 0 and room.layout then
                    furn = room.layout[ts.fi + 1]
                end
                table.insert(tasks, {
                    type = ts.ty, room = room, furniture = furn,
                    item_id = ts.id or -1, last_status = ts.ls or '',
                })
            end
            return tasks
        end
        plan.tasks_generic = rebuild_tasks(data.tasks_generic)
        plan.tasks_furniture = rebuild_tasks(data.tasks_furniture)

        -- flags
        plan.past_initial_phase = data.past_initial_phase or false
        plan.should_search_for_metal = data.should_search_for_metal or false
        plan.setup_done = true
        plan.builder = nil
        plan.builder_started = true

        -- population thresholds
        if population and data.military_min then
            population.military_min = data.military_min
            population.military_max = data.military_max
        end
    end)

    if not ok_r then
        log_err('[df-ai] persist restore failed: ' .. tostring(err))
        return false
    end

    -- priority-rule latch restore happens after priorities.prepare();
    -- Plan:startup wires this via M.restore_priority_state
    plan._persist_priorities = data.priorities
    return true
end

--- Re-apply priority-rule working latches after priorities.prepare().
function M.restore_priority_state(plan)
    local saved = plan._persist_priorities
    plan._persist_priorities = nil
    if not saved or not plan.priority_rules then return end
    for i, rule in ipairs(plan.priority_rules) do
        local s = saved[i]
        if s then
            rule.working = (s.w == 1)
            rule.keep_going = (s.k == 1) or rule.keep_going
        end
    end
end

-- ============================================================
-- DFHack storage layer
-- ============================================================

--- Serialize + write into the world save. Never throws.
function M.save(plan, population, log_fn)
    local ok, err = pcall(function()
        if not plan or not plan.setup_done then return end
        local data = M.serialize(plan, population)
        -- site discriminator for safe restore after re-embarks
        local ok_s, sid = pcall(function() return df.global.plotinfo.site_id end)
        if ok_s then data.site_id = sid end
        local ok_t, yr = pcall(function() return df.global.cur_year end)
        if ok_t then data.year = yr end
        dfhack.persistent.saveWorldData(PERSIST_KEY, data)
        if log_fn then
            log_fn('plan persisted (' .. #(data.rooms or {}) .. ' rooms, '
                .. #(data.tasks_generic or {}) .. '+'
                .. #(data.tasks_furniture or {}) .. ' tasks)')
        end
    end)
    if not ok then
        log_err('[df-ai] persist failed: ' .. tostring(err))
    end
    return ok
end

--- Read + restore from the world save. Returns true on a successful
-- restore (plan.setup_done becomes true).
function M.load(plan, rooms_module, population, log_fn)
    local ok, data = pcall(function()
        return dfhack.persistent.getWorldData(PERSIST_KEY)
    end)
    if not ok or not data or not data.rooms then
        return false
    end
    local restored = M.deserialize(plan, data, rooms_module, population)
    if restored and log_fn then
        log_fn('plan restored from save: ' .. #(plan.rooms or {})
            .. ' rooms, ' .. #(plan.corridors or {}) .. ' corridors'
            .. (data.year and (' (saved year ' .. data.year .. ')') or ''))
    end
    return restored
end

--- Delete the saved plan (C++ Plan::unpersist — called when the fort is
-- lost so the next embark in this world starts fresh).
function M.clear()
    pcall(function()
        dfhack.persistent.saveWorldData(PERSIST_KEY, { v = FORMAT, cleared = true })
    end)
end

return M
