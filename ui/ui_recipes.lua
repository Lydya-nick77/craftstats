local M = {}

local ffi  = require('ffi')
local d3d8 = require('d3d8')
local C    = ffi.C

-- D3D8 device (used for texture creation)
local d3d8dev = d3d8.get_device()

-- Item icon texture cache (item_id -> D3D texture object or false on failure)
local icon_cache = {}

local function load_item_icon(item_id)
    if not item_id then return nil end
    local cached = icon_cache[item_id]
    if cached ~= nil then return cached or nil end

    local ok, item = pcall(function() return AshitaCore:GetResourceManager():GetItemById(item_id) end)
    if not ok or not item or not item.Bitmap or item.ImageSize == 0 then
        icon_cache[item_id] = false
        return nil
    end

    local texture_ptr = ffi.new('IDirect3DTexture8*[1]')
    if C.D3DXCreateTextureFromFileInMemoryEx(d3d8dev, item.Bitmap, item.ImageSize,
        0xFFFFFFFF, 0xFFFFFFFF, 1, 0, C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED,
        C.D3DX_DEFAULT, C.D3DX_DEFAULT, 0xFF000000, nil, nil, texture_ptr) ~= C.S_OK then
        icon_cache[item_id] = false
        return nil
    end

    local tex = d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', texture_ptr[0]))
    icon_cache[item_id] = tex
    return tex
end

local function tex_ptr(tex)
    return tonumber(ffi.cast('uint32_t', tex))
end

ashita.events.register('unload', 'cs_recipes_icon_unload', function()
    icon_cache      = {}
    item_id_cache   = {}
    display_item_id_cache = {}
    item_scan_cache = nil
    scan_cache_progress = 0
    scan_cache_complete = false
    inventory_count_cache = {}
    inventory_cache_dirty = true
    last_inventory_refresh = 0
end)

-- Inventory count cache (item_id -> count)
local inventory_count_cache = {}
local inventory_cache_dirty = true
local inventory_refresh_interval = 0.75
local last_inventory_refresh = 0

local function update_inventory_cache()
    local now = os.clock()
    if not inventory_cache_dirty and (now - last_inventory_refresh) < inventory_refresh_interval then
        return true
    end
    inventory_count_cache = {}
    local ok, inv_mgr = pcall(function() return AshitaCore:GetMemoryManager():GetInventory() end)
    if not ok or not inv_mgr then 
        return false 
    end

    -- Only scan main inventory (bag 0). Bag 1=safe, 4=satchel, 5=sack, 7=mog house, etc.
    for slot = 0, 80 do
        local ok3, item = pcall(function() return inv_mgr:GetContainerItem(0, slot) end)
        if ok3 and item then
            local item_id_val = item.Id and tonumber(item.Id) or 0
            local qty_val = (item.Count and tonumber(item.Count)) or 1
            if item_id_val > 0 and qty_val > 0 then
                inventory_count_cache[item_id_val] = (inventory_count_cache[item_id_val] or 0) + qty_val
            end
        end
    end
    inventory_cache_dirty = false
    last_inventory_refresh = now
    return true
end

local function get_item_inventory_count(item_id)
    if not item_id then return 0 end
    local count = inventory_count_cache[item_id] or 0
    return count
end

-- Mark cache dirty on various events that indicate inventory change
ashita.events.register('packet_in', 'cs_recipes_inv_packet', function(e)
    -- Mark dirty on inventory-related packets (0x1F = item, 0x20 = equip, etc.)
    if e.id == 0x1F or e.id == 0x20 or e.id == 0xA1 or e.id == 0xA2 then
        inventory_cache_dirty = true
    end
end)

-- Resolve item id by name using the resource manager (with simple cache)
-- Name→id map built once by scanning all items (more reliable than GetItemByName).
-- item.Name is a C array in Ashita's FFI struct; we use indexed probes to extract the string.
local item_scan_cache = nil
local scan_cache_progress = 0
local scan_cache_complete = false

local function canonicalize_lookup_name(s)
    if type(s) ~= 'string' then return '' end
    -- Minimal normalization: lowercase, strip punctuation, collapse whitespace
    s = s:gsub('\226\128\153', "'")
    s = s:lower()
    s = s:gsub('[%p]', ' ')
    s = s:gsub('%s+', ' '):match('^%s*(.-)%s*$') or ''
    return s
