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

-- Raw-id substring -> watch category, for weapons
local WEAPON_CLASS = {
    CROSSBOW = 'weapon_ranged', BOW = 'weapon_ranged', BLOWGUN = 'weapon_ranged',
    AXE_TRAINING = 'weapon_training', SWORD_TRAINING = 'weapon_training',
    PICK = 'pick', BATTLE_AXE = 'axe',
}

-- ============================================================
-- r3.9: the C++ Watch tier (stocks.cpp Watch::load_defaults) —
-- population-scaled quotas. num_needed(k) = needed[k] +
-- citizens * per_dwarf[k] / 100; the manager order is
-- num_needed * 3 / 2 - count_free (C++ Stocks::act). Only keys the
-- classifier above can actually COUNT are listed — an uncountable
-- key would order forever (one order at a time) with no feedback.
-- ============================================================
local WATCH = {
    needed = {
        ammo_combat = 50, anvil = 1,
        armor_feet = 4, armor_hands = 4, armor_head = 2, armor_legs = 2,
        armor_shield = 2, armor_stand = 1, armor_torso = 2,
        axe = 2, backpack = 2, bag = 3, barrel = 4, bed = 4, bin = 4,
        block = 6, bookcase = 2, bucket = 2, cabinet = 4, cage = 3,
        chair = 3, chest = 4, coal = 12, coffin = 2, crafts = 50,
        crutch = 1, die = 3, door = 4, drink = 50, dye = 10, flask = 2,
        floodgate = 1, food_storage = 4, goblet = 10, hatch_cover = 2,
        hive = 1, jug = 1, meal = 20, mechanism = 4, nest_box = 1,
        pick = 2, pipe_section = 1, quern = 3, quiver = 2, rope = 1,
        screw = 1, slab = 1, soap = 1, splint = 1, stepladder = 2,
        table = 3, toy = 2, traction_bench = 1, weapon_melee = 2,
        weapon_rack = 1, weapon_ranged = 2, wheelbarrow = 1, wood = 16,
        ash = 1, potash = 5,
        -- cloth-chain (counted via cloth / clothes_* below)
        cloth = 1,
        clothes_feet = 4, clothes_hands = 4, clothes_head = 2,
        clothes_legs = 2, clothes_torso = 2,
    },
    per_dwarf = {
        ammo_combat = 250, ammo_training = 250,
        armor_feet = 6, armor_hands = 6, armor_head = 3, armor_legs = 3,
        armor_shield = 3, armor_torso = 3,
        cloth = 20,
        clothes_feet = 40, clothes_hands = 40, clothes_head = 20,
        clothes_legs = 20, clothes_torso = 20,
        crafts = 50, drink = 200, meal = 100, potash = 15, slab = 10,
        soap = 20, toy = 5, weapon_melee = 5, weapon_ranged = 5,
    },
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
    [IT.FLASK] = 'flask', [IT.GOBLET] = 'goblet', [IT.CHAIN] = 'rope',
    [IT.BACKPACK] = 'backpack', [IT.QUIVER] = 'quiver',
    [IT.SPLINT] = 'splint', [IT.TRACTION_BENCH] = 'traction_bench',
    [IT.FLOODGATE] = 'floodgate', [IT.HATCH_COVER] = 'hatch_cover',
    [IT.PIPE_SECTION] = 'pipe_section', [IT.ANVIL] = 'anvil',
}

local TOOL_CLASS = {
    STEPLADDER = 'stepladder', WHEELBARROW = 'wheelbarrow', NEST_BOX = 'nest_box',
    HIVE = 'hive', SCREW = 'screw', JUG = 'jug', PICK = 'pick', AXE = 'axe',
}

-- clothing material tokens (matinfo token substrings): an armor-type
-- item made of these is CLOTHING, not armor (C++ checks material flags)
local CLOTH_MAT = { CLOTH = true, SILK = true, YARN = true, LEATHER = true }

