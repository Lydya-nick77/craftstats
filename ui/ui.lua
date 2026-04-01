local M = {}

local show_prices_editor = false
local show_history_editor = false

local function load_local_module(name)
    if addon and addon.path and type(addon.path) == 'string' and #addon.path > 0 then
        local path = string.format('%s\\%s.lua', addon.path, name)
        local ok, mod = pcall(dofile, path)
        if ok and type(mod) == 'table' then
            return mod
        end
    end

    return require(name)
end

local main_ui = load_local_module('ui\\ui_main')
local prices_ui = load_local_module('ui\\ui_prices')
local history_ui = load_local_module('ui\\ui_history')

function M.render(params)
    if not params.show_window[1] then
        return
    end

    local toggled_prices, toggled_history = main_ui.render(params)
    if toggled_prices then
        show_prices_editor = not show_prices_editor
    end
    if toggled_history then
        show_history_editor = not show_history_editor
    end

    show_prices_editor = prices_ui.render({
        show_prices_editor = show_prices_editor,
        imgui = params.imgui,
        fonts = params.fonts,
        chrome = params.chrome,
        item_prices = params.item_prices,
        on_prices_save = params.on_prices_save,
        on_prices_import = params.on_prices_import,
        on_prices_import_hgather = params.on_prices_import_hgather,
        ui_text_scale = params.ui_text_scale,
    })

    show_history_editor = history_ui.render({
        show_history_editor = show_history_editor,
        imgui = params.imgui,
        fonts = params.fonts,
        chrome = params.chrome,
        craft_history = params.craft_history,
        on_history_clear = params.on_history_clear,
        ui_text_scale = params.ui_text_scale,
    })
end

return M