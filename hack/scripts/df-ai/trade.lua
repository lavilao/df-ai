--@module = true
-- trade.lua — trading support for DF 53.16
--
-- v50 rewrote the trade UI into new data-driven screens that are not mapped
-- in df-structures, so direct viewscreen automation (the old
-- viewscreen_trade_listst / viewscreen_trade_detailst approach) is no longer
-- possible. What we CAN do reliably:
--   * track the broker (position or appraisal skill)
--   * verify a trade depot exists and is accessible
--   * keep trade goods flowing (the plan module stocks a trade stockpile)
-- Actual offer/accept automation is deferred until DFHack maps the new trade
-- screens (or exposes a trade API).

local Trade = {}
Trade.__index = Trade

local compat = dfhack.run_script_with_env(nil, 'df-ai/compat', {module = true})

local STATE = {
    IDLE = 'idle',
    CHECK_BROKER = 'check_broker',
    CHECK_DEPOT = 'check_depot',
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
        last_reported_year = -1,
    }
    setmetatable(o, Trade)
    return o
end

function Trade:setup()
    dfhack.println('[df-ai] Trade check starting...')
    self.is_trading = true
    self.state = STATE.CHECK_BROKER
    self.attempt = 0
    return true
end

function Trade:perform()
    if self.state == STATE.CHECK_BROKER then
        self:check_broker()
    elseif self.state == STATE.CHECK_DEPOT then
        self:check_depot()
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

function Trade:check_broker()
    -- v50+: broker position is on the fortress entity
    self.broker_id = compat.position_holder('BROKER')

    if self.broker_id < 0 then
        -- No broker appointed: remember the best appraiser for later
        local best, best_skill = nil, -1
        local units = df.global.world.units.all
        if units then
            for _, unit in ipairs(units) do
                if dfhack.units.isCitizen(unit) and dfhack.units.isAlive(unit)
                    and unit.status.current_soul then
                    for _, skill in ipairs(unit.status.current_soul.skills or {}) do
                        if skill.id == df.job_skill.APPRAISAL and skill.rating > best_skill then
                            best_skill = skill.rating
                            best = unit
                        end
                    end
                end
            end
        end
        if best then
            self.preferred_broker_id = best.id
        end
    end

    self.state = STATE.CHECK_DEPOT
end

function Trade:check_depot()
    -- Verify a trade depot exists
    local depot = nil
    for _, bld in ipairs(df.global.world.buildings.all) do
        if bld:getType() == df.building_type.TradeDepot then
            depot = bld
            break
        end
    end

    local year = df.global.cur_year
    if depot and year ~= self.last_reported_year then
        self.last_reported_year = year
        local broker = self.broker_id >= 0 and df.unit.find(self.broker_id)
        dfhack.println('[df-ai] trade depot ready'
            .. (broker and ('; broker: ' .. dfhack.units.getVisibleName(broker)) or '; no broker appointed'))
        -- NOTE: actual caravan trading UI automation is not possible on v50+
        -- screens yet; goods are kept flowing via the trade stockpile.
    end

    self.state = STATE.DONE
end

function Trade:status()
    return '  Is trading: ' .. tostring(self.is_trading) ..
        '  State: ' .. tostring(self.state) ..
        '  Broker: ' .. tostring(self.broker_id)
end

return Trade
