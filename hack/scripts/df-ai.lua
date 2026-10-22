--@enable = true
--@module = true

local utils = require('utils')
local repeatutil = require('repeat-util')
local json = require('json')

local GLOBAL_KEY = 'df-ai'

local AI = {}

local function debug_log(...)
    dfhack.println('[df-ai] ', ...)
end

local function load_config()
    local ok, config = pcall(json.decode_file, 'dfhack-config/df-ai.json')
    if not ok or not config then
        config = {}
    end
    return config
end

local function save_config(config)
    json.encode_file(config, 'dfhack-config/df-ai.json', { pretty = true })
end

local function default_config()
    return {
        random_embark = true,
        embark_mode = 'quick',
        random_embark_world = '',
        write_console = true,
        write_log = true,
        record_movie = false,
        no_quit = true,
        embark_options = {
            DimensionX = 3,
            DimensionY = 2,
            AquiferLight = 0,
            AquiferHeavy = 0,
            Savagery = 2,
        },
        world_size = 1,
        camera = true,
        fps_meter = true,
        manage_labors = 'autolabor',
        manage_nobles = true,
        cancel_announce = 0,
        allow_pause = true,
    }
end

function AI:new()
    local o = {
        config = default_config(),
        enabled = false,
        population = nil,
        plan = nil,
        stocks = nil,
        camera = nil,
        trade = nil,
        exclusive = nil,
        exclusive_queue = {},
        onupdate_list = {},
        onstatechange_list = {},
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function AI:init()
    self.config = load_config()
    -- merge defaults for any missing keys. Without this, a missing or
    -- empty config file (json encodes an empty table as []) leaves the
    -- AI with NO config at all — random_embark etc. silently nil.
    local defaults = default_config()
    for k, v in pairs(defaults) do
        if self.config[k] == nil then
            self.config[k] = v
        end
    end
    save_config(self.config)
    self:load_modules()
end

function AI:load_modules()
    local mods = {
        population = 'df-ai/population',
        plan = 'df-ai/plan',
        stocks = 'df-ai/stocks',
        camera = 'df-ai/camera',
        trade = 'df-ai/trade',
        embark = 'df-ai/embark',
    }
    for key, path in pairs(mods) do
        local ok, mod = pcall(dfhack.run_script_with_env, nil, path, {module=true})
        if ok and type(mod) == 'table' and mod.new then
            self[key] = mod.new(self)
        else
            debug_log('failed to load module ' .. path .. ': ' .. tostring(mod))
        end
    end
    -- Load rooms module (not a class, just utility)
    local ok, rooms = pcall(dfhack.run_script_with_env, nil, 'df-ai/rooms', {module=true})
    if ok and type(rooms) == 'table' then
        self.rooms_module = rooms
    end
end

function AI:is_dwarfmode_viewscreen()
    local ok, view = pcall(function()
        return dfhack.gui.getCurViewscreen(false)
    end)
    if not ok or not view then return false end
    if df.viewscreen_dwarfmodest:is_instance(view) then return true end
    return false
end

function AI:on_state_change(sc)
    if sc == SC_MAP_LOADED then
        self:startup()
    elseif sc == SC_MAP_UNLOADED then
        self:shutdown()
    end
end

function AI:startup()
    debug_log('AI starting up')
    -- only (re)load modules if missing — startup can run after init()
    -- already created them, and re-loading would discard module state
    if not self.plan or not self.population then
        self:load_modules()
    end
    if self.population then self.population:startup() end
    if self.plan then
        self.plan:startup()
        -- kick the first plan update immediately so digging starts ASAP
        local ok, err = pcall(function() self.plan:update() end)
        if not ok then debug_log('first plan update failed: ' .. tostring(err)) end
    end
    if self.stocks then self.stocks:startup() end
    if self.camera then self.camera:startup() end
    self:register_repeating_tasks()
    self:unpause()
end

function AI:shutdown()
    debug_log('AI shutting down')
    repeatutil.cancel(GLOBAL_KEY .. '-plan')
    repeatutil.cancel(GLOBAL_KEY .. '-pop')
    repeatutil.cancel(GLOBAL_KEY .. '-pop-deathwatch')
    repeatutil.cancel(GLOBAL_KEY .. '-stocks')
    repeatutil.cancel(GLOBAL_KEY .. '-camera')
    repeatutil.cancel(GLOBAL_KEY .. '-embark')
    self:clear()
    -- if still enabled, re-arm the auto-embark watcher so the
    -- abandon -> new fortress cycle keeps working
    if ai_enabled and self.config and self.config.random_embark then
        self:arm_embark_watch()
    end
end

-- Auto-embark watcher: polls the pre-fortress screens while no map is
-- loaded. Must be armed at enable time (NOT at map load) because worldgen
-- completes without a viewscreen change.
-- NOTE: repeat-util 'ticks' timers do NOT run without a loaded map, so
-- this uses a self-re-arming frame-based dfhack.timeout instead (frames
-- render at the title screen and during worldgen).
function AI:arm_embark_watch()
    local function poll()
        if not ai_enabled or dfhack.isMapLoaded() then
            return -- stop polling; the map-load flow takes over
        end
        local ok, err = pcall(function()
            if the_ai and the_ai.embark then
                the_ai.embark:on_viewscreen()
            end
        end)
        if not ok then
            dfhack.printerr('[df-ai] embark watcher: ' .. tostring(err))
        end
        dfhack.timeout(30, 'frames', poll) -- ~0.5s at 60 fps
    end
    dfhack.timeout(5, 'frames', poll)
end

function AI:clear()
    self.population = nil
    self.plan = nil
    self.stocks = nil
    self.camera = nil
    self.trade = nil
    self.embark = nil
end

function AI:register_repeating_tasks()
    if self.plan then
        repeatutil.scheduleEvery(GLOBAL_KEY .. '-plan', 25, 'ticks', function()
            if self.plan then self.plan:update() end
        end)
    end
    if self.population then
        repeatutil.scheduleEvery(GLOBAL_KEY .. '-pop', 25, 'ticks', function()
            if self.population then self.population:update() end
        end)
        repeatutil.scheduleEvery(GLOBAL_KEY .. '-pop-deathwatch', 1, 'ticks', function()
            if self.population then self.population:deathwatch() end
        end)
    end
    if self.stocks then
        repeatutil.scheduleEvery(GLOBAL_KEY .. '-stocks', 50, 'ticks', function()
            if self.stocks then self.stocks:update() end
        end)
    end
    if self.camera then
        repeatutil.scheduleEvery(GLOBAL_KEY .. '-camera', 5, 'ticks', function()
            if self.camera then self.camera:update() end
        end)
    end
    -- Announcement watcher
    repeatutil.scheduleEvery(GLOBAL_KEY .. '-announce', 10, 'ticks', function()
        self:watch_announcements()
    end)
end

function AI:unpause()
    -- direct state write — the old "multicmd resume; resume" commands
    -- no longer exist in DFHack 50+
    if df.global.pause_state then
        df.global.pause_state = false
    end
end

function AI:abandon()
    debug_log('abandoning fortress')
    dfhack.run_command('die')
end

function AI:watch_announcements()
    local world = df.global.world
    if not world or not world.status then return end
    local announcements = world.status.announcements
    if not announcements then return end

    for _, ann in ipairs(announcements) do
        if ann.flags and (ann.flags.danger or ann.flags.attack) then
            -- Mark hostile creatures nearby
            self:tag_enemies()
            if ann.type then
                local type_name = tostring(ann.type) or 'unknown'
                debug_log('Danger: ' .. type_name)
            end
        end
    end
end

function AI:tag_enemies()
    local world = df.global.world
    if not world then return end
    local units = world.units.all
    if not units then return end

    for _, unit in ipairs(units) do
        -- v50: use DFHack's own-civ check (fort civ is not a simple field anymore)
        if not dfhack.units.isOwnCiv(unit) and dfhack.units.isAlive(unit) then
            local pos = dfhack.units.getPosition(unit)
            if pos then
                -- Follow hostiles if camera is enabled (old df-ai "tagged"
                -- units internally; the 53.16 port tracks them via camera)
                if self.camera and self.camera.enabled then
                    self.camera:follow_unit(unit.id)
                end
            end
        end
    end
end

function AI:status()
    local parts = {'=== df-ai Status ==='}
    if self.population then
        table.insert(parts, self.population:status())
    end
    if self.plan then
        table.insert(parts, self.plan:status())
    end
    if self.stocks then
        table.insert(parts, self.stocks:status())
    end
    return table.concat(parts, '\n')
end

function AI:report()
    return self:status()
end

function AI:spiral_search(origin, max_dist, min_dist, step, fn)
    local min_d = min_dist or 0
    local st = step or 1
    for r = min_d, max_dist, st do
        for dx = -r, r, st do
            local x = origin.x + dx
            for dy = -r, r, st do
                local y = origin.y + dy
                if math.abs(dx) == r or math.abs(dy) == r then
                    local c = { x = x, y = y, z = origin.z }
                    local ok, result = pcall(fn, c)
                    if ok and result then
                        return c
                    end
                end
            end
        end
    end
    return nil
end

function AI:find_room(type, filter)
    if not self.plan then return nil end
    local rooms = self.plan.rooms
    if not rooms then return nil end
    for _, r in ipairs(rooms) do
        if r.type == type then
            if not filter or filter(r) then
                return r
            end
        end
    end
    return nil
end

function AI:find_room_at(c)
    if not self.plan then return nil end
    local rooms = self.plan.rooms
    if not rooms then return nil end
    for _, r in ipairs(rooms) do
        if r:include(c) then
            return r
        end
    end
    return nil
end

-- ============================================================
-- Persistent state
-- ============================================================
-- IMPORTANT: `the_ai` and `ai_enabled` are intentionally GLOBALS
-- (no `local`!). DFHack caches each script's environment table and
-- reuses it across invocations, so globals survive from one run of
-- this script to the next — locals do not.
--
-- Why this matters: on SC_WORLD_LOADED, DFHack's script-manager
-- re-runs EVERY script in module mode (reqscript scan). That
-- re-execution used to re-register dfhack.onStateChange['df-ai']
-- with a closure over a fresh (nil) local `the_ai`, clobbering the
-- real instance created by `enable df-ai` — so the AI silently
-- never started at map load. With env globals, every incarnation of
-- the callback sees the same, persistent state.

-- keep prior values if this env already ran the script before
the_ai = the_ai or nil
ai_enabled = ai_enabled or false

-- Modern DFHack enable API: lets `enable`/`disable`, the control
-- panel and `script-manager` track our state.
function isEnabled()
    return ai_enabled
end

local function safe(fn, what)
    local ok, err = pcall(fn)
    if not ok then
        dfhack.printerr('[df-ai] ' .. what .. ' failed: ' .. tostring(err))
    end
    return ok
end

local function print_status()
    if the_ai then
        print(the_ai:status())
    else
        print('df-ai is not running.')
    end
end

local function print_version()
    print('df-ai Lua rewrite for DF 53.16 (DFHack 53.16-r3)')
    print('Based on BenLubar/df-ai')
end

local function handle_command(args)
    if not args or #args == 0 then
        print_status()
        return
    end

    local cmd = args[1]
    if cmd == 'version' then
        print_version()
    elseif cmd == 'status' then
        print_status()
    elseif cmd == 'embark' then
        -- manual trigger for the auto-embark flow
        if the_ai and the_ai.embark then
            safe(function() the_ai.embark:on_viewscreen(true) end, 'embark')
        else
            print('df-ai is not running (enable it first).')
        end
    elseif cmd == 'report' then
        if the_ai then
            local report = the_ai:report()
            json.encode_file({report = report}, 'df-ai-report.json', {pretty = true})
            print('Report written to df-ai-report.json')
        else
            print('df-ai is not running.')
        end
    elseif cmd == 'abandon' then
        if the_ai then
            the_ai:abandon()
        else
            print('df-ai is not running.')
        end
    elseif cmd == 'enable' and args[2] then
        local sub = args[2]
        print('df-ai option enabled: ' .. sub)
    elseif cmd == 'disable' and args[2] then
        local sub = args[2]
        print('df-ai option disabled: ' .. sub)
    else
        print('Unknown command: ' .. cmd)
        print('Available: version, status, report, abandon, embark, enable <opt>, disable <opt>')
    end
end

-- ============================================================
-- State-change hook (re-registered on every run of this script;
-- idempotent because all state lives in the persistent env above)
-- ============================================================

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        if ai_enabled then
            safe(function()
                if not the_ai then
                    the_ai = AI:new()
                    the_ai:init()
                end
                the_ai:startup()
            end, 'startup')
        end
    elseif sc == SC_MAP_UNLOADED then
        if the_ai then
            safe(function() the_ai:shutdown() end, 'shutdown')
        end
    elseif sc == SC_VIEWSCREEN_CHANGED then
        -- auto-embark watcher (pre-fortress screens only)
        if ai_enabled and the_ai and not dfhack.isMapLoaded() then
            safe(function()
                if the_ai.embark and the_ai.embark.on_viewscreen then
                    the_ai.embark:on_viewscreen()
                end
            end, 'embark watcher')
        end
    end
end

-- Module mode: dfhack.reqscript / run_script_with_env(module=true) expect the
-- module table back. Without this guard the script falls through to
-- handle_command() and prints "df-ai is not running." at every boot
-- (script-manager scans all scripts as modules at DFHack startup).
if moduleMode then
    return AI
end

if dfhack_flags and dfhack_flags.enable then
    if dfhack_flags.enable_state then
        ai_enabled = true
        safe(function()
            if not the_ai then
                the_ai = AI:new()
                the_ai:init()
            end
            -- if a fortress map is already loaded, start right away;
            -- otherwise arm the auto-embark watcher for the title flow
            if dfhack.isMapLoaded() then
                the_ai:startup()
            else
                the_ai:arm_embark_watch()
            end
        end, 'enable')
        print('df-ai enabled' ..
            (the_ai and the_ai.config and the_ai.config.random_embark
                and ' (auto-embark on)' or ''))
    else
        ai_enabled = false
        if the_ai then
            safe(function() the_ai:shutdown() end, 'shutdown')
        end
        the_ai = nil
        print('df-ai disabled')
    end
    return
end

handle_command({...})
