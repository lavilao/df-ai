--@module = true
-- compat.lua — API compatibility layer for DF 53.16 / DFHack 53.16-r3
-- Centralizes every enum rename / structural change between DF 0.47.05 and
-- 53.16 so modules keep one canonical source of truth.

local compat = {}

-- ============================================================
-- Enum renames (old df-ai name -> 53.16 value)
-- ============================================================

compat.workshop = {
    Carpenters    = df.workshop_type.Carpenters,
    Farmers       = df.workshop_type.Farmers,
    Masons        = df.workshop_type.Masons,
    Craftsdwarf   = df.workshop_type.Craftsdwarfs,
    Jewelers      = df.workshop_type.Jewelers,
    Forge         = df.workshop_type.MetalsmithsForge,
    MagmaForge    = df.workshop_type.MagmaForge,
    Bowyers       = df.workshop_type.Bowyers,
    Mechanics     = df.workshop_type.Mechanics,
    Siege         = df.workshop_type.Siege,
    Butchers      = df.workshop_type.Butchers,
    Leatherworks  = df.workshop_type.Leatherworks,
    Tanners       = df.workshop_type.Tanners,
    Clothiers     = df.workshop_type.Clothiers,
    Fishery       = df.workshop_type.Fishery,
    Still         = df.workshop_type.Still,
    Loom          = df.workshop_type.Loom,
    Quern         = df.workshop_type.Quern,
    Kennels       = df.workshop_type.Kennels,
    Kitchen       = df.workshop_type.Kitchen,
    Ashery        = df.workshop_type.Ashery,
    Dyers         = df.workshop_type.Dyers,
    Millstone     = df.workshop_type.Millstone,
    Custom        = df.workshop_type.Custom,
    Tool          = df.workshop_type.Tool,
}

-- Furnaces are a separate building type in DF (building_type.Furnace)
compat.furnace = {
    WoodFurnace      = df.furnace_type.WoodFurnace,
    Smelter          = df.furnace_type.Smelter,
    GlassFurnace     = df.furnace_type.GlassFurnace,
    Kiln             = df.furnace_type.Kiln,
    MagmaSmelter     = df.furnace_type.MagmaSmelter,
    MagmaGlassFurnace = df.furnace_type.MagmaGlassFurnace,
    MagmaKiln        = df.furnace_type.MagmaKiln,
    Custom           = df.furnace_type.Custom,
}

compat.job = {
    MakeBin            = df.job_type.ConstructBin,
    MakeMeal           = df.job_type.PrepareMeal,
    MakeMechanisms     = df.job_type.ConstructMechanisms,
    ConstructCage      = df.job_type.MakeCage,
    ConstructChair     = df.job_type.ConstructThrone,
    MakeFloodgate      = df.job_type.ConstructFloodgate,
    MakeHatchCover     = df.job_type.ConstructHatchCover,
    MakeSplint         = df.job_type.ConstructSplint,
    MakeTractionBench  = df.job_type.ConstructTractionBench,
    ProcessCloth       = df.job_type.WeaveCloth,
    ProcessThread      = df.job_type.SpinThread,
    CollectWeapons     = nil, -- removed in v50; military hauling reworked
    CollectArmor       = nil,
}

compat.skill = {
    FORGING          = df.job_skill.METALCRAFT,
    WEAPONSMITH      = df.job_skill.FORGE_WEAPON,
    ARMORSMITH       = df.job_skill.FORGE_ARMOR,
    METALSMITH       = df.job_skill.METALCRAFT,
    STRAND_EXTRACTOR = df.job_skill.EXTRACT_STRAND,
    WEAVER           = df.job_skill.WEAVING,
    CLOTHIER         = df.job_skill.CLOTHESMAKING,
    CHEESE_MAKING    = df.job_skill.CHEESEMAKING,
    CUT_GEM          = df.job_skill.CUTGEM,
    ENCRUST_GEM      = df.job_skill.ENCRUSTGEM,
    MECHANIC         = df.job_skill.MECHANICS,
    EXTRACT_STRAND   = df.job_skill.EXTRACT_STRAND,
}

compat.item = {
    BLOCK   = df.item_type.BLOCKS,
    LEATHER = df.item_type.SKIN_TANNED,
}