end

local function normalize_for_lookup(s)
    return canonicalize_lookup_name(s)
end

local function index_item_name(cache, name, id)
    local key = normalize_for_lookup(name)
    if key ~= '' and not cache[key] then
        cache[key] = id
    end
end

local function collect_item_names(item)
    -- Return all name strings found across all language indices (0-4)
    -- from display names, log names, and any abbreviation fields.
    local result = {}
    local seen = {}

    local function push(n)
        if type(n) ~= 'string' or n == '' then return end
        if seen[n] then return end
        seen[n] = true
        result[#result + 1] = n
    end

    local function probe_field(field)
        if field == nil then return end
        for idx = 0, 4 do
            local ok_i, n_i = pcall(function() return field[idx] end)
            if ok_i then push(n_i) end
        end
        local ok_g, n_g = pcall(function() return field.get and field:get() or nil end)
        if ok_g and n_g then push(n_g) end
        local ok_t, n_t = pcall(function() return tostring(field) end)
        if ok_t and type(n_t) == 'string' and n_t ~= '' and not n_t:find('userdata', 1, true) then
            push(n_t)
        end
    end

    for idx = 0, 4 do
        local ok, n = pcall(function() return item.Name[idx] end)
        if ok then push(n) end

        local ok_s, n_s = pcall(function() return item.LogNameSingular[idx] end)
        if ok_s then push(n_s) end

        local ok_p, n_p = pcall(function() return item.LogNamePlural[idx] end)
        if ok_p then push(n_p) end
    end

    probe_field(item.Name)
    probe_field(item.LogNameSingular)
    probe_field(item.LogNamePlural)
    -- Add any known abbreviations (if present)
    if item.Abbreviation then probe_field(item.Abbreviation) end

    return result
end

local function ensure_item_scan_cache()
    if scan_cache_complete then return end
    if not item_scan_cache then
        item_scan_cache = {}
        scan_cache_progress = 1
    end
    
    local ok, resources = pcall(function() return AshitaCore:GetResourceManager() end)
    if not ok or not resources then scan_cache_complete = true; return end
    
    local chunk_size = 1500
    local start_id = scan_cache_progress
    local end_id = math.min(start_id + chunk_size - 1, 65535)
    
    for id = start_id, end_id do
        local ok2, item = pcall(function() return resources:GetItemById(id) end)
        if ok2 and item and item.Id and tonumber(item.Id) == id then
            for _, name in ipairs(collect_item_names(item)) do
                index_item_name(item_scan_cache, name, id)
                local alt = name:gsub('[Ll]ightng%.%s*', 'Lightning '):gsub('%s+', ' '):match('^(.-)%s*$')
                if alt and alt ~= name then
                    index_item_name(item_scan_cache, alt, id)
                end
            end
        end
    end
    
    scan_cache_progress = end_id + 1
    if end_id >= 65535 then
        scan_cache_complete = true
    end
end

local item_id_cache = {}
local display_item_id_cache = {}
local function get_item_id_by_name(name)
    if type(name) ~= 'string' or name == '' then return nil end
    local cached = item_id_cache[name]
    if cached ~= nil then return cached or nil end

    ensure_item_scan_cache()

    local key = normalize_for_lookup(name)
    local id = item_scan_cache and item_scan_cache[key] or nil
    
    -- If exact match fails, try substring/contains match through all indexed names
    if not id and item_scan_cache then
        for indexed_key, item_id in pairs(item_scan_cache) do
            if indexed_key:find(key, 1, true) or key:find(indexed_key, 1, true) then
                id = item_id
                break
            end
        end
    end
    
    if not id then
        -- Fallback: try resource manager by name (all languages)
        local ok, resources = pcall(function() return AshitaCore:GetResourceManager() end)
        if ok and resources then
            for _, lang in ipairs({ 2, 0, 1, 3, 4 }) do
                local ok2, item = pcall(function() return resources:GetItemByName(name, lang) end)
                if ok2 and item and item.Id and item.Id > 0 then
                    id = tonumber(item.Id)
                    if id then
                        for _, n in ipairs(collect_item_names(item)) do
                            index_item_name(item_scan_cache, n, id)
                        end
                        break
                    end
                end
            end
        end
    end

    -- Only cache a miss once the full scan is done; otherwise a premature lookup
    -- would permanently record nil and never retry after the scan catches up.
    if id then
        item_id_cache[name] = id
    elseif scan_cache_complete then
        item_id_cache[name] = false
    end
    return id
end

local function get_item_id_for_display_name(display)
    if type(display) ~= 'string' or display == '' then return nil end

    local cached = display_item_id_cache[display]
    if cached ~= nil then return cached or nil end

    local base = display:match('^(.-)%s+[xX]%d+%s*$') or display
    local id = get_item_id_by_name(base)

    if id then
        display_item_id_cache[display] = id
    elseif scan_cache_complete then
        display_item_id_cache[display] = false
    end

    return id
end

local CRAFT_SKILLS = {
    { name = 'Alchemy',      },
    { name = 'Bonecraft',    },
    { name = 'Clothcraft',   },
    { name = 'Cooking',      },
    { name = 'Goldsmithing', filter_name = 'Goldsmith' },
    { name = 'Leathercraft', },
    { name = 'Smithing',     },
    { name = 'Woodworking',  },
}

local RANKS = {
    { name = 'Amateur',    min = 1,  max = 10  },
    { name = 'Recruit',    min = 11, max = 20  },
    { name = 'Initiate',   min = 21, max = 30  },
    { name = 'Novice',     min = 31, max = 40  },
    { name = 'Apprentice', min = 41, max = 50  },
    { name = 'Journeyman', min = 51, max = 60  },
    { name = 'Craftsman',  min = 61, max = 70  },
    { name = 'Artisan',    min = 71, max = 80  },
    { name = 'Adept',      min = 81, max = 90  },
    { name = 'Veteran',    min = 91, max = 100 },
}

local selected_skill_index  = 1
local selected_rank_index   = 1
local selected_recipe_index = 1
local search_buffer         = { '' }

-- Recipe filter cache: invalidated whenever the size of recipes.by_name changes
-- (recipes are loaded lazily across frames).
local recipe_cache      = {}
local recipe_cache_size = -1

local function count_recipes(recipes)
    local n = 0
    for _ in pairs(recipes.by_name or {}) do n = n + 1 end
    return n
end

local function subcraft_matches(recipe, skill_lower, min_lv, max_lv)
    if type(recipe.subcraft) ~= 'table' then return false end
    for _, entry in ipairs(recipe.subcraft) do
        local es, el = tostring(entry or ''):match('^%s*(.-)%s*%((%d+)%)%s*$')
        if es and es:lower() == skill_lower then
            local lv = tonumber(el) or 0
            if lv >= min_lv and lv <= max_lv then
                return true
            end
        end
    end
    return false
end

local function effective_level(recipe, skill_lower)
    if tostring(recipe.skill or ''):lower() == skill_lower then
        return tonumber(recipe.level) or 0
    end
    if type(recipe.subcraft) == 'table' then
        for _, entry in ipairs(recipe.subcraft) do
            local es, el = tostring(entry or ''):match('^%s*(.-)%s*%((%d+)%)%s*$')
            if es and es:lower() == skill_lower then
                return tonumber(el) or 0
            end
        end
    end
    return tonumber(recipe.level) or 0
end

local function recipe_matches_search(recipe, query)
    if query == '' then return true end
    local name = tostring(recipe.name or ''):lower()
    if name:find(query, 1, true) then return true end
    for _, field in ipairs({ recipe.hq1, recipe.hq2, recipe.hq3 }) do
        if type(field) == 'string' and field:lower():find(query, 1, true) then
            return true
        end
    end
    return false
end

local function get_filtered_recipes(recipes, skill_name, rank)
    local cache_key    = skill_name .. ':' .. rank.min .. '-' .. rank.max
    local current_size = count_recipes(recipes)
    if recipe_cache_size ~= current_size then
        recipe_cache      = {}
        recipe_cache_size = current_size
    end
    if recipe_cache[cache_key] then
        return recipe_cache[cache_key]
    end

    local skill_lower = skill_name:lower()
    local min_lv, max_lv = rank.min, rank.max
    local filtered, seen = {}, {}

    for _, recipe in pairs(recipes.by_name or {}) do
        if type(recipe) == 'table' and not seen[recipe] then
            local rs = tostring(recipe.skill or ''):lower()
            local lv = tonumber(recipe.level) or 0
            if (rs == skill_lower and lv >= min_lv and lv <= max_lv) or
               subcraft_matches(recipe, skill_lower, min_lv, max_lv) then
                filtered[#filtered + 1] = recipe
                seen[recipe]            = true
            end
        end
    end

    table.sort(filtered, function(a, b)
        local al = effective_level(a, skill_lower)
        local bl = effective_level(b, skill_lower)
        if al ~= bl then return al < bl end
        return tostring(a.name or '') < tostring(b.name or '')
    end)

    recipe_cache[cache_key] = filtered
    return filtered
end

local function render_recipe_name_list(imgui, fonts, filtered, skill_lower)
    if #filtered == 0 then
        fonts.Label('No recipes found for this craft and rank.')
        return
    end

    fonts.WithFont(18, function()
        for i, recipe in ipairs(filtered) do
            local disp_level = effective_level(recipe, skill_lower)
            local name       = tostring(recipe.name or 'Unknown')
            local label      = string.format('(%d) %s##cs_rname_%d', disp_level, name, i)
            if imgui.Selectable(label, selected_recipe_index == i) then
                selected_recipe_index = i
            end
        end
    end)
end

local function render_recipe_detail(imgui, fonts, recipe, skill_lower)
    if recipe == nil then
        fonts.Label('Select a recipe on the left.')
        return
    end

    local recipe_name = tostring(recipe.name or 'Unknown')
    local main_skill  = tostring(recipe.skill or '')
    local main_level  = tonumber(recipe.level) or 0
    local crystal     = tostring(recipe.crystal or 'Unknown Crystal')

    -- Recipe name with icon (strip quantity suffix for icon lookup)
    local item_id  = get_item_id_for_display_name(recipe_name)
    local tex_id   = item_id and load_item_icon(item_id)
    local icon_size = 32
    if tex_id then
        imgui.Image(tex_ptr(tex_id), { icon_size, icon_size }, { 0, 0 }, { 1, 1 }, { 1, 1, 1, 1 }, { 0, 0, 0, 0 })
        imgui.SameLine(0, 8)
        local cur_y = imgui.GetCursorPosY()
        imgui.SetCursorPosY(cur_y + (icon_size - 24) * 0.5)
    end
    fonts.Title(recipe_name)
    if tex_id then
        imgui.SetCursorPosY(imgui.GetCursorPosY())
    end
    imgui.Separator()

    -- HQ results (under the name)
    fonts.Label('HQ Results:')
    local has_hq = false
    if type(recipe.hq1) == 'string' and recipe.hq1 ~= '' then
        fonts.Label('  HQ1: ' .. recipe.hq1)
        has_hq = true
    end
    if type(recipe.hq2) == 'string' and recipe.hq2 ~= '' then
        fonts.Label('  HQ2: ' .. recipe.hq2)
        has_hq = true
    end
    if type(recipe.hq3) == 'string' and recipe.hq3 ~= '' then
        fonts.Label('  HQ3: ' .. recipe.hq3)
        has_hq = true
    end
    if not has_hq then
        fonts.Label('  None')
    end

    imgui.Separator()

    -- Skills block
    fonts.Label(string.format('Main skill: %s %d', main_skill, main_level))

    if type(recipe.subcraft) == 'table' and #recipe.subcraft > 0 then
        local sub_parts = {}
        for _, sub in ipairs(recipe.subcraft) do
            local sub_text  = tostring(sub or '')
            local sub_skill, sub_lv = sub_text:match('^%s*(.-)%s*%((%d+)%)%s*$')
            if sub_skill and sub_lv then
                sub_parts[#sub_parts + 1] = sub_skill .. ' ' .. sub_lv
            else
                sub_parts[#sub_parts + 1] = sub_text
            end
        end
        if #sub_parts > 0 then
            fonts.Label('Sub skill: ' .. table.concat(sub_parts, ', '))
        end
    end

    imgui.Separator()

    -- Ingredients: crystal row, then remaining ingredients in a 2-column table
    local ICON = 32
    local ICON_COUNT_SPACING = 6

    local function get_text_dims(text)
        local a, b = imgui.CalcTextSize(text)
        if type(a) == 'table' then
            local w = tonumber(a.x) or tonumber(a[1]) or 0
            local h = tonumber(a.y) or tonumber(a[2]) or 0
            return w, h
        end
        return tonumber(a) or 0, tonumber(b) or 0
    end

    local function get_content_width()
        local a, b = imgui.GetContentRegionAvail()
        if type(a) == 'table' then
            return tonumber(a.x) or tonumber(a[1]) or 0
        end
        return tonumber(a) or 0
    end

    local function render_centered_icon_count_name(tex, count, name)
        local count_text = '(' .. tostring(count or 0) .. ')'
        local display_name = tostring(name or '')

        imgui.BeginGroup()
            fonts.WithFont(18, function()
                local name_w = get_text_dims(display_name)
                local count_w, count_h = get_text_dims(count_text)
                local cell_x = imgui.GetCursorPosX()
                local cell_w = get_content_width()
                local top_w = tex and (ICON + ICON_COUNT_SPACING + count_w) or count_w

                imgui.SetCursorPosX(cell_x + math.max(0, (cell_w - top_w) * 0.5))
                if tex then
                    imgui.Image(tex_ptr(tex), { ICON, ICON }, { 0, 0 }, { 1, 1 }, { 1, 1, 1, 1 }, { 0, 0, 0, 0 })
                    imgui.SameLine(0, ICON_COUNT_SPACING)
                    local cy = imgui.GetCursorPosY()
                    imgui.SetCursorPosY(cy + (ICON - count_h) * 0.5)
                end
                imgui.TextColored(fonts.COLORS.WHITE, count_text)

                imgui.SetCursorPosX(cell_x + math.max(0, (cell_w - name_w) * 0.5))
                imgui.TextColored(fonts.COLORS.WHITE, display_name)
            end)
        imgui.EndGroup()
    end

    fonts.Label('Ingredients:')

    -- Row 1 (full width): crystal icon with name below
    local crystal_id   = get_item_id_for_display_name(crystal)
    local crystal_tid  = load_item_icon(crystal_id)
    local crystal_count = crystal_id and get_item_inventory_count(crystal_id) or 0
    local crystal_display = crystal
    render_centered_icon_count_name(crystal_tid, crystal_count, crystal_display)

    -- Rows 2+ (2-column table): ingredient icon with name below per cell
    if type(recipe.ingredients) == 'table' and #recipe.ingredients > 0 then
        local ings = recipe.ingredients
        local tbl_flags = bit.bor(ImGuiTableFlags_SizingStretchSame or 0)
        if imgui.BeginTable('cs_recipe_ings', 2, tbl_flags) then
            local i = 1
            while i <= #ings do
                imgui.TableNextRow()
                for col = 0, 1 do
                    imgui.TableNextColumn()
                    local ing = ings[i + col]
                    if ing then
                        local display = tostring(ing)
                        local ing_id  = get_item_id_for_display_name(display)
                        local tid     = load_item_icon(ing_id)
                        local ing_count = ing_id and get_item_inventory_count(ing_id) or 0
                        render_centered_icon_count_name(tid, ing_count, display)
                    end
                end
                i = i + 2
            end
            imgui.EndTable()
        end
    end
end

function M.render(params)
    if not params.show_recipes_window then
        return false
    end

    local imgui         = params.imgui
    local fonts         = params.fonts
    local chrome        = params.chrome
    local recipes       = params.recipes
    local ui_text_scale = params.ui_text_scale or 1.0
    local window_scale  = ui_text_scale * (14 / 18)

    -- Refresh inventory cache only when dirty (set by relevant packet events).
    update_inventory_cache()

    local style_colors, style_vars = chrome.push_theme()
    imgui.PushStyleVar(ImGuiStyleVar_WindowTitleAlign, { 0.5, 0.5 })
    style_vars = style_vars + 1

    local open  = { true }
    local began = false
    pcall(function()
        local window_flags = bit.bor(ImGuiWindowFlags_NoCollapse or 0, ImGuiWindowFlags_NoResize or 0)
        imgui.SetNextWindowSize({ 625, 645 }, ImGuiCond_Always)
        began = imgui.Begin('CraftStats - Recipes', open, window_flags)
        if not began then return end

        fonts.SetScale(window_scale)

        -- Top pane: dropdowns + search
        imgui.BeginChild('cs_recipe_filters', { 0, 80 }, true)
            fonts.WithFont(18, function()
                imgui.AlignTextToFramePadding()
                imgui.Text('Craft:')
                imgui.SameLine()
                imgui.SetNextItemWidth(160)
                local craft_preview = CRAFT_SKILLS[selected_skill_index].name
                if imgui.BeginCombo('##cs_craft_combo', craft_preview) then
                    for i, skill in ipairs(CRAFT_SKILLS) do
                        local selected = (selected_skill_index == i)
                        if imgui.Selectable(skill.name .. '##cs_craft_' .. i, selected) then
                            if selected_skill_index ~= i then
                                selected_skill_index = i
                                selected_rank_index  = 1
                            end
                        end
                        if selected then imgui.SetItemDefaultFocus() end
                    end
                    imgui.EndCombo()
                end

                imgui.SameLine(0, 20)

                imgui.AlignTextToFramePadding()
                imgui.Text('Rank:')
                imgui.SameLine()
                imgui.SetNextItemWidth(200)
                local rank_preview = string.format('%s (%d-%d)', RANKS[selected_rank_index].name, RANKS[selected_rank_index].min, RANKS[selected_rank_index].max)
                if imgui.BeginCombo('##cs_rank_combo', rank_preview) then
                    for i, rank in ipairs(RANKS) do
                        local selected = (selected_rank_index == i)
                        local label = string.format('%s (%d-%d)##cs_rank_%d', rank.name, rank.min, rank.max, i)
                        if imgui.Selectable(label, selected) then
                            selected_rank_index = i
                        end
                        if selected then imgui.SetItemDefaultFocus() end
                    end
                    imgui.EndCombo()
                end
            end)

            imgui.Spacing()
            fonts.WithFont(18, function()
                imgui.AlignTextToFramePadding()
                imgui.Text('Search:')
                imgui.SameLine()
                imgui.SetNextItemWidth(-1)
                imgui.InputText('##cs_recipe_search', search_buffer, 128)
            end)
        imgui.EndChild()

        -- Bottom pane: split recipe list (left) + detail (right)
        local skill = CRAFT_SKILLS[selected_skill_index]
        local rank  = RANKS[selected_rank_index]
        local query = tostring(search_buffer[1] or ''):lower():match('^%s*(.-)%s*$') or ''

        local filtered    = {}
        local skill_lower = ''
        if skill and rank then
            if count_recipes(recipes) == 0 then
                imgui.BeginChild('cs_recipe_list_outer', { 0, 0 }, true)
                    fonts.Label('Recipes are still loading...')
                imgui.EndChild()
            else
                if query ~= '' then
                    -- Search across all recipes, ignore craft/rank filters
                    for _, recipe in pairs(recipes.by_name or {}) do
                        if type(recipe) == 'table' and recipe_matches_search(recipe, query) then
                            filtered[#filtered + 1] = recipe
                        end
                    end
                    table.sort(filtered, function(a, b)
                        return tostring(a.name or '') < tostring(b.name or '')
                    end)
                else
                    local filter_name = skill.filter_name or skill.name
                    filtered    = get_filtered_recipes(recipes, filter_name, rank)
                    skill_lower = filter_name:lower()
                end

                -- Clamp selection when the list shrinks (craft/rank changed)
                if selected_recipe_index > #filtered then
                    selected_recipe_index = math.max(1, #filtered)
                end

                imgui.BeginChild('cs_recipe_names', { 240, 0 }, true)
                    render_recipe_name_list(imgui, fonts, filtered, skill_lower)
                imgui.EndChild()

                imgui.SameLine()

                imgui.BeginChild('cs_recipe_detail', { 0, 0 }, true)
                    local selected_recipe = filtered[selected_recipe_index]
                    render_recipe_detail(imgui, fonts, selected_recipe, skill_lower)
                imgui.EndChild()
            end
        end
    end)

    if began then
        fonts.ResetScale()
        pcall(imgui.End)
    end

    if style_vars > 0 then
        pcall(function() imgui.PopStyleVar(style_vars) end)
    end
    if style_colors > 0 then
        pcall(function() imgui.PopStyleColor(style_colors) end)
    end

    return open[1] == true
end

return M
