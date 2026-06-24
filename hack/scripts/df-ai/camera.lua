--@module = true

local Camera = {}
Camera.__index = Camera

function Camera.new(ai)
    local o = {
        ai = ai,
        following = -1,
        enabled = true,
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

    if self.following >= 0 then
        local unit = df.unit.find(self.following)
        if unit and dfhack.units.isAlive(unit) then
            local pos = dfhack.units.getPosition(unit)
            if pos then
                df.global.cursor.x = pos.x
                df.global.cursor.y = pos.y
                df.global.cursor.z = pos.z
            end
            return
        end
    end

    -- Find a dwarf to follow
    local all = world.units.all
    if not all then return end
    for _, unit in ipairs(all) do
        if dfhack.units.isCitizen(unit, true) and dfhack.units.isAlive(unit) then
            local pos = dfhack.units.getPosition(unit)
            if pos then
                self.following = unit.id
                df.global.cursor.x = pos.x
                df.global.cursor.y = pos.y
                df.global.cursor.z = pos.z
                return
            end
        end
    end
end

function Camera:follow_unit(unit_id)
    self.following = unit_id
end

function Camera:status()
    return '  Following: ' .. (self.following >= 0 and tostring(self.following) or 'none')
end

return Camera