-- Reactions that replaced hardcoded jobs in DF v50
compat.reaction = {
    BrewDrink      = 'BREW_DRINK_FROM_PLANT',
    BrewDrinkGrowth = 'BREW_DRINK_FROM_PLANT_GROWTH',
    MakeMead       = 'MAKE_MEAD',
    MakeSoapTallow = 'MAKE_SOAP_FROM_TALLOW',
    MakeSoapOil    = 'MAKE_SOAP_FROM_OIL',
    TanHide        = 'TAN_A_HIDE',
    Bookbinding    = 'BIND_BOOK',
    MakeClayHive   = 'MAKE_CLAY_HIVE',
    RenderFat      = 'RENDER_FAT',
}

-- Tiletype shapes: Wall->WALL, Void/Abyss removed in 53.16
compat.shape = {
    Wall  = df.tiletype_shape.WALL,
    Floor = df.tiletype_shape.FLOOR,
    -- Void / Abyss no longer exist; treat as EMPTY
    Void  = df.tiletype_shape.EMPTY,
    Abyss = df.tiletype_shape.EMPTY,
}

-- ============================================================
-- Runtime raw-subtype resolution
-- Subtypes are indices into world.raws.itemdefs.* — they are raw-driven,
-- so resolve them by raw id string at runtime (never hardcode numbers).
-- ============================================================

local subtype_cache = {}

-- Find item subtype index by raw id (e.g. item_type WEAPON, id 'ITEM_WEAPON_PICK')
-- Returns -1 when not found (safe default for "no subtype").
function compat.subtype_by_id(item_type, raw_id)
    if raw_id == nil then return -1 end
    local cache_key = tostring(item_type) .. ':' .. raw_id
    if subtype_cache[cache_key] ~= nil then
        return subtype_cache[cache_key]
    end
    local result = -1
    local count = dfhack.items.getSubtypeCount(item_type)
    if count then
        for i = 0, count - 1 do
            local def = dfhack.items.getSubtypeDef(item_type, i)
            if def and def.id == raw_id then
                result = i
                break
            end
        end
    end
    subtype_cache[cache_key] = result
    return result
end

-- Weapon subtypes (df-ai names -> raw ids)
compat.weapon = {
    PICK          = { raw_id = 'ITEM_WEAPON_PICK' },
    BATTLE_AXE    = { raw_id = 'ITEM_WEAPON_BATTLE_AXE' },
    SHORT_SWORD   = { raw_id = 'ITEM_WEAPON_SHORT_SWORD' },
    CROSSBOW      = { raw_id = 'ITEM_WEAPON_CROSSBOW' },
    SWORD_TRAINING = { raw_id = 'ITEM_WEAPON_SWORD_TRAINING' },
    AXE_TRAINING  = { raw_id = 'ITEM_WEAPON_AXE_TRAINING' },
}

function compat.weapon_subtype(name)
    local def = compat.weapon[name]
    if not def then return -1 end
    return compat.subtype_by_id(df.item_type.WEAPON, def.raw_id)
end

-- Tool subtypes (stepladder, wheelbarrow, etc. are TOOLS in modern DF)
compat.tool = {
    STEPLADDER  = 'ITEM_TOOL_STEPLADDER',
    WHEELBARROW = 'ITEM_TOOL_WHEELBARROW',
    NEST_BOX    = 'ITEM_TOOL_NEST_BOX',
    HIVE        = 'ITEM_TOOL_HIVE',
    SCREW       = 'ITEM_TOOL_SCREW',
    JUG         = 'ITEM_TOOL_JUG',
    PICK        = 'ITEM_TOOL_PICK',
    AXE         = 'ITEM_TOOL_AXE',
}

function compat.tool_subtype(name)
    local raw_id = compat.tool[name]
    if not raw_id then return -1 end
    return compat.subtype_by_id(df.item_type.TOOL, raw_id)
end

-- Armor-piece subtypes span several item types in modern DF
compat.armor = {
    HELM       = { item_type = df.item_type.HELM,   raw_id = 'ITEM_HELM_HELM' },
    MAIL_SHIRT = { item_type = df.item_type.ARMOR,  raw_id = 'ITEM_ARMOR_MAIL_SHIRT' },
    BREASTPLATE = { item_type = df.item_type.ARMOR, raw_id = 'ITEM_ARMOR_BREASTPLATE' },
    GREAVES    = { item_type = df.item_type.PANTS,  raw_id = 'ITEM_PANTS_GREAVES' },
    GAUNTLETS  = { item_type = df.item_type.GLOVES, raw_id = 'ITEM_GLOVES_GAUNTLETS' },
    HIGH_BOOT  = { item_type = df.item_type.SHOES,  raw_id = 'ITEM_SHOES_BOOTS' },
    SHIELD     = { item_type = df.item_type.SHIELD, raw_id = 'ITEM_SHIELD_SHIELD' },
}

