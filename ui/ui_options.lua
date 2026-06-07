local M = {}

local function button_with_font(imgui, fonts, label)
    local clicked = false
    fonts.WithFont(18, function()
        clicked = imgui.Button(label)
    end)
    return clicked
end

function M.render(params)
    if not params.show_options_window then
        return false
    end

    local imgui = params.imgui
    local fonts = params.fonts
    local chrome = params.chrome
    local ui_text_scale = params.ui_text_scale or 1.0
    local options_window_scale = ui_text_scale * (14 / 18)

    local get_ui_scale = params.get_ui_scale
    local get_auto_ui_scale = params.get_auto_ui_scale
    local is_ui_scale_auto = params.is_ui_scale_auto
    local set_ui_scale = params.set_ui_scale
    local set_ui_scale_auto = params.set_ui_scale_auto
    local step_ui_scale = params.step_ui_scale

    local style_colors, style_vars = chrome.push_theme()
    imgui.PushStyleVar(ImGuiStyleVar_WindowTitleAlign, { 0.5, 0.5 })
    style_vars = style_vars + 1

    local open = { true }
    local began = false
    pcall(function()
        local window_flags = bit.bor(
            ImGuiWindowFlags_AlwaysAutoResize or 0,
            ImGuiWindowFlags_NoCollapse or 0
        )
        began = imgui.Begin('CraftStats Options', open, window_flags)
        if not began then
            return
        end

        fonts.SetScale(options_window_scale)
        fonts.Title('Options')
        imgui.Separator()

        local current_scale = type(get_ui_scale) == 'function' and (tonumber(get_ui_scale()) or ui_text_scale) or ui_text_scale
        local auto_scale = type(get_auto_ui_scale) == 'function' and (tonumber(get_auto_ui_scale()) or current_scale) or current_scale
        local auto_mode = type(is_ui_scale_auto) == 'function' and is_ui_scale_auto() or false

        fonts.Header('UI Scale')
        fonts.Label(string.format('Current: %.2f', current_scale))
        fonts.Label(string.format('Auto target: %.2f', auto_scale))
        fonts.Label(string.format('Mode: %s', auto_mode and 'Auto' or 'Manual'))

        imgui.Spacing()

        if button_with_font(imgui, fonts, 'Scale -') then
            if type(step_ui_scale) == 'function' then
                step_ui_scale(-0.10)
            end
        end
        imgui.SameLine()
        if button_with_font(imgui, fonts, 'Scale +') then
            if type(step_ui_scale) == 'function' then
                step_ui_scale(0.10)
            end
        end
        imgui.SameLine()
        if button_with_font(imgui, fonts, 'Auto') then
            if type(set_ui_scale_auto) == 'function' then
                set_ui_scale_auto()
            end
        end

        imgui.Spacing()
        fonts.WithFont(18, function()
            local presets = { 0.92, 1.18, 1.40, 1.60, 1.80, 2.00 }
            for i = 1, #presets do
                local label = string.format('%.2f##cs_scale_preset_%d', presets[i], i)
                if imgui.Button(label) then
                    if type(set_ui_scale) == 'function' then
                        set_ui_scale(presets[i])
                    end
                end
                if i < #presets then
                    imgui.SameLine()
                end
            end
        end)
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
