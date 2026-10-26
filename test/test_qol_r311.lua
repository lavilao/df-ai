-- test_qol_r311.lua — r3.11 QOL wave: idler sweep + trade automation
--
-- Runs with PLAIN lua5.3. Covers:
--   1. Population:check_idle (the "no dejar enanos en idle" sweep)
--      - missing hauling labors get enabled on idle dwarves
--      - an open unassigned job's labor gets matched to an idle dwarf
--      - busy dwarves untouched; manage_labors='none' disables the sweep
--      - many idlers + zero open jobs -> early stocks audit (once/day)
--   2. Trade automation over the MAPPED v50+ trade UI
--      (df.global.game.main_interface.trade — r3.10 wrongly claimed it
--      was unmapped; the community 'caravan' overlay proves it isn't)
--      - mark_goods policy: skip artifacts, bin contents, keep-list
--      - dedup per open session; re-arm after close
--      - optional SEC_SELECT auto-confirm behind config.trade_confirm
--
-- Usage: lua5.3 test/test_qol_r311.lua   (from the repository root)

local SCRIPTS = 'hack/scripts'
local failures = 0

local function check(cond, msg)
    if cond then
        print('OK   ' .. msg)
    else
        failures = failures + 1
        print('FAIL ' .. msg)
    end
end

-- ============================================================
-- Mock environment (same conventions as unit_fixes.lua)
-- ============================================================

local keys_sent = {}
local cur_screen_mock = nil

local function make_struct(backing, missing)
    missing = missing or {}
    local proxy = {}
    setmetatable(proxy, {
        __index = function(_, k)
            if missing[k] then
                error('Cannot read field ' .. k .. ': not found.', 2)
            end
            return backing[k]
        end,
        __newindex = function(_, k, v)
            if missing[k] then
                error('Cannot write field ' .. k .. ': not found.', 2)
            end
            backing[k] = v
        end,
    })
    return proxy
end

-- 0-based DFHack vector mock (ipairs starts at 0 on 53.16-r3)
local function dfvec(items)
    local n = #items
    local store = {}
    for i, v in ipairs(items) do store[i - 1] = v end
    local proxy = {}
    setmetatable(proxy, {
        __index = function(_, k)
            if type(k) == 'number' then return store[k] end
            return nil
        end,
        __len = function() return n end,
        __ipairs = function()
            local i = -1
            return function()
                i = i + 1
                if i < n then return i, store[i] end
                return nil
            end
        end,
    })
    return proxy
end

local function generic(name)
    local t = {}
    setmetatable(t, {
        __index = function(self, k)
            local v = generic(name .. '.' .. tostring(k))
            rawset(self, k, v)
            return v
        end,
        __newindex = function(self, k, v) rawset(self, k, v) end,
        __call = function() return nil end,
        __tostring = function() return '<mock:' .. name .. '>' end,
    })
    return t
end

local df_mock = generic('df')

local dfhack_mock = {}
dfhack_mock.println = function(...) end
dfhack_mock.printerr = function(...) end
dfhack_mock.run_command = function() end
dfhack_mock.onStateChange = {}
dfhack_mock.gui = {
    getCurViewscreen = function() return cur_screen_mock end,
    getCurFocus = function() return 'dwarfmode/Default' end,
    simulateInput = function(scr, ...)
        local ev = { ... }
        keys_sent[#keys_sent + 1] = ev[1]
        return true
    end,
}
dfhack_mock.units = {
    isCitizen = function(u) return u.citizen == true end,
    isAlive = function(u) return u.alive ~= false end,
    isBaby = function() return false end,
    isChild = function() return false end,
}
dfhack_mock.jobs = {
    getWorker = function(job) return job.worker end,
}
dfhack_mock.items = {
    getValue = function(item) return item.value or 0 end,
    getSubtypeCount = function() return 0 end,
    getSubtypeDef = function() return nil end,
}

dfhack_mock.run_script_with_env = function(env, name, opts)
    if opts and opts.module then
        local chunk, err = loadfile(SCRIPTS .. '/' .. name .. '.lua')
        if not chunk then error('cannot load ' .. name .. ': ' .. tostring(err)) end
        local ok, result = pcall(chunk)
        if not ok then error('load ' .. name .. ' failed: ' .. tostring(result)) end
        return result
    end
    return nil
end

_G.df = df_mock
_G.dfhack = dfhack_mock

package.loaded['gui'] = {
    simulateInput = function(scr, ...)
        local ev = { ... }
        keys_sent[#keys_sent + 1] = ev[1]
        return true
    end,
}
package.loaded['utils'] = {}
package.loaded['repeat-util'] = { scheduleEvery = function() end, cancel = function() end }
package.loaded['json'] = {
    decode_file = function() return nil end,
    encode_file = function() return true end,
    decode = function() return nil end,
    encode = function() return '' end,
}

df_mock.global = {
    world = nil,
    game = { main_interface = { help = { open = false } } },
    plotinfo = make_struct({}, { embark_pos = true }),
    cur_year = 101,
    cur_year_tick = 500,
}

-- ============================================================
-- 1. Population:check_idle — the idler sweep
-- ============================================================
print('--- r3.11 idler sweep (check_idle) ---')
do
    local ok_pop, Population = pcall(dfhack_mock.run_script_with_env,
        nil, 'df-ai/population', { module = true })
    check(ok_pop, 'population module loads')

    local HAUL_ITEM = df.unit_labor.HAUL_ITEM
    local HAUL_WOOD = df.unit_labor.HAUL_WOOD
    local MINE = df.unit_labor.MINE
    check(HAUL_ITEM ~= nil and MINE ~= nil, 'labor enums resolve under the mock')

    -- a dig job is open and unassigned; nobody has MINING
    df_mock.job_type = { attrs = { [3] = { labor = MINE } } }

    local mk = function(id, job, labors)
        return {
            id = id, citizen = true, alive = true,
            job = job and { current_job = job } or nil,
            flags1 = { bits = {} },
            status = { labors = labors },
        }
    end

    local u1 = mk(1, nil, {})                                -- idle, no labors
    local u2 = mk(2, { job_type = 0 }, { [MINE] = true })    -- busy dwarf
    local u3 = mk(3, nil, { [HAUL_ITEM] = true })            -- idle hauler

    df_mock.global.world = {
        units = { active = dfvec({ u1, u2, u3 }) },
        jobs = { list = dfvec({
            { flags = { bits = { suspend = false } }, job_type = 3 },
        }) },
    }

    local pop = Population.new({ config = { manage_labors = 'autolabor' } })
    local ok_ci = pcall(function() pop:check_idle() end)
    check(ok_ci, 'check_idle runs without crashing')

    check(u1.status.labors[HAUL_ITEM] == true and u1.status.labors[HAUL_WOOD] == true,
        'idle dwarf missing hauling labors gets them all')
    local mine_holders = 0
    if u1.status.labors[MINE] == true then mine_holders = mine_holders + 1 end
    if u3.status.labors[MINE] == true then mine_holders = mine_holders + 1 end
    check(mine_holders == 1,
        'the open dig job matched ONE idle dwarf to MINING (autolabor gap)')
    check(u2.status.labors[HAUL_ITEM] ~= true and u2.status.labors[HAUL_ITEM] == nil,
        'busy dwarf untouched (no haul-labor churn on workers)')

    -- manage_labors = 'none': the sweep must do nothing
    local u4 = mk(4, nil, {})
    df_mock.global.world.units.active = dfvec({ u4 })
    df_mock.global.world.jobs.list = dfvec({})
    local pop_none = Population.new({ config = { manage_labors = 'none' } })
    local ok_none = pcall(function() pop_none:check_idle() end)
    check(ok_none and next(u4.status.labors) == nil,
        "manage_labors='none' leaves the player's labors alone")

    -- nudge: 4 idlers + zero open jobs -> one early stocks audit per day
    -- (idlers carry the FULL haul set already, otherwise the sweep would
    -- report haul_fixed > 0 and the queue-dry nudge stays silent)
    local nudged = 0
    local HAUL_LABORS = {
        df.unit_labor.HAUL_ITEM, df.unit_labor.HAUL_WOOD,
        df.unit_labor.HAUL_FOOD, df.unit_labor.HAUL_BODY,
        df.unit_labor.HAUL_REFUSE, df.unit_labor.HAUL_FURNITURE,
        df.unit_labor.HAUL_ANIMALS, df.unit_labor.HAUL_TRADE,
        df.unit_labor.HAUL_WATER, df.unit_labor.HANDLE_VEHICLES,
    }
    local idlers = {}
    for i = 10, 13 do
        local labors = {}
        for _, labor in ipairs(HAUL_LABORS) do labors[labor] = true end
        idlers[#idlers + 1] = mk(i, nil, labors)
    end
    df_mock.global.world.units.active = dfvec(idlers)
    df_mock.global.world.jobs.list = dfvec({})
    local pop_nudge = Population.new({
        config = { manage_labors = 'autolabor' },
        stocks = { update = function() nudged = nudged + 1 end },
    })
    pop_nudge:check_idle()
    check(nudged == 1, 'many idlers with an empty queue poked the stocks engine once')
    pop_nudge:check_idle()
    check(nudged == 1, 'the nudge is throttled to once per in-game day')
end

-- ============================================================
-- 2. Trade automation over the mapped v50+ trade UI
-- ============================================================
print('--- r3.11 trade marking (main_interface.trade) ---')
do
    local ok_tr, Trade = pcall(dfhack_mock.run_script_with_env,
        nil, 'df-ai/trade', { module = true })
    check(ok_tr, 'trade module loads')

    df_mock.item_type = { SEEDS = 5, PLANT = 6, DRINK = 4, CRAFTS = 20, FIGURINE = 21 }

    local crafts = {
        value = 100, flags = { artifact = false },
        getType = function() return 20 end,
    }
    local artifact = {
        value = 9999, flags = { artifact = true },
        getType = function() return 21 end,
    }
    local seeds = {
        value = 5, flags = { artifact = false },
        getType = function() return 5 end,
    }
    local bin_content = {
        value = 50, flags = { artifact = false },
        getType = function() return 21 end,
    }

    local ui = {
        open = true,
        good = { [0] = dfvec({}), [1] = dfvec({ crafts, artifact, seeds, bin_content }) },
        goodflag = { [0] = dfvec({}), [1] = dfvec({
            { selected = false, contained = false },
            { selected = false, contained = false },
            { selected = false, contained = false },
            { selected = false, contained = true },  -- inside a bin
        }) },
    }
    df_mock.global.game = { main_interface = { trade = ui } }

    local t = Trade.new({ config = { trade_confirm = false } })
    t:setup()
    check(t.state ~= 'idle', 'setup arms the trade watcher')

    local ok_p1 = pcall(function() t:perform() end)
    check(ok_p1, 'perform runs against the mapped UI')
    check(ui.goodflag[1][0].selected == true, 'crafts marked for trade')
    check(ui.goodflag[1][1].selected ~= true, 'artifact stays home')
    check(ui.goodflag[1][2].selected ~= true, 'seeds on the keep-list stay home')
    check(ui.goodflag[1][3].selected ~= true,
        'bin contents skipped (their bin carries them)')
    check(t.marked == true, 'marking deduplicated for this open session')

    -- idempotent while the screen stays open
    ui.goodflag[1][1].selected = false
    t:perform()
    check(ui.goodflag[1][1].selected ~= true,
        'no double-marking while the session stays open')

    -- screen closes: the next open re-arms
    ui.open = false
    t:perform()
    check(t.marked == false, 'closing the screen re-arms the marker')
    ui.open = true
    ui.goodflag[1][0].selected = false
    t:perform()
    check(ui.goodflag[1][0].selected == true, 'second session marks again')

    -- caravan leaves: full reset
    t:reset()
    check(t.marked == false and t.state == 'idle', 'reset re-arms for the next visit')

    -- auto-confirm (opt-in) sends exactly one SEC_SELECT
    keys_sent = {}
    cur_screen_mock = {}
    df_mock.interface_key = { SEC_SELECT = 85 }
    local t2 = Trade.new({ config = { trade_confirm = true } })
    ui.goodflag[1][0].selected = false
    t2:setup()
    t2:perform()
    check(keys_sent[1] == 85, 'trade_confirm ON sends one SEC_SELECT confirm')
    keys_sent = {}
    t2:perform()
    check(#keys_sent == 0, 'confirm sent once per session (no key spam)')
end

print(failures == 0 and '=== ALL QOL r3.11 TESTS PASS ==='
    or ('=== ' .. failures .. ' FAILURES ==='))
os.exit(failures == 0 and 0 or 1)
