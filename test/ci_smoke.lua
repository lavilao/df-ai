-- ci_smoke.lua — standalone module-load smoke test for df-ai (Lua rewrite)
--
-- Runs with PLAIN lua5.3 (the exact Lua version DFHack 53.16-r3 embeds).
-- No DF/DFHack installation required. It loads every df-ai module under a
-- mocked DFHack API, which catches load-time runtime errors (nil indexing,
-- missing globals, bad enum references, etc.) in addition to the syntax
-- check (`luac -p`) run by CI.
--
-- Usage: lua5.3 test/ci_smoke.lua   (from the repository root)

local SCRIPTS = 'hack/scripts'

-- ============================================================
-- Mock infrastructure
-- ============================================================

-- Generic auto-vivifying object: any property access returns another
-- generic object; calling it returns nil. Used for df.* enums, dfhack
-- sub-modules, etc. so that top-level references never crash the loader.
local function generic(name)
    local t = {}
    setmetatable(t, {
        __index = function(self, k)
            local v = generic(name .. '.' .. tostring(k))
            rawset(self, k, v)
            return v
        end,
        __newindex = function(self, k, v)
            rawset(self, k, v)
        end,
        __call = function()
            return nil
        end,
        __tostring = function()
            return '<mock:' .. name .. '>'
        end,
    })
    return t
end

-- Load a df-ai script the way DFHack's run_script_with_env(..., module=true)
-- does: set the global moduleMode, execute the file, return its value.
local function load_script(name)
    local path = SCRIPTS .. '/' .. name .. '.lua'
    local chunk, err = loadfile(path)
    if not chunk then
        return false, 'cannot load ' .. path .. ': ' .. tostring(err)
    end
    moduleMode = true
    local ok, result = pcall(chunk)
    moduleMode = nil
    if not ok then
        return false, tostring(result)
    end
    return true, result
end

-- ============================================================
-- Mock DFHack environment
-- ============================================================

local dfhack_mock = {}

dfhack_mock.println = function(...)
    local parts = {}
    for i = 1, select('#', ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    print('[mock] ' .. table.concat(parts, ' '))
end
dfhack_mock.print = dfhack_mock.println
dfhack_mock.printerr = function(...)
    local parts = {}
    for i = 1, select('#', ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    io.stderr:write('[mockerr] ' .. table.concat(parts, ' ') .. '\n')
end
dfhack_mock.run_command = function() end
dfhack_mock.getDFVersion = function() return 'v0.53.16' end
dfhack_mock.getDFHackVersion = function() return '53.16-r3' end

-- onStateChange must be a REAL table: scripts assign into it at load time.
dfhack_mock.onStateChange = {}

-- run_script_with_env: actually load sibling df-ai scripts so inter-module
-- dependencies (e.g. stocks -> compat) resolve to real module tables.
dfhack_mock.run_script_with_env = function(env, name, opts)
    if opts and opts.module then
        local ok, result = load_script(name)
        if not ok then
            error('mock load of ' .. name .. ' failed: ' .. tostring(result))
        end
        return result
    end
    return nil
end
dfhack_mock.reqscript = dfhack_mock.run_script_with_env

-- Auto-vivify everything else (filesystem, units, maps, buildings, gui, ...)
setmetatable(dfhack_mock, {
    __index = function(self, k)
        local v = generic('dfhack.' .. tostring(k))
        rawset(self, k, v)
        return v
    end,
})

-- df global: auto-vivifying enum namespace + df.global
local df_mock = generic('df')

_G.dfhack = dfhack_mock
_G.df = df_mock

-- require() mocks (utils, json, repeat-util are DFHack-provided libraries)
package.loaded['utils'] = generic('utils')
package.loaded['repeat-util'] = generic('repeat-util')
package.loaded['gui'] = generic('gui')
package.loaded['json'] = {
    decode_file = function(path)
        -- no real JSON parsing needed at load time; report "not found"
        return nil, 'mock: ' .. path .. ' not available'
    end,
    encode_file = function() return true end,
    decode = function() return nil end,
    encode = function() return '' end,
}

-- ============================================================
-- Run the smoke test
-- ============================================================

local modules = {
    'df-ai/compat', 'df-ai/config', 'df-ai/uihelp', 'df-ai/camera',
    'df-ai/embark', 'df-ai/rooms', 'df-ai/plan', 'df-ai/population',
    'df-ai/stocks', 'df-ai/trade',
}

local failures = 0

print('=== df-ai module load smoke test (mock DFHack API, lua ' .. _VERSION .. ') ===')

for _, name in ipairs(modules) do
    local ok, result = load_script(name)
    if ok and type(result) == 'table' then
        local n = 0
        for _ in pairs(result) do n = n + 1 end
        print(string.format('OK   %-22s (%d exports)', name, n))
    else
        print(string.format('FAIL %-22s %s', name, tostring(result)))
        failures = failures + 1
    end
end

-- Main script: must return the AI table (module mode guard must work)
do
    local ok, result = load_script('df-ai')
    if ok and type(result) == 'table' and type(result.new) == 'function' then
        print('OK   df-ai (main)         (module guard works, AI.new present)')
    else
        print('FAIL df-ai (main): ' .. tostring(result))
        failures = failures + 1
    end
end

-- Instantiate the full AI object like `enable df-ai` does (config load,
-- module wiring). Mock json returns nil so defaults are used.
do
    local ok, AI = load_script('df-ai')
    if ok then
        local ok_inst, ai = pcall(function()
            local a = AI:new()
            a:init()
            return a
        end)
        if ok_inst and ai and ai.config then
            local loaded = 0
            for _, k in ipairs({ 'population', 'plan', 'stocks', 'camera', 'trade', 'embark' }) do
                if ai[k] then loaded = loaded + 1 end
            end
            print(string.format('OK   AI:new()+init()      (%d/6 modules wired)', loaded))
        else
            print('FAIL AI:new()+init(): ' .. tostring(ai))
            failures = failures + 1
        end
    end
end

print('=== ' .. (failures == 0 and 'ALL MODULES LOAD CLEANLY' or failures .. ' FAILURES') .. ' ===')
os.exit(failures == 0 and 0 or 1)
