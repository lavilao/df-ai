--@module = true
-- trade.lua — trade automation for DF 53.16 (r3.11)
--
-- r3.10 and earlier claimed the v50+ trade UI was "not mapped in
-- df-structures" and reduced this module to a depot/broker status check.
-- That claim was WRONG. The whole trade screen lives in
-- df.global.game.main_interface.trade (trade_interfacest), fully mapped
-- in 53.16:
--   open             — the trade screen is on screen right now
--   mer              — caravan_state being traded with
--   fortress_trader  — the unit trading for the fort (the broker)
--   good[2]          — item vectors: [0] caravan goods, [1] fort goods
--   goodflag[2]      — per-item trade_interface_good_flag:
--                      selected / contained / container_collapsed /
--                      filtered_off
-- (verified against the 53.16 df-structures; the community "caravan"
-- overlay drives the exact same fields.)
--
-- What this module does:
--   * while a caravan sits at the depot (driven from
--     Population:update_trading), it watches for the trade screen to be
--     open; when it opens, it marks every fort good for trade following
--     the C++ stocks_trade spirit:
--       - artifacts stay home (they are fortress history)
--       - bin CONTENTS are skipped (their bin is selected instead, so
--         contents travel with it and nothing is double-selected)
--       - the keep-list stays home: seeds, plants, food, drink, thread,
--         cloth, eggs, milk... the fort eats and clothes itself first
--   * optional auto-confirm (config.trade_confirm, default OFF): after
--     marking, simulates the SEC_SELECT keypress (the generic v50
--     confirm) once. Enable with `df-ai enable trade_confirm` if the
--     vanilla Trade button does not fire on its own.
--   * dedup per open-session; re-arms when the screen closes or the
--     caravan leaves.

local Trade = {}
Trade.__index = Trade

local compat = dfhack.run_script_with_env(nil, 'df-ai/compat', { module = true })

local STATE = {
    IDLE = 'idle',     -- no caravan at the depot
    ACTIVE = 'active', -- caravan at the depot, watching for the screen
    DONE = 'done',     -- visit handled
}

-- item_type names that never leave the fortress (raw/strategic stocks)
local KEEP_BY_NAME = {
    SEEDS = true, PLANT = true, DRINK = true, LIQUID_MISC = true,
    POWDER_MISC = true, GLOB = true, CHEESE = true, MEAT = true,
    FISH = true, FISH_RAW = true, EGG = true,
    THREAD = true, CLOTH = true,
    CORPSE = true, CORPSEPIECE = true, REMAINS = true,
}

local function build_keep_types()
    local keep = {}
    pcall(function()
        -- KEEP_BY_NAME is keyed BY NAME (values are true) — iterate keys
        for name in pairs(KEEP_BY_NAME) do
            local v = df.item_type[name]
            if v and v >= 0 then keep[v] = true end
        end
    end)
    return keep
end

function Trade.new(ai)
    local o = {
        ai = ai,
        is_trading = false,
        state = STATE.IDLE,
        attempt = 0,
        max_attempts = 10,
        broker_id = -1,
        last_reported_year = -1,
        marked = false,      -- goods marked for the current open session
        confirmed = false,   -- confirm keypress sent for this session
        _keep = nil,
    }
    setmetatable(o, Trade)
    return o
end

-- Called when a caravan REACHES the depot (Population:update_trading).
function Trade:setup()
    if self.state ~= STATE.ACTIVE then
        dfhack.println('[df-ai] Trade check starting...')
    end
    self.is_trading = true
    self.state = STATE.ACTIVE
    self.attempt = 0
    return true
end

-- Caravan gone: re-arm for the next visit.
function Trade:reset()
    self.is_trading = false
    self.state = STATE.IDLE
    self.marked = false
    self.confirmed = false
end

