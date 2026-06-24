local Stocks = {}
Stocks.__index = Stocks

local STOCK_ITEMS = {
    ammo_combat = true, ammo_training = true, anvil = true,
    armor_feet = true, armor_hands = true, armor_head = true,
    armor_legs = true, armor_shield = true, armor_stand = true,
    armor_torso = true, axe = true, bed = true, block = true,
    bone = true, bucket = true, cabinet = true, cage = true,
    chair = true, chest = true, cloth = true, coffin = true,
    door = true, drink = true, flask = true, floodgate = true,
    food_storage = true, goblet = true, hatch_cover = true,
    leather = true, meal = true, mechanism = true, metal_ore = true,
    pick = true, pipe_section = true, quern = true, rope = true,
    rough_gem = true, screw = true, slab = true, soap = true,
    splint = true, statue = true, stepladder = true, stone = true,
    table = true, thread = true, traction_bench = true,
    weapon_melee = true, weapon_rack = true, weapon_ranged = true,
    weapon_training = true, wheelbarrow = true, wood = true,
}

local DEFAULT_NEEDS = {
    pick = 3, axe = 3, anvil = 1, bed = 20, chair = 20,
    table = 20, door = 10, chest = 20, cabinet = 20,
    screw = 5, mechanism = 10, bucket = 5, flask = 10,
    goblet = 20, splint = 5, crutch = 3, traction_bench = 2,
}

function Stocks.new(ai)
    local o = {
        ai = ai,
        count_free = {},
        count_total = {},
        count_subtype = {},
        ingots = {},
        farmplots = {},
        seeds = {},
        plants = {},
        last_unforbidall_year = -1,
        last_managerstall = -1,
        updating_seeds = false,
        updating_plants = false,
        updating_corpses = false,
        updating_slabs = false,
        updating_ingots = false,
        updating_farmplots = {},
        metal_pref = {},
        simple_metal_ores = {},
        cant_pickaxe = false,
    }
    setmetatable(o, Stocks)
    return o
end

function Stocks:startup()
    self:reset()
end

function Stocks:reset()
    self.count_free = {}
    self.count_total = {}
    self.count_subtype = {}
    self.ingots = {}
end

function Stocks:update()
    self:count_stocks()
    self:update_kitchen()
    self:update_plants()
    self:update_corpses()
    self:update_slabs()
    self:update_ingots()

    for item, need in pairs(DEFAULT_NEEDS) do
        if item == 'pick' or item == 'axe' or item == 'anvil' then
            if (self.count_free[item] or 0) < need then
                self:act(item)
            end
        end
    end
end

function Stocks:count_stocks()
    local world = df.global.world
    if not world then return end
    local items = world.items.all
    if not items then return end

    local free = {}
    local total = {}

    for _, item in ipairs(items) do
        local item_type = item:getType()
        local subtype = item:getSubtype()
        local key = tostring(item_type)

        total[key] = (total[key] or 0) + 1

        local in_job = false
        if item.general_refs then
            for _, ref in ipairs(item.general_refs) do
                if ref:getType() == df.general_ref_type.IS_JOB then
                    in_job = true
                    break
                end
            end
        end

        if not in_job then
            free[key] = (free[key] or 0) + 1
        end
    end

    self.count_free = free
    self.count_total = total
end

function Stocks:update_kitchen()
end

function Stocks:update_plants()
end

function Stocks:update_corpses()
end

function Stocks:update_slabs()
end

function Stocks:update_ingots()
end

function Stocks:act(item_key)
    dfhack.println('[df-ai] Need more: ' .. item_key)
end

function Stocks:status()
    local parts = {}
    table.insert(parts, '  Free items tracked: ' .. #self.count_free)
    table.insert(parts, '  Ingots: ' .. #self.ingots)
    for k, v in pairs(self.count_free) do
        table.insert(parts, '    ' .. k .. ': ' .. v)
    end
    return table.concat(parts, '\n')
end

return Stocks
