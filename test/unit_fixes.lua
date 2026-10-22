-- unit_fixes.lua — targeted unit tests for the r3.3 fixes
--
-- Runs with PLAIN lua5.3 (same Lua as DFHack 53.16-r3). Complements
-- ci_smoke.lua: instead of only LOADING modules, it CALLS the fixed
-- functions under typed mocks that reproduce DFHack Lua's harshest
-- behavior — reading or writing a struct field that does not exist
-- THROWS (that is what killed AI startup via plotinfo.embark_pos).
--
-- Covered:
--   1. Plan:find_fort_entrance  — odd map sizes (integer coords), tree
--      canopy skipped, no plotinfo.embark_pos anywhere
--   2. AI:watch_announcements   — 53.16 report layout (no flags.danger),
--      no history replay, danger detection by type
--   3. Embark:handle_title      — title screen state machine: Continue /
--      Start / NewWorld, list pages, struct-throw survival
--   4. click_frac               — coordinate scaling 160x66 -> 170x64
--
-- Usage: lua5.3 test/unit_fixes.lua   (from the repository root)

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
-- Mock environment
-- ============================================================

local keys_sent = {}      -- gui.simulateInput recorder
local mouse_pos = {}      -- last gps.mouse_x/y
local cur_screen_mock = nil
local recorded_blocks = {} -- coords passed to getTileBlock

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

-- DFHack vector mock: 0-based indexing AND 0-based ipairs (verified live
-- on DF 53.16-r3: `for i,v in ipairs(vec)` starts at i=0). Lua 5.3 honors
-- the __ipairs metamethod, exactly like DFHack's embedded 5.3.6.
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

-- df: auto-vivifying for everything not explicitly mocked below (modules
-- reference many enums at load time; a plain table would crash on them),
-- with REAL tables assigned on top for the behavior under test.
local function generic(name)
    local t = {}
    setmetatable(t, {
        __index = function(self, k)
            local v = generic(name .. '.' .. tostring(k))
            rawset(self, k, v)
            return v
        end,
        __newindex = function(self, k, v)
            rawset(self, k, v)
        end,
        __call = function() return nil end,
        __tostring = function() return '<mock:' .. name .. '>' end,
    })
    return t
end

local df_mock = generic('df')

df_mock.gps = make_struct({ dimx = 160, dimy = 66, mouse_x = 0, mouse_y = 0 })
df_mock.viewscreen_titlest = { is_instance = function(_, s) return false end }
df_mock.viewscreen_new_regionst = { is_instance = function(_, s) return false end }
df_mock.viewscreen_choose_game_typest = { is_instance = function(_, s) return false end }
df_mock.viewscreen_choose_start_sitest = { is_instance = function(_, s) return false end }
df_mock.viewscreen_setupdwarfgamest = { is_instance = function(_, s) return false end }
df_mock.viewscreen_dwarfmodest = { is_instance = function(_, s) return false end }

df_mock.tiletype_shape = {
    NONE = -1, EMPTY = 0, FLOOR = 1, WALL = 2, RAMP = 3, STAIR_UP = 4,
    STAIR_DOWN = 5, STAIR_UPDOWN = 6, BROOK_TOP = 7, TREE = 8,
}
-- tile value == shape value for simplicity
df_mock.tiletype = {
    attrs = setmetatable({}, { __index = function(_, t) return { shape = t } end }),
}

df_mock.announcement_type = {
    Siege = 1, Ambush = 2, Migrant = 3, CombatAttack = 4, StruckVein = 5,
}
df_mock.title_mode_type = {
    NONE = -1, MAIN_MENU = 0, CONTINUE_INACTIVE = 1,
    CONTINUE_ACTIVE_WORLD = 2, CONTINUE_ACTIVE = 3, ABOUT = 4,
}
df_mock.main_choice_type = {
    NONE = -1, Continue = 0, Start = 1, NewWorld = 2,
    TestingArena = 3, Mods = 4, Settings = 5, AboutDF = 6, Quit = 7,
}
df_mock.help_context_type = { [1] = 'POPUP_A', [2] = 'POPUP_B', [3] = 'OTHER_X' }
df_mock.game_type = { DWARF_MAIN = 0, ADVENTURE_MAIN = 1 }