-- r3.9: memoized material token per (mat_type, mat_index) — shared by
-- classify (clothes vs armor) and count_stocks (bar aliases). One
-- matinfo.decode + getToken per UNIQUE material, not per item.
local MAT_TOK = {}
local function mat_token(item)
    local ck = item.mat_type .. ':' .. item.mat_index
    local tok = MAT_TOK[ck]
    if tok == nil then
        local ok, mat = pcall(dfhack.matinfo.decode, item)
        if ok and mat then
            local ok2, tk = pcall(function() return mat:getToken() end)
            tok = (ok2 and tk) or false
        else
            tok = false
        end
        MAT_TOK[ck] = tok
    end
    return tok or nil
end

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

    -- Ammo: training ammo by raw id (C++ stock_item::ammo_training)
    if t == IT.AMMO then
        local sid = subtype_id(item) or ''
        if sid:find('TRAINING') then return 'ammo_training' end
        return 'ammo_combat'
    end

    -- Armor pieces: several item types, classify by raw id
    if t == IT.ARMOR or t == IT.HELM or t == IT.GLOVES or t == IT.SHOES
        or t == IT.PANTS or t == IT.SHIELD then
        local sid = subtype_id(item) or ''
        -- r3.9: CLOTH/SILK/YARN/LEATHER versions of the same subtypes
        -- are CLOTHING (C++ checks the material flags; we check the
        -- memoized matinfo token — same result, one decode per material)
        local tok = mat_token(item) or ''
        local is_cloth = false
        for cm in pairs(CLOTH_MAT) do
            if tok:find(cm) then is_cloth = true break end
        end
        local prefix = is_cloth and 'clothes_' or 'armor_'
        for pat, cat in pairs(ARMOR_CLASS) do
            if sid:find(pat) then
                -- ARMOR_CLASS values are armor_*; swap the prefix for
                -- clothing (armor_torso <-> clothes_torso)
                return prefix .. cat:gsub('^armor_', '')
            end
        end
        if is_cloth then
            if t == IT.HELM then return 'clothes_head' end
            if t == IT.GLOVES then return 'clothes_hands' end
            if t == IT.SHOES then return 'clothes_feet' end
            if t == IT.PANTS then return 'clothes_legs' end
            if t == IT.SHIELD then return 'armor_shield' end
            return 'clothes_torso'
        end
        if t == IT.HELM then return 'armor_head' end
        if t == IT.GLOVES then return 'armor_hands' end
        if t == IT.SHOES then return 'armor_feet' end
        if t == IT.PANTS then return 'armor_legs' end
        if t == IT.SHIELD then return 'armor_shield' end
        return 'armor_torso'
    end

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
    if t == IT.FOOD then return 'meal' end
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

    -- r3.9: C++ Watch keys the old classifier missed
    if t == IT.POWDER_MISC then return 'dye' end
    if t == IT.CRAFT then return 'crafts' end
    if t == IT.TOY then return 'toy' end
    if t == IT.DIE then return 'die' end
    if t == IT.BOOKCASE then return 'bookcase' end

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
    step(function() self:trim_stalled_orders() end, 'trim')
    step(function() self:update_plants() end, 'plants')
    step(function() self:unforbid_items() end, 'unforbid')
end

