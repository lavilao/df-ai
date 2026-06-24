--@module = true

local Stocks = {}
Stocks.__index = Stocks

-- Item count keys used for watch/need tracking
local WATCH_KEYS = {
    ammo_combat = 'ammo_combat', ammo_training = 'ammo_training',
    anvil = 'anvil', armor_feet = 'armor_feet', armor_hands = 'armor_hands',
    armor_head = 'armor_head', armor_legs = 'armor_legs', armor_shield = 'armor_shield',
    armor_stand = 'armor_stand', armor_torso = 'armor_torso', axe = 'axe',
    backpack = 'backpack', bag = 'bag', barrel = 'barrel', bed = 'bed',
    bin = 'bin', block = 'block', bone = 'bone', book = 'book',
    box = 'box', bucket = 'bucket', cabinet = 'cabinet', cage = 'cage',
    chain = 'chain', chair = 'chair', chest = 'chest', cloth = 'cloth',
    coffin = 'coffin', door = 'door', drink = 'drink', flask = 'flask',
    floodgate = 'floodgate', food = 'food', food_storage = 'food_storage',
    goblet = 'goblet', hatch_cover = 'hatch_cover', hive = 'hive',
    instrument = 'instrument', jug = 'jug', leather = 'leather',
    meal = 'meal', mechanism = 'mechanism', metal_ore = 'metal_ore',
    millstone = 'millstone', nest_box = 'nest_box', pick = 'pick',
    pipe_section = 'pipe_section', quern = 'quern', rope = 'rope',
    rough_gem = 'rough_gem', screw = 'screw', slab = 'slab',
    soap = 'soap', splint = 'splint', statue = 'statue',
    stepladder = 'stepladder', stone = 'stone', table = 'table',
    thread = 'thread', tool = 'tool', traction_bench = 'traction_bench',
    weapon_melee = 'weapon_melee', weapon_rack = 'weapon_rack',
    weapon_ranged = 'weapon_ranged', weapon_training = 'weapon_training',
    wheelbarrow = 'wheelbarrow', wood = 'wood', armor_helm = 'armor_helm',
    armor_gauntlets = 'armor_gauntlets', armor_high_boots = 'armor_high_boots',
    armor_mail_shirt = 'armor_mail_shirt', armor_breastplate = 'armor_breastplate',
    armor_greaves = 'armor_greaves', armor_mittens = 'armor_mittens',
    armor_low_boots = 'armor_low_boots', armor_cap = 'armor_cap',
    armor_hood = 'armor_hood', armor_mask = 'armor_mask',
    drink_plant = 'drink_plant', drink_animal = 'drink_animal',
    meal_plant = 'meal_plant', meal_animal = 'meal_animal',
    bars = 'bars', coins = 'coins', cut_gem = 'cut_gem',
    crude_wood = 'crude_wood', prepared_meal = 'prepared_meal',
}

-- Target quantities for each item type
local NEEDS = {
    pick = 3, axe = 3, anvil = 1,
    bed = 30, chair = 30, table = 30, door = 20,
    chest = 20, cabinet = 20, weapon_rack = 6, armor_stand = 6,
    screw = 10, mechanism = 30, bucket = 10, flask = 15,
    goblet = 30, splint = 10, traction_bench = 5, cage = 20,
    barrel = 20, bin = 20, wheelbarrow = 5, stepladder = 3,
    quern = 5, millstone = 1, nest_box = 5, hive = 5,
    statue = 5, slab = 3, coffin = 10,
    weapon_melee = 15, weapon_ranged = 8, weapon_training = 10,
    ammo_combat = 300, ammo_training = 150,
    armor_torso = 10, armor_head = 10, armor_feet = 10,
    armor_hands = 10, armor_legs = 10, armor_shield = 10,
    cloth = 50, thread = 50, leather = 50,
    soap = 10, book = 5,
    bars = 200, block = 300, stone = 100,
    drink = 600, meal = 300, prepared_meal = 100,
    food = 200, food_storage = 10,
}

