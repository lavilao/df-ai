--@module = true
-- stocks.lua — item watch/need tracking + manager orders for DF 53.16
local Stocks = {}
Stocks.__index = Stocks

local compat = dfhack.run_script_with_env(nil, 'df-ai/compat', {module = true})

local IT = df.item_type

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
    wheelbarrow = 'wheelbarrow', wood = 'wood',
    bars = 'bars', coins = 'coins', cut_gem = 'cut_gem',
    prepared_meal = 'prepared_meal', seeds = 'seeds', plants = 'plants',
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
    food = 200, food_storage = 10, seeds = 40,
}

-- Raw-id substring -> watch category, for weapons
local WEAPON_CLASS = {
    CROSSBOW = 'weapon_ranged', BOW = 'weapon_ranged', BLOWGUN = 'weapon_ranged',
    AXE_TRAINING = 'weapon_training', SWORD_TRAINING = 'weapon_training',
    PICK = 'pick', BATTLE_AXE = 'axe',
}

-- Raw-id substring -> watch category, for armor pieces (any armor-ish item type)
local ARMOR_CLASS = {
    MAIL_SHIRT = 'armor_torso', BREASTPLATE = 'armor_torso',
    HELM = 'armor_head', CAP = 'armor_head', HOOD = 'armor_head', MASK = 'armor_head',
    GAUNTLETS = 'armor_hands', MITTENS = 'armor_hands',
    HIGH_BOOT = 'armor_feet', LOW_BOOT = 'armor_feet', SHOE = 'armor_feet', BOOT = 'armor_feet',
    GREAVES = 'armor_legs', LEGGINGS = 'armor_legs',
    SHIELD = 'armor_shield', BUCKLER = 'armor_shield',
}

-- Get the raw id string of an item's subtype (e.g. 'ITEM_WEAPON_PICK')
-- or nil when the item has no meaningful subtype.
local function subtype_id(item)
    local st = item:getSubtype()
    if not st or st < 0 then return nil end
    local ok, def = pcall(dfhack.items.getSubtypeDef, item:getType(), st)
    if ok and def and def.id then return def.id end
    return nil
end

-- Map a furniture-ish item_type to its watch category.
local FURNITURE_ITEM_CATEGORY = {
    [IT.BED] = 'bed', [IT.CHAIR] = 'chair', [IT.TABLE] = 'table',
    [IT.DOOR] = 'door', [IT.BOX] = 'chest', [IT.BAG] = 'bag',
    [IT.BIN] = 'bin', [IT.CABINET] = 'cabinet', [IT.WEAPONRACK] = 'weapon_rack',
    [IT.ARMORSTAND] = 'armor_stand', [IT.STATUE] = 'statue', [IT.COFFIN] = 'coffin',
    [IT.SLAB] = 'slab', [IT.QUERN] = 'quern', [IT.MILLSTONE] = 'millstone',
    [IT.CAGE] = 'cage', [IT.BARREL] = 'barrel', [IT.BUCKET] = 'bucket',
    [IT.FLASK] = 'flask', [IT.GOBLET] = 'goblet', [IT.CHAIN] = 'chain',
    [IT.BACKPACK] = 'backpack', [IT.QUIVER] = 'quiver',
    [IT.SPLINT] = 'splint', [IT.TRACTION_BENCH] = 'traction_bench',
    [IT.FLOODGATE] = 'floodgate', [IT.HATCH_COVER] = 'hatch_cover',
    [IT.PIPE_SECTION] = 'pipe_section', [IT.ANVIL] = 'anvil',
}

local TOOL_CLASS = {
    STEPLADDER = 'stepladder', WHEELBARROW = 'wheelbarrow', NEST_BOX = 'nest_box',
    HIVE = 'hive', SCREW = 'screw', JUG = 'jug', PICK = 'pick', AXE = 'axe',
}

