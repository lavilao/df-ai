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
        tick = 0,
    }
    setmetatable(o, Camera)
    return o
end

function Camera:startup()
    self.enabled = self.ai.config.camera ~= false
end

-- Ticks a followed dwarf stays on camera before rotating to the next one
-- (the old df-ai cycled slowly; jumping every tick was nauseating).
local FOLLOW_PERIOD = 1200

function Camera:update()
    if not self.enabled then return end

    local world = df.global.world
    if not world then return end
    local all = world.units.all
    if not all then return end

    self.tick = self.tick + 1

    -- Rebuild the citizen list & rotate the target periodically
    if #self.follow_history == 0 or self.tick % FOLLOW_PERIOD == 0 then
        local hist = {}
        for _, unit in ipairs(all) do
            local ok_c, is_c = pcall(function()
                return dfhack.units.isCitizen(unit, true) and dfhack.units.isAlive(unit)
            end)
            if ok_c and is_c then
                table.insert(hist, unit.id)
            end
        end
        if #hist > 0 then
            self.follow_history = hist
            self.follow_idx = (self.follow_idx % #hist) + 1
            self.following = hist[self.follow_idx]
        end
    end

    if self.following < 0 then return end

    local unit = df.unit.find(self.following)
    if not unit or not dfhack.units.isAlive(unit) then return end

    -- 53.16: getPosition returns x, y, z as THREE values (not a table);
    -- indexing the first one used to throw "attempt to index a number
    -- value" on every camera update.
    local ok_p, x, y, z = pcall(function()
        return dfhack.units.getPosition(unit)
    end)
    if not ok_p or not x or x < 0 or not y or not z then return end

    -- v50 camera: revealInDwarfmodeMap pans the real fortress view (the
    -- old cursor writes only moved the keyboard cursor). pcall-guarded
    -- with the cursor write as a fallback.
    local ok_r = pcall(function()
        dfhack.gui.revealInDwarfmodeMap({ x = x, y = y, z = z }, false, false)
    end)
    if not ok_r then
        pcall(function()
            df.global.cursor.x = x
            df.global.cursor.y = y
            df.global.cursor.z = z
        end)
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