-- r3.9: C++ Stocks::update monthly trim — if the FRONT manager order
-- is validated but not completing and is the same job as last month,
-- shave 3 off it (or remove it entirely when almost done). Keeps a
-- single impossible order from blocking the whole queue forever.
function Stocks:trim_stalled_orders()
    local month = math.floor((df.global.cur_year_tick or 0) / (28 * 1200))
    if month == (self.last_managerstall or -1) then return end
    self.last_managerstall = month
    local orders = compat.get_orders_vector()
    if not orders or #orders == 0 then return end
    -- DFHack vectors are 0-based; #orders counts entries
    local m = orders[0]
    if not m then return end
    local ok, validated = pcall(function() return m.status.validated end)
    if not ok or not validated then return end
    if m.job_type == (self.last_managerorder or -1) then
        if m.amount_left > 3 then
            m.amount_left = m.amount_left - 3
            m.amount_total = math.max(m.amount_total - 3, m.amount_left)
        else
            local okd, errd = pcall(function()
                local h = df.global.world.manager_orders
                if h and h.all then h.all:erase(0) end
            end)
            if not okd then
                dfhack.printerr('[df-ai] stocks trim failed: ' .. tostring(errd))
            end
        end
    else
        self.last_managerorder = m.job_type
    end
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
        local k = classify_item(item)
        if k then
            total[k] = (total[k] or 0) + 1

            -- Items hauled by jobs don't count as "free"
            if not compat.item_in_job(item) then
                free[k] = (free[k] or 0) + 1
            end
        end

        -- Count bars by material / boulders as ore + bar material
        -- aliases for the C++ Watch keys (coal/ash/potash/soap are all
        -- BAR items with specific materials)
        local t = item:getType()
        if t == IT.BAR or t == IT.BOULDER then
            local tok = mat_token(item)
            if tok then
                if t == IT.BAR then
                    total['bar_' .. tok] = (total['bar_' .. tok] or 0) + 1
                    free['bar_' .. tok] = (free['bar_' .. tok] or 0) + 1
                    if tok:find('COAL') or tok:find('CHARCOAL') then
                        total.coal = (total.coal or 0) + 1
                        free.coal = (free.coal or 0) + 1
                    end
                    if tok:find('ASH') then
                        total.ash = (total.ash or 0) + 1
                        free.ash = (free.ash or 0) + 1
                        if tok:find('POTASH') then
                            total.potash = (total.potash or 0) + 1
                            free.potash = (free.potash or 0) + 1
                        end
                    end
                    if tok:find('SOAP') then
                        total.soap = (total.soap or 0) + 1
                        free.soap = (free.soap or 0) + 1
                    end
                else
                    total['ore_' .. tok] = (total['ore_' .. tok] or 0) + 1
                    free['ore_' .. tok] = (free['ore_' .. tok] or 0) + 1
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
    -- r3.9: C++ Stocks::add_manager_order amount accounting: subtract
    -- what matching orders still have left; if something is already
    -- queued and the remainder is small (< 5), do not top it up.
    local already = 0
    local orders = compat.get_orders_vector()
    if orders then
        for _, order in ipairs(orders) do
            if order.job_type == job_type
                and order.item_type == (item_type or IT.NONE)
                and order.item_subtype == (item_subtype or -1)
                and order.mat_type == (mat_type or -1)
                and order.mat_index == (mat_index or -1)
                and order.amount_left > 0 then
                already = already + order.amount_left
            end
        end
    end
    if already > 0 then
        amount = amount - already
        if amount < 5 then return false end
    end
    if amount <= 0 then return false end
    local order = compat.create_order{
        job_type = job_type,
        item_type = item_type,
        item_subtype = item_subtype,
        amount = amount,
        mat_type = mat_type,
        mat_index = mat_index,
    }
    if order then
        -- r3.6: every queued manager order is logged (once) so the
        -- console shows what production the AI actually ordered.
        -- (enum tables do NOT iterate with pairs() — use the numeric
        -- range with reverse lookup, same lesson as keyhunt)
        local ok_n, name = pcall(function()
            local jt = df.job_type
            for v = jt._first_item or 0, jt._last_item or 999 do
                if v == job_type then return jt[v] end
            end
            return tostring(job_type)
        end)
        self._order_log = self._order_log or {}
        local key = tostring(name) .. '/' .. tostring(item_subtype)
        if not self._order_log[key] then
            self._order_log[key] = true
            dfhack.println('[df-ai:stocks] manager order queued: ' .. tostring(name)
                .. ' x' .. tostring(amount))
        end
    end
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