local FUNCTION_STARTS = {
    df.job_type.MakeWeapon,
    df.job_type.MakeArmor,
    df.job_type.MakeAmmo,
}
local FUNCTION_ENDS = {
    [df.job_type.MakeWeapon] = df.job_type.MakeWeapon + 40,
    [df.job_type.MakeArmor] = df.job_type.MakeArmor + 89,
    [df.job_type.MakeAmmo] = df.job_type.MakeAmmo + 13,
}

function Stocks.new(ai)
    local o = {
        ai = ai,
        count_free = {},
        count_total = {},
        ingots = {},
        farmplots = {},
        seeds = {},
        plants = {},
        last_unforbidall_year = -1,
        last_managerstall = 0,
        updating_seeds = false,
        updating_plants = false,
        updating_corpses = false,
        updating_slabs = false,
        updating_ingots = false,
        updating_farmplots = {},
        metal_pref = {},
        simple_metal_ores = {},
        cant_pickaxe = false,
        order_cooldown = 0,
    }
    setmetatable(o, Stocks)
    return o
end

function Stocks:startup()
    self:reset()
    self:init_metal_prefs()
end

function Stocks:reset()
    self.count_free = {}
    self.count_total = {}
    self.ingots = {}
end

function Stocks:init_metal_prefs()
    -- Prefer iron/steel for weapons/armor, copper for decoration
    self.metal_pref = {
        weapon_melee = { df.job_skill.FORGING, { 'steel', 'iron', 'bronze', 'copper', 'silver' } },
        armor_torso = { df.job_skill.FORGING, { 'steel', 'iron', 'bronze', 'copper' } },
        anvil = { df.job_skill.FORGING, { 'iron', 'steel' } },
    }
end

function Stocks:update()
    if self.order_cooldown > 0 then
        self.order_cooldown = self.order_cooldown - 1
    end

    if self.order_cooldown <= 0 then
        self:count_stocks()
        self:check_needs()
        self.order_cooldown = 5
    end

    self:update_kitchen()
    self:update_plants()
    self:update_corpses()
    self:update_slabs()
    self:update_ingots()
end

-- ============================================================
-- Item counting
-- ============================================================

