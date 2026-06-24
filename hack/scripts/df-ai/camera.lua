--@module = true

local Camera = {}
Camera.__index = Camera

function Camera.new(ai)
    local o = {
        ai = ai,
        following = -1,
        follow_history = {},
        follow_idx = 0,
        enabled = true,
        target_enemies = false,
        known_hostiles = {},
    }
    setmetatable(o, Camera)
    return o
end

function Camera:startup()
    self.enabled = self.ai.config.camera ~= false
end

function Camera:update()
    if not self.enabled then return end

    local world = df.global.world
    if not world then return end

    -- Update follow history: maintain list of citizens
    local all = world.units.all
    if not all then return end

    -- Rebuild follow history periodically
    self.follow_history = {}
    for _, unit in ipairs(all) do
        if dfhack.units.isCitizen(unit, true) and dfhack.units.isAlive(unit) then
            table.insert(self.follow_history, unit.id)
        end
    end

    if #self.follow_history == 0 then return end

    -- Cycle through dwarves every 120 ticks (about 3 game days)
    if self.follow_idx >= #self.follow_history then
        self.follow_idx = 0
    end

    self.follow_idx = self.follow_idx + 1
    self.following = self.follow_history[self.follow_idx]

    if self.following >= 0 then
        local unit = df.unit.find(self.following)
        if unit and dfhack.units.isAlive(unit) then
            local pos = dfhack.units.getPosition(unit)
            if pos then
                df.global.cursor.x = pos.x
                df.global.cursor.y = pos.y
                df.global.cursor.z = pos.z
            end
        end
    end
end

function Camera:follow_unit(unit_id)
    self.following = unit_id
    -- Find index in history
    for i, uid in ipairs(self.follow_history) do
        if uid == unit_id then
            self.follow_idx = i
            break
        end
    end
end

function Camera:status()
    return '  Following: ' .. (self.following >= 0 and tostring(self.following) or 'none') ..
           '  History: ' .. #self.follow_history .. ' dwarves'
end

return Camera