local function classify_item(item)
    local t = item:getType()

    -- Weapons: classify by raw id
    if t == IT.WEAPON then
        local sid = subtype_id(item) or ''
        for pat, cat in pairs(WEAPON_CLASS) do
            if sid:find(pat) then return cat end
        end
        return 'weapon_melee'
    end

    -- Armor pieces: several item types, classify by raw id
    if t == IT.ARMOR or t == IT.HELM or t == IT.GLOVES or t == IT.SHOES
        or t == IT.PANTS or t == IT.SHIELD then
        local sid = subtype_id(item) or ''
        for pat, cat in pairs(ARMOR_CLASS) do
            if sid:find(pat) then return cat end
        end
        if t == IT.HELM then return 'armor_head' end
        if t == IT.GLOVES then return 'armor_hands' end
        if t == IT.SHOES then return 'armor_feet' end
        if t == IT.PANTS then return 'armor_legs' end
        if t == IT.SHIELD then return 'armor_shield' end
        return 'armor_torso'
    end

    if t == IT.AMMO then return 'ammo_combat' end
    if t == IT.TRAPCOMP then return 'mechanism' end

    -- Tools: pick/axe/etc by raw id
    if t == IT.TOOL then
        local sid = subtype_id(item) or ''
        for pat, cat in pairs(TOOL_CLASS) do
            if sid:find(pat) then return cat end
        end
        return 'tool'
    end

    -- Food chain: distinct item types in 53.16
    if t == IT.FOOD then return 'prepared_meal' end
    if t == IT.DRINK then return 'drink' end
    if t == IT.MEAT or t == IT.FISH or t == IT.FISH_RAW or t == IT.CHEESE
        or t == IT.EGG or t == IT.GLOB then return 'food' end
    if t == IT.PLANT then return 'plants' end
    if t == IT.SEEDS then return 'seeds' end

    -- Straightforward item types
    local direct = FURNITURE_ITEM_CATEGORY[t]
    if direct then return direct end

    if t == IT.BAR then return 'bars' end
    if t == IT.BOULDER then return 'stone' end
    if t == IT.WOOD then return 'wood' end
    if t == IT.BLOCKS then return 'block' end
    if t == IT.ROUGH then return 'rough_gem' end
    if t == IT.SMALLGEM then return 'cut_gem' end
    if t == IT.CLOTH then return 'cloth' end
    if t == IT.THREAD then return 'thread' end
    if t == IT.SKIN_TANNED then return 'leather' end
    if t == IT.SIEGEAMMO then return 'ammo_combat' end
    if t == IT.COIN then return 'coins' end
    if t == IT.LIQUID_MISC then return 'drink' end
    if t == IT.BOOK then return 'book' end

    return nil
end

function Stocks.new(ai)
    local o = {
        ai = ai,
        count_free = {},
        count_total = {},
        ingots = {},
        farmplots = {},
        last_unforbidall_year = -1,
        updating_seeds = false,
        updating_plants = false,
    }
    setmetatable(o, Stocks)
    return o
end

function Stocks:startup()
    self:count_stocks()
end

function Stocks:update()
    -- Each phase runs independently: a crash in one (e.g. an API field
    -- removed in a future version) must not starve the others.
    local function step(fn, what)
        local ok, err = pcall(fn)
        if not ok then
            dfhack.printerr('[df-ai] stocks ' .. what .. ' failed: ' .. tostring(err))
        end
    end
    step(function() self:count_stocks() end, 'count')
    step(function() self:check_needs() end, 'needs')
    step(function() self:update_plants() end, 'plants')
    step(function() self:unforbid_items() end, 'unforbid')
end

-- ============================================================
-- Stock counting
-- ============================================================

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

            -- Items hauled by jobs don't count as "free"
            if not compat.item_in_job(item) then
                free[key] = (free[key] or 0) + 1
            end
        end

        -- Count bars by metal type
        if item:getType() == IT.BAR then
            local ok, mat = pcall(dfhack.matinfo.decode, item)
            if ok and mat then
                local ok2, mt = pcall(function() return mat:getToken() end)
                if ok2 and mt then
                    local key2 = 'bar_' .. mt
                    total[key2] = (total[key2] or 0) + 1
                    free[key2] = (free[key2] or 0) + 1
                end
            end
        end

        -- Count metal ores
        if item:getType() == IT.BOULDER then
            local ok, mat = pcall(dfhack.matinfo.decode, item)
            if ok and mat then
                local ok2, mt = pcall(function() return mat:getToken() end)
                if ok2 and mt then
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
-- Manager order helpers (53.16 workquota_handlerst)
-- ============================================================