local function classify_item(item)
    local t = item:getType()
    local st = item:getSubtype()

    if t == df.item_type.WEAPON then
        local sub = df.weapon_subtype[st]
        if not sub then return nil end
        local n = tostring(sub)
        if n:find('BOW') or n:find('CROSSBOW') or n:find('BLOWGUN') then
            return 'weapon_ranged'
        end
        if n:find('AXE_TRAINING') or n:find('SWORD_TRAINING') then
            return 'weapon_training'
        end
        return 'weapon_melee'
    end

    if t == df.item_type.ARMOR then
        local sub_str = tostring(df.armor_subtype[st] or '')
        if sub_str:find('MAIL_SHIRT') or sub_str:find('BREASTPLATE') or sub_str:find('SHIRT') then
            return 'armor_torso'
        end
        if sub_str:find('HELM') or sub_str:find('CAP') or sub_str:find('HOOD') or sub_str:find('MASK') then
            return 'armor_head'
        end
        if sub_str:find('GAUNTLETS') or sub_str:find('MITTENS') then
            return 'armor_hands'
        end
        if sub_str:find('HIGH_BOOT') or sub_str:find('LOW_BOOT') or sub_str:find('SHOE') then
            return 'armor_feet'
        end
        if sub_str:find('GREAVES') or sub_str:find('LEGGINGS') then
            return 'armor_legs'
        end
        if sub_str:find('SHIELD') then
            return 'armor_shield'
        end
        return 'armor_torso'
    end

    if t == df.item_type.AMMO then
        return 'ammo_combat'
    end

    if t == df.item_type.TRAPCOMP then
        return 'mechanism'
    end

    if t == df.item_type.TOOL then
        local sub = df.tool_subtype[st]
        if sub then
            local sn = tostring(sub)
            if sn == 'PICK' then return 'pick' end
            if sn == 'AXE' then return 'axe' end
            if sn == 'STEAM_PUMP' or sn == 'SCREW_PUMP' then return 'tool' end
        end
        return 'tool'
    end

    if t == df.item_type.FURNITURE then
        local sub = df.furniture_subtype[st]
        if sub then
            local sn = tostring(sub)
            if sn == 'BED' then return 'bed' end
            if sn == 'CHAIR' then return 'chair' end
            if sn == 'TABLE' then return 'table' end
            if sn == 'DOOR' then return 'door' end
            if sn == 'CHEST' then return 'chest' end
            if sn == 'CABINET' then return 'cabinet' end
            if sn == 'STATUE' then return 'statue' end
            if sn == 'COFFIN' then return 'coffin' end
            if sn == 'WEAPON_RACK' then return 'weapon_rack' end
            if sn == 'ARMOR_STAND' then return 'armor_stand' end
        end
        return 'furniture'
    end

    if t == df.item_type.FOOD then
        local st_name = tostring(df.food_subtype[st] or '')
        if st_name == 'MEAT' or st_name == 'FISH' or st_name == 'CHEESE' then
            return 'food'
        end
        if st_name:find('PLANT') or st_name:find('MILL') then
            return 'food'
        end
        if st_name == 'DRINK' then
            return 'drink'
        end
        if st_name == 'MEAL' then
            return 'prepared_meal'
        end
        return 'food'
    end

    if t == df.item_type.BAR then
        return 'bars'
    end

    if t == df.item_type.BOULDER then
        return 'stone'
    end

    if t == df.item_type.WOOD then
        return 'wood'
    end

    if t == df.item_type.BLOCK then
        return 'block'
    end

    if t == df.item_type.ROUGH then
        return 'rough_gem'
    end

    if t == df.item_type.SMALLGEM then
        return 'cut_gem'
    end

    if t == df.item_type.PIECES then
        if st == df.furniture_subtype.CHAIN then return 'chain' end
        if st == df.furniture_subtype.ROPE then return 'rope' end
        if st == df.furniture_subtype.BACKPACK then return 'backpack' end
        if st == df.furniture_subtype.QUIVER then return 'tool' end
        if st == df.furniture_subtype.BAG then return 'bag' end
        if st == df.furniture_subtype.FLASK then return 'flask' end
        if st == df.furniture_subtype.GOBLET then return 'goblet' end
        if st == df.furniture_subtype.BUCKET then return 'bucket' end
        if st == df.furniture_subtype.BARREL then return 'barrel' end
        if st == df.furniture_subtype.BIN then return 'bin' end
        if st == df.furniture_subtype.SPLINT then return 'splint' end
        if st == df.furniture_subtype.BOX then return 'food_storage' end
        if st == df.furniture_subtype.JUG then return 'jug' end
        if st == df.furniture_subtype.SLAB then return 'slab' end
        if st == df.furniture_subtype.CAGE then return 'cage' end
        if st == df.furniture_subtype.TRACTION_BENCH then return 'traction_bench' end
        if st == df.furniture_subtype.STEPLADDER then return 'stepladder' end
        if st == df.furniture_subtype.QUERN then return 'quern' end
        if st == df.furniture_subtype.MILLSTONE then return 'millstone' end
        if st == df.furniture_subtype.NEST_BOX then return 'nest_box' end
        if st == df.furniture_subtype.HIVE then return 'hive' end
        if st == df.furniture_subtype.SCREW then return 'screw' end
        if st == df.furniture_subtype.PIPE_SECTION then return 'pipe_section' end
        if st == df.furniture_subtype.HATCH_COVER then return 'hatch_cover' end
        if st == df.furniture_subtype.FLOODGATE then return 'floodgate' end
        if st == df.furniture_subtype.WHEELBARROW then return 'wheelbarrow' end
        return 'furniture'
    end

    if t == df.item_type.CLOTH then
        return 'cloth'
    end

    if t == df.item_type.THREAD then
        return 'thread'
    end

    if t == df.item_type.LEATHER then
        return 'leather'
    end

    if t == df.item_type.SIEGEAMMO then
        return 'ammo_combat'
    end

    if t == df.item_type.COIN then
        return 'coins'
    end

    if t == df.item_type.LIQUID_MISC then
        return 'drink'
    end

    return nil
