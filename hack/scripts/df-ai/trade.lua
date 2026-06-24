local Trade = {}
Trade.__index = Trade

function Trade.new(ai)
    local o = {
        ai = ai,
        is_trading = false,
    }
    setmetatable(o, Trade)
    return o
end

function Trade:setup()
    -- Placeholder: navigate to trade depot and set up trading
    dfhack.println('[df-ai] Setting up trade...')
    self.is_trading = true
    return true
end

function Trade:perform()
    -- Placeholder: execute a trade
    dfhack.println('[df-ai] Performing trade...')
    self.is_trading = false
    return true
end

function Trade:status()
    return '  Is trading: ' .. tostring(self.is_trading)
end

return Trade