function compat.armor_subtype(name)
    local def = compat.armor[name]
    if not def then return -1, -1 end
    return def.item_type, compat.subtype_by_id(def.item_type, def.raw_id)
end

-- Ammo subtype
function compat.ammo_subtype(name)
    if name == 'BOLT' then
        return compat.subtype_by_id(df.item_type.AMMO, 'ITEM_AMMO_BOLTS')
    end
    return -1
end

-- ============================================================
-- Furniture categories: df-ai's furniture model maps each category to a
-- concrete (item_type, job_type) pair in 53.16 (mostly subtype-less).
-- ============================================================

local IT = df.item_type
local JT = df.job_type

compat.furniture = {
    BED            = { item_type = IT.BED,           job = JT.ConstructBed,          subtype = -1 },
    CHAIR          = { item_type = IT.CHAIR,         job = JT.ConstructThrone,       subtype = -1 },
    TABLE          = { item_type = IT.TABLE,         job = JT.ConstructTable,        subtype = -1 },
    DOOR           = { item_type = IT.DOOR,          job = JT.ConstructDoor,         subtype = -1 },
    CHEST          = { item_type = IT.BOX,           job = JT.ConstructChest,        subtype = -1 },
    BOX            = { item_type = IT.BOX,           job = JT.ConstructChest,        subtype = -1 },
    BAG            = { item_type = IT.BAG,           job = JT.ConstructBag,          subtype = -1 },
    BIN            = { item_type = IT.BIN,           job = JT.ConstructBin,          subtype = -1 },
    CABINET        = { item_type = IT.CABINET,       job = JT.ConstructCabinet,      subtype = -1 },
    WEAPON_RACK    = { item_type = IT.WEAPONRACK,    job = JT.ConstructWeaponRack,   subtype = -1 },
    ARMOR_STAND    = { item_type = IT.ARMORSTAND,    job = JT.ConstructArmorStand,   subtype = -1 },
    STATUE         = { item_type = IT.STATUE,        job = JT.ConstructStatue,       subtype = -1 },
    COFFIN         = { item_type = IT.COFFIN,        job = JT.ConstructCoffin,       subtype = -1 },
    SLAB           = { item_type = IT.SLAB,          job = JT.ConstructSlab,         subtype = -1 },
    QUERN          = { item_type = IT.QUERN,         job = JT.ConstructQuern,        subtype = -1 },
    MILLSTONE      = { item_type = IT.MILLSTONE,     job = JT.ConstructMillstone,    subtype = -1 },
    CAGE           = { item_type = IT.CAGE,          job = JT.MakeCage,              subtype = -1 },
    BARREL         = { item_type = IT.BARREL,        job = JT.MakeBarrel,            subtype = -1 },
    BUCKET         = { item_type = IT.BUCKET,        job = JT.MakeBucket,            subtype = -1 },
    FLASK          = { item_type = IT.FLASK,         job = JT.MakeFlask,             subtype = -1 },
    GOBLET         = { item_type = IT.GOBLET,        job = JT.MakeGoblet,            subtype = -1 },
    CHAIN          = { item_type = IT.CHAIN,         job = JT.MakeChain,             subtype = -1 },
    ROPE           = { item_type = IT.CHAIN,         job = JT.MakeChain,             subtype = -1 },
    BACKPACK       = { item_type = IT.BACKPACK,      job = JT.MakeBackpack,          subtype = -1 },
    QUIVER        = { item_type = IT.QUIVER,        job = JT.MakeQuiver,            subtype = -1 },
    SPLINT         = { item_type = IT.SPLINT,        job = JT.ConstructSplint,       subtype = -1 },
    TRACTION_BENCH = { item_type = IT.TRACTION_BENCH, job = JT.ConstructTractionBench, subtype = -1 },
    FLOODGATE      = { item_type = IT.FLOODGATE,     job = JT.ConstructFloodgate,    subtype = -1 },
    HATCH_COVER    = { item_type = IT.HATCH_COVER,   job = JT.ConstructHatchCover,   subtype = -1 },
    PIPE_SECTION   = { item_type = IT.PIPE_SECTION,  job = JT.MakePipeSection,      subtype = -1 },
    ANVIL          = { item_type = IT.ANVIL,         job = JT.ForgeAnvil,            subtype = -1 },
    -- Tool-based furniture
    STEPLADDER     = { item_type = IT.TOOL,          job = JT.MakeTool, subtype = 'STEPLADDER' },
    WHEELBARROW    = { item_type = IT.TOOL,          job = JT.MakeTool, subtype = 'WHEELBARROW' },
    NEST_BOX       = { item_type = IT.TOOL,          job = JT.MakeTool, subtype = 'NEST_BOX' },
    HIVE           = { item_type = IT.TOOL,          job = JT.MakeTool, subtype = 'HIVE' },
    SCREW          = { item_type = IT.TOOL,          job = JT.MakeTool, subtype = 'SCREW' },
    JUG            = { item_type = IT.TOOL,          job = JT.MakeTool, subtype = 'JUG' },
}