end

function Stocks:count_stocks()
    local world = df.global.world
    if not world then return end
    local items = world.items.all
    if not items then return end

    local free = {}
    local total = {}

    for _, item in ipairs(items) do
        local key = classify_item(item)
        if key then
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

        -- Count bars by metal type
        if item:getType() == df.item_type.BAR then
            local mat = dfhack.matinfo.decode(item)
            if mat then
                local mt = dfhack.matinfo.getToken(mat)
                if mt then
                    local key2 = 'bar_' .. mt
                    total[key2] = (total[key2] or 0) + 1
                    free[key2] = (free[key2] or 0) + 1
                end
            end
        end

        -- Count metal ores
        if item:getType() == df.item_type.BOULDER then
            local mat = dfhack.matinfo.decode(item)
            if mat then
                local mt = dfhack.matinfo.getToken(mat)
                if mt then
                    local key2 = 'ore_' .. mt
                    total[key2] = (total[key2] or 0) + 1
                    free[key2] = (free[key2] or 0) + 1
                end
            end
        end
    end

    self.count_free = free
    self.count_total = total
end

-- ============================================================
-- Manager order helpers
-- ============================================================

function Stocks:order_exists(job_type, item_type, item_subtype)
    local orders = df.global.world.manager_orders
    if not orders then return false end
    for _, order in ipairs(orders) do
        if order.job_type == job_type
            and order.item_type == item_type
            and order.item_subtype == item_subtype
            and order.amount_left > 0 then
            return true
        end
    end
    return false
end