-- r3.8: a bare job order with no item type (MilkCreature, ShearCreature,
-- EngraveSlab — the C++ manager_order_template with just a job_type).
-- Deduped against identical orders already in the queue.
function Stocks:queue_job_amount(job, amount)
    local already = 0
    local orders = compat.get_orders_vector()
    if orders then
        for _, order in ipairs(orders) do
            if order.job_type == job and order.item_type == IT.NONE then
                already = already + (order.amount_left or 0)
            end
        end
    end
    if already >= amount then return false end
    local order = compat.create_order{
        job_type = job,
        item_type = IT.NONE,
        item_subtype = -1,
        amount = amount - already,
    }
    return order ~= nil
end

-- C++ Stocks::queue_slab — a memorial slab for a restless ghost
-- (skips histfigs that already have an engraved memorial slab)
function Stocks:queue_slab(histfig_id)
    if not histfig_id or histfig_id < 0 then return false end
    local ok, has = pcall(function()
        local slabs = df.global.world.items.other[df.items_other_id.SLAB]
        for _, item in ipairs(slabs or {}) do
            if df.item_slabst:is_instance(item)
                and item.engraving_type == df.slab_engraving_type.Memorial
                and item.topic == histfig_id then
                return true
            end
        end
        return false
    end)
    if ok and has then return false end
    local order = compat.create_order{
        job_type = df.job_type.EngraveSlab,
        item_type = IT.NONE,
        item_subtype = -1,
        amount = 1,
        hist_figure_id = histfig_id,
    }
    return order ~= nil
end

-- ============================================================
-- Need checking and order creation
-- ============================================================

-- C++ Stocks::num_needed — population-scaled quota
function Stocks:num_needed(key)
    local base = WATCH.needed[key]
    if not base then return nil end
    local amount = base
    local pd = WATCH.per_dwarf[key]
    if pd then
        local citizens = 0
        if self.ai and self.ai.population then
            citizens = self.ai.population:citizen_count()
        end
        amount = amount + math.floor(citizens * pd / 100)
    end
    return amount
end

function Stocks:check_needs()
    -- C++ Stocks::act for every Needed key: when free < quota, order
    -- quota * 3 / 2 - free (the 3/2 headroom avoids re-ordering the
    -- moment one item gets consumed)
    for key in pairs(WATCH.needed) do
        local quota = self:num_needed(key)
        local current = self.count_free[key] or 0
        if current < quota then
            local order_amount = math.floor(quota * 3 / 2) - current
            if order_amount > 0 then
                self:act(key, order_amount)
            end
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
        or item_key == 'seeds' or item_key == 'plants' then
        self:queue_food_orders(item_key, amount)
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

function Stocks:queue_food_orders(item_key, amount)
    amount = amount or 10
    if item_key == nil or item_key == 'drink' then
        self:queue_reaction(compat.reaction.BrewDrink, amount)
    end

    if item_key == nil or item_key == 'meal' then
        -- PrepareMeal with item_type FOOD (prepared meals are FOOD items)
        self:queue_order(df.job_type.PrepareMeal, IT.FOOD, -1, amount)
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
    local ok, err = pcall(function() self:farm_setup() end)
    if not ok then
        dfhack.printerr('[df-ai] farm setup failed: ' .. tostring(err))
    end
    self.updating_plants = false
end

-- r3.9: C++ Stocks::farm_setup + Stocks::farmplot — per-SEASON crop
-- selection for every farm plot. The C++ logic, kept intact:
--   * candidates = plants that grow in the plot's biome (BIOME_* flag),
--     are not trees, and have seeds
--   * first plot of each (farm_type, outdoor): the drink+edible staple
--   * other food plots: anything edible/drinkable/millable
--   * cloth plots: thread plants, then dye plants as fallback
--   * per-season score: plants grown - seeds owned + 18 * plots already
--     growing it this season (spread the fields)

-- safe plant flag read (BitArray named reads THROW on removed members;
-- 53.16 verified present: SEED TREE GRASS DRINK THREAD MILL + seasons)
local function pflag(p, flag)
    if not p or flag == nil then return false end
    local ok, v = pcall(function() return p.flags[flag] == true end)
    return ok and v or false
