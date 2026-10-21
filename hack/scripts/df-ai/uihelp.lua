--@module = true
-- df-ai port: UI automation helpers for DF 53.16 (mouse-click driven)
local M = {}

local gui = require('gui')

function M.click(scr, x, y)
    df.global.gps.mouse_x = x
    df.global.gps.mouse_y = y
    df.global.gps.precise_mouse_x = x * df.global.gps.tile_pixel_x
    df.global.gps.precise_mouse_y = y * df.global.gps.tile_pixel_y
    gui.simulateInput(scr, '_MOUSE_L')
end

function M.top_button(scr)
    local sw, sh = dfhack.screen.getWindowSize()
    local y
    if sh < 60 then
        y = 25
    else
        y = (sh // 2) + 3
    end
    M.click(scr, sw // 2, y)
end

function M.screen()
    return dfhack.gui.getCurViewscreen()
end

function M.focus()
    return table.concat(dfhack.gui.getCurFocus(true), '|')
end

function M.describe()
    local scr = M.screen()
    local desc = tostring(scr) .. ' focus=' .. M.focus()
    if df.viewscreen_titlest:is_instance(scr) then
        local items = {}
        for i, v in ipairs(scr.menu_line_id) do
            items[#items+1] = tostring(df.main_choice_type[v])
        end
        desc = desc .. ' menu=[' .. table.concat(items, ',') .. '] mode=' .. scr.mode
        desc = desc .. ' regions=' .. #scr.region_choice .. ' saves=' .. #scr.savegame_header
    elseif df.viewscreen_choose_game_typest:is_instance(scr) then
        desc = desc .. ' (choose game type screen)'
    elseif df.viewscreen_choose_start_sitest:is_instance(scr) then
        desc = desc .. ' page=' .. tostring(scr.page)
    elseif df.viewscreen_setupdwarfgamest:is_instance(scr) then
        desc = desc .. ' (setup dwarf screen)'
    end
    return desc
end

return M
