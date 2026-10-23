--@module = true
--
-- df-ai blueprint placement engine — Lua port of the original C++ system
-- (plan_setup_blueprint.cpp + blueprint_merge.cpp) for DFHack 53.16.
--
-- The C++ engine never "finds a path" to rooms: it grows the fort as a
-- TREE. Every blueprint is anchored on a live EXIT tile of an already
-- placed room, every room records its parent (accesspath), and digroom()
-- later digs parents first. Reachability is a structural invariant of
-- placement — that is what the old radial Lua placer got wrong.
--
-- Phases (PlanSetup::build):
--   1. start    — the generic01_start template (surface entrance + stair
--                 shaft + first workshops) near the fort entrance
--   2. outdoor  — apiary / cage traps / depot / mineshaft / outdoor farms
--                 / pasture / pitting tower, on random surface tiles
--   3. connect  — growth loop: anchor a random blueprint variant on a
--                 random live exit until limits are met or max_failures
--
-- Everything below mirrors the C++ code as closely as Lua allows.
-- Data: plans/generic01.json, rooms/templates/<type>/<variant>.json,
-- rooms/instances/<type>/<instance>.json (release layout:
-- df-ai-blueprints/{plans,templates,instances}/...).
--

local json = require('json')

local M = {}

-- ============================================================
-- Tile helpers (53.16-safe: enum reads by name never throw)
-- ============================================================

local WALL_SHAPES, OPEN_SHAPES, FLOOR_SHAPES

local function ensure_shape_tables()
    if WALL_SHAPES then return end
    WALL_SHAPES, OPEN_SHAPES, FLOOR_SHAPES = {}, {}, {}
    local TTS = df.tiletype_shape
    for _, name in ipairs({ 'WALL', 'FORTIFICATION', 'TREE', 'TWIG',
        'BRANCH', 'TRUNK_BRANCH', 'ROOT' }) do
        local v = TTS[name]
        if v ~= nil then WALL_SHAPES[v] = true end
    end
    for _, name in ipairs({ 'OPEN_SPACE', 'RAMP_TOP', 'ENDLESS_PIT' }) do
        local v = TTS[name]
        if v ~= nil then OPEN_SHAPES[v] = true end
    end
    for _, name in ipairs({ 'FLOOR', 'BOULDER', 'PEBBLES', 'RAMP',
        'STAIR_UP', 'STAIR_DOWN', 'STAIR_UPDOWN', 'BROOK_TOP',
        'SAPLING', 'SHRUB' }) do
        local v = TTS[name]
        if v ~= nil then FLOOR_SHAPES[v] = true end
    end
end

local function shape_family(shape)
    ensure_shape_tables()
    if shape == nil then return nil end
    if WALL_SHAPES[shape] then return 'wall' end
    if OPEN_SHAPES[shape] then return 'open' end
    if FLOOR_SHAPES[shape] then return 'floor' end
    return 'other'
end

local function tile_data(x, y, z)
    -- shape, material, designation, occupancy (or nil)
    local ok, block = pcall(dfhack.maps.getTileBlock, x, y, z)
    if not ok or not block then return nil end
    local lx, ly = x % 16, y % 16
    local okT, tt = pcall(function() return block.tiletype[lx][ly] end)
    if not okT or tt == nil then return nil end
    local okA, attrs = pcall(function() return df.tiletype.attrs[tt] end)
    if not okA or not attrs then return nil end
    local des, occ
    pcall(function() des = block.designation[lx][ly] end)
    pcall(function() occ = block.occupancy[lx][ly] end)
    return {
        shape = attrs.shape,
        material = attrs.material,
        des = des,
        occ = occ,
    }
end

-- C++ Plan::surface_tile_at: walk down from the map top for the first
-- Floor/Ramp (skips open air, rejects pools/rivers, allows tree tops).
local function surface_tile_at(x, y, z_top, allow_trees)
    local TTM = df.tiletype_material
    local tree = false
    for z = z_top, 0, -1 do
        local td = tile_data(x, y, z)
        if td then
            local family = shape_family(td.shape)
            if family == 'open' then
                -- keep descending
            elseif td.material == TTM.POOL or td.material == TTM.RIVER then
                return nil
            elseif td.material == TTM.TREE then
                tree = true
            elseif family == 'floor' then
                return { x = x, y = y, z = z }
            elseif tree then
                if not allow_trees then return nil end
                return { x = x, y = y, z = z + 1 }
            end
        end
    end
    return nil
end

local function key(x, y, z) return x .. ',' .. y .. ',' .. z end

-- ============================================================
-- Data loading + template x instance merge
-- ============================================================

local SEARCH_ROOTS = {
    'df-ai-blueprints/',          -- release package
    'df-53.16-r3/df-ai-blueprints/', -- some unzip layouts
    '',                            -- repo checkout (plans/, rooms/)
}

local function read_json(paths)
    for _, p in ipairs(paths) do
        local ok, data = pcall(json.decode_file, p)
        if ok and data then return data, p end
    end
    return nil
end

local function list_json_dir(dir)
    -- dfhack.filesystem.listdir returns nil (no error) for missing dirs
    local ok, files = pcall(dfhack.filesystem.listdir, dir)
    if ok and type(files) == 'table' then
        local out = {}
        for _, f in ipairs(files) do
            if f:match('%.json$') then table.insert(out, f) end
        end
        table.sort(out)
        return out
    end
    return nil
