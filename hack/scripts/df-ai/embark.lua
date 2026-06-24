--@module = true

local Embark = {}
Embark.__index = Embark

local STATE = {
    IDLE = 'idle',
    WORLD_SELECT = 'world_select',
    SITE_SELECT = 'site_select',
    DWARF_CONFIG = 'dwarf_config',
    ITEMS_CONFIG = 'items_config',
    EMBARKING = 'embarking',
    DONE = 'done',
}

function Embark.new(ai)
    local o = {
        ai = ai,
        is_embarking = false,
        state = STATE.IDLE,
        attempt = 0,
        max_attempts = 30,
        world_id = -1,
        civ_id = -1,
        site_x = 0,
        site_y = 0,
    }
    setmetatable(o, Embark)
    return o
end

function Embark:start_embark()
    dfhack.println('[df-ai] Starting embark sequence...')
    self.is_embarking = true
    self.state = STATE.WORLD_SELECT
    self.attempt = 0

    -- Step 1: Wait for the world to load from abandon
    -- Handled in df-ai.lua's on_state_change for SC_MAP_UNLOADED

    -- Step 2: Select embark site
    if self.ai.config.random_embark then
        self:random_embark()
    end

    return true
end

function Embark:random_embark()
    local world = df.global.world
    if not world then return end

    -- Pick a random site from the current world
    local sites = world.world_data.sites
    if not sites or #sites == 0 then return end

    local attempts = 0
    while attempts < 50 do
        local idx = math.random(1, #sites)
        local site = sites[idx]
        if site and site.type == df.world_site_type.PlayerFortress then
            self.site_x = site.pos.x
            self.site_y = site.pos.y
            dfhack.run_command(string.format('embark %d %d', site.pos.x, site.pos.y))
            self.state = STATE.DWARF_CONFIG
            return
        end
        attempts = attempts + 1
    end

    -- Fallback: embark at random location
    if world.map_extras then
        self.site_x = math.random(10, world.world_data.world_width - 10)
        self.site_y = math.random(10, world.world_data.world_height - 10)
    end
    self.state = STATE.DWARF_CONFIG
end

function Embark:update()
    if not self.is_embarking then return end
    self.attempt = self.attempt + 1
    if self.attempt >= self.max_attempts then
        self.state = STATE.DONE
        self.is_embarking = false
        return
    end

    local screen = dfhack.gui.getCurViewscreen(false)
    if not screen then return end

    -- Check which embark screen we're on
    local vs_type = type(screen)

    if self.state == STATE.DWARF_CONFIG then
        -- Configure dwarves: accept defaults
        dfhack.run_command('embark')
        self.state = STATE.ITEMS_CONFIG
    elseif self.state == STATE.ITEMS_CONFIG then
        -- Configure items: accept defaults
        dfhack.run_command('embark')
        self.state = STATE.EMBARKING
    elseif self.state == STATE.EMBARKING then
        -- Confirm embark
        if df.viewscreen_choose_start_sitest then
            -- Still on site selection, try again
            dfhack.run_command('embark')
        else
            self.state = STATE.DONE
            self.is_embarking = false
        end
    end
end

function Embark:abandon()
    dfhack.run_command('die')
    -- Will trigger SC_MAP_UNLOADED → AI:shutdown() → later AI:startup()
end

function Embark:status()
    return '  Is embarking: ' .. tostring(self.is_embarking) ..
           '  State: ' .. tostring(self.state)
end

return Embark
