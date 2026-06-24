local Embark = {}
Embark.__index = Embark

function Embark.new(ai)
    local o = {
        ai = ai,
        is_embarking = false,
    }
    setmetatable(o, Embark)
    return o
end

function Embark:start_embark()
    if self.ai.config.random_embark then
        self.is_embarking = true
        dfhack.run_command('embark')
        dfhack.run_command('die')
    end
end

function Embark:status()
    return '  Is embarking: ' .. tostring(self.is_embarking)
end

return Embark
