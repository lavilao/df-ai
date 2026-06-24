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
    self.population = require('df-ai.population').new(self)
    self.plan = require('df-ai.plan').new(self)
    self.stocks = require('df-ai.stocks').new(self)
    self.camera = require('df-ai.camera').new(self)
    self.trade = require('df-ai.trade').new(self)
    self.embark = require('df-ai.embark').new(self)
end

function AI:is_dwarfmode_viewscreen()
    local plotinfo = df.global.plotinfo
    if not plotinfo then return false end
    if plotinfo.main.mode ~= df.ui_sidebar_mode.Default then return false end
    if #df.global.world.status.popups > 0 then return false end
    local view = dfhack.gui.getCurViewscreen(false)
    if not view then return false end
    if dfhack.screen.isDismissed(view) then return false end
    if not df.viewscreen_dwarfmodest:is_instance(view) then return false end
    return true
end

function AI:on_state_change(sc)
    if sc == df.state_change_event.SC_MAP_LOADED then
        self:startup()
    elseif sc == df.state_change_event.SC_MAP_UNLOADED then
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
end

function AI:shutdown()
    debug_log('AI shutting down')
    repeatUtil.cancel(GLOBAL_KEY)
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

local the_ai = nil

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == df.state_change_event.SC_MAP_LOADED then
        if the_ai then
            the_ai:startup()
        end
    elseif sc == df.state_change_event.SC_MAP_UNLOADED then
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
        local world = df.global.world
        if world and world.map.block_count > 0 then
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