function Stocks:order_exists(job_type, item_type, item_subtype, reaction_name)
    local orders = compat.get_orders_vector()
    if not orders then return false end
    for _, order in ipairs(orders) do
        if order.job_type == job_type
            and order.item_type == (item_type or IT.NONE)
            and order.item_subtype == (item_subtype or -1)
            and (reaction_name == nil or order.reaction_name == reaction_name)
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
    local order = compat.create_order{
        job_type = job_type,
        item_type = item_type,
        item_subtype = item_subtype,
        amount = amount,
        mat_type = mat_type,
        mat_index = mat_index,
    }
    return order ~= nil
end

-- Queue a raw-reaction order (brewing, soap, tanning, ...)
function Stocks:queue_reaction(reaction_name, amount)
    if self:order_exists(df.job_type.CustomReaction, IT.NONE, -1, reaction_name) then
        return false
    end
    local order = compat.create_order{
        job_type = df.job_type.CustomReaction,
        reaction_name = reaction_name,
        amount = amount,
    }
    return order ~= nil
end

-- Queue a furniture order by df-ai category name (bed, chair, ...)
function Stocks:queue_furniture(name, amount)
    local job, item_type, subtype = compat.furniture_order(name)
    if not job then return false end
    return self:queue_order(job, item_type, subtype, amount)
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

    -- r3.5: compat.furniture is keyed by the df-ai furniture names in
    -- UPPER case (BED, CHAIR, TRACTION_BENCH, ...). r3.4 looked them up
    -- with the lowercase watch keys, so EVERY furniture category missed,
    -- fell through to the else branch and just printed "Need more: ..."
    -- over and over — the manager never received a single furniture
    -- order (bed, door, table, coffin, ...). Uppercase the key here and
    -- pass it on to queue_furniture -> compat.furniture_order.
    local furniture_key = item_key == 'food_storage' and 'BOX'
        or item_key == 'rope' and 'ROPE'
        or item_key
    local fkey = furniture_key:upper()
    local fdef = compat.furniture[fkey]
    if fdef and fdef.item_type ~= IT.TOOL then
        self:queue_furniture(fkey, amount)
        return
    end

    if item_key == 'pick' then
        self:queue_order(df.job_type.MakeWeapon, IT.WEAPON, compat.weapon_subtype('PICK'), amount)
    elseif item_key == 'axe' then
        self:queue_order(df.job_type.MakeWeapon, IT.WEAPON, compat.weapon_subtype('BATTLE_AXE'), amount)
    elseif item_key == 'anvil' then
        self:queue_order(df.job_type.ForgeAnvil, IT.ANVIL, -1, 1)
    elseif item_key == 'mechanism' then
        self:queue_order(df.job_type.ConstructMechanisms, IT.TRAPCOMP, -1, amount)
    elseif item_key == 'cloth' then
        self:queue_order(df.job_type.WeaveCloth, IT.CLOTH, -1, amount)
    elseif item_key == 'thread' then
        self:queue_order(df.job_type.SpinThread, IT.THREAD, -1, amount)
    elseif item_key == 'leather' then
        self:queue_reaction(compat.reaction.TanHide, amount)
    elseif item_key == 'soap' then
        self:queue_reaction(compat.reaction.MakeSoapTallow, amount)
    elseif item_key == 'book' then
        self:queue_reaction(compat.reaction.Bookbinding, amount)
    elseif item_key == 'bars' then
        self:queue_smelt_orders()
    elseif item_key == 'drink' or item_key == 'meal' or item_key == 'food'
        or item_key == 'prepared_meal' or item_key == 'seeds' or item_key == 'plants' then
        self:queue_food_orders()
    elseif item_key == 'block' then
        -- r3.5: blocks were falling through to the "Need more" print;
        -- masons can produce them (ConstructBlocks + item_type BLOCKS;
        -- live enum: ConstructBlockS = 80, the singular form is nil).
        self:queue_order(df.job_type.ConstructBlocks, IT.BLOCKS, -1, amount)
    elseif item_key == 'stepladder' or item_key == 'wheelbarrow' or item_key == 'nest_box'
        or item_key == 'hive' or item_key == 'screw' or item_key == 'jug' then
        -- Tool-based furniture
        local sub = compat.tool_subtype(item_key:upper())
        self:queue_order(df.job_type.MakeTool, IT.TOOL, sub, amount)
    elseif item_key:find('weapon_') == 1 or item_key:find('armor_') == 1
        or item_key:find('ammo_') == 1 then
        self:queue_military_orders(item_key, amount)
    else
        -- Categories with no producible manager order ("stone": boulders
        -- only come from mining). r3.4 printed this on EVERY stocks update
        -- (twice a second, forever); now only when the deficit changes.
        self.last_need_print = self.last_need_print or {}
        if self.last_need_print[item_key] ~= amount then
            self.last_need_print[item_key] = amount
            dfhack.println('[df-ai] Need more: ' .. item_key .. ' (x' .. amount .. ')')
        end
    end
