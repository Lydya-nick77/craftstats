-- craftstats.lua
-- Ashita v4 addon for tracking crafting statistics and skills
-- Tracks: Success, Break, HQ, NQ counts and percentages

addon.name    = 'craftstats'
addon.author  = 'Lydya'
addon.version = '0.6.0'
addon.desc    = 'Tracks crafting statistics (success, break, HQ, NQ) and displays counts and percentages.'


require('common')
local imgui = require('imgui')
local json = require('json')
-- Recipe data starts empty; sub-modules are loaded one per d3d_present frame (see below).
local recipes = {
    by_name = {},
    by_result = {
        [637] = {
            name = 'Mythril Ingot',
            skill = 'Smithing',
            crystal = 'Fire Crystal',
            ingredients = { 'Mythril Ore x4' },
        },
    },
}

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

local fonts = load_local_module('fonts')
local chrome = load_local_module('chrome')
local create_bonus_tracker = load_local_module('bonus_tracker')
local create_stats_store = load_local_module('stats_store')
local create_prices_store = load_local_module('prices_store')
local create_craft_history_store = load_local_module('craft_history_store')
local ui = load_local_module('ui\\ui')
local item_resources = load_local_module('item_resources')

local bonus = create_bonus_tracker()
local stats_store = create_stats_store(addon, json)
local prices_store = create_prices_store(addon, json, recipes)
local history_store = create_craft_history_store(addon, json)

local last_craft = {
    id = 0,
    name = 'N/A',
    quantity = 0,
    recipe = nil,
    hq_tier = nil,
    result_label = nil,
    crystal_id = nil,
    ingredient_ids = nil,
    logged = false,
}

local function find_recipe(item_id, item_name)
    if recipes and recipes.by_result and item_id and recipes.by_result[item_id] then
        return recipes.by_result[item_id]
    end

    if recipes and recipes.by_name and item_name and #item_name > 0 then
        return recipes.by_name[item_name:lower()]
    end

    return nil
end

-- Data is loaded lazily across the first few d3d_present frames so addon load
-- returns immediately without freezing the game.  Each store starts empty.
local stats = stats_store.empty()
local item_prices = prices_store.empty()
local craft_history = history_store.empty()
local pending_lost_items = {}
local pending_break_entry = nil
local pending_break_deadline = nil

local function trim_text(value)
    if type(value) ~= 'string' then
        return ''
    end

    return value:match('^%s*(.-)%s*$') or ''
end

local function normalize_price_item_name(name)
    local normalized = trim_text(name)
    normalized = normalized:gsub('%s+[xX]%d+%s*$', '')
    return trim_text(normalized)
end

local function parse_ingredient_name_and_qty(raw)
    local text = trim_text(raw)
    if text == '' then
        return '', 0
    end

    local base, qty = text:match('^(.-)%s+[xX](%d+)%s*$')
    if base ~= nil and qty ~= nil then
        return trim_text(base), tonumber(qty) or 1
    end

    return text, 1
end

local function is_hq_label(label)
    return label == 'HQ1' or label == 'HQ2' or label == 'HQ3'
end

-- Persistent item name -> ID cache; populated lazily, valid for the entire session.
local item_name_id_cache = {}

local function safe_get_item_id_by_name(name)
    if type(name) ~= 'string' or name == '' then return nil end
    local cached = item_name_id_cache[name]
    if cached ~= nil then return cached or nil end  -- false = confirmed miss

    local resources = AshitaCore:GetResourceManager()
    if resources == nil then return nil end

    local function try_name(n)
        for _, lang in ipairs({2, 0, 1, 3, 4}) do
            local ok, item = pcall(function() return resources:GetItemByName(n, lang) end)
            if ok and item and item.Id and item.Id > 0 then
                return tonumber(item.Id)
            end
        end
        local ok, item = pcall(function() return resources:GetItemByName(n) end)
        if ok and item and item.Id and item.Id > 0 then return tonumber(item.Id) end
        return nil
    end

    local id = try_name(name)
    if not id then
        local contracted = name:gsub('[Ll]ightning%s+', 'Lightng. ')
        if contracted ~= name then id = try_name(contracted) end
    end
    if not id then
        local expanded = name:gsub('[Ll]ightng%.%s*', 'Lightning '):gsub('%s+', ' '):match('^(.-)%s*$')
        if expanded ~= name then id = try_name(expanded) end
    end

    item_name_id_cache[name] = id or false
    return id
end

