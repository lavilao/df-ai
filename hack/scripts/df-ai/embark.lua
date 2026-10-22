--@module = true
-- embark.lua — automatic embark for df-ai on DF 53.16 / DFHack 53.16-r3
--
-- Restores the "random embark" behavior of the original C++ df-ai: with
-- `enable df-ai` active at the title screen, df-ai drives the pre-fortress
-- flow —
--     title -> (new world if needed) -> worldgen -> game type: Fortress
--          -> site selection (scored) -> Embark -> Play Now
-- and hands over to the fortress AI when the map loads (SC_MAP_LOADED).
--
-- Input strategy per screen, most-preferred first:
--   1. direct state writes (always works — worldgen params, embark
--      rectangle, zoom)
--   2. interface-key injection via gui.simulateInput (the same channel
--      DFHack keybindings use; works on a real display)
--   3. clear console instructions for the 1-2 clicks we cannot inject
--
-- The watcher is polled (repeat-util, see df-ai.lua) while no map is
-- loaded, so worldgen completion (which happens without a viewscreen
-- change) is also caught.

local gui = require('gui')

local Embark = {}
Embark.__index = Embark

-- Persistent debug log (env global: survives module re-execution).
-- Read it with:
--   dfhack.script_environment('df-ai/embark').EMBARK_LOG
EMBARK_LOG = EMBARK_LOG or {}

local function say(msg)
    dfhack.println('[df-ai embark] ' .. msg)
    table.insert(EMBARK_LOG, msg)
    if #EMBARK_LOG > 200 then table.remove(EMBARK_LOG, 1) end
end

local function dbg(msg)
    table.insert(EMBARK_LOG, msg)
    if #EMBARK_LOG > 200 then table.remove(EMBARK_LOG, 1) end
end

local function cur_screen()
    return dfhack.gui.getCurViewscreen(true)
end

local function focus_string()
    local ok, f = pcall(dfhack.gui.getCurFocus, true)
    if not ok then return '' end
    if type(f) == 'table' then f = table.concat(f, '/') end
    return f or ''
end

-- inject interface keys into the current screen
local function send_keys(...)
    local s = cur_screen()
    if not s then return false end
    local ok, err = pcall(gui.simulateInput, s, ...)
    if not ok then
        say('input injection failed: ' .. tostring(err))
    end
    return ok
end

-- Programmatic button click: position DF's internal mouse at grid
-- coordinates and inject a left click (technique used by DFHack's own
-- hide-tutorials script). Grid units = 8x12 font cells.
local function click_grid(gx, gy)
    local s = cur_screen()
    if not s then return false end
    pcall(function()
        df.global.gps.mouse_x = gx
        df.global.gps.mouse_y = gy
    end)
    return pcall(gui.simulateInput, s, '_MOUSE_L')
end

function Embark.new(ai)
    local o = {
        ai = ai,
        -- debounce memory: which (screen, stage) pairs we already handled
        handled = {},
        announced_site = false,
    }
    setmetatable(o, Embark)
    return o
end

-- Reset per-screen debounce memory (call when leaving pre-game flow).
function Embark:reset()
    self.handled = {}
    self.announced_site = false
end