local dfhack_mock = {}
dfhack_mock.println = function(...) end
dfhack_mock.printerr = function(...) end
dfhack_mock.run_command = function() end
dfhack_mock.isMapLoaded = function() return false end
dfhack_mock.onStateChange = {}
dfhack_mock.timeout = function() end
dfhack_mock.gui = {
    getCurViewscreen = function() return cur_screen_mock end,
    getCurFocus = function() return 'title' end,
}
dfhack_mock.maps = {
    getMapSize = function() return dfhack_mock.__map_size end,
    getTileBlock = function(x, y, z)
        recorded_blocks[#recorded_blocks + 1] = { x = x, y = y, z = z }
        local tile = dfhack_mock.__tile_for_z[z] or 0
        return {
            tiletype = setmetatable({}, { __index = function()
                return setmetatable({}, { __index = function() return tile end })
            end }),
        }
    end,
}
dfhack_mock.run_script_with_env = function(env, name, opts)
    if opts and opts.module then
        local chunk, err = loadfile(SCRIPTS .. '/' .. name .. '.lua')
        if not chunk then error('cannot load ' .. name .. ': ' .. tostring(err)) end
        moduleMode = true
        local ok, result = pcall(chunk)
        moduleMode = nil
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

-- df.global (assignments after mock setup)
df_mock.global = {
    gps = df_mock.gps,
    world = nil,
    game = { main_interface = { help = { open = false } } },
    plotinfo = make_struct({
        tutorial_seen = { insert = function() end },
        tutorial_hide = { insert = function() end },
    }, { embark_pos = true }), -- plotinfo.embark_pos MUST throw if touched
    pause_state = true,
}

-- ============================================================
-- 1. Plan:find_fort_entrance
-- ============================================================
print('--- Plan:find_fort_entrance ---')
do
    local ok_plan, Plan = pcall(dfhack_mock.run_script_with_env, nil, 'df-ai/plan', { module = true })
    check(ok_plan, 'plan module loads')
    local p = Plan.new({ config = {} })

    -- odd map: 97 x 99 x 5; z=4 EMPTY, z=3 TREE canopy, z=2 FLOOR
    dfhack_mock.__map_size = { x = 97, y = 99, z = 5 }
    dfhack_mock.__tile_for_z = { [4] = 0, [3] = 8, [2] = 1 }

    local entrance = p:find_fort_entrance()
    check(entrance ~= nil, 'find_fort_entrance returns a position')
    check(entrance and entrance.x == 48 and entrance.y == 49,
        'integer map center on odd map (48,49), got '
        .. tostring(entrance and entrance.x) .. ',' .. tostring(entrance and entrance.y))
    check(entrance and entrance.z == 2,
        'skips air + tree canopy, lands on surface floor (z=2), got z='
        .. tostring(entrance and entrance.z))
    local all_int = true
    for _, b in ipairs(recorded_blocks) do
        if math.floor(b.x) ~= b.x or math.floor(b.y) ~= b.y then all_int = false end
    end
    check(all_int, 'all tile lookups used integer coordinates')
    check(not pcall(function() return df_mock.global.plotinfo.embark_pos end),
        'sanity: mock really throws on plotinfo.embark_pos (the r3.2 crash)')

    -- no ground anywhere: falls back to top of map instead of nil
    dfhack_mock.__tile_for_z = { [4] = 8, [3] = 8, [2] = 8, [1] = 8, [0] = 8 }
    entrance = p:find_fort_entrance()
    check(entrance ~= nil and entrance.z == 4, 'all-trees map falls back to z=top')
end

-- ============================================================
-- 2. AI:watch_announcements (53.16 report layout)
-- ============================================================
print('--- AI:watch_announcements ---')
do
    local ok_ai, AI = pcall(dfhack_mock.run_script_with_env, nil, 'df-ai', { module = true })
    check(ok_ai, 'df-ai main module loads')
    local ai = AI:new()
    ai:init()

    local tagged = 0
    ai.tag_enemies = function() tagged = tagged + 1 end

    -- history: Siege id=10 already in the list, next id = 11 -> must NOT trigger
    local anns = dfvec({ { id = 10, type = 1 }, { id = 9, type = 3 } })
    df_mock.global.world = {
        status = {
            announcements = anns,
            next_report_id = 11,
        },
    }
    ai:watch_announcements()
    check(tagged == 0, 'existing history does not re-trigger tag_enemies')
    check(ai.last_report_id == 10, 'last_report_id initialized to newest seen id')

    -- new danger report arrives (append via a fresh 0-based vector)
    anns = dfvec({ { id = 10, type = 1 }, { id = 9, type = 3 }, { id = 11, type = 1 } })
    df_mock.global.world.status.announcements = anns
    ai:watch_announcements()
    check(tagged == 1, 'new Siege report triggers tag_enemies exactly once')

    -- new harmless report
    anns = dfvec({ { id = 10, type = 1 }, { id = 9, type = 3 }, { id = 11, type = 1 }, { id = 12, type = 3 } })
    df_mock.global.world.status.announcements = anns
    ai:watch_announcements()
    check(tagged == 1, 'harmless report does not trigger tag_enemies')

    -- reports WITHOUT flags field at all (53.16 danger detection must not
    -- read flags.danger — that field does not exist and would throw)
    local ok_w = pcall(function() ai:watch_announcements() end)
    check(ok_w, 'watch_announcements never throws on the 53.16 report layout')
end

-- ============================================================
-- 3. Embark:handle_title (title state machine)
-- ============================================================
print('--- Embark:handle_title ---')
do
    local ok_emb, Embark = pcall(dfhack_mock.run_script_with_env, nil, 'df-ai/embark', { module = true })
    check(ok_emb, 'embark module loads')

    local function fresh_embark(config)
        local e = Embark.new({ config = config or {
            random_embark = true, embark_continue_fort = true,
        } })
        -- route screen dispatch straight to the title handler
        df_mock.viewscreen_titlest.is_instance = function(_, s) return s == cur_screen_mock end
        return e
    end

    local function title_screen(backing, missing)
        local scr = make_struct(backing, missing)
        cur_screen_mock = scr
        return scr, backing
    end

    -- 3a. MAIN_MENU + fort saves -> Continue highlighted + SELECT
    keys_sent = {}
    local e = fresh_embark()
    local _, backing = title_screen({
        mode = 0,
        menu_line_id = dfvec({ 0, 2, 3, 5, 7 }), -- Continue, NewWorld, Arena, Settings, Quit
        savegame_header_game = dfvec({ { id = 1 } }),
        savegame_header_world = dfvec({ { id = 1 } }),
        selected = -1,
    }, { savegame_header = true }) -- unsuffixed vector missing -> must throw, must survive
    local ok_t = pcall(function() e:on_viewscreen() end)
    check(ok_t, 'handle_title survives struct-throw on missing savegame_header')
    check(backing.selected == 0, 'Continue item highlighted (selected=0, 0-based vector)')
    check(df_mock.gps.mouse_x == 79 and df_mock.gps.mouse_y == 36,
        'Continue (item 0) clicked inside the measured button band (79,36), got '
        .. df_mock.gps.mouse_x .. ',' .. df_mock.gps.mouse_y)
    check(keys_sent[#keys_sent] == 'SELECT', 'SELECT sent for Continue (backup channel)')

    -- 3b. MAIN_MENU, no forts, worlds exist, continue disabled -> Start
    keys_sent = {}
    e = fresh_embark({ random_embark = true, embark_continue_fort = false })
    _, backing = title_screen({
        mode = 0,
        menu_line_id = dfvec({ 1, 2, 3, 5, 7 }), -- Start, NewWorld, Arena, Settings, Quit
        savegame_header_world = dfvec({ { id = 1 } }),
        selected = -1,
    })
    pcall(function() e:on_viewscreen() end)
    check(backing.selected == 0, 'Start item highlighted when continue disabled')

    -- 3c. MAIN_MENU, nothing -> NewWorld
    keys_sent = {}
    e = fresh_embark()
    _, backing = title_screen({
        mode = 0,
        menu_line_id = dfvec({ 2, 3, 5, 7 }), -- NewWorld, Arena, Settings, Quit
        selected = -1,
    })
    pcall(function() e:on_viewscreen() end)
    check(backing.selected == 0, 'NewWorld item highlighted with no saves')
    check(df_mock.gps.mouse_x == 79 and df_mock.gps.mouse_y == 36,
        'NewWorld (item 0) clicked inside the measured button band (79,36), got '
        .. df_mock.gps.mouse_x .. ',' .. df_mock.gps.mouse_y)

    -- 3d. CONTINUE_ACTIVE save list -> row 0 selected + SELECT
    keys_sent = {}
    e = fresh_embark()
    _, backing = title_screen({
        mode = 3, -- CONTINUE_ACTIVE
        savegame_header_game = dfvec({ { id = 1 } }),
        selected = -1,
        selected_r = -1,
    })
    pcall(function() e:on_viewscreen() end)
    check(backing.selected == 0 and backing.selected_r == 0,
        'save list: first row selected (selected/selected_r = 0)')
    check(df_mock.gps.mouse_x == 79,
        'save list click uses the center column (x=79), got '
        .. df_mock.gps.mouse_x)
    local has_select = false
    for _, k in ipairs(keys_sent) do if k == 'SELECT' then has_select = true end end
    check(has_select, 'SELECT sent on save list (backup channel)')

    -- 3e. saw Continue on the menu (goal cached), then landed on the
    -- Start world list -> back out to the main menu
    keys_sent = {}
    e = fresh_embark()
    title_screen({
        mode = 0,
        menu_line_id = dfvec({ 0, 2, 3, 5, 7 }), -- Continue present
        savegame_header_game = dfvec({ { id = 1 } }),
        selected = -1,
    })
    pcall(function() e:on_viewscreen() end)
    check(e.want_continue == true, 'continue goal cached from the main menu')
    title_screen({
        mode = 1, -- CONTINUE_INACTIVE (Start world list)
        selected = 0,
    })
    pcall(function() e:on_viewscreen() end)
    check(keys_sent[#keys_sent] == 'LEAVESCREEN', 'wrong list page: LEAVESCREEN back to menu')

    -- 3f. retries stop after the cap without crashing
    local e2 = fresh_embark()
    local _, b2 = title_screen({
        mode = 0,
        menu_line_id = dfvec({ 0, 2 }),
        savegame_header_game = dfvec({ { id = 1 } }),
        selected = -1,
    })
    local crashed = false
    for i = 1, 15 do
        local ok = pcall(function() e2:on_viewscreen() end)
        if not ok then crashed = true end
    end
    check(not crashed, '15 consecutive handle_title polls do not crash')
    check(b2.selected == 0, 'selection kept stable across retries')
end

-- ============================================================
-- 4. click_frac scaling (160x66 reference -> 170x64 user grid)
-- ============================================================
print('--- click_frac scaling ---')
do
    local ok_emb2, Embark2 = pcall(dfhack_mock.run_script_with_env, nil, 'df-ai/embark', { module = true })
    check(ok_emb2, 'embark module reloads for click test')
    -- reach the local click_frac through the module's public surface:
    -- Embark:select_site is not needed; instead verify through gps writes
    -- made by a handled quick-start dialog click on the site screen.
    local e = Embark2.new({ config = { random_embark = true } })
    df_mock.viewscreen_titlest.is_instance = function() return false end
    df_mock.viewscreen_choose_start_sitest.is_instance = function(_, s) return s == cur_screen_mock end

    -- site screen in quick mode with the tutorial dialog open
    df_mock.global.game.main_interface.help.open = true
    cur_screen_mock = make_struct({}, {})
    df_mock.gps.dimx = 170
    df_mock.gps.dimy = 64
    keys_sent = {}
    pcall(function() e:on_viewscreen() end)
    check(df_mock.gps.mouse_x == 98 and df_mock.gps.mouse_y == 36,
        'quick-start click scales to 170x64 (98,36), got '
        .. df_mock.gps.mouse_x .. ',' .. df_mock.gps.mouse_y)
    check(keys_sent[#keys_sent] == '_MOUSE_L', 'mouse click injected')

    -- reference grid reproduces the original 92,37 measurement
    df_mock.global.game.main_interface.help.open = true
    local e3 = Embark2.new({ config = { random_embark = true } })
    df_mock.gps.dimx = 160
    df_mock.gps.dimy = 66
    pcall(function() e3:on_viewscreen() end)
    check(df_mock.gps.mouse_x == 92 and df_mock.gps.mouse_y == 37,
        'reference 160x66 grid reproduces the measured (92,37), got '
        .. df_mock.gps.mouse_x .. ',' .. df_mock.gps.mouse_y)
end

-- ============================================================
print(failures == 0 and '=== ALL UNIT TESTS PASS ==='
    or ('=== ' .. failures .. ' FAILURES ==='))
os.exit(failures == 0 and 0 or 1)
