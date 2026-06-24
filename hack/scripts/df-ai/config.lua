local config = {}

local function default_config()
    return {
        random_embark = true,
        random_embark_world = '',
        write_console = true,
        write_log = true,
        record_movie = false,
        no_quit = true,
        embark_options = {
            DimensionX = 3,
            DimensionY = 2,
            AquiferLight = 0,
            AquiferHeavy = 0,
            Savagery = 2,
        },
        world_size = 1,
        camera = true,
        fps_meter = true,
        manage_labors = 'autolabor',
        manage_nobles = true,
        cancel_announce = 0,
        allow_pause = true,
    }
end

local json = require('json')

local CONFIG_FILE = 'dfhack-config/df-ai.json'

function config.load()
    local ok, data = pcall(json.decode_file, CONFIG_FILE)
    if not ok or not data then
        return default_config()
    end
    local cfg = default_config()
    for k, v in pairs(data) do
        cfg[k] = v
    end
    return cfg
end

function config.save(cfg)
    json.encode_file(cfg, CONFIG_FILE, { pretty = true })
end

return config