-- Recipe lookup indices:
--   recipe_output_index:    "name:qty" -> recipe
--   recipe_hq_index:        "name:qty" -> {recipe, tier}
--   crystal_name_to_recipes: lowercase crystal name -> {recipe, ...}  (built at load, no AshitaCore)
--   crystal_name_originals:  lowercase crystal name -> original-cased string (for ID lookup)
--   crystal_recipe_index:   crystal_id -> {{recipe, needed_counts, needed_total}, ...}
local recipe_output_index = nil
local recipe_hq_index = nil
local crystal_name_to_recipes = nil
local crystal_name_originals = nil
local crystal_recipe_index = nil
local crystal_index_built_for = nil

local function build_result_indices()
    recipe_output_index = {}
    recipe_hq_index = {}
    crystal_name_to_recipes = {}
    crystal_name_originals = {}
    for _, recipe in pairs(recipes.by_name or {}) do
        if type(recipe) == 'table' then
            if recipe.name ~= nil then
                local rname, rqty = parse_ingredient_name_and_qty(recipe.name)
                local key = normalize_price_item_name(rname):lower() .. ':' .. (tonumber(rqty) or 1)
                if not recipe_output_index[key] then
                    recipe_output_index[key] = recipe
                end
            end
            for _, field in ipairs({'hq1', 'hq2', 'hq3'}) do
                if recipe[field] ~= nil then
                    local hname, hqty = parse_ingredient_name_and_qty(recipe[field])
                    local key = normalize_price_item_name(hname):lower() .. ':' .. (tonumber(hqty) or 1)
                    if not recipe_hq_index[key] then
                        recipe_hq_index[key] = {recipe = recipe, tier = field:upper()}
                    end
                end
            end
            -- Group by crystal name so ensure_crystal_bucket iterates only the relevant subset.
            if recipe.crystal then
                local c_base, _ = parse_ingredient_name_and_qty(recipe.crystal)
                local c_key = normalize_price_item_name(c_base):lower()
                if c_key ~= '' then
                    if not crystal_name_to_recipes[c_key] then
                        crystal_name_to_recipes[c_key] = {}
                        crystal_name_originals[c_key] = c_base
                    end
                    local tbl = crystal_name_to_recipes[c_key]
                    tbl[#tbl + 1] = recipe
                end
            end
        end
    end
end

local function ensure_result_indices()
    if recipe_output_index == nil or recipe_hq_index == nil then
        build_result_indices()
    end
end

local function ensure_crystal_bucket(crystal_id)
    if type(crystal_id) ~= 'number' then return end
    if crystal_recipe_index == nil then crystal_recipe_index = {} end
    if crystal_index_built_for == nil then crystal_index_built_for = {} end
    if crystal_index_built_for[crystal_id] then return end

    -- Fast path: resolve crystal name from ID then look up the pre-grouped recipe list.
    -- This is O(crystal_recipes) instead of O(all_recipes), and skips per-recipe crystal
    -- ID resolution entirely.
    local recipe_list
    if crystal_name_to_recipes ~= nil then
        local c_name_raw = item_resources.get_item_name_by_id(crystal_id)
        if c_name_raw then
            local c_key = normalize_price_item_name(c_name_raw):lower()
            recipe_list = crystal_name_to_recipes[c_key] or {}
        else
            recipe_list = {}
        end
    else
        -- Index not built yet: fall back to full scan (original behaviour).
        recipe_list = {}
        for _, recipe in pairs(recipes.by_name or {}) do
            if type(recipe) == 'table' and recipe.crystal and type(recipe.ingredients) == 'table' then
                local c_name2, _ = parse_ingredient_name_and_qty(recipe.crystal)
                local c_id2 = safe_get_item_id_by_name(c_name2)
                if c_id2 and c_id2 == crystal_id then
                    recipe_list[#recipe_list + 1] = recipe
                end
            end
        end
    end

    local bucket = {}
    for _, recipe in ipairs(recipe_list) do
        if type(recipe) == 'table' and type(recipe.ingredients) == 'table' then
            local needed_counts = {}
            local needed_total = 0
            local ok_recipe = true
            for _, ing in ipairs(recipe.ingredients) do
                local i_name, i_qty = parse_ingredient_name_and_qty(ing)
                local i_id = safe_get_item_id_by_name(i_name)
                if not i_id then ok_recipe = false break end
                local qty = math.max(1, tonumber(i_qty) or 1)
                needed_counts[i_id] = (needed_counts[i_id] or 0) + qty
                needed_total = needed_total + qty
            end
            if ok_recipe then
                bucket[#bucket + 1] = {recipe = recipe, needed_counts = needed_counts, needed_total = needed_total}
            end
        end
    end

    crystal_recipe_index[crystal_id] = bucket
    crystal_index_built_for[crystal_id] = true
end

-- Prewarm all crystal buckets so the first craft has zero index-build cost.
-- Called once on the first d3d_present frame when AshitaCore is fully ready.
local function prewarm_all_crystal_buckets()
    if crystal_name_originals == nil then return end
    for _, orig_name in pairs(crystal_name_originals) do
        local id = safe_get_item_id_by_name(orig_name)
        if id then
            ensure_crystal_bucket(id)
        end
    end
end

local function find_recipe_by_output_name(item_name, item_qty)
    if type(item_name) ~= 'string' or item_name == '' then return nil end
    ensure_result_indices()
    local key = normalize_price_item_name(item_name):lower() .. ':' .. (tonumber(item_qty) or 1)
    return recipe_output_index[key]
end

-- Find the recipe that contains item_name/item_qty as one of its HQ results.
-- Returns: recipe, tier_label ('HQ1'/'HQ2'/'HQ3') or nil, nil if not found.
local function find_recipe_by_hq_name(item_name, item_qty)
    if type(item_name) ~= 'string' or item_name == '' then return nil, nil end
    ensure_result_indices()
    local key = normalize_price_item_name(item_name):lower() .. ':' .. (tonumber(item_qty) or 1)
    local entry = recipe_hq_index[key]
    if entry then return entry.recipe, entry.tier end
    return nil, nil
end

-- Determine NQ/HQ1/HQ2/HQ3 by comparing the crafted item name AND quantity against recipe fields
local function determine_result_label(item_name, item_qty, recipe)
    if type(recipe) ~= 'table' or type(item_name) ~= 'string' or item_name == '' then
        return 'NQ'
    end
    local normalized = normalize_price_item_name(item_name):lower()
    local crafted_qty = tonumber(item_qty) or 1
    local function matches(field)
        if field == nil then return false end
        local fname, fqty = parse_ingredient_name_and_qty(field)
        if normalize_price_item_name(fname):lower() ~= normalized then
            return false
        end
        -- If the recipe field specifies a quantity, it must match
        local field_qty = tonumber(fqty) or 1
        if field_qty > 1 then
            return crafted_qty == field_qty
        end
        return true
    end
    if matches(recipe.hq3) then return 'HQ3' end
    if matches(recipe.hq2) then return 'HQ2' end
    if matches(recipe.hq1) then return 'HQ1' end
    return 'NQ'
end

-- Find a recipe by crystal ID and ingredient ID list (multiset match).
-- Uses a pre-built index: O(candidates_per_crystal) instead of O(all_recipes).
local function find_recipe_by_ids(crystal_id, ingredient_ids)
    if not crystal_id or type(ingredient_ids) ~= 'table' then return nil end
    local given_counts = {}
    local given_total = 0
    for _, v in ipairs(ingredient_ids) do
        local id = tonumber(v) or 0
        if id > 0 then
            given_counts[id] = (given_counts[id] or 0) + 1
            given_total = given_total + 1
        end
    end
    if given_total == 0 then return nil end
    ensure_crystal_bucket(crystal_id)
    local candidates = crystal_recipe_index[crystal_id]
    if not candidates then return nil end
    for _, entry in ipairs(candidates) do
        if entry.needed_total == given_total then
            local match = true
            for nid, ncount in pairs(entry.needed_counts) do
                if given_counts[nid] ~= ncount then match = false break end
            end
            if match then return entry.recipe end
        end
    end
    return nil
end

-- Lazily-built price map; invalidated whenever item_prices is replaced.
local price_lookup_cache = nil

local function get_price_lookup()
    if price_lookup_cache then return price_lookup_cache end
    local map = {}
    if type(item_prices) == 'table' and type(item_prices.items) == 'table' then
        for _, entry in ipairs(item_prices.items) do
            local key = normalize_price_item_name(entry.name):lower()
            if key ~= '' then
                map[key] = math.max(0, math.floor(tonumber(entry.price) or 0))
            end
        end
    end
    price_lookup_cache = map
    return map
end

-- Pre-normalized skill names (lowercase alpha only) for fast recipe-skill matching.
local normalized_skill_id_by_name = nil

local function get_normalized_skill_id_by_name()
    if normalized_skill_id_by_name then return normalized_skill_id_by_name end
    normalized_skill_id_by_name = {}
    for id, name in pairs(bonus.skill_names or {}) do
        normalized_skill_id_by_name[tostring(name):lower():gsub('[^a-z]', '')] = id
    end
    return normalized_skill_id_by_name
end

local function get_player_skill_for_recipe(recipe)
    if type(recipe) ~= 'table' or recipe.skill == nil then
        return 0
    end
    local recipe_skill = tostring(recipe.skill):lower():gsub('[^a-z]', '')
    local id = get_normalized_skill_id_by_name()[recipe_skill]
    if id then
        return (tonumber(bonus.skills[id]) or 0) + (tonumber(bonus.skill_bonuses[id]) or 0)
    end
    return 0
end

local function get_recipe_craft_cost(recipe)
    if type(recipe) ~= 'table' then
        return 0
    end

    local lookup = get_price_lookup()
    local total = 0

    if recipe.crystal ~= nil then
        local crystal_name, crystal_qty = parse_ingredient_name_and_qty(recipe.crystal)
        local crystal_key = normalize_price_item_name(crystal_name):lower()
        local crystal_price = lookup[crystal_key] or 0
        total = total + (crystal_price * math.max(1, tonumber(crystal_qty) or 1))
    end

    if type(recipe.ingredients) == 'table' then
        for _, ingredient in ipairs(recipe.ingredients) do
            local ingredient_name, qty = parse_ingredient_name_and_qty(ingredient)
            local key = normalize_price_item_name(ingredient_name):lower()
            local price = lookup[key] or 0
            total = total + (price * math.max(1, tonumber(qty) or 1))
        end
    end

    return total
end

local function get_lost_items_cost(lost_items_str)
    if type(lost_items_str) ~= 'string' or lost_items_str == '' or lost_items_str == 'Unknown' then
        return 0
    end
    local lookup = get_price_lookup()

    local prefix_patterns = {
        '^handful of%s+',
        '^chunk of%s+',
        '^lump of%s+',
        '^block of%s+',
        '^sheet of%s+',
        '^ball of%s+',
        '^bottle of%s+',
        '^vial of%s+',
        '^flask of%s+',
        '^jar of%s+',
        '^pot of%s+',
        '^sprig of%s+',
        '^head of%s+',
        '^slice of%s+',
        '^clump of%s+',
    }

    local total = 0
    for item_str in (lost_items_str .. ','):gmatch('([^,]+),') do
        local name, qty = parse_ingredient_name_and_qty(trim_text(item_str))
        local key = normalize_price_item_name(name):lower()
        local price = lookup[key]

        -- Break messages can include container prefixes while price entries often use the base item name.
        if price == nil then
            for _, pattern in ipairs(prefix_patterns) do
                local base_key = key:gsub(pattern, '')
                if base_key ~= key then
                    price = lookup[base_key]
                    if price ~= nil then
                        break
                    end
                end
            end
        end

        price = price or 0
        total = total + price * math.max(1, tonumber(qty) or 1)
    end
    return total
end

local function get_made_item_price(result_label)
    if result_label == 'Break' then
        return 0
    end

    local crafted_name = normalize_price_item_name(last_craft.name)
    if crafted_name == '' then
        return 0
    end

    local qty = math.max(1, tonumber(last_craft.quantity) or 1)
    local unit_price = get_price_lookup()[crafted_name:lower()] or 0
    return unit_price * qty
end

local function has_non_break_result_item(item_name, item_qty)
    local normalized = normalize_price_item_name(item_name or ''):lower()
    local qty = tonumber(item_qty) or 0
    return normalized ~= '' and normalized ~= 'n/a' and normalized ~= 'mangled mess' and qty > 0
end

local function correct_break_to_success(result_label)
    if result_label ~= 'NQ' and not is_hq_label(result_label) then
        return
    end

    if stats.break_ > 0 then
        stats.break_ = stats.break_ - 1
    end

    stats.success = stats.success + 1
    if result_label == 'NQ' then
        stats.nq = stats.nq + 1
    else
        stats.hq = stats.hq + 1
    end

    stats_store.save(stats)
end

local function push_pending_lost_item(name)
    local text = trim_text(name)
    if text ~= '' then
        pending_lost_items[#pending_lost_items + 1] = text
    end
end

local function consume_pending_lost_items()
    if #pending_lost_items == 0 then return '' end
    local counts = {}
    local order = {}
    for _, item in ipairs(pending_lost_items) do
        local key = item:lower()
        if not counts[key] then
            order[#order + 1] = item
            counts[key] = 0
        end
        counts[key] = counts[key] + 1
    end
    local parts = {}
    for _, item in ipairs(order) do
        local n = counts[item:lower()]
        parts[#parts + 1] = n > 1 and (item .. ' x' .. n) or item
    end
    pending_lost_items = {}
    return table.concat(parts, ', ')
end

local function log_craft_result(result_label)
    -- Guard against duplicate calls caused by lag-retransmitted 0x006F packets.
    if last_craft.logged then return end

    -- Use crystal/ingredient IDs to find recipe if possible (calls top-level find_recipe_by_ids)

    if (last_craft.recipe == nil or last_craft.recipe == false) and last_craft.crystal_id and last_craft.ingredient_ids then
        last_craft.recipe = find_recipe_by_ids(last_craft.crystal_id, last_craft.ingredient_ids)
    end
    if type(result_label) ~= 'string' or result_label == '' then
        return
    end
    if (last_craft.recipe == nil) and (tostring(last_craft.name or '') == 'N/A') then
        return
    end

    bonus.update_skill_bonuses()

    local recipe = last_craft.recipe
    local recipe_name = (type(recipe) == 'table' and recipe.name) or last_craft.name or 'Unknown'
    local recipe_level = (type(recipe) == 'table' and tonumber(recipe.level)) or 0
    local player_skill = get_player_skill_for_recipe(recipe)
    if result_label == 'Break' then
        last_craft.logged = true
        -- Defer: text_in lost-item messages arrive after the 0x006F result packet,
        -- so we wait a short time before committing the history entry.
        pending_break_entry = {
            time = os.date('%Y-%m-%d %H:%M:%S'),
            recipe_name = tostring(recipe_name),
            recipe_level = recipe_level,
            player_skill = player_skill,
            result = result_label,
            made_item_price = 0,
        }
        pending_break_deadline = os.clock() + 2.0
        return
    end

    last_craft.logged = true
    consume_pending_lost_items()
    local made_item_price = get_made_item_price(result_label)
    local craft_cost = get_recipe_craft_cost(recipe)

    history_store.append(craft_history, {
        time = os.date('%Y-%m-%d %H:%M:%S'),
        recipe_name = tostring(recipe_name),
        recipe_level = recipe_level,
        player_skill = player_skill,
        result = result_label,
        craft_cost = craft_cost,
        made_item_price = made_item_price,
        lost_items = '',
    })
    history_store.save(craft_history)
end

local function replace_item_prices(next_prices)
    item_prices.items = {}
    price_lookup_cache = nil  -- invalidate cached price map
    if type(next_prices) ~= 'table' or type(next_prices.items) ~= 'table' then
        return
    end

    for i, entry in ipairs(next_prices.items) do
        item_prices.items[i] = {
            id = tonumber(entry.id) or i,
            name = tostring(entry.name or ''),
            price = math.max(0, math.floor(tonumber(entry.price) or 0)),
        }
    end
end

local function merge_imported_items_preserving_prices(imported_prices)
    local existing_price_by_name = {}
    if type(item_prices) == 'table' and type(item_prices.items) == 'table' then
        for _, entry in ipairs(item_prices.items) do
            local key = normalize_price_item_name(entry.name):lower()
            if key ~= '' then
                existing_price_by_name[key] = math.max(0, math.floor(tonumber(entry.price) or 0))
            end
        end
    end

    local merged = { items = {} }
    if type(imported_prices) ~= 'table' or type(imported_prices.items) ~= 'table' then
        return merged
    end

    for i, entry in ipairs(imported_prices.items) do
        local name = tostring(entry.name or '')
        local key = normalize_price_item_name(name):lower()
        local imported_price = math.max(0, math.floor(tonumber(entry.price) or 0))
        local preserved_price = existing_price_by_name[key]

        merged.items[i] = {
            id = tonumber(entry.id) or i,
            name = name,
            price = (preserved_price ~= nil) and preserved_price or imported_price,
        }
    end

    return merged
end

-- Initialize skill values on addon load
bonus.update_skills()

-- build_result_indices and all store loads are deferred to d3d_present frames (see below).
local function reset_stats()
    local empty = stats_store.empty()
    for key, value in pairs(empty) do
        stats[key] = value
    end
    stats_store.save(stats)
end

local function clear_history()
    local entries = (type(craft_history) == 'table' and type(craft_history.entries) == 'table') and craft_history.entries or {}
    local cleared = #entries
    craft_history.entries = {}
    history_store.save(craft_history)
    return cleared
end

-- ImGui UI for live stats
local show_window = { true }
local ui_text_scale = 0.92

-- Reset stats and toggle command
ashita.events.register('command', 'craftstats_command', function(e)
    local args = e.command:lower():split(' ')
    if args[1] == '/craftstats' then
        if args[2] == 'reset' then
            reset_stats()
            return true
        end
        if args[2] == nil or args[2] == '' then
            show_window[1] = not show_window[1]
            return true
        end
    end
    return false
end)

-- Helper to map result byte to stat (for 0x0030: 0=NQ, 1=Break, 2/3/4=HQ)
local function handle_craft_result_0030(result_byte)
    local result_label = nil
    if result_byte == 0 then
        stats.nq = stats.nq + 1
        stats.success = stats.success + 1
        result_label = 'NQ'
    elseif result_byte == 1 then
        stats.break_ = stats.break_ + 1
        result_label = 'Break'
    elseif result_byte == 2 or result_byte == 3 or result_byte == 4 then
        stats.hq = stats.hq + 1
        stats.success = stats.success + 1
        result_label = string.format('HQ%d', result_byte - 1)
    else
        -- Unknown result, ignore
        return nil
    end
    stats.total = stats.total + 1
    -- Update skills now that a craft finished
    bonus.update_skills()
    stats_store.save(stats)
    return result_label
end

-- Determine the history result label for 0x006F using the authoritative 0x0030 result when available.
local function handle_craft_result_006F(result_byte, item_name, item_qty, hq_tier, recipe, result_hint)
    if result_hint == 'Break' then
        if has_non_break_result_item(item_name, item_qty) then
            local corrected = hq_tier or determine_result_label(item_name or '', item_qty or 1, recipe)
            if not is_hq_label(corrected) then
                corrected = 'NQ'
            end
            correct_break_to_success(corrected)
            return corrected
        end
        return 'Break'
    end

    if normalize_price_item_name(item_name or ''):lower() == 'mangled mess' then
        return 'Break'
    end

    if result_hint == 'NQ' then
        return 'NQ'
    end

    if is_hq_label(result_hint) then
        if hq_tier == result_hint then
            return result_hint
        end

        local derived = determine_result_label(item_name or '', item_qty or 1, recipe)
        if derived ~= 'NQ' then
            return derived
        end

        return result_hint
    end

    if result_byte == 0 or result_byte == 1 or result_byte == 12 then
        return hq_tier or determine_result_label(item_name or '', item_qty or 1, recipe)
    end

    return nil
end

-- Only count the first 0x0030 per craft using a cooldown timer
local last_craft_time = 0
local craft_cooldown = 2.0 -- seconds, adjust as needed

ashita.events.register('packet_in', 'craftstats_packet_in', function(e)
    if e.id == 0x0030 then
        local player = GetPlayerEntity and GetPlayerEntity() or nil
        if player ~= nil then
            local my_index = player.TargetIndex
            local pkt_index = struct.unpack('H', e.data_modified, 0x08 + 0x01)
            if my_index == pkt_index then
                local now = os.clock()
                if now - last_craft_time > craft_cooldown then
                    last_craft_time = now
                    local result = struct.unpack('b', e.data_modified, 0x0C + 0x01)
                    last_craft.result_label = handle_craft_result_0030(result)
                end
            end
        end
    end

    -- Synthesis results packet; use this to identify the crafted item.
    if e.id == 0x006F then
        local result = struct.unpack('b', e.data_modified, 0x04 + 0x01)
        local item_id = struct.unpack('H', e.data_modified, 0x08 + 0x01)
        local qty = struct.unpack('B', e.data_modified, 0x06 + 0x01)
        if item_id ~= nil and item_id > 0 then
            local item = AshitaCore:GetResourceManager():GetItemById(item_id)

            last_craft.id = item_id or 0
            last_craft.quantity = math.max(1, tonumber(qty) or 1)
            last_craft.name = (item and item.Name and item.Name[1]) or ('Item #' .. tostring(item_id))
            last_craft.recipe = nil
            last_craft.hq_tier = nil

            if last_craft.result_label == 'NQ' then
                last_craft.recipe = find_recipe_by_output_name(last_craft.name, last_craft.quantity)
            elseif is_hq_label(last_craft.result_label) then
                local hq_recipe, hq_tier = find_recipe_by_hq_name(last_craft.name, last_craft.quantity)
                last_craft.recipe = hq_recipe
                last_craft.hq_tier = hq_tier
            else
                local hq_recipe, hq_tier = find_recipe_by_hq_name(last_craft.name, last_craft.quantity)
                if hq_recipe ~= nil then
                    last_craft.recipe = hq_recipe
                    last_craft.hq_tier = hq_tier
                else
                    last_craft.recipe = find_recipe_by_output_name(last_craft.name, last_craft.quantity)
                end
            end

            if last_craft.recipe == nil then
                last_craft.recipe = find_recipe(item_id, last_craft.name)
            end

            -- Always prefer the ID-based recipe (actual crystal+ingredient IDs from the outgoing
            -- 0x0096 packet) over name-based lookups, which can be ambiguous when multiple recipes
            -- share the same output name (e.g. "Brass Ingot" exists at both level 9 and level 10).
            if last_craft.crystal_id and last_craft.ingredient_ids then
                local id_recipe = find_recipe_by_ids(last_craft.crystal_id, last_craft.ingredient_ids)
                if id_recipe ~= nil then
                    last_craft.recipe = id_recipe
                end
            end
        end

        local result_label = handle_craft_result_006F(result, last_craft.name, last_craft.quantity, last_craft.hq_tier, last_craft.recipe, last_craft.result_label)
        log_craft_result(result_label)
    end
end)

ashita.events.register('packet_out', 'craftstats_packet_out', function(e)
    if e.id == 0x0096 or e.id == 0x96 then
        -- Always parse outgoing 0x0096 to capture crystal/ingredient IDs for recipe lookup
        local data = e.data_modified or e.data
        local len = tonumber(e.size) or 0
        local bytes = {}
        if type(data) == 'string' then
            for i = 1, #data do bytes[i] = string.byte(data, i) or 0 end
        else
            local ok, t = pcall(function() return data:totable() end)
            if ok and type(t) == 'table' and #t > 0 then
                bytes = t
            else
                for i = 0, (len - 1) do
                    local okb, v = pcall(struct.unpack, 'B', data, i + 1)
                    if okb and v then bytes[i + 1] = tonumber(v) or 0 else bytes[i + 1] = 0 end
                end
            end
        end

        -- Parse crystal and ingredient IDs (LE)
        local function safe_read_u8(off) return bytes[off + 1] or 0 end
        local crystal_le = (bytes[0x07 + 1] or 0) * 256 + (bytes[0x06 + 1] or 0)
        local items_count = math.min(safe_read_u8(0x09), 8)
        local itemnos_le = {}
        for i = 0, items_count - 1 do
            local off = 0x0A + (i * 2)
            itemnos_le[i + 1] = (bytes[off + 2] or 0) * 256 + (bytes[off + 1] or 0)
        end

        last_craft.crystal_id = crystal_le
        last_craft.ingredient_ids = itemnos_le
        last_craft.logged = false

        -- Attempt to resolve recipe now so it will be available even on break
        if (last_craft.recipe == nil or last_craft.recipe == false) and last_craft.crystal_id and last_craft.ingredient_ids then
            last_craft.recipe = find_recipe_by_ids(last_craft.crystal_id, last_craft.ingredient_ids)
        end
    end
end)

local function strip_color_codes(s)
    -- Remove Ashita/FFXI chat color escape sequences (\30\x and \31\x)
    return (s:gsub('\30.', ''):gsub('\31.', ''))
end

ashita.events.register('text_in', 'craftstats_text_in', function(e)
    local message = strip_color_codes(trim_text(e.message_modified or e.message or ''))
    if message == '' then
        return false
    end

    -- Synthesis support applied: "Your X skills went up [qualifier]."
    -- The buff ID is identical for all tiers on HorizonXI, so parse the message phrasing.
    if message:match('[Yy]our .- skills went up') then
        bonus.set_support_tier_from_message(message)
        return false
    end

    local item_name = message:match('[Aa]n? (.+) was lost%.')
    if item_name ~= nil then
        push_pending_lost_item(strip_color_codes(trim_text(item_name)))
        return false
    end

    if message:match('You lost the .+ you were using%.') then
        -- FFXI says "the crystal" without naming it; look up by ID instead
        local crystal_name = last_craft.crystal_id and item_resources.get_item_name_by_id(last_craft.crystal_id)
        if crystal_name then
            -- Expand FFXI abbreviated name: "Lightng. Crystal" -> "Lightning Crystal"
            crystal_name = crystal_name:gsub('[Ll]ightng%.%s*', 'Lightning '):gsub('%s+', ' '):match('^(.-)%s*$')
        end
        push_pending_lost_item(crystal_name or 'Crystal')
        return false
    end

    return false
end)

local function flush_pending_break_entry()
    local lost = consume_pending_lost_items()
    local entry = pending_break_entry
    entry.lost_items = lost
    entry.craft_cost = get_lost_items_cost(lost)
    pending_break_entry = nil
    pending_break_deadline = nil
    history_store.append(craft_history, entry)
    history_store.save(craft_history)
end

-- Pre-built params table: avoids allocating a new table + closures every d3d_present frame.
local ui_render_params = {
    imgui = imgui,
    fonts = fonts,
    chrome = chrome,
    stats = stats,
    craft_history = craft_history,
    bonus = bonus,
    last_craft = last_craft,
    item_prices = item_prices,
    show_window = show_window,
    ui_text_scale = ui_text_scale,
    on_reset = reset_stats,
    on_prices_save = function()
        price_lookup_cache = nil
        prices_store.save(item_prices)
    end,
    on_prices_import = function()
        local imported = prices_store.import_from_recipes()
        local merged = merge_imported_items_preserving_prices(imported)
        replace_item_prices(merged)
        prices_store.save(item_prices)
        return #item_prices.items
    end,
    on_prices_import_hgather = function()
        local merged, updated, matched, ok = prices_store.import_prices_from_hgather(item_prices)
        if not ok then
            return 0, 0, false
        end
        replace_item_prices(merged)
        prices_store.save(item_prices)
        return matched or 0, updated or 0, true
    end,
    on_history_clear = function()
        return clear_history()
    end,
    on_new_session = function()
        reset_stats()
        clear_history()
    end,
}

-- Multi-phase deferred startup: each step runs on its own d3d_present frame so no single
-- frame blocks the game long enough to be felt as a freeze.
--   Frames 1-8: load one recipe sub-module per frame (mutate recipes.by_name in place)
--   Frame 9:  build recipe/crystal-name indices + load stats
--   Frame 10: load item prices (largest JSON decode)
--   Frame 11: load craft history
--   Frame 12+: prewarm one crystal ID bucket per frame
local recipe_submodule_queue = {
    'recipes.woodworking',
    'recipes.alchemy',
    'recipes.bonecraft',
    'recipes.clothcraft',
    'recipes.cooking',
    'recipes.goldsmith',
    'recipes.leathercraft',
    'recipes.smithing',
}
local recipe_load_index = 0   -- 0 = not started; advances to 8 when all loaded
local init_step = 0           -- runs AFTER all recipe sub-modules are loaded
local crystal_prewarm_queue = nil
local crystal_prewarm_index = 0

local function tick_crystal_prewarm()
    -- Build the queue lazily after build_result_indices has populated crystal_name_originals.
    if crystal_prewarm_queue == nil then
        crystal_prewarm_queue = {}
        if crystal_name_originals ~= nil then
            for _, orig_name in pairs(crystal_name_originals) do
                crystal_prewarm_queue[#crystal_prewarm_queue + 1] = orig_name
            end
        end
    end
    crystal_prewarm_index = crystal_prewarm_index + 1
    local orig_name = crystal_prewarm_queue[crystal_prewarm_index]
    if orig_name == nil then return end  -- all crystals prewarmed
    local id = safe_get_item_id_by_name(orig_name)
    if id then
        ensure_crystal_bucket(id)
    end
end

ashita.events.register('d3d_present', 'craftstats_present', function()
    if recipe_load_index < #recipe_submodule_queue then
        -- Load one recipe sub-module per frame; merge entries into the shared recipes table.
        recipe_load_index = recipe_load_index + 1
        pcall(function()
            local sub = require(recipe_submodule_queue[recipe_load_index])
            if type(sub) == 'table' and type(sub.by_name) == 'table' then
                for k, v in pairs(sub.by_name) do
                    recipes.by_name[k] = v
                end
            end
        end)
    elseif init_step == 0 then
        -- All recipe files loaded; build indices and load stats (both fast, pure Lua).
        init_step = 1
        pcall(function()
            local ls = stats_store.load()
            for k, v in pairs(ls) do stats[k] = v end
            build_result_indices()
        end)
    elseif init_step == 1 then
        -- Step 1: item prices JSON (1000+ items, potentially the slowest decode).
        init_step = 2
        pcall(function()
            local lp = prices_store.load_or_import()
            item_prices.items = lp.items or {}
        end)
    elseif init_step == 2 then
        -- Step 2: craft history JSON.
        init_step = 3
        pcall(function()
            local lh = history_store.load()
            craft_history.entries = lh.entries or {}
        end)
    elseif crystal_prewarm_queue == nil or crystal_prewarm_index < #crystal_prewarm_queue then
        -- Step 3+: prewarm one crystal bucket per frame until done.
        pcall(tick_crystal_prewarm)
    end
    if pending_break_entry and os.clock() >= pending_break_deadline then
        flush_pending_break_entry()
    end
    ui.render(ui_render_params)
end)

return {
    stats = stats,
    skills = bonus.skills,
    update_skills = bonus.update_skills
}