function Stocks:queue_order(job_type, item_type, item_subtype, amount, mat_type, mat_index)
    if self:order_exists(job_type, item_type, item_subtype) then
        return false
    end

    local order = df.manager_order:new()
    order.job_type = job_type
    order.item_type = item_type
    order.item_subtype = item_subtype or -1
    order.mat_type = mat_type or -1
    order.mat_index = mat_index or -1
    order.amount = amount
    order.amount_left = amount
    order.id = df.global.world.manager_order_next_id
    df.global.world.manager_order_next_id = df.global.world.manager_order_next_id + 1
    order.is_valid = true

    local orders = df.global.world.manager_orders
    if orders then
        orders:insert(#orders, order)
    end
    return true
end

function Stocks:queue_craft(job_type, item_type, item_subtype, amount, material)
    -- material: 'plant_cloth', 'leather', 'stone', 'wood', 'bone', etc.
    local mat_type = -1
    local mat_index = -1

    if material == 'plant_cloth' then
        mat_type = 0
    elseif material == 'leather' then
        mat_type = 0
    elseif material == 'stone' then
        mat_type = 0
    elseif material == 'wood' then
        mat_type = 0
    end

    return self:queue_order(job_type, item_type, item_subtype, amount, mat_type, mat_index)
end

-- ============================================================
-- Need checking and order creation
-- ============================================================

function Stocks:check_needs()
    for key, target in pairs(NEEDS) do
        local current = self.count_free[key] or 0
        if current < target then
            local deficit = target - current
            local order_amount = math.min(deficit, 20)
            self:act(key, order_amount)
        end
    end
end

function Stocks:act(item_key, amount)
    if not amount or amount <= 0 then return end

    if item_key == 'pick' then
        self:queue_order(df.job_type.MakeWeapon, df.item_type.WEAPON, df.weapon_subtype.PICK, amount)
    elseif item_key == 'axe' then
        self:queue_order(df.job_type.MakeWeapon, df.item_type.WEAPON, df.weapon_subtype.BATTLE_AXE, amount)
    elseif item_key == 'anvil' then
        -- Anvils are special: queue MakeWeapon for anvil
        self:queue_order(df.job_type.MakeWeapon, df.item_type.WEAPON, df.weapon_subtype.ANVIL, 1)
    elseif item_key == 'bed' then
        self:queue_order(df.job_type.ConstructBed, df.item_type.FURNITURE, df.furniture_subtype.BED, amount)
    elseif item_key == 'chair' then
        self:queue_order(df.job_type.ConstructChair, df.item_type.FURNITURE, df.furniture_subtype.CHAIR, amount)
    elseif item_key == 'table' then
        self:queue_order(df.job_type.ConstructTable, df.item_type.FURNITURE, df.furniture_subtype.TABLE, amount)
    elseif item_key == 'door' then
        self:queue_order(df.job_type.ConstructDoor, df.item_type.FURNITURE, df.furniture_subtype.DOOR, amount)
    elseif item_key == 'chest' then
        self:queue_order(df.job_type.ConstructChest, df.item_type.FURNITURE, df.furniture_subtype.CHEST, amount)
    elseif item_key == 'cabinet' then
        self:queue_order(df.job_type.ConstructCabinet, df.item_type.FURNITURE, df.furniture_subtype.CABINET, amount)
    elseif item_key == 'weapon_rack' then
        self:queue_order(df.job_type.ConstructWeaponRack, df.item_type.FURNITURE, df.furniture_subtype.WEAPON_RACK, amount)
    elseif item_key == 'armor_stand' then
        self:queue_order(df.job_type.ConstructArmorStand, df.item_type.FURNITURE, df.furniture_subtype.ARMOR_STAND, amount)
    elseif item_key == 'mechanism' then
        self:queue_order(df.job_type.MakeMechanisms, df.item_type.TRAPCOMP, -1, amount)
    elseif item_key == 'quern' then
        self:queue_order(df.job_type.ConstructQuern, df.item_type.FURNITURE, df.furniture_subtype.QUERN, amount)
    elseif item_key == 'millstone' then
        self:queue_order(df.job_type.ConstructMillstone, df.item_type.FURNITURE, df.furniture_subtype.MILLSTONE, amount)
    elseif item_key == 'cage' then
        self:queue_order(df.job_type.ConstructCage, df.item_type.FURNITURE, df.furniture_subtype.CAGE, amount)
    elseif item_key == 'barrel' then
        self:queue_order(df.job_type.MakeBarrel, df.item_type.FURNITURE, df.furniture_subtype.BARREL, amount)
    elseif item_key == 'bucket' then
        self:queue_order(df.job_type.MakeBucket, df.item_type.FURNITURE, df.furniture_subtype.BUCKET, amount)
    elseif item_key == 'flask' then
        self:queue_order(df.job_type.MakeFlask, df.item_type.FURNITURE, df.furniture_subtype.FLASK, amount)
    elseif item_key == 'goblet' then
        self:queue_order(df.job_type.MakeGoblet, df.item_type.FURNITURE, df.furniture_subtype.GOBLET, amount)
    elseif item_key == 'bin' then
        self:queue_order(df.job_type.MakeBin, df.item_type.FURNITURE, df.furniture_subtype.BIN, amount)
    elseif item_key == 'splint' then
        self:queue_order(df.job_type.MakeSplint, df.item_type.FURNITURE, df.furniture_subtype.SPLINT, amount)
    elseif item_key == 'traction_bench' then
        self:queue_order(df.job_type.MakeTractionBench, df.item_type.FURNITURE, df.furniture_subtype.TRACTION_BENCH, amount)
    elseif item_key == 'stepladder' then
        self:queue_order(df.job_type.MakeStepladder, df.item_type.FURNITURE, df.furniture_subtype.STEPLADDER, amount)
    elseif item_key == 'statue' then
        self:queue_order(df.job_type.ConstructStatue, df.item_type.FURNITURE, df.furniture_subtype.STATUE, amount)
    elseif item_key == 'coffin' then
        self:queue_order(df.job_type.ConstructCoffin, df.item_type.FURNITURE, df.furniture_subtype.COFFIN, amount)
    elseif item_key == 'slab' then
        self:queue_order(df.job_type.ConstructSlab, df.item_type.FURNITURE, df.furniture_subtype.SLAB, amount)
    elseif item_key == 'wheelbarrow' then
        self:queue_order(df.job_type.MakeWheelbarrow, df.item_type.FURNITURE, df.furniture_subtype.WHEELBARROW, amount)
    elseif item_key == 'nest_box' then
        self:queue_order(df.job_type.MakeNestBox, df.item_type.FURNITURE, df.furniture_subtype.NEST_BOX, amount)
    elseif item_key == 'hive' then
        self:queue_order(df.job_type.MakeHive, df.item_type.FURNITURE, df.furniture_subtype.HIVE, amount)
    elseif item_key == 'floodgate' then
        self:queue_order(df.job_type.MakeFloodgate, df.item_type.FURNITURE, df.furniture_subtype.FLOODGATE, amount)
    elseif item_key == 'hatch_cover' then
        self:queue_order(df.job_type.MakeHatchCover, df.item_type.FURNITURE, df.furniture_subtype.HATCH_COVER, amount)
    elseif item_key == 'screw' then
        self:queue_order(df.job_type.MakeScrew, df.item_type.FURNITURE, df.furniture_subtype.SCREW, amount)
    elseif item_key == 'pipe_section' then
        self:queue_order(df.job_type.MakePipeSection, df.item_type.FURNITURE, df.furniture_subtype.PIPE_SECTION, amount)
    elseif item_key == 'cloth' then
        self:queue_order(df.job_type.ProcessCloth, df.item_type.CLOTH, -1, amount)
    elseif item_key == 'thread' then
        self:queue_order(df.job_type.ProcessThread, df.item_type.THREAD, -1, amount)
    elseif item_key == 'leather' then
        self:queue_order(df.job_type.TanATanHides, df.item_type.LEATHER, -1, amount)
    elseif item_key == 'soap' then
        self:queue_order(df.job_type.MakeSoap, df.item_type.BAR, -1, amount)
    elseif item_key == 'book' then
        self:queue_order(df.job_type.Bookbinding, df.item_type.TOOL, -1, amount)
    elseif item_key == 'bars' then
        self:queue_smelt_orders()
    elseif item_key == 'drink' or item_key == 'meal' or item_key == 'food' or item_key == 'prepared_meal' then
        self:queue_food_orders()
    elseif item_key:find('weapon_') == 1 or item_key:find('armor_') == 1 or item_key:find('ammo_') == 1 then
        self:queue_military_orders(item_key, amount)
    else
        dfhack.println('[df-ai] Need more: ' .. item_key .. ' (x' .. amount .. ')')
    end
end

-- ============================================================
-- Military equipment orders
-- ============================================================

function Stocks:queue_military_orders(item_key, amount)
    if item_key == 'weapon_melee' then
        self:queue_order(df.job_type.MakeWeapon, df.item_type.WEAPON, df.weapon_subtype.SHORT_SWORD, amount)
    elseif item_key == 'weapon_ranged' then
        self:queue_order(df.job_type.MakeWeapon, df.item_type.WEAPON, df.weapon_subtype.CROSSBOW, amount)
    elseif item_key == 'weapon_training' then
        self:queue_order(df.job_type.MakeWeapon, df.item_type.WEAPON, df.weapon_subtype.SWORD_TRAINING, amount)
    elseif item_key == 'ammo_combat' then
        self:queue_order(df.job_type.MakeAmmo, df.item_type.AMMO, df.ammo_subtype.BOLT, amount)
    elseif item_key == 'armor_torso' then
        self:queue_order(df.job_type.MakeArmor, df.item_type.ARMOR, df.armor_subtype.MAIL_SHIRT, amount)
    elseif item_key == 'armor_head' then
        self:queue_order(df.job_type.MakeArmor, df.item_type.ARMOR, df.armor_subtype.HELM, amount)
    elseif item_key == 'armor_feet' then
        self:queue_order(df.job_type.MakeArmor, df.item_type.ARMOR, df.armor_subtype.HIGH_BOOT, amount)
    elseif item_key == 'armor_hands' then
        self:queue_order(df.job_type.MakeArmor, df.item_type.ARMOR, df.armor_subtype.GAUNTLETS, amount)
    elseif item_key == 'armor_legs' then
        self:queue_order(df.job_type.MakeArmor, df.item_type.ARMOR, df.armor_subtype.GREAVES, amount)
    elseif item_key == 'armor_shield' then
        self:queue_order(df.job_type.MakeArmor, df.item_type.ARMOR, df.armor_subtype.SHIELD, amount)
    end
end

-- ============================================================
-- Smelting / bars
-- ============================================================

function Stocks:update_ingots()
    -- Count bars by type
    self.ingots = {}
    local items = df.global.world.items.all
    if not items then return end
    for _, item in ipairs(items) do
        if item:getType() == df.item_type.BAR then
            local mat = dfhack.matinfo.decode(item)
            if mat then
                local mt = dfhack.matinfo.getToken(mat)
                if mt then
                    self.ingots[mt] = (self.ingots[mt] or 0) + 1
                end
            end
        end
    end
end

function Stocks:queue_smelt_orders()
    -- Count bars
    local total_bars = 0
    for _, v in pairs(self.ingots) do
        total_bars = total_bars + v
    end

    if total_bars >= 150 then return end

    -- Find ores to smelt
    for key, count in pairs(self.count_free) do
        if key:find('^ore_') then
            local metal = key:sub(5)
            if count > 20 then
                local current_bar = self.ingots[metal] or 0
                if current_bar < 30 then
                    self:queue_order(df.job_type.SmeltOre, df.item_type.BAR, -1, math.min(count, 10), -1, -1)
                    return
                end
            end
        end
    end
end

-- ============================================================
-- Food production orders
-- ============================================================

function Stocks:queue_food_orders()
    local drinks = self.count_free['drink'] or 0
    if drinks < 400 then
        self:queue_order(df.job_type.MakeDrink, df.item_type.FOOD, df.food_subtype.DRINK, 10)
    end

    local meals = self.count_free['prepared_meal'] or 0
    if meals < 100 then
        self:queue_order(df.job_type.MakeMeal, df.item_type.FOOD, df.food_subtype.MEAL, 10)
    end
end

-- ============================================================
-- Kitchen management: forbid ingredients, enable cooking
-- ============================================================

function Stocks:update_kitchen()
end

-- ============================================================
-- Farm management: scan plots, queue planting
-- ============================================================

function Stocks:update_plants()
    if self.updating_plants then return end
    self.updating_plants = true

    -- Scan farm plots for missing plants
    if self.ai and self.ai.plan then
        for _, r in ipairs(self.ai.plan.rooms) do
            if r.type == 'farmplot' and r.bld_id >= 0 then
                local bld = df.building.find(r.bld_id)
                if bld and bld:getType() == df.building_type.FarmPlot then
                    local farm = bld
                    -- Set all seasons active
                    farm.seasons[0] = true
                    farm.seasons[1] = true
                    farm.seasons[2] = true
                    farm.seasons[3] = true
                    -- Queue planting if not planted
                    if not farm.planted_tile then
                        farm.plant_now = true
                    end
                end
            end
        end
    end

    self.updating_plants = false
end

-- ============================================================
-- Corpse management
-- ============================================================

function Stocks:update_corpses()
end

-- ============================================================
-- Slab management
-- ============================================================

function Stocks:update_slabs()
end

-- ============================================================
-- Unforbid items
-- ============================================================

function Stocks:unforbid_items()
    local items = df.global.world.items.all
    if not items then return end
    for _, item in ipairs(items) do
        if item.flags and item.flags.forbid then
            item.flags.forbid = false
        end
    end
end

-- ============================================================
-- Status
-- ============================================================

function Stocks:status()
    local parts = {}
    table.insert(parts, '  Watched items:')
    local count = 0
    for k, v in pairs(self.count_free) do
        local target = NEEDS[k]
        if target then
            local status = v >= target and 'OK' or 'LOW'
            table.insert(parts, '    ' .. k .. ': ' .. v .. '/' .. target .. ' ' .. status)
            count = count + 1
            if count >= 15 then
                table.insert(parts, '    ... and ' .. (#self.count_free - 15) .. ' more')
                break
            end
        end
    end
    table.insert(parts, '  Ingots: ' .. #self.ingots)
    return table.concat(parts, '\n')
end

return Stocks