end

local function dir_variants(kind, base)
    -- kind: 'templates' | 'instances'
    for _, root in ipairs(SEARCH_ROOTS) do
        local dir = root .. kind .. '/' .. base .. '/'
        local files = list_json_dir(dir)
        if files then return dir, files end
        -- repo layout nests under rooms/
        dir = root .. 'rooms/' .. kind .. '/' .. base .. '/'
        files = list_json_dir(dir)
        if files then return dir, files end
    end
    return nil, {}
end

local function list_bases()
    -- enumerate template type dirs (generic01_*)
    for _, root in ipairs(SEARCH_ROOTS) do
        local ok, dirs = pcall(dfhack.filesystem.listdir, root .. 'templates')
        if ok and type(dirs) == 'table' then
            local out = {}
            for _, d in ipairs(dirs) do
                if d:find('^generic01_') then table.insert(out, d) end
            end
            table.sort(out)
            if #out > 0 then return out end
        end
        local ok2, dirs2 = pcall(dfhack.filesystem.listdir, root .. 'rooms/templates')
        if ok2 and type(dirs2) == 'table' then
            local out = {}
            for _, d in ipairs(dirs2) do
                if d:find('^generic01_') then table.insert(out, d) end
            end
            table.sort(out)
            if #out > 0 then return out end
        end
    end
    return nil
end

-- deep copy of plain JSON tables
local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k2, v2 in pairs(v) do out[k2] = copy(v2) end
    return out
end

