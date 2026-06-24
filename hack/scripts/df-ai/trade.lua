--@module = true

local Trade = {}
Trade.__index = Trade

local STATE = {
    IDLE = 'idle',
    ASSIGN_BROKER = 'assign_broker',
    OPEN_DEPOT = 'open_depot',
    TRADE_LIST = 'trade_list',
    TRADE_DETAIL = 'trade_detail',
    CONFIRM = 'confirm',
    DONE = 'done',
}

function Trade.new(ai)
    local o = {
        ai = ai,
        is_trading = false,
        state = STATE.IDLE,
        attempt = 0,
        max_attempts = 10,
        broker_id = -1,
    }
    setmetatable(o, Trade)
    return o
end

function Trade:setup()
    dfhack.println('[df-ai] Setting up trade...')
    self.is_trading = true
    self.state = STATE.ASSIGN_BROKER
    self.attempt = 0
    return true
end

function Trade:perform()
    dfhack.println('[df-ai] Performing trade...')

    if self.state == STATE.ASSIGN_BROKER then
        self:assign_broker()
    elseif self.state == STATE.OPEN_DEPOT then
        self:open_depot()
    elseif self.state == STATE.TRADE_LIST then
        self:handle_trade_list()
    elseif self.state == STATE.TRADE_DETAIL then
        self:handle_trade_detail()
    elseif self.state == STATE.CONFIRM then
        self:handle_confirm()
    elseif self.state == STATE.DONE then
        self.is_trading = false
        return true
    end

    self.attempt = self.attempt + 1
    if self.attempt >= self.max_attempts then
        self.state = STATE.DONE
    end
    return false
end

function Trade:assign_broker()
    -- Find the broker position
    local assignments = df.global.plotinfo.assignments
    if not assignments then
        self.state = STATE.OPEN_DEPOT
        return
    end

    for _, assign in ipairs(assignments) do
        if assign.position and tostring(assign.position) == 'BROKER' then
            if assign.holder >= 0 then
                self.broker_id = assign.holder
                self.state = STATE.OPEN_DEPOT
                return
            end
        end
    end

    -- No broker assigned; find a dwarf with appraisal skill
    local units = df.global.world.units.all
    if not units then
        self.state = STATE.DONE
        return
    end

    local best = nil
    local best_skill = -1

    for _, unit in ipairs(units) do
        if dfhack.units.isCitizen(unit) and dfhack.units.isAlive(unit) then
            if unit.status.current_soul then
                local soul = unit.status.current_soul
                if soul.skills then
                    for _, skill in ipairs(soul.skills) do
                        if skill.id == df.job_skill.APPRAISAL then
                            local rating = skill.rating
                            if rating > best_skill then
                                best_skill = rating
                                best = unit
                            end
                        end
                    end
                end
            end
        end
    end

    if best then
        self.broker_id = best.id
        -- Use force-assign command
        dfhack.run_command('force-assign ' .. best.id .. ' BROKER')
        self.state = STATE.OPEN_DEPOT
    else
        self.state = STATE.DONE
    end
end

function Trade:open_depot()
    -- Open the trade depot screen by interacting with the depot
    dfhack.run_command('building')
    self.state = STATE.TRADE_LIST
end

function Trade:handle_trade_list()
    local screen = dfhack.gui.getCurViewscreen(false)
    if not screen then
        self.state = STATE.OPEN_DEPOT
        return
    end

    local trade_list = dfhack.gui.getViewscreenByType(df.viewscreen_trade_listst)
    if trade_list then
        -- Navigate to the first caravan
        self:select_caravan(trade_list)
    end

    self.state = STATE.TRADE_DETAIL
end

function Trade:select_caravan(trade_list)
    if trade_list and trade_list.caravans then
        for i, caravan in ipairs(trade_list.caravans) do
            if caravan.flags and caravan.flags.available then
                trade_list.sel_trade = i - 1
                return
            end
        end
    end
end

function Trade:handle_trade_detail()
    local trade_detail = dfhack.gui.getViewscreenByType(df.viewscreen_trade_detailst)
    if not trade_detail then
        self.state = STATE.DONE
        return
    end

    -- Auto-trade: buy all
    if trade_detail.offered_goods then
        for i = 0, #trade_detail.offered_goods - 1 do
            trade_detail.sel_offered = i
            trade_detail:addTrade(true)
        end
    end

    self.state = STATE.CONFIRM
end

function Trade:handle_confirm()
    local screen = dfhack.gui.getCurViewscreen(false)
    if not screen then
        self.state = STATE.DONE
        return
    end

    -- Try to confirm the trade
    pcall(function()
        dfhack.run_command('confirm')
    end)

    self.state = STATE.DONE
end

function Trade:status()
    return '  Is trading: ' .. tostring(self.is_trading) ..
           '  State: ' .. tostring(self.state)
end

return Trade