-- Resolve a furniture category to a queue-order triple
-- (job_type, item_type, item_subtype) for the manager.
function compat.furniture_order(name)
    local def = compat.furniture[name]
    if not def then return nil end
    local subtype = def.subtype
    if type(subtype) == 'string' then
        subtype = compat.tool_subtype(subtype)
    end
    return def.job, def.item_type, subtype
end

-- ============================================================
-- Modern manager orders (workquota_handlerst in 53.16)
-- ============================================================

function compat.get_orders_vector()
    local handler = df.global.world.manager_orders
    if handler then return handler.all end
    return nil
end

function compat.get_next_order_id()
    local handler = df.global.world.manager_orders
    if handler then return handler.manager_order_next_id end
    return 0
end

-- Create a standard manager order. For reaction-based products pass
-- `reaction_name` (brew/soap/tan/book/...) — job_type must then be
-- CustomReaction.
-- Returns the created order (not yet inserted) or nil.
function compat.create_order(opts)
    local order = df.manager_order:new()
    order.job_type = opts.job_type
    order.item_type = opts.item_type or df.item_type.NONE
    order.item_subtype = opts.item_subtype or -1
    order.mat_type = opts.mat_type or -1
    order.mat_index = opts.mat_index or -1
    if opts.reaction_name then
        order.reaction_name = opts.reaction_name
    end
    order.amount_left = opts.amount or 1
    order.amount_total = opts.amount or 1
    order.id = compat.get_next_order_id()
    local handler = df.global.world.manager_orders
    if handler then
        handler.manager_order_next_id = handler.manager_order_next_id + 1
        handler.all:insert('#', order)
    end
    -- v50 manager_order.status bitfield (validated/active)
    if order.status then
        order.status.validated = true
        order.status.active = true
    end
    return order
end

-- ============================================================
-- Fortress entity helpers (replaces ui.civ_id / ui.assignments)
-- ============================================================

-- Returns the fortress historical_entity (site government), or nil.
function compat.fort_entity()
    local main = df.global.plotinfo and df.global.plotinfo.main
    if main and main.fortress_entity then
        return main.fortress_entity
    end
    return nil
end

function compat.fort_entity_id()
    local e = compat.fort_entity()
    return e and e.id or -1
end

-- Fortress position assignments (broker, bookkeeper, ...)
function compat.assignments()
    local e = compat.fort_entity()
    if e and e.assignments then
        return e.assignments
    end
    return nil
end

-- Find the holder unit id of a fortress position by code ('BROKER', ...)
-- Returns -1 when the position is vacant or not found.
function compat.position_holder(code)
    local e = compat.fort_entity()
    if not e then return -1 end
    local positions = e.positions and e.positions.own
    if not positions then return -1 end
    for _, pos in ipairs(positions) do
        if pos.code == code then
            for _, assign in ipairs(e.assignments or {}) do
                if assign.position_id == pos.id and assign.histfig >= 0 then
                    -- histfig -> historical figure; resolve to unit
                    local histfig = df.historical_figure.find(assign.histfig)
                    if histfig then
                        local unit_id = histfig.unit_id
                        if unit_id and unit_id >= 0 then
                            return unit_id
                        end
                    end
                end
            end
        end
    end
    return -1
end

-- ============================================================
-- Misc helpers
-- ============================================================

-- Civzone (activity zone) construction for 53.16
function compat.new_civzone()
    return df.building_civzonest:new()
end

-- Is this item already claimed by a job? (replaces general_ref IS_JOB scan)
function compat.item_in_job(item)
    if not item or not item.specific_refs then return false end
    for _, ref in ipairs(item.specific_refs) do
        if ref.type == df.specific_ref_type.JOB then
            return true
        end
    end
    return false
end

return compat
