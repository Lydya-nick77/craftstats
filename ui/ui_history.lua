local M = {}
local history_action_status = ''
local PROFIT_FONT_SIZE = 24

local function get_history_entries(craft_history)
    if type(craft_history) == 'table' and type(craft_history.entries) == 'table' then
        return craft_history.entries
    end

    return {}
end

local function calculate_history_profit(entries)
    local total_cost = 0
    local total_made = 0

    if type(entries) ~= 'table' then
        return 0
    end

    for _, entry in ipairs(entries) do
        total_cost = total_cost + (tonumber(entry.craft_cost) or 0)
        total_made = total_made + (tonumber(entry.made_item_price) or 0)
    end

    return total_made - total_cost
end

local function get_profit_color(fonts, profit)
    if profit >= 0 then
        return fonts.COLORS.GREEN
    end

    return fonts.COLORS.RED
end

local function push_history_table_theme(imgui)
    local count = 0

    local function push_color_if_available(color_id, value)
        if color_id ~= nil then
            imgui.PushStyleColor(color_id, value)
            count = count + 1
        end
    end

    push_color_if_available(ImGuiCol_TableHeaderBg, {0.137, 0.125, 0.106, 1.0})
    push_color_if_available(ImGuiCol_TableBorderStrong, {0.765, 0.684, 0.474, 0.85})
    push_color_if_available(ImGuiCol_TableBorderLight, {0.300, 0.275, 0.235, 1.0})
    push_color_if_available(ImGuiCol_TableRowBg, {0.020, 0.020, 0.020, 0.60})
    push_color_if_available(ImGuiCol_TableRowBgAlt, {0.098, 0.090, 0.075, 0.65})

    return count
end

local function measure_profit_summary_width(imgui, fonts, profit)
    local profit_prefix = 'Profit: '
    local profit_value = tostring(profit)
    local total_width = nil

    pcall(function()
        fonts.WithFont(PROFIT_FONT_SIZE, function()
            local prefix_size = imgui.CalcTextSize(profit_prefix)
            local value_size = imgui.CalcTextSize(profit_value)
            local prefix_width = prefix_size.x or prefix_size[1] or 0
            local value_width = value_size.x or value_size[1] or 0
            total_width = prefix_width + value_width
        end)
    end)

    return total_width or 0
end

local function render_profit_summary(imgui, fonts, profit)
    local profit_prefix = 'Profit: '
    local profit_value = tostring(profit)

    fonts.WithFont(PROFIT_FONT_SIZE, function()
        imgui.TextColored(fonts.COLORS.WHITE, profit_prefix)
        imgui.SameLine(0, 0)
        imgui.TextColored(get_profit_color(fonts, profit), profit_value)
    end)
end

local function render_history_editor(imgui, fonts, craft_history, on_history_clear)
    fonts.Title('History')

    local entries = get_history_entries(craft_history)
    local profit = calculate_history_profit(entries)
    local profit_width = measure_profit_summary_width(imgui, fonts, profit)
    local table_style_colors = push_history_table_theme(imgui)

    if imgui.BeginTable('craftstats_history_header', 2, ImGuiTableFlags_SizingStretchProp) then
        imgui.TableSetupColumn('Actions', ImGuiTableColumnFlags_WidthStretch)
        imgui.TableSetupColumn('Profit', ImGuiTableColumnFlags_WidthFixed, profit_width)
        imgui.TableNextRow()

        imgui.TableSetColumnIndex(0)
        if imgui.Button('Clear History') then
            if type(on_history_clear) == 'function' then
                local cleared = tonumber(on_history_clear()) or 0
                history_action_status = string.format('History cleared (%d entries).', cleared)
                entries = get_history_entries(craft_history)
                profit = calculate_history_profit(entries)
                profit_width = measure_profit_summary_width(imgui, fonts, profit)
            end
        end

        imgui.TableSetColumnIndex(1)
        render_profit_summary(imgui, fonts, profit)

        imgui.EndTable()
    end

    if history_action_status ~= '' then
        fonts.Label(history_action_status)
    end

    imgui.Separator()

    if #entries == 0 then
        fonts.Label('No craft history yet.')
        return
    end

    local flags = bit.bor(
        ImGuiTableFlags_RowBg,
        ImGuiTableFlags_Borders,
        ImGuiTableFlags_BordersInnerV,
        ImGuiTableFlags_ScrollX,
        ImGuiTableFlags_ScrollY,
        ImGuiTableFlags_SizingStretchProp
    )

    if imgui.BeginTable('craftstats_history_table', 8, flags, { 0, 360 }) then
        imgui.TableSetupColumn('Time', ImGuiTableColumnFlags_WidthFixed, 150)
        imgui.TableSetupColumn('Recipe')
        imgui.TableSetupColumn('Lvl', ImGuiTableColumnFlags_WidthFixed, 55)
        imgui.TableSetupColumn('Skill', ImGuiTableColumnFlags_WidthFixed, 65)
        imgui.TableSetupColumn('Result', ImGuiTableColumnFlags_WidthFixed, 65)
        imgui.TableSetupColumn('Cost', ImGuiTableColumnFlags_WidthFixed, 80)
        imgui.TableSetupColumn('Made', ImGuiTableColumnFlags_WidthFixed, 80)
        imgui.TableSetupColumn('Lost Items')
        imgui.TableHeadersRow()

        for i = #entries, 1, -1 do
            local entry = entries[i]
            imgui.TableNextRow()

            imgui.TableSetColumnIndex(0)
            fonts.Label(tostring(entry.time or ''))

            imgui.TableSetColumnIndex(1)
            fonts.Label(tostring(entry.recipe_name or 'Unknown'))

            imgui.TableSetColumnIndex(2)
            fonts.Label(tostring(entry.recipe_level or 0))

            imgui.TableSetColumnIndex(3)
            fonts.Label(string.format('%.1f', tonumber(entry.player_skill) or 0))

            imgui.TableSetColumnIndex(4)
            fonts.Label(tostring(entry.result or ''))

            imgui.TableSetColumnIndex(5)
            fonts.Label(tostring(entry.craft_cost or 0))

            imgui.TableSetColumnIndex(6)
            fonts.Label(tostring(entry.made_item_price or 0))

            imgui.TableSetColumnIndex(7)
            fonts.Label(tostring(entry.lost_items or ''))
        end

        imgui.EndTable()
    end

    if table_style_colors > 0 then
        imgui.PopStyleColor(table_style_colors)
    end
end

function M.render(params)
    if not params.show_history_editor then
        return false
    end

    local imgui = params.imgui
    local fonts = params.fonts
    local chrome = params.chrome
    local craft_history = params.craft_history
    local on_history_clear = params.on_history_clear
    local ui_text_scale = params.ui_text_scale or 1.0

    local style_colors, style_vars = chrome.push_theme()
    imgui.PushStyleVar(ImGuiStyleVar_WindowTitleAlign, { 0.5, 0.5 })
    style_vars = style_vars + 1

    local open = { true }
    local began = false
    pcall(function()
        began = imgui.Begin('CraftStats History', open, imgui.WindowFlags_AlwaysAutoResize)
        if not began then
            return
        end

        fonts.SetScale(ui_text_scale)
        render_history_editor(imgui, fonts, craft_history, on_history_clear)
    end)

    if began then
        fonts.ResetScale()
        pcall(imgui.End)
    end

    if style_vars > 0 then
        pcall(function()
            imgui.PopStyleVar(style_vars)
        end)
    end
    if style_colors > 0 then
        pcall(function()
            imgui.PopStyleColor(style_colors)
        end)
    end

    return open[1] == true
end

return M