end

-- ============================================================
-- Military equipment orders
-- ============================================================

function Stocks:queue_military_orders(item_key, amount)
    if item_key == 'weapon_melee' then
        self:queue_order(df.job_type.MakeWeapon, IT.WEAPON, compat.weapon_subtype('SHORT_SWORD'), amount)
    elseif item_key == 'weapon_ranged' then
        self:queue_order(df.job_type.MakeWeapon, IT.WEAPON, compat.weapon_subtype('CROSSBOW'), amount)
    elseif item_key == 'weapon_training' then
        self:queue_order(df.job_type.MakeWeapon, IT.WEAPON, compat.weapon_subtype('SWORD_TRAINING'), amount)
    elseif item_key == 'ammo_combat' then
        self:queue_order(df.job_type.MakeAmmo, IT.AMMO, compat.ammo_subtype('BOLT'), amount)
    elseif item_key == 'armor_torso' then
        local it, sub = compat.armor_subtype('MAIL_SHIRT')
        self:queue_order(df.job_type.MakeArmor, it, sub, amount)
    elseif item_key == 'armor_head' then
        local it, sub = compat.armor_subtype('HELM')
        self:queue_order(df.job_type.MakeHelm, it, sub, amount)
    elseif item_key == 'armor_feet' then
        local it, sub = compat.armor_subtype('HIGH_BOOT')
        self:queue_order(df.job_type.MakeShoes, it, sub, amount)
    elseif item_key == 'armor_hands' then
        local it, sub = compat.armor_subtype('GAUNTLETS')
        self:queue_order(df.job_type.MakeGloves, it, sub, amount)
    elseif item_key == 'armor_legs' then
        local it, sub = compat.armor_subtype('GREAVES')
        self:queue_order(df.job_type.MakePants, it, sub, amount)
    elseif item_key == 'armor_shield' then
        local it, sub = compat.armor_subtype('SHIELD')
        self:queue_order(df.job_type.MakeShield, it, sub, amount)
    end
end

-- ============================================================
-- Smelting / bars
-- ============================================================

function Stocks:update_ingots()
    self.ingots = {}
    local items = df.global.world.items.all
    if not items then return end
    for _, item in ipairs(items) do
        if item:getType() == IT.BAR then
            local ok, mat = pcall(dfhack.matinfo.decode, item)
            if ok and mat then
                local ok2, mt = pcall(function() return mat:getToken() end)
                if ok2 and mt then
                    self.ingots[mt] = (self.ingots[mt] or 0) + 1
                end
            end
        end
    end
end

