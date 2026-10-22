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

-- All button positions were measured on a 160x66 grid (1280x800 windowed)
-- and are stored as FRACTIONS of the screen so they scale to any grid
-- size. A 1366x768 display runs a 170x64 grid — fixed grid coordinates
-- miss every button there.
local function click_frac(fx, fy)
    local dimx, dimy = 160, 66
    pcall(function()
        dimx = df.global.gps.dimx or 160
        dimy = df.global.gps.dimy or 66
    end)
    if dimx < 40 or dimy < 20 then dimx, dimy = 160, 66 end
    return click_grid(math.floor(fx * dimx + 0.5), math.floor(fy * dimy + 0.5))
end

function Embark.new(ai)
    local o = {
        ai = ai,
        -- debounce memory: which (screen, stage) pairs we already handled
        handled = {},
        announced_site = false,
    }
    setmetatable(o, Embark)
    o:reset()
    return o
end

-- Reset per-screen debounce memory (call when leaving pre-game flow).
function Embark:reset()
    self.handled = {}
    self.announced_site = false
    self.title_tries = 0
    self.gt_tries = 0
    self.su_tries = 0
    self.last_title_mode = nil
    self.want_continue = nil
    self.site_settle = nil
    self.guided_title = false
    self.guided_title_list = false
    self.guided_gametype = false
    self.guided_setup = false
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

        if help and help.open then
            -- skip the embark tutorial prompt the way hide-tutorials does:
            -- switch to the plain message context and click its button
            local scr = dfhack.gui.getCurViewscreen(true)
            local fy = 0.348 -- row 23 on the 160x66 reference grid
            if help.context == df.help_context_type.EMBARK_TUTORIAL_CHOICE then
                help.context = df.help_context_type.EMBARK_MESSAGE
                fy = 0.273 -- row 18 on the reference grid
            end
            if help.context == df.help_context_type.EMBARK_MESSAGE and scr then
                df.global.gps.mouse_x = df.global.gps.dimx // 2
                df.global.gps.mouse_y = math.floor(fy * df.global.gps.dimy + 0.5)
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
                -- one bad tile read must not abort the whole scan
                local ok, score, f1, f2, f3, f4, f5 = pcall(function()
                    local s = 0
                    -- elevation (df-structures): 0-99 = ocean, 100-149 =
                    -- all other biomes (land), 150+ = mountains
                    local elev = tonumber(e.elevation) or 0
                    if elev < 100 then s = s - 1200
                    elseif elev >= 200 then s = s - 300
                    elseif elev >= 150 then s = s - 120 end
                    -- evil: 0-32 good, 33-65 neutral, 66+ evil
                    local evil = tonumber(e.evilness) or 50
                    if evil >= 66 then s = s - 800 end
                    s = s - evil * 2
                    -- savagery: 0-32 calm, 33-65 neutral, 66+ savage
                    local sav = tonumber(e.savagery) or 50
                    if sav >= 66 then s = s - 500 end
                    s = s - sav * 2
                    -- temperature: df-structures says Urist (10000 = 0 C),
                    -- but the live 53.16 binary reads 0-100 (75 = temperate
                    -- on a pocket island) — handle BOTH scales
                    local t = tonumber(e.temperature) or 60
                    if t > 5000 then
                        if t < 9900 then s = s - 400 end   -- freezing
                        if t > 11000 then s = s - 400 end   -- scorching
                        s = s - math.abs(t - 10400) / 8
                    else
                        if t < 25 then s = s - 400 end      -- freezing
                        if t > 85 then s = s - 400 end      -- scorching
                        s = s - math.abs(t - 60) * 3
                    end
                    -- vegetation: want trees (beds!)
                    local veg = tonumber(e.vegetation) or 0
                    if veg < 10 then s = s - 300 end
                    s = s + veg * 2
                    -- salinity: prefer fresh (coastal salt = no drinking)
                    local sal = tonumber(e.salinity) or 0
                    if sal >= 66 then s = s - 100 end
                    return s, elev, evil, sav, veg, t
                end)
                if ok then
                    samples = samples + 1
                    if score > best_score then
                        best_score = score
                        -- keep the scan-time field values: the region map
                        -- can be repopulated by the site screen AFTER the
                        -- scan, so re-reading best.entry later may differ
                        best = { x = x, y = y, score = score, entry = e,
                            scan_elev = f1, scan_evil = f2, scan_sav = f3,
                            scan_veg = f4, scan_temp = f5 }
                    end
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

    local ok, werr = pcall(function()
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
        dbg('select_site: write failed: ' .. tostring(werr))
        say('failed to write embark location — pick a site manually')
        return false
    end

    -- log the raw tile values too — if the flat-array indexing ever drifts,
    -- the user's console report shows it immediately
    local raw = ''
    pcall(function()
        raw = string.format(' [scan: elev %s evil %s sav %s veg %s temp %s | reread: %s %s %s %s]',
            tostring(best.scan_elev), tostring(best.scan_evil), tostring(best.scan_sav),
            tostring(best.scan_veg), tostring(best.scan_temp),
            tostring(best.entry.elevation), tostring(best.entry.evilness),
            tostring(best.entry.savagery), tostring(best.entry.vegetation))
    end)
    say(string.format('site selected: region (%d, %d), %dx%d, score %.0f%s (of %d tiles scanned)',
        rx, ry, dx, dy, best.score, raw, best.samples or 0))
    return true
end

-- ============================================================
-- Per-screen handlers
-- ============================================================

function Embark:handle_title(screen)
    self:suppress_tutorial()

    -- 53.16 title screen state machine (df-structures: viewscreen_titlest):
    --   mode: MAIN_MENU | CONTINUE_INACTIVE (Start->world list)
    --       | CONTINUE_ACTIVE_WORLD (Continue->world list)
    --       | CONTINUE_ACTIVE (Continue->save list) | ABOUT
    --   menu_line_id: vector<main_choice_type> shown on the main menu
    --   selected: index (0-based) into the current menu/list
    local M = df.title_mode_type
    local mode = screen.mode

    -- reset the retry counter whenever the title screen changes page
    if self.last_title_mode ~= mode then
        self.last_title_mode = mode
        self.title_tries = 0
    end
    self.title_tries = self.title_tries + 1

    -- Detect what the menu OFFERS. NOTE: the savegame_header_* vectors are
    -- EMPTY while on the main menu (they are populated only inside the
    -- lists — verified live), so the menu items themselves are the signal:
    --   "Continue" present -> fort saves exist
    --   "Start" present    -> worlds exist (but no fort saves)
    local function menu_has(choice)
        local found = false
        pcall(function()
            for _, v in ipairs(screen.menu_line_id) do
                if v == choice then found = true end
            end
        end)
        return found
    end

    if mode == M.MAIN_MENU then
        -- (re)compute and CACHE the goal: in the list modes menu_line_id
        -- may be stale/empty, so the decision must not depend on it there
        local has_continue = menu_has(df.main_choice_type.Continue)
        self.want_continue = has_continue
            and (not self.ai or not self.ai.config
                or self.ai.config.embark_continue_fort ~= false)
    end
    local want_continue
    if self.want_continue ~= nil then
        want_continue = self.want_continue
    else
        -- never saw the main menu this run: infer the goal from the list
        -- we are already in (Start-world list = new-fortress flow)
        want_continue = (mode ~= M.CONTINUE_INACTIVE)
    end

    if mode == M.MAIN_MENU then
        local choice
        if want_continue then
            choice = df.main_choice_type.Continue
        elseif menu_has(df.main_choice_type.Start) then
            choice = df.main_choice_type.Start
        else
            choice = df.main_choice_type.NewWorld
        end

        -- find the menu item and highlight it. NOTE: ipairs over a DFHack
        -- vector is 0-BASED (verified live: first iteration yields i=0) —
        -- i IS the 0-based menu index; do not subtract 1 (the old i-1 set
        -- selected=-1, which is why "Continue Playing" was never picked)
        local idx0 = nil
        pcall(function()
            for i, v in ipairs(screen.menu_line_id) do
                if v == choice then idx0 = i end
            end
        end)

        if self.title_tries == 1 then
            if choice == df.main_choice_type.Continue then
                say('existing fort save found — selecting "Continue Playing"')
            elseif choice == df.main_choice_type.Start then
                say('existing world found — selecting "Start Playing"')
            else
                say('no saves found — selecting "Create New World"')
            end
        end

        if idx0 then
            -- v50 title buttons are MOUSE-driven: selected+SELECT alone does
            -- NOTHING (verified live on 53.16), but a gps-injected click at
            -- the button works. Measured layout (calibrated on BOTH
            -- 1280x800/160x66 and 1366x768/170x64):
            --   menu items are top-anchored, first item's button at ~55.3%
            --   of the screen height, spacing EXACTLY 3 grid rows at any
            --   resolution (35.8px @66 rows, 36px @64 rows). There is no
            --   big banner: Continue/Start is simply item 0.
            local dimx, dimy = 160, 66
            pcall(function()
                dimx = df.global.gps.dimx or 160
                dimy = df.global.gps.dimy or 66
            end)
            if dimx < 40 or dimy < 20 then dimx, dimy = 160, 66 end
            local gy = math.floor(0.553 * dimy + 0.5) + 3 * idx0
            click_grid(math.floor(0.494 * dimx + 0.5), gy)
            -- key/state channel kept as backup (harmless if ignored)
            pcall(function() screen.selected = idx0 end)
            send_keys('SELECT')
        end
        if self.title_tries >= 10 and not self.guided_title then
            self.guided_title = true
            say("if the menu did not move, click 'Continue Playing' / 'Start Playing' / 'Create New World' yourself")
        end
        return
    end

    if mode == M.CONTINUE_INACTIVE or mode == M.CONTINUE_ACTIVE_WORLD
        or mode == M.CONTINUE_ACTIVE then
        -- a save/world list page of the title screen
        local ok_mode = (want_continue and mode ~= M.CONTINUE_INACTIVE)
            or (not want_continue and mode == M.CONTINUE_INACTIVE)
        if not ok_mode then
            -- wrong list for our goal: back out to the main menu
            send_keys('LEAVESCREEN')
            return
        end
        if self.title_tries == 1 then
            if mode == M.CONTINUE_INACTIVE then
                say('world list — selecting the first world')
            elseif mode == M.CONTINUE_ACTIVE_WORLD then
                say('world list — selecting the first world')
            else
                say('save list — selecting the first (most recent) save')
            end
        end
        -- key/state channel first…
        pcall(function() screen.selected = 0 end)
        pcall(function() screen.selected_r = 0 end)
        send_keys('SELECT')
        -- …plus a click on the first row. Measured on the world list at
        -- 1366x768: the first entry's text spans 421-443px (~55-57% of the
        -- height); cycle nearby candidates per poll. x=0.494 is the center
        -- column, clear of the right-edge delete buttons.
        local rows = { 0.522, 0.5625, 0.6025 }
        click_frac(0.494, rows[((self.title_tries - 1) % #rows) + 1])
        if self.title_tries >= 10 and not self.guided_title_list then
            self.guided_title_list = true
            say('if nothing happened, click the first entry in the list yourself')
        end
        return
    end

    -- ABOUT / other pages: nothing to do
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
        click_frac(0.050, 0.333) -- [Play now!] (bottom-left of the report)
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

    -- params screen (-1/0). CLICKS ONLY (a stray SELECT key here opens the
    -- abort prompt and stalls worldgen — verified in earlier sessions).
    -- First the welcome popup [Okay], then [Create world] with the default
    -- worldgen params (writing simple_* params does not stick; the screen
    -- re-syncs them from the selected preset).
    if not self.handled.nr_announced then
        self.handled.nr_announced = true
        say('worldgen screen — creating a world (default params)')
        local function try_create()
            local st = -1
            pcall(function()
                st = df.global.world.worldgen_status.state or -1
            end)
            -- never click [Create world] once generation has started
            if st < 1 then click_frac(0.661, 0.941) end
        end
        click_frac(0.501, 0.386) -- welcome popup [Okay] (harmless if absent)
        dfhack.timeout(15, 'frames', function() click_frac(0.501, 0.386) end)
        dfhack.timeout(40, 'frames', try_create) -- [Create world]
        dfhack.timeout(90, 'frames', try_create) -- retry if the first was eaten
    end
end

function Embark:handle_game_type(screen)
    self:suppress_tutorial()

    self.gt_tries = (self.gt_tries or 0) + 1

    -- Fortress is gametype DWARF_MAIN. NOTE: this screen has NO 'selected'
    -- field in 53.16 (verified against df-structures) — selection is made
    -- by clicking the Fortress box or pressing SELECT.
    local idx = nil
    pcall(function()
        for i, gt in ipairs(screen.gametypes or {}) do
            if gt == df.game_type.DWARF_MAIN then idx = i end
        end
    end)
    if not idx then
        if self.gt_tries == 1 then
            say("choose 'Dwarf Fortress' mode to continue the auto-embark flow")
        end
        return
    end
    if self.gt_tries == 1 then
        say('game type: Fortress')
    end
    -- cycle candidate positions for the Fortress box across polls (the
    -- box position varies with layout; 0.358 is the 1280x800 measurement)
    local candidates = {
        { 0.494, 0.358 }, { 0.494, 0.310 }, { 0.494, 0.405 },
        { 0.494, 0.445 }, { 0.494, 0.265 },
    }
    local c = candidates[((self.gt_tries - 1) % #candidates) + 1]
    click_frac(c[1], c[2])
    send_keys('SELECT')
    if self.gt_tries >= 10 and not self.guided_gametype then
        self.guided_gametype = true
        say("if nothing happened, click the 'Dwarf Fortress' box")
    end
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
            -- (57.5%, 56.1% of the screen on the reference grid)
            click_frac(0.575, 0.561)
            dfhack.timeout(10, 'frames', function() click_frac(0.575, 0.561) end)
            dfhack.timeout(30, 'frames', function() click_frac(0.575, 0.561) end)
            dfhack.timeout(80, 'frames', function() click_frac(0.575, 0.561) end)
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
        -- let the site screen settle for one poll first: scanning the
        -- region map immediately after entry read STALE values (live
        -- debugging showed tiles flipping from ocean to land after the
        -- screen finished loading — score -1681 for a tile that reads
        -- elevation 146 a moment later)
        if not self.site_settle then
            self.site_settle = true
            return
        end
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
        dfhack.timeout(15, 'frames', function() click_frac(0.706, 0.955) end)
        dfhack.timeout(40, 'frames', function() click_frac(0.706, 0.955) end)
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
    self:suppress_tutorial()

    self.su_tries = (self.su_tries or 0) + 1

    -- NOTE: 53.16's viewscreen_setupdwarfgamest has no 'initial_selection'
    -- field (verified against df-structures). Try a spread of likely
    -- [Play Now!] button positions + SELECT, and tell the user what to do
    -- if none of them land.
    if self.su_tries == 1 then
        say('dwarf setup screen — going for [Play Now!]')
    end
    -- candidate positions (screen fractions), one per poll
    local candidates = {
        { 0.125, 0.500 }, { 0.125, 0.115 }, { 0.125, 0.885 },
        { 0.500, 0.925 }, { 0.125, 0.300 }, { 0.125, 0.700 },
    }
    local c = candidates[((self.su_tries - 1) % #candidates) + 1]
    click_frac(c[1], c[2])
    send_keys('SELECT')
    if self.su_tries >= #candidates and not self.guided_setup then
        self.guided_setup = true
        say("if nothing happened, click [Play Now!] yourself — the AI takes over when the map loads")
    end
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
