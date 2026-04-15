local M = {}

local function get_skill_value_color(fonts, skill_value)
    local value = tonumber(skill_value) or 0
    if value >= 100 then
        return fonts.COLORS.YELLOW
    elseif value >= 60 then
        return fonts.COLORS.BLUE
    end

    return fonts.COLORS.WHITE
end

local function get_recipe_skill_id_and_name(bonus, recipe)
    if type(recipe) ~= 'table' or recipe.skill == nil then
        return nil, nil
    end

    local recipe_skill = tostring(recipe.skill):lower():gsub('[^a-z]', '')
    for id, name in pairs(bonus.skill_names or {}) do
        local lname = tostring(name):lower():gsub('[^a-z]', '')
        if recipe_skill == lname then
            return id, name
        end
    end

    return nil, nil
end

local function get_hq_tier_label(delta)
    if delta >= 51 then
        return 'T3'
    elseif delta >= 31 then
        return 'T2'
    elseif delta >= 11 then
        return 'T1'
    elseif delta >= 0 then
        return 'T0'
    end

    return 'Below T0'
end

local function button_with_font(imgui, fonts, label)
    local clicked = false
    fonts.WithFont(18, function()
        clicked = imgui.Button(label)
    end)
    return clicked
end

function M.render(params)
    if not params.show_window[1] then
        return false
    end

    local imgui = params.imgui
    local fonts = params.fonts
    local chrome = params.chrome
    local stats = params.stats
    local bonus = params.bonus
    local last_craft = params.last_craft
    local on_reset = params.on_reset
    local on_new_session = params.on_new_session
    local ui_text_scale = params.ui_text_scale or 1.0
    local main_window_scale = ui_text_scale * (14 / 18)

    local toggle_prices = false
    local toggle_history = false
    local pushed_style_colors = 0
    local pushed_style_vars = 0

    bonus.update_skill_bonuses()

    pushed_style_colors, pushed_style_vars = chrome.push_theme()
    imgui.PushStyleVar(ImGuiStyleVar_WindowTitleAlign, { 0.5, 0.5 })
    pushed_style_vars = pushed_style_vars + 1

    local began = false
    pcall(function()
        local window_flags = bit.bor(
            ImGuiWindowFlags_AlwaysAutoResize or 0,
            ImGuiWindowFlags_NoCollapse or 0
        )
        began = imgui.Begin('CraftStats', params.show_window, window_flags)
        if not began then
            return
        end

        fonts.SetScale(main_window_scale)
        fonts.Title('Statistics')
        imgui.Separator()
        fonts.Label(string.format('Success: %d (%.1f%%)', stats.success, stats.total > 0 and stats.success / stats.total * 100 or 0))
        imgui.SameLine()
        fonts.Label(string.format('Break:   %d (%.1f%%)', stats.break_, stats.total > 0 and stats.break_ / stats.total * 100 or 0))
        fonts.Label(string.format('HQ:      %d (%.1f%%)', stats.hq, stats.success > 0 and stats.hq / stats.success * 100 or 0))
        fonts.Label(string.format('NQ:      %d (%.1f%%)', stats.nq, stats.success > 0 and stats.nq / stats.success * 100 or 0))
        fonts.Label(string.format('Total:   %d', stats.total))
        imgui.Separator()
        fonts.Header('Skills')

        for _, id in ipairs(bonus.skill_ids) do
            local name = bonus.skill_names[id] or tostring(id)
            local base_val = bonus.skills[id] or 0
            local bonus_val = bonus.skill_bonuses[id] or 0
            local effective_val = base_val + bonus_val
            local value_text = tostring(base_val)
            if bonus_val > 0 then
                value_text = string.format('%d (+%d)', effective_val, bonus_val)
            end

            fonts.WithFont(18, function()
                imgui.TextColored(fonts.COLORS.WHITE, string.format('%s: ', name))
                imgui.SameLine(0, 0)
                imgui.TextColored(get_skill_value_color(fonts, effective_val), value_text)
            end)
        end

        local total_bonus = bonus.get_total_bonus()
        if total_bonus > 0 then
            fonts.Label('Bonus:')
            if bonus.support_bonus_value > 0 and bonus.support_bonus_skill_id > 0 then
                fonts.Label(string.format('Synthesis support: +%d (%s)', bonus.support_bonus_value, bonus.skill_names[bonus.support_bonus_skill_id] or tostring(bonus.support_bonus_skill_id)))
            end
            if bonus.moghancement_bonus_value > 0 and bonus.moghancement_bonus_skill_id > 0 then
                fonts.Label(string.format('Moghancement: +%d (%s)', bonus.moghancement_bonus_value, bonus.skill_names[bonus.moghancement_bonus_skill_id] or tostring(bonus.moghancement_bonus_skill_id)))
            end
            if (bonus.gear_bonus_total or 0) > 0 then
                local gear_parts = {}
                for _, id in ipairs(bonus.skill_ids or {}) do
                    local v = bonus.gear_bonus_by_skill and bonus.gear_bonus_by_skill[id] or 0
                    if v > 0 then
                        gear_parts[#gear_parts + 1] = (bonus.skill_names[id] or tostring(id))
                    end
                end
                local gear_suffix = #gear_parts > 0 and (' (' .. table.concat(gear_parts, ', ') .. ')') or ''
                fonts.Label(string.format('Gear: +%d%s', bonus.gear_bonus_total, gear_suffix))
            end
        end

        imgui.Separator()
        local craft_qty = tonumber(last_craft.quantity) or 0
        local craft_suffix = craft_qty > 1 and (' x' .. craft_qty) or ''
        fonts.Header(string.format('Last Craft: %s%s', tostring(last_craft.name or 'N/A'), craft_suffix))
        if last_craft.recipe and last_craft.recipe.skill then
            fonts.Label(string.format('Recipe Skill: %s', tostring(last_craft.recipe.skill)))

            local recipe_level = tonumber(last_craft.recipe.level)
            local skill_id = get_recipe_skill_id_and_name(bonus, last_craft.recipe)
            if recipe_level and skill_id then
                local effective_skill = (bonus.skills[skill_id] or 0) + (bonus.skill_bonuses[skill_id] or 0)
                local delta = effective_skill - recipe_level
                local tier = get_hq_tier_label(delta)
                fonts.Label(string.format('HQ Tier: %s', tier, effective_skill, recipe_level, delta))
            end
        end
        imgui.Separator()
        if button_with_font(imgui, fonts, 'Reset Stats') then
            on_reset()
        end
        imgui.SameLine()
        if button_with_font(imgui, fonts, 'Prices') then
            toggle_prices = true
        end
        imgui.SameLine()
        if button_with_font(imgui, fonts, 'History') then
            toggle_history = true
        end
        imgui.SameLine()
        if button_with_font(imgui, fonts, 'New Session') then
            if type(on_new_session) == 'function' then
                on_new_session()
            else
                on_reset()
            end
        end
    end)

    if began then
        fonts.ResetScale()
        pcall(imgui.End)
    end

    if pushed_style_vars > 0 then
        pcall(function()
            imgui.PopStyleVar(pushed_style_vars)
        end)
    end
    if pushed_style_colors > 0 then
        pcall(function()
            imgui.PopStyleColor(pushed_style_colors)
        end)
    end

    return toggle_prices, toggle_history
end

return M