end

local BIOME_FLAG_PREFIX = 'BIOME_'

function Stocks:farm_setup()
    local world = df.global.world
    if not world or not world.raws then return end
    local plants = world.raws.plants.all
    if not plants or #plants == 0 then return end

    if not self.ai or not self.ai.plan then return end

    -- collect farmplot rooms with live buildings
    local plots = {}
    for _, r in ipairs(self.ai.plan.rooms) do
        if r.type == 'farmplot' and r.bld_id and r.bld_id >= 0 then
            local bld = df.building.find(r.bld_id)
            if bld and df.building_farmplotst:is_instance(bld) then
                table.insert(plots, { room = r, bld = bld })
            end
        end
    end
    if #plots == 0 then return end

    -- plant id -> index map + current usage census (season, plant) like
    -- the C++ farmplots map
    local byid = {}
    for i, p in ipairs(plants) do byid[p.id] = i - 1 end

    local usage = {} -- [season .. ':' .. plantidx] = count
    for _, e in ipairs(plots) do
        for s = 0, 3 do
            local pid = e.bld.plant_id[s]
            if pid and pid >= 0 then
                local k = s .. ':' .. pid
                usage[k] = (usage[k] or 0) + 1
            end
        end
    end

    -- seed / plant census per plant index (memoized matinfo->plant)
    local seed_count, plant_count = self:plant_census()

    -- first-plot detection per (farm_type, outdoor)
    local first_seen = {}
    for _, e in ipairs(plots) do
        local r = e.room
        local fk = (r.farm_type or 'food') .. '/' .. tostring(r.outdoor)
        if not first_seen[fk] then first_seen[fk] = e end
        e.isfirst = (first_seen[fk] == e)
    end

    for _, e in ipairs(plots) do
        self:farmplot(e, plants, usage, seed_count, plant_count, byid)
    end
end

-- seed / plant per-species census (C++ Stocks::update_seeds /
-- count plants). Memoized per (mat_type, mat_index) -> plant index.
function Stocks:plant_census()
    local world = df.global.world
    local items = world.items.all
    local seeds, grown = {}, {}
    local memo = self._plant_memo or {}
    self._plant_memo = memo
    if items then
        for _, item in ipairs(items) do
            local t = item:getType()
            if t == IT.SEEDS or t == IT.PLANT then
                local ck = item.mat_type .. ':' .. item.mat_index
                local pi = memo[ck]
                if pi == nil then
                    pi = -1
                    local ok, mat = pcall(dfhack.matinfo.decode, item)
                    if ok and mat and mat.plant and mat.plant.id then
                        local idx = self._plant_by_id
                        if idx == nil then
                            idx = {}
                            local all = world.raws.plants.all
                            for i, p in ipairs(all) do idx[p.id] = i - 1 end
                            self._plant_by_id = idx
                        end
                        pi = idx[mat.plant.id] or -1
                    end
                    memo[ck] = pi
                end
                if pi >= 0 then
                    if t == IT.SEEDS then
                        seeds[pi] = (seeds[pi] or 0) + 1
                    else
                        grown[pi] = (grown[pi] or 0) + 1
                    end
                end
            end
        end
    end
    return seeds, grown
end

