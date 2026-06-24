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
    self:load_modules()
    if self.population then self.population:startup() end
    if self.plan then self.plan:startup() end
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
    self:clear()
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
end

function AI:unpause()
    if df.global.pause_state then
        dfhack.run_command('multicmd resume; resume')
    end
end

function AI:abandon()
    debug_log('abandoning fortress')
    dfhack.run_command('die')
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

local the_ai = nil

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        if the_ai then
            the_ai:startup()
        end
    elseif sc == SC_MAP_UNLOADED then
        if the_ai then
            the_ai:shutdown()
        end
    end
end

local function print_status()
    if the_ai then
        print(the_ai:status())
    else
        print('df-ai is not running.')
    end
end

local function print_version()
    print('df-ai Lua rewrite for DF 53.14')
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
        print('Available: version, status, report, abandon, enable <opt>, disable <opt>')
    end
end

if dfhack_flags and dfhack_flags.enable then
    if dfhack_flags.enable_state then
        if not the_ai then
            the_ai = AI:new()
            the_ai:init()
        end
        the_ai.enabled = true
        local ok, site = pcall(dfhack.world.getCurrentSite)
        if ok and site then
            the_ai:startup()
        end
        print('df-ai enabled')
    else
        if the_ai then
            the_ai:shutdown()
            the_ai = nil
        end
        print('df-ai disabled')
    end
    return
end

handle_command({...})
