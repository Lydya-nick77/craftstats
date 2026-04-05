local function create_prices_store(addon_info, json, recipes_data)
    local base_path
    if addon_info and addon_info.path and type(addon_info.path) == 'string' and #addon_info.path > 0 then
        base_path = addon_info.path
    else
        local ok, install = pcall(function() return AshitaCore:GetInstallPath() end)
        if ok and install and #install > 0 then
            base_path = ('%s\\addons\\%s'):fmt(install, addon_info.name)
        else
            base_path = '.'
        end
    end

    local items_dir = string.format('%s\\items', base_path)
    local prices_file = string.format('%s\\item_prices.json', items_dir)
    local hgather_constants_file = string.format('%s\\..\\HGather\\constants.lua', base_path)
    local hgather_config_dir = string.format('%s\\..\\..\\config\\addons\\hgather', base_path)
    local store = {}

    local function ensure_items_dir()
        pcall(function()
            os.execute(('mkdir "%s" >nul 2>nul'):format(items_dir))
        end)
    end

    local function file_exists(path)
        local file = io.open(path, 'r')
        if file then
            file:close()
            return true
        end
        return false
    end

    local function normalize_name(name)
        local raw = tostring(name or '')
        raw = raw:match('^%s*(.-)%s*$') or ''
        return raw
    end

    local function parse_item_price_string(raw)
        local text = normalize_name(raw)
        if text == '' then
            return nil, nil
        end

        local name, price_text = text:match('^(.-)%s*:%s*(-?%d+)%s*$')
        if name == nil or price_text == nil then
            return nil, nil
        end

        name = normalize_name(name)
        if name == '' then
            return nil, nil
        end

        local price = tonumber(price_text)
        if type(price) ~= 'number' then
            return nil, nil
        end

        return name, math.max(0, math.floor(price))
    end

    local function apply_item_index_entries(price_map, entries)
        if type(entries) ~= 'table' then
            return
        end

        for _, value in pairs(entries) do
            local name, price = parse_item_price_string(value)
            if name ~= nil and price ~= nil then
                price_map[name:lower()] = price
            end
        end
    end

    local function apply_hgather_constants(price_map)
        local file = io.open(hgather_constants_file, 'r')
        if not file then
            return false
        end

        local content = file:read('*a')
        file:close()
        if type(content) ~= 'string' then
            return false
        end

        local in_item_index = false
        for line in tostring(content):gmatch('[^\r\n]+') do
            if not in_item_index then
                if line:find('ItemIndex%s*=%s*T%s*{') then
                    in_item_index = true
                end
            else
                if line:find('^%s*}%s*;?%s*$') then
                    break
                end

                local raw = line:match('"([^"]+)"')
                if raw ~= nil then
                    local name, price = parse_item_price_string(raw)
                    if name ~= nil and price ~= nil then
                        price_map[name:lower()] = price
                    end
                end
            end
        end

        return true
    end

    local function load_hgather_settings_file(path)
        local chunk = loadfile(path)
        if type(chunk) ~= 'function' then
            return nil, false
        end

        local ok, loaded = pcall(chunk)
        if ok and type(loaded) == 'table' then
            return loaded, true
        end

        return nil, false
    end

    local function list_hgather_settings_files()
        local files = {}

        local defaults_file = string.format('%s\\defaults\\settings.lua', hgather_config_dir)
        if file_exists(defaults_file) then
            files[#files + 1] = defaults_file
        end

        local cmd = string.format('dir /b /ad "%s" 2>nul', hgather_config_dir)
        local handle = io.popen(cmd)
        if handle then
            for dirname in handle:lines() do
                local name = normalize_name(dirname)
                if name ~= '' and name:lower() ~= 'defaults' then
                    local path = string.format('%s\\%s\\settings.lua', hgather_config_dir, name)
                    if file_exists(path) then
                        files[#files + 1] = path
                    end
                end
            end
            handle:close()
        end

        return files
    end

    local function validate_hgather_sources()
        if not file_exists(hgather_constants_file) then
            return false
        end

        local settings_files = list_hgather_settings_files()
        if #settings_files == 0 then
            return false
        end

        return true
    end

    local function read_hgather_price_map()
        if not validate_hgather_sources() then
            return nil, false
        end

        local price_map = {}
        local constants_ok = apply_hgather_constants(price_map)
        if not constants_ok then
            return nil, false
        end

        for _, file_path in ipairs(list_hgather_settings_files()) do
            local settings_tbl, loaded_ok = load_hgather_settings_file(file_path)
            if not loaded_ok then
                return nil, false
            end
            if settings_tbl and type(settings_tbl.item_index) == 'table' then
                apply_item_index_entries(price_map, settings_tbl.item_index)
            end
        end

        return price_map, true
    end

    local function normalize_ingredient_name(raw)
        local name = normalize_name(raw)
        if name == '' then
            return ''
        end

        -- Strip trailing quantity suffixes like "x3" from recipe ingredients.
        name = name:gsub('%s+[xX]%d+%s*$', '')
        return normalize_name(name)
    end

    local function normalize_result_item_name(raw)
        local name = normalize_name(raw)
        if name == '' then
            return ''
        end

        -- Strip trailing quantity suffixes like "x3" from result names.
        name = name:gsub('%s+[xX]%d+%s*$', '')
        return normalize_name(name)
    end

    local function build_sorted_items(names)
        table.sort(names, function(a, b)
            return a:lower() < b:lower()
        end)

        local items = {}
        for i, name in ipairs(names) do
            items[i] = {
                id = i,
                name = name,
                price = 0,
            }
        end

        return items
    end

    function store.empty()
        return { items = {} }
    end

    function store.load()
        local file = io.open(prices_file, 'r')
        if file then
            local content = file:read('*a')
            file:close()

            local ok, loaded = pcall(json.decode, content)
            if ok and type(loaded) == 'table' and type(loaded.items) == 'table' then
                for i, entry in ipairs(loaded.items) do
                    entry.id = tonumber(entry.id) or i
                    entry.name = normalize_name(entry.name)
                    entry.price = math.max(0, math.floor(tonumber(entry.price) or 0))
                end
                return loaded
            end
        end

        return store.empty()
    end

    function store.save(tbl)
        if type(tbl) ~= 'table' then
            return false
        end

        if type(tbl.items) ~= 'table' then
            tbl.items = {}
        end

        ensure_items_dir()

        local file = io.open(prices_file, 'w+')
        if not file then
            return false
        end

        local ok, encoded = pcall(json.encode, tbl)
        if not ok or not encoded then
            file:write('{"items":[]}')
            file:close()
            return false
        end

        file:write(encoded)
        file:close()
        return true
    end

    function store.import_from_recipes()
        local names = {}
        local seen = {}

        local function add_name(raw_name)
            local name = normalize_name(raw_name)
            local key = name:lower()
            if name ~= '' and not seen[key] then
                seen[key] = true
                names[#names + 1] = name
            end
        end

        local function add_hq_result_names(recipe)
            if type(recipe) ~= 'table' then
                return
            end

            for key, value in pairs(recipe) do
                if type(key) == 'string' and key:match('^hq%d+$') then
                    local hq_name = normalize_result_item_name(value)
                    add_name(hq_name)
                end
            end
        end

        local recipe_index = recipes_data
        if type(recipe_index) ~= 'table' then
            local ok, loaded = pcall(require, 'recipes')
            if ok and type(loaded) == 'table' then
                recipe_index = loaded
            end
        end

        if type(recipe_index) == 'table' and type(recipe_index.by_name) == 'table' then
            for _, recipe in pairs(recipe_index.by_name) do
                if type(recipe) == 'table' then
                    local result_name = normalize_result_item_name(recipe.name)
                    add_name(result_name)
                    add_hq_result_names(recipe)

                    local crystal_name = normalize_name(recipe.crystal)
                    add_name(crystal_name)

                    if type(recipe.ingredients) == 'table' then
                        for _, ingredient in ipairs(recipe.ingredients) do
                            local ingredient_name = normalize_ingredient_name(ingredient)
                            add_name(ingredient_name)
                        end
                    end
                end
            end
        end

        return { items = build_sorted_items(names) }
    end

    function store.load_or_import()
        local loaded = store.load()
        if type(loaded.items) == 'table' and #loaded.items > 0 then
            return loaded
        end

        local imported = store.import_from_recipes()
        store.save(imported)
        return imported
    end

    function store.import_prices_from_hgather(current_prices)
        if type(current_prices) ~= 'table' or type(current_prices.items) ~= 'table' then
            return store.empty(), 0, 0, false
        end

        local hgather_prices, ok = read_hgather_price_map()
        if not ok or type(hgather_prices) ~= 'table' then
            return store.empty(), 0, 0, false
        end
        local merged = { items = {} }
        local updated = 0
        local matched = 0

        for i, entry in ipairs(current_prices.items) do
            local name = normalize_name(entry.name)
            local old_price = math.max(0, math.floor(tonumber(entry.price) or 0))
            local next_price = old_price

            local key = name:lower()
            if key ~= '' and hgather_prices[key] ~= nil then
                matched = matched + 1
                next_price = hgather_prices[key]
            end

            if next_price ~= old_price then
                updated = updated + 1
            end

            merged.items[i] = {
                id = tonumber(entry.id) or i,
                name = name,
                price = next_price,
            }
        end

        return merged, updated, matched, true
    end

    return store
end

return create_prices_store