-- the per-plot crop assignment (C++ Stocks::farmplot)
function Stocks:farmplot(e, plants, usage, seed_count, plant_count, byid)
    local r, bld = e.room, e.bld
    local pos = r:pos()

    -- biome -> plant_raw_flags member name (C++ find_enum_item BIOME_...)
    local biome_flag = self:biome_flag_at(pos)
    local farm_type = r.farm_type or 'food'

    -- candidate plants: grows here, not a tree, has seeds
    local may = {}
    for i, p in ipairs(plants) do
        local ok, fits = pcall(function()
            if p.flags[df.plant_raw_flags.TREE] then return false end
            if not p.flags[df.plant_raw_flags.SEED] then return false end
            if biome_flag and not p.flags[biome_flag] then return false end
            return true
        end)
        if ok and fits then table.insert(may, i - 1) end
    end
    -- biome flag unavailable (API drift): fall back to every seed plant
    if #may == 0 and not biome_flag then
        for i, p in ipairs(plants) do
            local ok, fits = pcall(function()
                if p.flags[df.plant_raw_flags.TREE] then return false end
                return p.flags[df.plant_raw_flags.SEED] == true
            end)
            if ok and fits then table.insert(may, i - 1) end
        end
    end

    -- seasonal fertilize (C++ farm_flags.bits.seasonal_fertilize)
    pcall(function() bld.farm_flags.seasonal_fertilize = true end)

    local SEASON_FLAG = {
        df.plant_raw_flags.SPRING, df.plant_raw_flags.SUMMER,
        df.plant_raw_flags.AUTUMN, df.plant_raw_flags.WINTER,
    }

    for s = 0, 3 do
        local sflag = SEASON_FLAG[s + 1]
        local pids = {}

        local season_ok = {} -- [plantidx] = fits this season
        for _, pi in ipairs(may) do
            local ok, fits = pcall(function()
                return pflag(plants[pi + 1], sflag)
            end)
            season_ok[pi] = ok and fits or false
        end

        if farm_type == 'food' then
            for _, pi in ipairs(may) do
                if season_ok[pi] then
                    local p = plants[pi + 1]
                    local drink = pflag(p, df.plant_raw_flags.DRINK)
                    local mill = pflag(p, df.plant_raw_flags.MILL)
                    -- 53.16: EDIBLE_RAW/EDIBLE_COOKED were removed from
                    -- plant_raw_flags; the plant's structural material
                    -- carries the edible flags now (matinfo.material.flags)
                    local edible = self:plant_edible(p)
                    if e.isfirst then
                        if edible and drink then table.insert(pids, pi) end
                    elseif edible or drink then
                        table.insert(pids, pi)
                    elseif mill then
                        local mill_ed = self:plant_mill_edible(p)
                        if mill_ed then table.insert(pids, pi) end
                    end
                end
            end
        elseif farm_type == 'cloth' then
            if e.isfirst then
                for _, pi in ipairs(may) do
                    if season_ok[pi] and self:plant_is_thread(plants[pi + 1]) then
                        table.insert(pids, pi)
                    end
                end
            end
            if #pids == 0 then
                for _, pi in ipairs(may) do
                    if season_ok[pi]
                        and (self:plant_is_thread(plants[pi + 1])
                            or self:plant_is_dye(plants[pi + 1])) then
                        table.insert(pids, pi)
                    end
                end
            end
        end

        -- C++ sort: seeds first, then score = grown - seeds + 18 * usage
        table.sort(pids, function(a, b)
            local sa, sb = seed_count[a], seed_count[b]
            if (sa ~= nil) ~= (sb ~= nil) then return sa ~= nil end
            local ascore = (plant_count[a] or 0) - (sa or 0)
                + 18 * (usage[s .. ':' .. a] or 0)
            local bscore = (plant_count[b] or 0) - (sb or 0)
                + 18 * (usage[s .. ':' .. b] or 0)
            return ascore < bscore
        end)

        if #pids > 0 then
            local old = bld.plant_id[s]
            local pid = pids[1]
            if old ~= pid then
                if old and old >= 0 then
                    local k = s .. ':' .. old
                    usage[k] = math.max((usage[k] or 1) - 1, 0)
                end
                usage[s .. ':' .. pid] = (usage[s .. ':' .. pid] or 0) + 1
                bld.plant_id[s] = pid
                if not self._farm_log then self._farm_log = {} end
                local lk = r.min.x .. ',' .. r.min.y .. ':' .. s
                if not self._farm_log[lk] then
                    self._farm_log[lk] = true
                    local okn, name = pcall(function()
                        return plants[pid + 1].id or tostring(pid)
                    end)
                    dfhack.println('[df-ai:stocks] farm ' ..
                        (r.farm_type or 'food') .. ' season ' .. s ..
                        ' -> ' .. tostring(okn and name or pid))
                end
            end
        end
    end