-- Apply one instance onto one template (blueprint_merge.cpp):
--   * entries whose `placeholder` is N get inst.p[N] applied on top
--     (p[N].skip = true drops the entry)
--   * all index references (accesspath / layout / workshop / target)
--     are remapped after any drops
--   * the instance's own f/r arrays are appended (renumbered)
local function merge_variant(btype, tmpl_name, tmpl, inst_name, inst)
    local f, r = {}, {}
    local fmap, rmap = {}, {}  -- old index (0-based) -> new index (0-based)
    inst = inst or { p = {} }

    for i, tf in ipairs(tmpl.f or {}) do
        local e = copy(tf)
        local ph = e.placeholder
        local patch = ph ~= nil and inst.p and inst.p[ph + 1] or nil
        local dropped = false
        if patch then
            if patch.skip then
                dropped = true
            else
                for k2, v2 in pairs(patch) do e[k2] = v2 end
            end
        end
        if not dropped then
            fmap[i - 1] = #f
            table.insert(f, e)
        end
    end
    for i, tr in ipairs(tmpl.r or {}) do
        local e = copy(tr)
        local ph = e.placeholder
        local patch = ph ~= nil and inst.p and inst.p[ph + 1] or nil
        local dropped = false
        if patch then
            if patch.skip then
                dropped = true
            else
                for k2, v2 in pairs(patch) do e[k2] = v2 end
            end
        end
        if not dropped then
            rmap[i - 1] = #r
            table.insert(r, e)
        end
    end

    -- instance's own furniture/rooms (rarely used; renumber + remap)
    local inst_f_base = #f
    for i, inf in ipairs(inst.f or {}) do
        table.insert(f, copy(inf))
    end
    for i, inr in ipairs(inst.r or {}) do
        local e = copy(inr)
        -- remap references into the combined arrays
        if e.accesspath then
            local ap = {}
            for _, idx in ipairs(e.accesspath) do ap[#ap + 1] = (rmap[idx] or idx) end
            e.accesspath = ap
        end
        if e.workshop ~= nil then
            e.workshop = rmap[e.workshop] or e.workshop
        end
        table.insert(r, e)
    end

    -- remap template-side references
    for _, e in ipairs(r) do
        if e.accesspath then
            local ap = {}
            for _, idx in ipairs(e.accesspath) do
                local m = rmap[idx]
                if m ~= nil then ap[#ap + 1] = m end
            end
            e.accesspath = ap
        end
        if e.workshop ~= nil then
            e.workshop = rmap[e.workshop]
        end
        if e.layout then
            local lay = {}
            for _, idx in ipairs(e.layout) do
                local m = fmap[idx]
                if m ~= nil then lay[#lay + 1] = m end
            end
            e.layout = lay
        end
    end
    for _, e in ipairs(f) do
        if e.target ~= nil then
            e.target = fmap[e.target]
        end
    end

    return {
        type = btype,
        tmpl_name = tmpl_name,
        name = inst_name or tmpl_name,
        f = f,
        r = r,
    }
end

-- Load the plan JSON, every template variant, and merge each template
-- with each of its instances (cartesian product, blueprint.cpp ctor).
-- Returns plan, variants (flat list), stats.
function M.load_all()
    local plan = nil
    for _, root in ipairs(SEARCH_ROOTS) do
        local p = root .. 'plans/generic01.json'
        local ok, data = pcall(json.decode_file, p)
        if ok and data then plan = data break end
    end
    if not plan then return nil, 'plan JSON not found' end

    local bases = list_bases()
    if not bases or #bases == 0 then return nil, 'template dirs not found' end

    local variants = {}
    for _, base in ipairs(bases) do
        local tdir, tfiles = dir_variants('templates', base)
        local idir, ifiles = dir_variants('instances', base)
        if tdir then
            for _, fname in ipairs(tfiles) do
                local ok, tmpl = pcall(json.decode_file, tdir .. fname)
                if ok and tmpl then
                    local tname = fname:gsub('%.json$', '')
                    if ifiles and #ifiles > 0 then
                        for _, iname in ipairs(ifiles) do
                            local ok2, inst = pcall(json.decode_file, idir .. iname)
                            if ok2 and inst then
                                table.insert(variants, merge_variant(base, tname,
                                    tmpl, iname:gsub('%.json$', ''), inst))
                            end
                        end
                    else
                        table.insert(variants, merge_variant(base, tname, tmpl))
                    end
                end
            end
        end
    end
    return plan, variants
end

-- ============================================================
-- build_cache — the four collision sets (blueprint_merge.cpp),
-- in BLUEPRINT-RELATIVE coordinates (offset applied at check time)
-- ============================================================

local function build_cache(rb)
    local cache = {
        corridor = {}, interior = {}, no_room = {}, no_corridor = {},
        max_noblesuite = -1,
    }
    local TTM = df.tiletype_material
    local DIG = df.tile_dig_designation

    for _, r in ipairs(rb.r) do
        if (r.noblesuite or -1) > cache.max_noblesuite then
            cache.max_noblesuite = r.noblesuite or -1
        end

        local rmin = r.min
        local exits = {}
        for _, e in ipairs(r.exits or {}) do
            exits[key(e[2], e[3], e[4])] = true
        end

        local holes = {}
        for _, fi in ipairs(r.layout or {}) do
            local f = rb.f[fi + 1]
            if f then
                local fx, fy, fz = rmin[1] + f.x, rmin[2] + f.y, rmin[3] + (f.z or 0)
                if f.dig == 'No' or f.construction == 'Wall' then
                    holes[key(fx, fy, fz)] = true
                elseif r.type == 'corridor' and r.corridor_type == 'corridor' then
                    if f.type ~= 'door' then
                        cache.interior[key(fx, fy, fz)] = true
                    end
                    cache.no_room[key(fx, fy, fz)] = true
                elseif r.in_corridor or r.require_walls == false or r.outdoor then
                    cache.interior[key(fx, fy, fz)] = true
                    cache.no_room[key(fx, fy, fz)] = true
                else
                    if f.type == 'door' then
                        cache.no_room[key(fx, fy, fz)] = true
                    else
                        cache.interior[key(fx, fy, fz)] = true
                        for dx = -1, 1 do
                            for dy = -1, 1 do
                                local kk = key(fx + dx, fy + dy, fz)
                                cache.no_corridor[kk] = true
                                cache.no_room[kk] = true
                            end
                        end
                    end
                end
                if f.dig == 'Channel' then
                    if not exits[key(f.x, f.y, (f.z or 0) - 1)] then
                        cache.interior[key(fx, fy, fz - 1)] = true
                        for dx = -1, 1 do
                            for dy = -1, 1 do
                                cache.no_room[key(fx + dx, fy + dy, fz - 1)] = true
                            end
                        end
                    end
                elseif f.dig == 'Ramp' then
                    cache.interior[key(fx, fy, fz + 1)] = true
                    for dx = -1, 1 do
                        for dy = -1, 1 do
                            cache.no_room[key(fx + dx, fy + dy, fz + 1)] = true
                        end
                    end
                end
            end
        end

        local is_corr = (r.type == 'corridor' and r.corridor_type == 'corridor')
        local flat_z = r.min[3] == r.max[3]
        for x = rmin[1], r.max[1] do
            for y = rmin[2], r.max[2] do
                for z = rmin[3], r.max[3] do
                    if not holes[key(x, y, z)] then
                        if is_corr and flat_z then
                            if not r.in_corridor then
                                cache.corridor[key(x, y, z)] = true
                                cache.no_corridor[key(x, y, z)] = true
                            else
                                cache.interior[key(x, y, z)] = true
                                cache.no_room[key(x, y, z)] = true
                            end
                        elseif r.in_corridor or r.require_walls == false or r.outdoor then
                            cache.interior[key(x, y, z)] = true
                            cache.no_room[key(x, y, z)] = true
                            if not r.in_corridor then
                                cache.no_corridor[key(x, y, z)] = true
                            end
                        else
                            cache.interior[key(x, y, z)] = true
                            for dx = -1, 1 do
                                for dy = -1, 1 do
                                    if not exits[key(x - rmin[1] + dx, y - rmin[2] + dy, 0)] then
                                        local kk = key(x + dx, y + dy, z)
                                        cache.no_room[kk] = true
                                        cache.no_corridor[kk] = true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    rb.cache = cache
    return cache
end

-- ============================================================
-- The placer
-- ============================================================

local Placer = {}
Placer.__index = Placer

function Placer.new(opts)
    local o = {
        log = opts.log or function() end,
        relaxed = opts.relaxed or false,
        map = opts.map,           -- {x=width, y=height, z=depth}
        z_top = opts.z_top,
        plan = opts.plan,
        variants = opts.variants,
        wagon_tiles = opts.wagon_tiles or {},  -- exempt from building checks
        corridor = {}, interior = {}, no_room = {}, no_corridor = {},
        room_connect = {},  -- [abskey] = { room = record, tags = {tag,...} }
        placed = {},        -- list of placed blueprint instances
        rooms = {},         -- flat list of room RECORDS (index + 1 = C++ index)
        counts = {},
        instance_counts = {},
        next_noblesuite = 0,
        tries = 0,
    }
    setmetatable(o, Placer)
    -- precompute caches once
    for _, rb in ipairs(o.variants) do build_cache(rb) end
    return o
end

-- PlanSetup::add — collision test + global set merge + exit registry
function Placer:add(rb, pos, parent_record)
    local cache = rb.cache
    local px, py, pz = pos.x, pos.y, pos.z
    local function abs(k)
        local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
        return key(px + tonumber(x), py + tonumber(y), pz + tonumber(z))
    end
    for k in pairs(cache.corridor) do
        if self.no_corridor[abs(k)] then return false, 'corridor hits no_corridor' end
    end
    for k in pairs(cache.interior) do
        if self.no_room[abs(k)] then return false, 'interior hits no_room' end
    end
    for k in pairs(cache.no_corridor) do
        if self.corridor[abs(k)] then return false, 'no_corridor hits corridor' end
    end
    for k in pairs(cache.no_room) do
        if self.interior[abs(k)] then return false, 'no_room hits interior' end
    end

    local room_base = #self.rooms
    local layout_base = 0
    for _, prev in ipairs(self.placed) do
        layout_base = layout_base + #prev.rb.f
    end
    local noblesuite_base = self.next_noblesuite
    self.next_noblesuite = noblesuite_base + cache.max_noblesuite + 1

    local inst = {
        rb = rb, pos = { x = px, y = py, z = pz },
        parent = parent_record,
        rooms = {},
    }
    table.insert(self.placed, inst)

    -- room records with ABSOLUTE bounds and remapped references
    for i, r in ipairs(rb.r) do
        local rec = {
            inst = inst,
            rb = rb,
            idx = i - 1,
            data = r,
            min = { x = px + r.min[1], y = py + r.min[2], z = pz + r.min[3] },
            max = { x = px + r.max[1], y = py + r.max[2], z = pz + r.max[3] },
            layout_base = layout_base,
            room_base = room_base,
            noblesuite = (r.noblesuite ~= nil and r.noblesuite ~= -1)
                and (r.noblesuite + noblesuite_base) or -1,
            parent = parent_record,
            sibling_ap = r.accesspath or {},
            workshop_idx = r.workshop,
            removed = false,
        }
        table.insert(self.rooms, rec)
        table.insert(inst.rooms, rec)
    end

    -- register exits (skip tiles blocked by existing no_room)
    for _, rec in ipairs(inst.rooms) do
        for _, e in ipairs(rec.data.exits or {}) do
            local ak = key(rec.min.x + e[2], rec.min.y + e[3], rec.min.z + e[4])
            if not self.no_room[ak] then
                local conn = self.room_connect[ak]
                if not conn then
                    conn = { room = rec, tags = {} }
                    self.room_connect[ak] = conn
                end
                table.insert(conn.tags, e[1])
            end
        end
    end

    -- merge the four sets (values = source description for debugging)
    local src = rb.type .. '/' .. rb.tmpl_name .. '/' .. rb.name
    for _, setname in ipairs({ 'corridor', 'interior', 'no_room', 'no_corridor' }) do
        local global = self[setname]
        for k in pairs(cache[setname]) do
            global[abs(k)] = src
        end
    end

    -- dead exits: exits covered by the new blueprint's no_room
    for k in pairs(cache.no_room) do
        local ak = abs(k)
        if self.room_connect[ak] then self.room_connect[ak] = nil end
    end

    -- count_as bookkeeping (PlanSetup::add_count)
    local plan = self.plan
    local ca = plan.count_as and plan.count_as[src] or nil
    if ca then
        for t, n in pairs(ca) do
            local slash = t:find('/')
            if not slash then
                self.counts[t] = (self.counts[t] or 0) + n
            else
                local tt, nn = t:sub(1, slash - 1), t:sub(slash + 1)
                self.instance_counts[tt] = self.instance_counts[tt] or {}
                self.instance_counts[tt][nn] = (self.instance_counts[tt][nn] or 0) + n
            end
        end
    end
    self.counts[rb.type] = (self.counts[rb.type] or 0) + 1
    self.instance_counts[rb.type] = self.instance_counts[rb.type] or {}
    self.instance_counts[rb.type][rb.name] =
        (self.instance_counts[rb.type][rb.name] or 0) + 1

    return true
end

-- PlanSetup::can_add_room — map viability (bounds / rock / water / ...)
function Placer:can_add_room(rb, pos)
    self.tries = self.tries + 1
    -- resumable: yield to the host every `yield_every` tries so a big map
    -- never freezes the game (the C++ spread setup over ticks the same way)
    if self.yield_every and self.tries % self.yield_every == 0 then
        coroutine.yield(self.tries)
    end
    local px, py, pz = pos.x, pos.y, pos.z
    local mw, mh, md = self.map.x, self.map.y, self.map.z
    local TTM = df.tiletype_material

    local function in_bounds(x, y, z)
        return x >= 0 and x < mw and y >= 0 and y < mh and z >= 0 and z < md
    end

    -- bounds: every no_room tile must be a valid tile
    for k in pairs(rb.cache.no_room) do
        local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
        if not in_bounds(px + tonumber(x), py + tonumber(y), pz + tonumber(z)) then
            return false
        end
    end

    for _, r in ipairs(rb.r) do
        local rmin = { x = px + r.min[1], y = py + r.min[2], z = pz + r.min[3] }
        local rmax = { x = px + r.max[1], y = py + r.max[2], z = pz + r.max[3] }
        if not in_bounds(rmin.x - 2, rmin.y - 2, rmin.z - 1)
            or not in_bounds(rmax.x + 2, rmax.y + 2, rmax.z + 1) then
            return false
        end

        if r.outdoor then
            for x = rmin.x, rmax.x do
                for y = rmin.y, rmax.y do
                    for z = rmin.z, rmax.z do
                        local td = tile_data(x, y, z)
                        if not td then return false end
                        if shape_family(td.shape) == 'wall' and td.material ~= TTM.TREE then
                            return false -- underground
                        end
                        if r.require_floor ~= false then
                            local s = surface_tile_at(x, y, self.z_top, true)
                            if not s or s.z ~= z then return false end
                        end
                        if td.occ and td.occ.building and td.occ.building ~= 0
                            and not self.wagon_tiles[key(x, y, z)] then
                            return false -- building present
                        end
                    end
                end
            end
        elseif not self.relaxed then
            -- dig furniture must not sit above a cavern
            for _, fi in ipairs(r.layout or {}) do
                local f = rb.f[fi + 1]
                if f and f.dig ~= nil and f.dig ~= 'No' and f.dig ~= 'Default'
                    and f.dig ~= 'UpStair' and f.dig ~= 'Ramp' then
                    local tx, ty, tz = rmin.x + f.x, rmin.y + f.y, rmin.z + (f.z or 0)
                    for dx = -1, 1 do
                        for dy = -1, 1 do
                            local td = tile_data(tx + dx, ty + dy, tz - 1)
                            if not td or shape_family(td.shape) ~= 'wall'
                                or td.material == TTM.TREE then
                                return false
                            end
                        end
                    end
                end
            end
            -- the room bbox + 1-tile ring + one z above: solid natural rock
            for x = rmin.x - 1, rmax.x + 1 do
                for y = rmin.y - 1, rmax.y + 1 do
                    for z = rmin.z, rmax.z + 1 do
                        local td = tile_data(x, y, z)
                        if not td then return false end
                        if td.des and td.des.flow_size > 0 then return false end
                        if td.material == TTM.POOL or td.material == TTM.RIVER
                            or td.material == TTM.BROOK then
                            return false
                        end
                        if z == rmax.z + 1 then
                            -- only water checked above the room
                        else
                            if shape_family(td.shape) ~= 'wall' or td.material == TTM.TREE then
                                return false -- above ground / open cavern
                            end
                            if td.occ and td.occ.building and td.occ.building ~= 0
                                and not self.wagon_tiles[key(x, y, z)] then
                                return false
                            end
                        end
                    end
                end
            end
        end
    end
    return true
end

-- availability filter shared by all phases (find_available_blueprints)
function Placer:available(tags_base)
    local plan = self.plan
    local tags = {}
    for _, t in ipairs(tags_base) do
        tags[t] = true
        local exp = plan.tags and plan.tags[t]
        if exp then
            for _, t2 in ipairs(exp) do tags[t2] = true end
        end
    end
    local out = {}
    for _, rb in ipairs(self.variants) do
        if tags[rb.type] then
            local limit = plan.limits and plan.limits[rb.type]
            local ilimits = plan.instance_limits and plan.instance_limits[rb.type]
            local count = self.counts[rb.type] or 0
            if limit and count >= limit[2] then
                -- type maxed
            elseif limit or ilimits then
                local icount = (self.instance_counts[rb.type] or {})[rb.name] or 0
                local ilimit = ilimits and ilimits[rb.name]
                if limit == nil and ilimit == nil then
                    -- not placeable
                elseif ilimit and icount >= ilimit[2] then
                    -- instance maxed
                else
                    table.insert(out, rb)
                end
            end
        end
    end
    return out
end

local function shuffled(list)
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    for i = #out, 2, -1 do
        local j = math.random(i)
        out[i], out[j] = out[j], out[i]
    end
    return out
end

-- place_rooms: outer loop re-scans availability after every success;
-- max_failures counts CONSECUTIVE failures. `tags_base` may be a list or
-- a FUNCTION returning the live tag list (the connect phase re-scans
-- live exit tags after every placement).
function Placer:place_rooms(tags_base, try_add)
    local max_failures = self.plan.max_failures or 100
    while true do
        local tags = type(tags_base) == 'function' and tags_base(self) or tags_base
        local avail = self:available(tags)
        if #avail == 0 then break end
        local order = shuffled(avail)
        local failures = 0
        local stop = false
        while not stop do
            for _, rb in ipairs(order) do
                if self.tries >= (self.max_tries or math.huge) then
                    stop = true
                    break
                end
                if try_add(self, rb) then
                    stop = true
                    break
                else
                    failures = failures + 1
                    if failures >= max_failures then
                        stop = true
                    end
                end
            end
            if failures >= max_failures then stop = true end
        end
        if failures >= max_failures or self.tries >= (self.max_tries or math.huge) then
            break
        end
    end
end

-- Phase 1: start — near the fort entrance (C++ uses random map spots;
-- we spiral outward from the wagon: dwarves start there)
function Placer:try_add_start(rb)
    local entrance = self.entrance
    local candidates = { { 0, 0 } }
    for r = 5, 45, 5 do
        for a = 0, 7 do
            table.insert(candidates, {
                math.floor(r * math.cos(a * math.pi / 4)),
                math.floor(r * math.sin(a * math.pi / 4)) })
        end
    end
    for _, off in ipairs(candidates) do
        local x, y = entrance.x + off[1], entrance.y + off[2]
        if x >= 3 and y >= 3 and x < self.map.x - 3 and y < self.map.y - 3 then
            local pos = surface_tile_at(x, y, self.z_top, true)
            if pos and self:can_add_room(rb, pos) then
                local ok = self:add(rb, pos, nil)
                if ok then
                    self.log('placed ' .. rb.type .. '/' .. rb.tmpl_name
                        .. ' at ' .. pos.x .. ',' .. pos.y .. ',' .. pos.z)
                    return true
                end
            end
        end
    end
    return false
end

-- Phase 2: outdoor blueprints at random surface tiles
function Placer:try_add_outdoor(rb)
    for _ = 1, 10 do
        local x = math.random(2, self.map.x - 3)
        local y = math.random(2, self.map.y - 3)
        local pos = surface_tile_at(x, y, self.z_top, true)
        if pos and self:can_add_room(rb, pos) then
            local ok = self:add(rb, pos, nil)
            if ok then
                self.log('placed ' .. rb.type .. '/' .. rb.tmpl_name .. '/'
                    .. rb.name .. ' at ' .. pos.x .. ',' .. pos.y .. ',' .. pos.z)
                return true
            end
        end
    end
    return false
end

-- Phase 3: connect — anchor a random variant on a random live exit
-- whose tag matches the variant type (through plan.tags expansion)
function Placer:try_add_connect(rb)
    local tags = { [rb.type] = true }
    for t, exp in pairs(self.plan.tags or {}) do
        for _, t2 in ipairs(exp) do
            if t2 == rb.type then tags[t] = true break end
        end
    end
    local connectors = {}
    for ak, conn in pairs(self.room_connect) do
        if not conn.room.removed then
            for _, t in ipairs(conn.tags) do
                if tags[t] then
                    table.insert(connectors, { conn.room, ak })
                    break
                end
            end
        end
    end
    if #connectors == 0 then return false end
    local chosen = connectors[math.random(#connectors)]
    local x, y, z = chosen[2]:match('^(-?%d+),(-?%d+),(-?%d+)$')
    local pos = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
    if self:can_add_room(rb, pos) then
        local ok = self:add(rb, pos, chosen[1])
        if ok then
            self.log('placed ' .. rb.type .. '/' .. rb.tmpl_name .. '/'
                .. rb.name .. ' at ' .. pos.x .. ',' .. pos.y .. ',' .. pos.z)
            return true
        end
    end
    return false
end

-- remove_unused_rooms fixpoint (blueprint engine post-pass)
function Placer:remove_unused_rooms()
    local changed = true
    while changed do
        changed = false
        local used = {}
        for _, rec in ipairs(self.rooms) do
            if not rec.removed then
                if rec.parent and not rec.parent.removed then
                    used[rec.parent] = true
                end
                for _, sidx in ipairs(rec.sibling_ap) do
                    local sib = rec.inst.rooms[sidx + 1]
                    if sib and not sib.removed then used[sib] = true end
                end
            end
        end
        for _, rec in ipairs(self.rooms) do
            if not rec.removed and rec.data.remove_if_unused and not used[rec] then
                rec.removed = true
                changed = true
            end
        end
    end
    -- purge exits owned by removed rooms
    for ak, conn in pairs(self.room_connect) do
        if conn.room.removed then self.room_connect[ak] = nil end
    end
end

-- handle_stairs_special: stairs_special furniture adapts to neighbors
function Placer:handle_stairs_special()
    local DIG = df.tile_dig_designation
    local stair_positions = {}
    for _, rec in ipairs(self.rooms) do
        if not rec.removed then
            for _, fi in ipairs(rec.data.layout or {}) do
                local f = rec.rb.f[fi + 1]
                if f and not f.ignore and f.dig
                    and (f.dig == 'UpStair' or f.dig == 'DownStair'
                        or f.dig == 'UpDownStair') then
                    stair_positions[key(rec.min.x + f.x, rec.min.y + f.y,
                        rec.min.z + (f.z or 0))] = true
                end
            end
        end
    end
    for _, rec in ipairs(self.rooms) do
        if not rec.removed then
            for _, fi in ipairs(rec.data.layout or {}) do
                local f = rec.rb.f[fi + 1]
                if f and f.stairs_special then
                    local fk = key(rec.min.x + f.x, rec.min.y + f.y, rec.min.z + (f.z or 0))
                    local z = rec.min.z + (f.z or 0)
                    local above = stair_positions[key(rec.min.x + f.x, rec.min.y + f.y, z + 1)]
                    local below = stair_positions[key(rec.min.x + f.x, rec.min.y + f.y, z - 1)]
                    if above and below then
                        f.dig = 'UpDownStair'
                    elseif above then
                        f.dig = 'UpStair'
                    elseif below then
                        f.dig = 'DownStair'
                    else
                        f.dig = 'Default'
                    end
                end
            end
        end
    end
end

function Placer:have_minimum_requirements()
    local plan = self.plan
    for t, limit in pairs(plan.limits or {}) do
        if (self.counts[t] or 0) < limit[1] then return false, t end
    end
    for t, ilimits in pairs(plan.instance_limits or {}) do
        for n, ilimit in pairs(ilimits) do
            if ((self.instance_counts[t] or {})[n] or 0) < ilimit[1] then
                return false, t .. '/' .. n
            end
        end
    end
    return true
end

-- The 3-phase build (PlanSetup::build)
function Placer:build()
    local plan = self.plan
    local start_tags = { plan.start }
    self:place_rooms(start_tags, Placer.try_add_start)
    if #self.placed == 0 then
        return false, 'start blueprint did not fit anywhere'
    end

    local outdoor_tags = {}
    for _, t in ipairs(plan.outdoor or {}) do table.insert(outdoor_tags, t) end
    if #outdoor_tags > 0 then
        self:place_rooms(outdoor_tags, Placer.try_add_outdoor)
    end

    -- connect phase: tags = every live exit tag
    self:place_rooms(function(pl)
        local tags = {}
        for _, conn in pairs(pl.room_connect) do
            if not conn.room.removed then
                for _, t in ipairs(conn.tags) do table.insert(tags, t) end
            end
        end
        return tags
    end, Placer.try_add_connect)

    local ok, missing = self:have_minimum_requirements()
    if not ok then
        self.log('note: minimum not reached for ' .. tostring(missing)
            .. ' (best effort)')
    end
    self:remove_unused_rooms()
    self:handle_stairs_special()
    return true
end

-- ============================================================
-- Instantiation — blueprint records -> rooms_module room objects
-- with RESOLVED accesspath/workshop references (create_from_blueprint)
-- ============================================================

local function build_room_kwargs(rec)
    local r = rec.data
    -- JSON carries workshop/furnace types as NAMES ("Carpenters");
    -- the runtime (construction dispatch, priority filters) needs the
    -- DF enum NUMBER.
    local function to_enum(enum_tbl, name)
        if name == nil or type(name) ~= 'string' then return name end
        local ok, v = pcall(function() return enum_tbl[name] end)
        if ok and v ~= nil then return v end
        return nil
    end
    return {
        corridor_type = r.corridor_type,
        farm_type = r.farm_type,
        stockpile_type = r.stockpile_type,
        nobleroom_type = r.nobleroom_type,
        outpost_type = r.outpost_type,
        location_type = r.location_type,
        cistern_type = r.cistern_type,
        workshop_type = to_enum(df.workshop_type, r.workshop_type),
        furnace_type = to_enum(df.furnace_type, r.furnace_type),
        raw_type = r.raw_type,
        comment = r.comment,
        level = r.level or 0,
        noblesuite = rec.noblesuite,
        queue = r.queue or 0,
        outdoor = r.outdoor or false,
        temporary = r.temporary or false,
        build_when_accessible = r.build_when_accessible or false,
        has_users = r.has_users or 0,
        stock_disable = r.stock_disable or {},
        stock_specific1 = r.stock_specific1 or false,
        stock_specific2 = r.stock_specific2 or false,
    }
end

local DIG_MAP = {
    No = 'No', Default = 'Default', UpStair = 'UpStair',
    DownStair = 'DownStair', UpDownStair = 'UpDownStair',
    Channel = 'Channel', Ramp = 'Ramp',
}

-- Turn the placed records into room/furniture objects.
-- rooms_module: the df-ai/rooms module. Returns:
--   rooms, corridors, fort_entrance (room object), stats
function M.instantiate(placer, rooms_module)
    local rooms, corridors = {}, {}
    local rec2room = {}

    local function dig_value(name)
        if name == nil then return nil end
        local dn = DIG_MAP[name] or name
        local ok, v = pcall(function() return df.tile_dig_designation[dn] end)
        if ok and v ~= nil then return v end
        return df.tile_dig_designation.Default
    end

    for _, rec in ipairs(placer.rooms) do
        if not rec.removed then
            local kwargs = build_room_kwargs(rec)
            local rm = rooms_module.room.new(rec.data.type or 'corridor',
                { x = rec.min.x, y = rec.min.y, z = rec.min.z },
                { x = rec.max.x, y = rec.max.y, z = rec.max.z },
                kwargs)
            rm.queue_dig = false
            rm.room_record = rec
            rec2room[rec] = rm

            for _, fi in ipairs(rec.data.layout or {}) do
                local f = rec.rb.f[fi + 1]
                if f then
                    local fobj = rooms_module.furniture.new(
                        f.type or 'none',
                        {
                            x = rec.min.x + f.x,
                            y = rec.min.y + f.y,
                            z = rec.min.z + (f.z or 0),
                        },
                        {
                            construction = f.construction,
                            dig = dig_value(f.dig),
                            makeroom = f.makeroom or false,
                            internal = f.internal or false,
                            ignore = f.ignore or false,
                            has_users = f.has_users or 0,
                            comment = f.comment or '',
                            stairs_special = f.stairs_special or false,
                            target_idx = f.target,
                        })
                    table.insert(rm.layout, fobj)
                end
            end
            table.insert(rooms, rm)
            if rm.type == 'corridor' then table.insert(corridors, rm) end
        end
    end

    -- resolve references (parent chain first, then siblings)
    for _, rec in ipairs(placer.rooms) do
        if not rec.removed then
            local rm = rec2room[rec]
            if rec.parent and not rec.parent.removed and rec2room[rec.parent] then
                table.insert(rm.accesspath, rec2room[rec.parent])
            end
            for _, sidx in ipairs(rec.sibling_ap) do
                local sib = rec.inst.rooms[sidx + 1]
                if sib and not sib.removed and rec2room[sib] then
                    table.insert(rm.accesspath, rec2room[sib])
                end
            end
            if rec.workshop_idx ~= nil then
                local wrec = rec.inst.rooms[rec.workshop_idx + 1]
                if wrec and not wrec.removed and rec2room[wrec] then
                    rm.workshop_room = rec2room[wrec]
                end
            end
        end
    end

    -- fort entrance = first room of the first placed blueprint
    local fort_entrance = nil
    local first = placer.placed[1]
    if first and first.rooms[1] and rec2room[first.rooms[1]] then
        fort_entrance = rec2room[first.rooms[1]]
    elseif rooms[1] then
        fort_entrance = rooms[1]
    end

    -- sort: outdoor first (euclidean), then indoor by entrance distance
    local function edist(r)
        local p = r:pos()
        local e = fort_entrance:pos()
        return math.sqrt((p.x - e.x) ^ 2 + (p.y - e.y) ^ 2 + (p.z - e.z) ^ 2)
    end
    table.sort(rooms, function(a, b)
        if a.outdoor ~= b.outdoor then return a.outdoor == true end
        if a.outdoor then return edist(a) < edist(b) end
        return a:distance_to(fort_entrance) < b:distance_to(fort_entrance)
    end)

    local stats = {
        placed = #placer.placed,
        rooms = #rooms,
        corridors = #corridors,
        counts = placer.counts,
        instance_counts = placer.instance_counts,
        tries = placer.tries,
    }
    return rooms, corridors, fort_entrance, stats
end

-- ============================================================
-- Entry point
-- ============================================================

-- Resumable builder: the C++ ran blueprint setup as an exclusive
-- callback over multiple ticks with a progress screen (PlanSetup,
-- one log-step every 2 ticks). A single blocking Lua call could
-- freeze the game for tens of seconds on big maps, so the whole
-- build runs inside a coroutine that yields every `yield_every`
-- placement tries. plan.lua resumes it from Plan:update.
--
-- builder = M.start_build(rooms_module, opts)
-- while not builder.done do builder:step(tries_budget) end
-- ok, rooms, corridors, fort_entrance, stats = builder:result()
function M.start_build(rooms_module, opts)
    opts = opts or {}
    local builder = {
        done = false,
        failed = false,
        status = 'starting',
        res = nil, -- NOTE: not `result` — that name is the METHOD below
        log = opts.log or function() end,
        rooms_module = rooms_module,
    }

    local co = coroutine.create(function()
        local plan, variants = M.load_all()
        if not plan then
            return false, 'blueprints unavailable: ' .. tostring(variants)
        end

        local mw, mh, md
        if opts.map then
            mw, mh, md = opts.map.x, opts.map.y, opts.map.z
        else
            local okMap, a, b, c = pcall(function()
                return dfhack.maps.getTileSize()
            end)
            if not okMap or not a or a <= 0 then
                return false, 'no map loaded'
            end
            mw, mh, md = a, b, c
        end

        local z_top = opts.z_top or (md - 1)
        local log = builder.log
        builder.plan = plan

        local function attempt(relaxed)
            local placer = Placer.new({
                plan = plan,
                variants = variants,
                map = { x = mw, y = mh, z = md },
                z_top = z_top,
                log = log,
                relaxed = relaxed,
                wagon_tiles = opts.wagon_tiles,
                yield_every = 250,
            })
            placer.entrance = opts.entrance
            placer.max_tries = opts.max_tries or 8000
            local ok, reason = placer:build()
            if not ok then return nil, reason end
            return placer
        end

        log('building fortress layout ('
            .. tostring(plan.priorities and #plan.priorities or 0)
            .. ' priority rules, ' .. #variants .. ' blueprint variants)')

        local placer, reason = attempt(false)
        local relaxed_used = false
        if not placer then
            log('strict placement failed (' .. tostring(reason)
                .. ') - retrying without rock validation')
            placer, reason = attempt(true)
            relaxed_used = placer ~= nil
            if not placer then
                return false, 'placement failed: ' .. tostring(reason)
            end
        end

        local rooms, corridors, fort_entrance, stats =
            M.instantiate(placer, rooms_module)
        stats.relaxed = relaxed_used
        stats.variants = #variants
        stats.counts = placer.counts
        return true, rooms, corridors, fort_entrance, stats
    end)

    builder.co = co

    -- resume for up to `budget` yields (each yield ~ yield_every tries)
    function builder:step(budget)
        budget = budget or 1
        for _ = 1, budget do
            if self.done then return end
            local ok, a, b, c, d, e = coroutine.resume(self.co)
            if not ok then
                self.done = true
                self.failed = true
                self.status = 'error: ' .. tostring(a)
                self.res = { false, tostring(a) }
                self.log('placement error: ' .. tostring(a))
                return
            end
            if coroutine.status(self.co) == 'dead' then
                self.done = true
                self.res = { a, b, c, d, e }
                if a then
                    self.status = 'done'
                else
                    self.failed = true
                    self.status = 'failed: ' .. tostring(b)
                end
                return
            end
            self.status = 'working (' .. tostring(a) .. ' placement tries)'
        end
    end

    function builder:result()
        if not self.done then
            self:step(math.huge)
        end
        local r = self.res or { false, self.status }
        return table.unpack(r)
    end

    return builder
end

-- Synchronous one-shot build (used by tests / small maps)
function M.build(rooms_module, opts)
    local b = M.start_build(rooms_module, opts)
    return b:result()
end

return M