function Stocks:queue_smelt_orders()
    self:update_ingots()
    local total_bars = 0
    for _, v in pairs(self.ingots) do
        total_bars = total_bars + v
    end

    if total_bars >= 150 then return end

    -- Find ores to smelt; queue one smelt order with the ore's material
    for key, count in pairs(self.count_free) do
        if key:find('^ore_') then
            local mat_token = key:sub(5)
            if count > 5 then
                local mat = dfhack.matinfo.find(mat_token)
                if mat and mat.type and mat.index then
                    if not self:order_exists(df.job_type.SmeltOre, IT.NONE, -1) then
                        compat.create_order{
                            job_type = df.job_type.SmeltOre,
                            item_type = IT.NONE,
                            mat_type = mat.type,
                            mat_index = mat.index,
                            amount = math.min(count, 10),
                        }
                        return
                    end
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
        self:queue_reaction(compat.reaction.BrewDrink, 10)
    end

    local meals = self.count_free['prepared_meal'] or 0
    if meals < 100 then
        -- PrepareMeal with item_type FOOD (prepared meals are FOOD items)
        self:queue_order(df.job_type.PrepareMeal, IT.FOOD, -1, 10)
    end
end

-- ============================================================
-- Farm management: pick crops, set plant_id per season
-- ============================================================

-- Find a plant raw suitable for farming: prefer drink-producing, then food
-- 53.16 NOTE: EDIBLE_RAW / EDIBLE_COOKED were REMOVED from the
-- plant_raw_flags enum (reading a missing BitArray field THROWS, which
-- used to abort every stocks update). Flag reads are gated on the enum
-- member actually existing, and the whole per-plant read is one pcall.
local PLANT_FLAGS = df and df.plant_raw_flags or nil

function Stocks:pick_farm_plant()
    local world = df.global.world
    if not world or not world.raws then return -1 end
    local plants = world.raws.plants.all
    if not plants then return -1 end
    local best, best_score = -1, -1
    -- r3.5: farm plot plant ids are INDICES into raws.plants.all.
    -- r3.4 assigned `plant.id` — the raw's STRING identifier — to `best`,
    -- and the caller's `plant_id >= 0` then died with
    -- "attempt to compare number with string" (stocks plants phase).
    -- ipairs over a DFHack vector is 0-based, so `i` IS the plant index
    -- (same convention as custom_workshop_index in plan.lua).
    for i, plant in ipairs(plants) do
        local ok_f, seed, spring, grass, tree, drink, mill, edible = pcall(function()
            local function flag(name)
                if not PLANT_FLAGS or PLANT_FLAGS[name] == nil then return false end
                return plant.flags[name] == true
            end
            return flag('SEED'), flag('SPRING'), flag('GRASS'), flag('TREE'),
                flag('DRINK'), flag('MILL'),
                flag('EDIBLE_RAW') or flag('EDIBLE_COOKED')
        end)
        if ok_f and seed and spring and not grass and not tree then
            local score = 0
            if drink then score = score + 3 end
            if mill then score = score + 2 end
            if edible then score = score + 1 end
            if score > best_score then
                best_score = score
                best = i
            end
        end
    end
    return best
end

function Stocks:update_plants()
    if self.updating_plants then return end
    self.updating_plants = true

    local plant_id = self:pick_farm_plant()

    if self.ai and self.ai.plan and plant_id >= 0 then
        for _, r in ipairs(self.ai.plan.rooms) do
            if r.type == 'farmplot' and r.bld_id and r.bld_id >= 0 then
                local bld = df.building.find(r.bld_id)
                if bld and df.building_farmplotst:is_instance(bld) then
                    -- Set the crop for every season (v50 farmplots use
                    -- plant_id[season] instead of the old seasons bool array)
                    for s = 0, 3 do
                        if bld.plant_id[s] == -1 then
                            bld.plant_id[s] = plant_id
                        end
                    end
                end
            end
        end
    end

    self.updating_plants = false
end

-- ============================================================
-- Unforbid items
-- ============================================================

function Stocks:unforbid_items()
    local items = df.global.world.items.all
    if not items then return end
    local year = df.global.cur_year
    if year == self.last_unforbidall_year then return end
    for _, item in ipairs(items) do
        if item.flags and item.flags.forbid then
            item.flags.forbid = false
        end
    end
    self.last_unforbidall_year = year
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
            if count >= 15 then break end
        end
    end
    local n_ingots = 0
    for _ in pairs(self.ingots) do n_ingots = n_ingots + 1 end
    table.insert(parts, '  Ingot types: ' .. n_ingots)
    return table.concat(parts, '\n')
end

return Stocks