function Trade:perform()
    if self.state == STATE.IDLE then return false end
    if self.state == STATE.DONE then
        self.is_trading = false
        return true
    end

    self:check_broker()
    self:watch_trade_screen()

    self.attempt = self.attempt + 1
    if self.attempt >= self.max_attempts then
        -- keep the broker info, but stop burning cycles on this visit
        self.state = STATE.DONE
    end
    return false
end

function Trade:check_broker()
    -- v50+: broker position is on the fortress entity
    local ok, id = pcall(function() return compat.position_holder('BROKER') end)
    if ok then self.broker_id = id or -1 end
end

-- The v50+ mapped trade UI: df.global.game.main_interface.trade
function Trade:get_trade_ui()
    local ok, trade = pcall(function()
        return df.global.game and df.global.game.main_interface
            and df.global.game.main_interface.trade
    end)
    if not ok then return nil end
    return trade
end

function Trade:watch_trade_screen()
    local trade = self:get_trade_ui()
    if not trade then return end

    local open = false
    pcall(function() open = trade.open end)

    if not open then
        -- screen closed: allow a fresh marking pass next time it opens
        if self.marked or self.confirmed then
            self.marked = false
            self.confirmed = false
        end
        return
    end

    if self.marked then return end

    local goods = trade.good and trade.good[1]      -- [1] = fort goods
    local flags = trade.goodflag and trade.goodflag[1]
    if not goods or not flags or #goods == 0 or #goods ~= #flags then
        return -- screen open but goods not loaded yet; try again next pass
    end

    local marked, value = self:mark_goods(goods, flags)
    self.marked = true
    if marked > 0 then
        dfhack.println(('[df-ai] trade screen open: marked %d good(s) '
            .. '(~%d value) for the caravan'):format(marked, value))
        if self.ai.config and self.ai.config.trade_confirm and not self.confirmed then
            self.confirmed = true
            self:confirm_trade()
        end
    else
        dfhack.println('[df-ai] trade screen open: nothing to sell — '
            .. 'everything is on the keep-list (make more crafts!)')
    end
end

-- Policy: mark everything except artifacts, bin contents (the bin is
-- selected instead — contents travel with it) and the keep-list.
function Trade:mark_goods(goods, flags)
    if not self._keep then self._keep = build_keep_types() end
    local keep = self._keep

    local marked, value = 0, 0
    for i, item in ipairs(goods) do
        local f = flags[i]
        local selectable = false
        local is_artifact = false
        local itype = nil
        pcall(function()
            selectable = not f.selected and not f.contained
            is_artifact = item.flags and item.flags.artifact or false
            itype = item:getType()
        end)
        if selectable and not is_artifact and itype ~= nil
            and not keep[itype] then
            local ok_m = false
            pcall(function()
                f.selected = true
                ok_m = true
            end)
            if ok_m then
                marked = marked + 1
                pcall(function()
                    value = value + (dfhack.items.getValue and dfhack.items.getValue(item) or 0)
                end)
            end
        end
    end
    return marked, value
end

-- Optional hands-free confirm. SEC_SELECT is the generic v50 "confirm"
-- key (Shift+Enter); on the trade screen it presses the Trade button on
-- builds where the button is keyboard-mapped. Gated behind
-- config.trade_confirm (default OFF) until verified on the user build.
function Trade:confirm_trade()
    local ok = pcall(function()
        local vs = dfhack.gui.getCurViewscreen(true)
        if vs and df.interface_key and df.interface_key.SEC_SELECT then
            dfhack.gui.simulateInput(vs, df.interface_key.SEC_SELECT)
        end
    end)
    if ok then
        dfhack.println('[df-ai] trade auto-confirm: Trade keypress sent')
    end
end

function Trade:status()
    return '  Is trading: ' .. tostring(self.is_trading) ..
        '  State: ' .. tostring(self.state) ..
        '  Broker: ' .. tostring(self.broker_id) ..
        '  Goods marked: ' .. tostring(self.marked)
end

return Trade
