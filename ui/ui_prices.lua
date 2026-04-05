local M = {}

local prices_search_buffer = { '' }
local prices_action_status = ''

local function trim_text(value)
    if type(value) ~= 'string' then
        return ''
    end

    return value:match('^%s*(.-)%s*$') or ''
end

-- Guard for ensure_price_buffers: skip the full item iteration when buffers are
-- already initialised.  After any import, replace_item_prices creates brand-new
-- entry objects (no price_buffer field), so checking items[1] reliably detects
-- when a fresh pass is needed.
local function ensure_price_buffers(item_prices)
    if type(item_prices) ~= 'table' or type(item_prices.items) ~= 'table' then
        return
    end

    local items = item_prices.items
    if #items == 0 then
        return
    end

    -- Fast-path: if the first entry already has a buffer every entry does.
    if type(items[1].price_buffer) == 'table' then
        return
    end

    for i, entry in ipairs(items) do
        entry.id = tonumber(entry.id) or i
        entry.name = tostring(entry.name or '')
        entry.price = math.max(0, math.floor(tonumber(entry.price) or 0))
        if type(entry.price_buffer) ~= 'table' then
            entry.price_buffer = { entry.price }
        else
            entry.price_buffer[1] = entry.price
        end
    end
end

local function push_prices_table_theme(imgui)
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

local function button_with_font(imgui, fonts, label)
    local clicked = false
    fonts.WithFont(18, function()
        clicked = imgui.Button(label)
    end)
    return clicked
end

local function render_prices_editor(imgui, fonts, item_prices, on_prices_save, on_prices_import, on_prices_import_hgather)
    fonts.Title('Item Prices')

    fonts.Label('Search:')
    imgui.SameLine()
    imgui.PushItemWidth(260)
    fonts.WithFont(18, function()
        imgui.InputText('##craftstats_prices_search', prices_search_buffer, 128)
    end)
    imgui.PopItemWidth()

    local search_text = trim_text(prices_search_buffer[1])
    local search_lc = search_text:lower()

    imgui.Separator()
    ensure_price_buffers(item_prices)

    local items = (type(item_prices) == 'table' and type(item_prices.items) == 'table') and item_prices.items or {}
    if #items == 0 then
        fonts.Label('No items loaded. Press Import Items.')
        return
    end

    local table_style_colors = push_prices_table_theme(imgui)

    if imgui.BeginTable('craftstats_prices_table', 2, bit.bor(ImGuiTableFlags_RowBg, ImGuiTableFlags_Borders, ImGuiTableFlags_BordersInnerV, ImGuiTableFlags_ScrollY, ImGuiTableFlags_SizingStretchProp), { 0, 320 }) then
        imgui.TableSetupColumn('Item')
        imgui.TableSetupColumn('Price', ImGuiTableColumnFlags_WidthFixed, 120)
        imgui.TableHeadersRow()

        local visible_count = 0
        for i, entry in ipairs(items) do
            local item_name = tostring(entry.name or '')
            local include = (search_lc == '') or (item_name:lower():find(search_lc, 1, true) ~= nil)
            if include then
                visible_count = visible_count + 1
                imgui.TableNextRow()

                imgui.TableSetColumnIndex(0)
                fonts.Label(item_name)

                imgui.TableSetColumnIndex(1)
                imgui.PushItemWidth(-1)
                fonts.WithFont(18, function()
                    if imgui.InputInt('##price_' .. tostring(entry.id or i), entry.price_buffer, 0, 0) then
                        entry.price = math.max(0, math.floor(tonumber(entry.price_buffer[1]) or 0))
                        entry.price_buffer[1] = entry.price
                    end
                end)
                imgui.PopItemWidth()
            end
        end

        if visible_count == 0 then
            imgui.TableNextRow()
            imgui.TableSetColumnIndex(0)
            fonts.Label('No matching items.')
            imgui.TableSetColumnIndex(1)
            fonts.Label('-')
        end

        imgui.EndTable()
    end

    if table_style_colors > 0 then
        imgui.PopStyleColor(table_style_colors)
    end

    if button_with_font(imgui, fonts, 'Import Items') then
        if type(on_prices_import) == 'function' then
            local imported_count = tonumber(on_prices_import()) or 0
            prices_action_status = string.format('Imported %d items from recipes.', imported_count)
        end
        ensure_price_buffers(item_prices)
    end

    imgui.SameLine()
    if button_with_font(imgui, fonts, 'Import prices from HGather') then
        if type(on_prices_import_hgather) == 'function' then
            local matched, updated, ok = on_prices_import_hgather()
            if ok == false then
                prices_action_status = "Error: Hgather couldn't be found!"
            else
                matched = tonumber(matched) or 0
                updated = tonumber(updated) or 0
                prices_action_status = string.format('Imported HGather prices: %d matched, %d updated.', matched, updated)
            end
        end
        ensure_price_buffers(item_prices)
    end

    imgui.SameLine()
    if button_with_font(imgui, fonts, 'Save Prices') then
        if type(on_prices_save) == 'function' then
            on_prices_save()
            prices_action_status = 'Prices saved.'
        end
    end

    if prices_action_status ~= '' then
        fonts.Label(prices_action_status)
    end
end

function M.render(params)
    if not params.show_prices_editor then
        return false
    end

    local imgui = params.imgui
    local fonts = params.fonts
    local chrome = params.chrome
    local item_prices = params.item_prices
    local on_prices_save = params.on_prices_save
    local on_prices_import = params.on_prices_import
    local on_prices_import_hgather = params.on_prices_import_hgather
    local ui_text_scale = params.ui_text_scale or 1.0
    local prices_window_scale = ui_text_scale * (14 / 18)

    local prices_style_colors, prices_style_vars = chrome.push_theme()
    imgui.PushStyleVar(ImGuiStyleVar_WindowTitleAlign, { 0.5, 0.5 })
    prices_style_vars = prices_style_vars + 1

    local prices_open = { true }
    local prices_began = false
    pcall(function()
        local window_flags = bit.bor(
            ImGuiWindowFlags_AlwaysAutoResize or 0,
            ImGuiWindowFlags_NoCollapse or 0
        )
        prices_began = imgui.Begin('CraftStats Prices', prices_open, window_flags)
        if not prices_began then
            return
        end

        fonts.SetScale(prices_window_scale)
        render_prices_editor(imgui, fonts, item_prices, on_prices_save, on_prices_import, on_prices_import_hgather)
    end)

    if prices_began then
        fonts.ResetScale()
        pcall(imgui.End)
    end

    if prices_style_vars > 0 then
        pcall(function()
            imgui.PopStyleVar(prices_style_vars)
        end)
    end
    if prices_style_colors > 0 then
        pcall(function()
            imgui.PopStyleColor(prices_style_colors)
        end)
    end

    return prices_open[1] == true
end

return M
