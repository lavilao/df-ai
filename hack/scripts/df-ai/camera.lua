--@module = true
-- camera.lua — AI camera control (C++ camera.cpp parity, r3.10)
--
-- Priority classes (C++ Camera::update):
--   targets0: primary antagonists (megabeast/semimega/feature beast/
--             titan/demon/night creature)
--   targets1: hostiles (marauders/skeletons/invaders/underworld/
--             uninvited visitors)
--   targets2: citizens, shuffled then sorted by job "boredom" score
--             (Sleep = most boring = highest score)
-- plus: anti-repeat (never re-follow the last 3 units), real follow
-- (plotinfo.follow_unit write, not just a viewport pan).

local Camera = {}
Camera.__index = Camera

-- rotation period: C++ re-picks every 2000 ticks; update() runs every
-- 50 ticks, so rotate every 40th call
local ROTATE_CALLS = 40
local ANTI_REPEAT = 3

function Camera.new(ai)
    local o = {
        ai = ai,
        following = -1,
        follow_prev = {},
        enabled = true,
        tick = 0,
    }
    setmetatable(o, Camera)
    return o
end

function Camera:startup()
    self.enabled = self.ai.config.camera ~= false
    -- C++ fps_meter: show the frame counter while in dwarf mode
    if self.ai.config.fps_meter then
        pcall(function()
            if df.global.gps then df.global.gps.display_frames = 1 end
        end)
    end
end

-- C++ camera.cpp job score: higher = more boring to watch. Citizens are
-- followed lowest-score-first.
local function job_score(unit)
    local job = unit.job and unit.job.current_job
    if not job then return 0 end
    if job.job_type == df.job_type.Sleep then return 100 end
    local cls = nil
    pcall(function() cls = df.job_type.attrs[job.job_type].type end)
    if cls == nil then return 0 end
    local C = df.job_type_class
    if cls == C.Misc then return -20 end
    if cls == C.Digging then return -50 end
    if cls == C.Building then return -35 end
    if cls == C.Hauling then return -40 end
    if cls == C.LifeSupport then return -10 end
    if cls == C.TidyUp then return -20 end
    if cls == C.Leisure then return -20 end
    if cls == C.Gathering then return -30 end
    if cls == C.Manufacture then return -10 end
    return 0
end

local function unit_race_flags(u)
    local flags = nil
    pcall(function()
        local race = df.creature_raw.find(u.race)
        if race then flags = race.flags end
    end)
    return flags
end

local function is_beast(u)
    local f = unit_race_flags(u)
    if not f then return false end
    local F = df.creature_raw_flags
    local names = {
        'HAS_ANY_MEGABEAST', 'HAS_ANY_SEMIMEGABEAST', 'HAS_ANY_FEATURE_BEAST',
        'HAS_ANY_TITAN', 'HAS_ANY_UNIQUE_DEMON', 'HAS_ANY_DEMON',
        'HAS_ANY_NIGHT_CREATURE',
    }
    for _, n in ipairs(names) do
        local v = F[n]
        if v ~= nil then
            local ok, on = pcall(f.is_set, f, v)
            if ok and on then return true end
        end
    end
    return false
end

local function is_hostile(u)
    local yes = false
    pcall(function()
        if u.flags1.bits.marauder or u.flags1.bits.skeleton
            or u.flags1.bits.active_invader
            or u.flags2.bits.underworld
            or u.flags2.bits.visitor_uninvited then
            yes = true
        end
    end)
    return yes
end

function Camera:pick_target()
    local world = df.global.world
    if not world or not world.units or not world.units.active then return end

    local beasts, hostiles, citizens = {}, {}, {}
    for _, u in ipairs(world.units.active) do
        local visible = false
        pcall(function()
            local x, y, z = dfhack.units.getPosition(u)
            if not x or x < 0 then return end
            local b = dfhack.maps.getTileBlock(x, y, z)
            if not b then return end
            -- only a HIDDEN tile excludes a candidate; a block without a
            -- designation table (mock environments) stays visible
            local des = b.designation and b.designation[x % 16]
                and b.designation[x % 16][y % 16]
            if des and des.d and des.d.hidden then return end
            visible = true
        end)
        local inactive = false
        pcall(function() inactive = u.flags1.bits.inactive end)
        if visible and not inactive then
            if is_beast(u) then
                table.insert(beasts, u)
            elseif is_hostile(u) then
                table.insert(hostiles, u)
            elseif dfhack.units.isCitizen(u, true)
                and dfhack.units.isAlive(u) then
                table.insert(citizens, u)
            end
        end
    end

    -- citizens: lowest job score first (C++ sorts by score after shuffle)
    for i = #citizens, 2, -1 do -- small shuffle for variety
        local j = math.random(i)
        citizens[i], citizens[j] = citizens[j], citizens[i]
    end
    table.sort(citizens, function(a, b)
        return job_score(a) < job_score(b)
    end)

    -- anti-repeat: skip the last few followed units when possible
    local function pick(list)
        for _, u in ipairs(list) do
            local fresh = true
            for _, prev in ipairs(self.follow_prev) do
                if prev == u.id then fresh = false break end
            end
            if fresh then return u end
        end
        return list[1]
    end

    local chosen = pick(beasts) or pick(hostiles) or pick(citizens)
    if not chosen then return end

    self.following = chosen.id
    table.insert(self.follow_prev, 1, chosen.id)
    while #self.follow_prev > ANTI_REPEAT do
        table.remove(self.follow_prev)
    end

    -- real follow (C++ sets ui->follow_unit so the view tracks the unit)
    pcall(function()
        df.global.plotinfo.follow_unit = chosen.id
    end)
    self:reveal(chosen)
end

function Camera:reveal(unit)
    local ok_p, x, y, z = pcall(function()
        return dfhack.units.getPosition(unit)
    end)
    if not ok_p or not x or x < 0 or not y or not z then return end
    -- v50 camera: revealInDwarfmodeMap pans the real fortress view (the
    -- old cursor writes only moved the keyboard cursor)
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

function Camera:update()
    if not self.enabled then return end

    local world = df.global.world
    if not world then return end

    self.tick = self.tick + 1

    -- an external follow (user, military screen) takes precedence, like
    -- the C++ "followed unit changed externally" handling
    local ext = -1
    pcall(function() ext = df.global.plotinfo.follow_unit end)
    if ext ~= nil and ext >= 0 and ext ~= self.following then
        self.following = ext
    end

    if self.tick % ROTATE_CALLS == 0
        or self.following == nil or self.following < 0 then
        self:pick_target()
        return
    end

    local unit = df.unit.find(self.following)
    if not unit or not dfhack.units.isAlive(unit) then
        self:pick_target()
        return
    end
    self:reveal(unit)
end

function Camera:follow_unit(unit_id)
    self.following = unit_id
    table.insert(self.follow_prev, 1, unit_id)
    while #self.follow_prev > ANTI_REPEAT do
        table.remove(self.follow_prev)
    end
    pcall(function()
        df.global.plotinfo.follow_unit = unit_id
    end)
    local unit = df.unit.find(unit_id)
    if unit then self:reveal(unit) end
end

function Camera:status()
    return '  Following: ' .. (self.following >= 0 and tostring(self.following) or 'none')
end

return Camera