end

-- plant structural material edibility (53.16: the flags live on the
-- material, not on plant_raw_flags anymore)
function Stocks:plant_edible(p)
    return self:_plant_mat_flag(p, 'basic_mat', function(mat)
        return mat.flags[df.material_flags.EDIBLE_RAW] == true
            or mat.flags[df.material_flags.EDIBLE_COOKED] == true
    end)
end

function Stocks:plant_mill_edible(p)
    return self:_plant_mat_flag(p, 'mill', function(mat)
        return mat.flags[df.material_flags.EDIBLE_RAW] == true
            or mat.flags[df.material_flags.EDIBLE_COOKED] == true
    end)
end

function Stocks:plant_is_thread(p)
    -- C++ thread_plants: plant_raw_flags.THREAD (verified in 53.16)
    return pflag(p, df.plant_raw_flags.THREAD)
end

function Stocks:plant_is_dye(p)
    -- C++ dye_plants: MILL flag + the mill material has IS_DYE
    -- (plant_raw_flags has NO DYE member in 53.16 — material_flags does)
    if not pflag(p, df.plant_raw_flags.MILL) then return false end
    return self:_plant_mat_flag(p, 'mill', function(mat)
        return mat.flags[df.material_flags.IS_DYE] == true
    end)
end

-- resolve a plant material def (basic_mat / mill / ...) and run fn(mat)
-- layout: p.material_defs.type[plant_material_def.X] + .idx[...] are
-- static arrays indexed by the df.plant_material_def enum
function Stocks:_plant_mat_flag(p, field, fn)
    local ok, res = pcall(function()
        local md = p.material_defs
        if not md or not md.type or not md.idx then return false end
        local pd = df.plant_material_def[field]
        if pd == nil then return false end
        local mt = md.type[pd]
        local mi = md.idx[pd]
        if not mt or mt < 0 then return false end
        local mat = dfhack.matinfo.decode(mt, mi)
        if not mat or not mat.material or not mat.material.flags then
            return false
        end
        return fn(mat.material) == true
    end)
    return ok and res or false
end

-- biome plant_raw_flags member for the tile (C++ "BIOME_" + biome key)
function Stocks:biome_flag_at(pos)
    local ok, flag = pcall(function()
        local rx, ry = dfhack.maps.getTileBiomeRgn(pos)
        local biome = dfhack.maps.getBiomeType(rx, ry)
        -- subterranean plots (C++): SUBTERRANEAN_WATER
        local des = dfhack.maps.getTileDesignation(pos)
        if des and des.subterranean then
            biome = df.biome_type.SUBTERRANEAN_WATER
        end
        -- reverse enum lookup (enum tables do not iterate with pairs)
        local name = nil
        local bt = df.biome_type
        for v = bt._first_item or 0, bt._last_item or 99 do
            if v == biome then name = bt[v] break end
        end
        if not name then return nil end
        local member = 'BIOME_' .. name
        if df.plant_raw_flags[member] == nil then return nil end
        return df.plant_raw_flags[member]
    end)
    if ok then return flag end
    return nil
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
    table.insert(parts, '  Watched items (free / population-scaled quota):')
    local shown = {}
    for k in pairs(WATCH.needed) do
        local v = self.count_free[k] or 0
        local target = self:num_needed(k) or 0
        if v < target then
            table.insert(shown, { k, v, target })
        end
    end
    table.sort(shown, function(a, b) return a[1] < b[1] end)
    for i = 1, math.min(#shown, 15) do
        local e = shown[i]
        table.insert(parts, '    ' .. e[1] .. ': ' .. e[2] .. '/' .. e[3] .. ' LOW')
    end
    if #shown == 0 then
        table.insert(parts, '    all quotas satisfied')
    end
    return table.concat(parts, '\n')
end

return Stocks
