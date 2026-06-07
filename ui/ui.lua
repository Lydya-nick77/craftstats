local M = {}

local show_prices_editor  = false
local show_history_editor = false
local show_recipes_editor = false
local show_options_window = false

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

local main_ui    = load_local_module('ui\\ui_main')
local prices_ui  = load_local_module('ui\\ui_prices')
local history_ui = load_local_module('ui\\ui_history')
local recipes_ui = load_local_module('ui\\ui_recipes')
local options_ui = load_local_module('ui\\ui_options')

local prices_params  = nil
local history_params = nil
local recipes_params = nil
local options_params = nil

function M.render(params)
    if not params.show_window[1] then
        return
    end

    local toggled_prices, toggled_history, toggled_recipes, toggled_options = main_ui.render(params)
    if toggled_prices then
        show_prices_editor = not show_prices_editor
    end
    if toggled_history then
        show_history_editor = not show_history_editor
    end
    if toggled_recipes then
        show_recipes_editor = not show_recipes_editor
    end
    if toggled_options then
        show_options_window = not show_options_window
    end

    -- Lazily initialise persistent sub-param tables so we only assign the
    -- show_* boolean each frame rather than allocating a new table every frame.
    if prices_params == nil then
        prices_params = {
            show_prices_editor = false,
            imgui = params.imgui,
            fonts = params.fonts,
            chrome = params.chrome,
            item_prices = params.item_prices,
            on_prices_save = params.on_prices_save,
            on_prices_import = params.on_prices_import,
            on_prices_import_hgather = params.on_prices_import_hgather,
            ui_text_scale = params.ui_text_scale,
        }
    end
    prices_params.show_prices_editor = show_prices_editor
    prices_params.ui_text_scale = params.ui_text_scale
    show_prices_editor = prices_ui.render(prices_params)

    if history_params == nil then
        history_params = {
            show_history_editor = false,
            imgui = params.imgui,
            fonts = params.fonts,
            chrome = params.chrome,
            craft_history = params.craft_history,
            on_history_clear = params.on_history_clear,
            ui_text_scale = params.ui_text_scale,
        }
    end
    history_params.show_history_editor = show_history_editor
    history_params.ui_text_scale = params.ui_text_scale
    show_history_editor = history_ui.render(history_params)

    if recipes_params == nil then
        recipes_params = {
            show_recipes_window = false,
            imgui               = params.imgui,
            fonts               = params.fonts,
            chrome              = params.chrome,
            recipes             = params.recipes,
            ui_text_scale       = params.ui_text_scale,
        }
    end
    recipes_params.show_recipes_window = show_recipes_editor
    recipes_params.recipes             = params.recipes
    recipes_params.ui_text_scale       = params.ui_text_scale
    show_recipes_editor = recipes_ui.render(recipes_params)

    if options_params == nil then
        options_params = {
            show_options_window = false,
            imgui = params.imgui,
            fonts = params.fonts,
            chrome = params.chrome,
            get_ui_scale = params.get_ui_scale,
            get_auto_ui_scale = params.get_auto_ui_scale,
            is_ui_scale_auto = params.is_ui_scale_auto,
            set_ui_scale = params.set_ui_scale,
            set_ui_scale_auto = params.set_ui_scale_auto,
            step_ui_scale = params.step_ui_scale,
            ui_text_scale = params.ui_text_scale,
        }
    end
    options_params.show_options_window = show_options_window
    options_params.ui_text_scale = params.ui_text_scale
    show_options_window = options_ui.render(options_params)
end

return M