-- ============================================================
-- Tutorial suppression — the v50 first-time tutorial popup covers
-- the embark site screen and eats clicks/keys. This mirrors DFHack's
-- own hide-tutorials script: close the help popup, click through the
-- embark tutorial prompt, and opt out of all fortress popups.
-- ============================================================
function Embark:suppress_tutorial()
    pcall(function()
        local help = df.global.game.main_interface.help
        local pi = df.global.plotinfo

        -- opt out of every fortress-mode tutorial popup (like
        -- hide-tutorials' hide_all_popups)
        for i, name in ipairs(df.help_context_type) do
            if type(name) == 'string' and name:startswith('POPUP_') then
                local seen, hide = pi.tutorial_seen, pi.tutorial_hide
                local function ins_sorted(vec, v)
                    for _, x in ipairs(vec) do if x == v then return end end
                    vec:insert('#', v)
                end
                ins_sorted(seen, i)
                ins_sorted(hide, i)
            end
        end

        if pi.flags and pi.flags.need_to_do_tutorial then
            pi.flags.need_to_do_tutorial = false
        end

        if help and help.open then
            -- skip the embark tutorial prompt the way hide-tutorials does:
            -- switch to the plain message context and click its button
            local scr = dfhack.gui.getCurViewscreen(true)
            local mouse_y = 23
            if help.context == df.help_context_type.EMBARK_TUTORIAL_CHOICE then
                help.context = df.help_context_type.EMBARK_MESSAGE
                mouse_y = 18
            end
            if help.context == df.help_context_type.EMBARK_MESSAGE and scr then
                df.global.gps.mouse_x = df.global.gps.dimx // 2
                df.global.gps.mouse_y = mouse_y
                pcall(gui.simulateInput, scr, '_MOUSE_L')
            end
            help.open = false
        end
    end)
end

-- ============================================================
-- Site scoring — the spirit of the old find_embark: pick a
-- habitable, calm, non-evil, vegetated, temperate land tile.
-- ============================================================

-- region_map is a region_map_entry** (x-major: region_map[x] is a pointer
-- to the column of entries for world x). In the DFHack Lua wrapper, rm[x]
-- double-dereferences and returns a region_map_entry wrapper for entry
-- (x, 0) — verified live on DF 53.16: rm[5].elevation works, but rm[5][7]
-- fails ("Cannot read field region_map_entry.7"). For y > 0 we take the
-- address of entry (x, 0) — df.sizeof(obj) returns (size, address) — and
-- reinterpret-cast to (x, y). sizeof(region_map_entry) = 112 on 53.16.
local RM_SIZE = nil
local function region_entry(rm, x, y)
    local ok, e = pcall(function() return rm[x] end)
    if not ok or not e then return nil end
    if y == 0 then return e end
    if not RM_SIZE then
        local ok_s, sz = pcall(df.sizeof, df.region_map_entry)
        if not ok_s or not sz or sz <= 0 then return nil end
        RM_SIZE = sz
    end
    -- address of entry (x, 0); df.sizeof returns (size, address)
    local ok_a, _, base = pcall(df.sizeof, e)
    if not ok_a or not base or base == 0 then return nil end
    local ok_e, e2 = pcall(df.reinterpret_cast, df.region_map_entry, base + y * RM_SIZE)
    if ok_e then return e2 end
    return nil
end

function Embark:score_sites()
    local world = df.global.world
    if not world or not world.world_data then
        dbg('score: no world/world_data')
        return nil
    end
    local wd = world.world_data
    local w, h = wd.world_width, wd.world_height
    if not w or not h or w <= 0 or h <= 0 or not wd.region_map then
        dbg('score: bad dims or region_map (w=' .. tostring(w) .. ' h=' .. tostring(h) .. ')')
        return nil
    end

    local best, best_score = nil, -1e9
    local samples = 0
    -- sample the map (stride 1 on a pocket/small world is fine; larger
    -- worlds get stride sampling to keep this cheap)
    local step = (w * h > 4000) and 2 or 1
    for x = 2, w - 2, step do
        for y = 2, h - 2, step do
            local e = region_entry(wd.region_map, x, y)
            if e then
                samples = samples + 1
                local score = 0
                local elev = e.elevation or 0
                -- land (not ocean/lake <100, not mountain 150+)
                if elev < 100 then score = score - 1000
                elseif elev >= 150 then score = score - 120 end
                -- evil: 0-32 good, 33-65 neutral, 66+ evil
                local evil = e.evilness or 50
                if evil >= 66 then score = score - 800 end
                score = score - evil * 2
                -- savagery: 0-32 calm, 33-65 neutral, 66+ savage
                local sav = e.savagery or 50
                if sav >= 66 then score = score - 500 end
                score = score - sav * 2
                -- temperature in Urist (10000 = 0 C): prefer temperate
                local t = e.temperature or 10000
                if t < 9900 then score = score - 400 end      -- freezing
                if t > 11000 then score = score - 400 end      -- scorching
                local tdist = math.abs(t - 10400)
                score = score - tdist / 8
                -- vegetation: want trees (beds!)
                local veg = e.vegetation or 0
                if veg < 10 then score = score - 300 end
                score = score + veg * 2
                -- salinity: prefer fresh (coastal salt = no drinking)
                local sal = e.salinity or 0
                if sal >= 66 then score = score - 100 end
                -- slight preference for variety of elevation nearby:
                -- flat-but-not-too-flat is nice; skip (needs neighbors)
                if score > best_score then
                    best_score = score
                    best = { x = x, y = y, score = score, entry = e }
                end
            end
        end
    end
    if best then best.samples = samples end
    if not best then
        dbg('score: no candidate found (samples=' .. samples .. ')')
    end
    return best
end

-- Write the chosen site into the site-selection viewscreen.
function Embark:select_site(screen)
    local best = self:score_sites()
    if not best then
        say('could not read the world map — pick a site manually')
        return false
    end

    local cfg = (self.ai and self.ai.config and self.ai.config.embark_options) or {}
    local dx = math.max(1, math.min(cfg.DimensionX or 3, 16))
    local dy = math.max(1, math.min(cfg.DimensionY or 2, 16))
    -- center the embark rect inside the 16x16 local area of the region tile
    local lx = math.floor((16 - dx) / 2)
    local ly = math.floor((16 - dy) / 2)
    local rx, ry = best.x, best.y

    local ok = pcall(function()
        screen.location.region_pos.x = rx
        screen.location.region_pos.y = ry
        screen.location.embark_pos_min.x = rx * 16 + lx
        screen.location.embark_pos_min.y = ry * 16 + ly
        screen.location.embark_pos_max.x = rx * 16 + lx + dx - 1
        screen.location.embark_pos_max.y = ry * 16 + ly + dy - 1
        -- zoom the local view to our site
        screen.zoomed_in = true
        screen.zoom_cent_x = rx * 16 + 8
        screen.zoom_cent_y = ry * 16 + 8
    end)
    if not ok then
        dbg('select_site: write failed: ' .. tostring(plan_err))
        say('failed to write embark location — pick a site manually')
        return false
    end

    say(string.format('site selected: region (%d, %d), %dx%d, score %.0f (of %d tiles scanned)',
        rx, ry, dx, dy, best.score, best.samples or 0))
    return true
end

-- ============================================================
-- Per-screen handlers
-- ============================================================

function Embark:handle_title(screen)
    if self.handled.title then return end
    self.handled.title = true
    self:suppress_tutorial()

    -- With an existing world save, the v50 title screen opens directly in
    -- the "Continue Playing" world list. Entering a world leads to the
    -- game-type selection, which is what we want.
    local n_worlds = 0
    pcall(function() n_worlds = #(screen.savegame_header_world or {}) end)
    if n_worlds > 0 then
        say('existing world found — selecting it to start playing')
        -- the first row is highlighted by default; SELECT/Enter loads it
        send_keys('SELECT')
        say("if nothing happened, click the world in the 'Continue playing' list")
        return
    end

    -- No world: the main menu. Choose "Create new world".
    local want = nil
    local ok_items = pcall(function()
        for i, v in ipairs(screen.menu_line_id or {}) do
            if v == df.main_choice_type.NewWorld then
                want = i
            end
        end
    end)
    if not ok_items or not want then
        say("at the title screen — select 'Create new world' to begin the auto-embark flow")
        return
    end

    say('title menu: selecting "Create new world"')
    pcall(function() screen.selected = want - 1 end) -- 0-based
    send_keys('SELECT')
    say('if nothing happened, click "Create new world" on the menu')
end

function Embark:handle_new_region(screen)
    -- worldgen_status.state: -1/0 = params screen, 1..10 = generating,
    -- 11 = Done ("Play now!" report). NOTE: world_data.world_width > 0 is
    -- NOT a valid completion check — it becomes true during generation.
    local world = df.global.world
    local gen_state = -1
    pcall(function()
        if world and world.worldgen_status then
            gen_state = world.worldgen_status.state or -1
        end
    end)

    -- If an abort prompt paused generation (e.g. a stray key during
    -- worldgen), dismiss it so generation continues.
    pcall(function()
        if screen.abort_world_gen_dialogue and screen.abort_world_gen_dialogue ~= 0 then
            screen.abort_world_gen_dialogue = 0
            say('cleared worldgen abort prompt')
        end
    end)

    if gen_state == 11 or (gen_state == 10 and self.nr_done_pending) then
        -- worldgen finished: the [Play now!] report screen. NOTE: the
        -- report screen appears while state is still 10 (Finalizing) in
        -- 53.16 — state 11 is only reached later (if ever), so we treat
        -- "state 10 seen for a while" as done.
        if self.handled.play_now then return end
        self.handled.play_now = true
        say('world generated — going for quick start (Play now!)')
        click_grid(8, 22)   -- [Play now!] (bottom-left of the report)
        send_keys('SELECT')
        say('if nothing happened, click [Play now!] (bottom left of the worldgen report)')
        return
    end

    if gen_state == 10 then
        -- Finalizing; give it a few polls before declaring done
        self.nr_done_pending = (self.nr_done_pending or 0) + 1
        if self.nr_done_pending > 6 then
            self.handled.play_now = nil -- allow the done branch next poll
        end
        return
    end

    if gen_state >= 1 then
        return -- generating; nothing to do
    end

    -- params screen (-1/0). Do NOT inject keys here: a stray SELECT during
    -- generation start opens the abort prompt and stalls worldgen. Also,
    -- writing simple_* params does not stick (the screen re-syncs them
    -- from the selected worldgen preset), so we just guide the user.
    if not self.handled.nr_announced then
        self.handled.nr_announced = true
        say('worldgen screen ready — dismiss the welcome popup (if any) and click [Create world]')
    end
end

function Embark:handle_game_type(screen)
    if self.handled.game_type then return end
    self.handled.game_type = true
    self:suppress_tutorial()

    -- Fortress is gametype DWARF_MAIN; find it and select it
    local idx = nil
    pcall(function()
        for i, gt in ipairs(screen.gametypes or {}) do
            if gt == df.game_type.DWARF_MAIN then idx = i end
        end
    end)
    if not idx then
        say("choose 'Dwarf Fortress' mode to continue the auto-embark flow")
        return
    end
    say('game type: Fortress')
    pcall(function() screen.selected = idx - 1 end)
    click_grid(79, 23)  -- the Fortress box (roughly centered)
    send_keys('SELECT')
    say("if nothing happened, click the 'Dwarf Fortress' box")
end

function Embark:handle_site(screen)
    local mode = (self.ai and self.ai.config and self.ai.config.embark_mode) or 'quick'

    -- 'quick' mode: press the tutorial-choice dialog's [Start tutorial /
    -- quick start] button — the game then picks a forested mineral-rich
    -- site and runs the whole embark flow by itself. This is one click on
    -- a DIALOG button (the input layer where programmatic clicks are
    -- reliable), unlike the site screen's bottom bar.
    if mode == 'quick' then
        local help_open = false
        pcall(function()
            help_open = df.global.game.main_interface.help.open
        end)
        if help_open and not self.handled.quick_start then
            self.handled.quick_start = true
            say('quick start: letting the game pick a forested mineral-rich site')
            -- [Start tutorial / quick start] button of the choice dialog
            -- (grid 92,37 on a 160x66 grid — the yellow hotkey marker)
            click_grid(92, 37)
            dfhack.timeout(10, 'frames', function() click_grid(92, 37) end)
            dfhack.timeout(30, 'frames', function() click_grid(92, 37) end)
            dfhack.timeout(80, 'frames', function() click_grid(92, 37) end)
            return
        end
        if not help_open and not self.handled.quick_start then
            -- popup already gone (dismissed earlier / opted out):
            -- fall through to scored mode below
            mode = 'scored'
            if not self.handled.quick_missed then
                self.handled.quick_missed = true
                say('tutorial dialog not available — using scored site selection')
            end
        end
    end

    -- 'scored' mode: pick our own site, place the rect, try to press Embark
    self:suppress_tutorial()

    -- select a scored site (idempotent: only announces once)
    if not self.announced_site then
        self.announced_site = true
        self:select_site(screen)
        -- The game shows an [Abort] button (instead of [Embark]) until a
        -- selection is made through its own input flow, so simulate a drag
        -- on the local map: the view is centered on our zoom_cent, i.e.
        -- the map center IS our chosen site. Drag out a small rectangle.
        local cx = df.global.gps.dimx // 2
        local cy = df.global.gps.dimy // 2
        pcall(function()
            df.global.gps.mouse_x = cx
            df.global.gps.mouse_y = cy
            gui.simulateInput(screen, '_MOUSE_L_DOWN')
            df.global.gps.mouse_x = cx + 18
            df.global.gps.mouse_y = cy + 9
            gui.simulateInput(screen, '_MOUSE_L_UP')
        end)
        say('embark rectangle placed — pressing Embark')
        -- after the drag the [Embark] button appears; click it a few
        -- frames later (give the game a moment to process the selection)
        dfhack.timeout(15, 'frames', function() click_grid(113, 63) end)
        dfhack.timeout(40, 'frames', function() click_grid(113, 63) end)
        say('press the green [Embark] button (bottom right) if the screen did not advance')
        return
    end

    -- keep the tutorial suppressed while we wait
    local help_ok, help_open = pcall(function()
        return df.global.game.main_interface.help.open
    end)
    if help_ok and help_open then
        self:suppress_tutorial()
    end
end

function Embark:handle_setup(screen)
    if self.handled.setup then return end
    self.handled.setup = true
    self:suppress_tutorial()

    say('dwarf setup screen — going for [Play Now!]')
    -- initial_selection: 0 = Play Now, 1 = Prepare carefully
    pcall(function() screen.initial_selection = 0 end)
    send_keys('SELECT')
    say("if nothing happened, click [Play Now!] on the left")
end

-- ============================================================
-- Entry point — called from df-ai.lua (polled + on screen change)
-- ============================================================
function Embark:on_viewscreen(manual)
    if dfhack.isMapLoaded() then return end

    local cfg = self.ai and self.ai.config or {}
    if not cfg.random_embark and not manual then return end
    if not self.ai then return end

    local s = cur_screen()
    if not s then return end

    if df.viewscreen_titlest:is_instance(s) then
        self:handle_title(s)
    elseif df.viewscreen_new_regionst:is_instance(s) then
        self:handle_new_region(s)
    elseif df.viewscreen_choose_game_typest:is_instance(s) then
        self:handle_game_type(s)
    elseif df.viewscreen_choose_start_sitest:is_instance(s) then
        self:handle_site(s)
    elseif df.viewscreen_setupdwarfgamest:is_instance(s) then
        self:handle_setup(s)
    end
end

function Embark:status()
    return '  auto-embark: ' ..
        (self.announced_site and 'site selected' or 'armed') ..
        ' (random_embark=' .. tostring(self.ai and self.ai.config and self.ai.config.random_embark) .. ')'
end

return Embark
