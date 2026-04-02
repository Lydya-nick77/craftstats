local function create_craft_history_store(addon_info, json)
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

    local addon_name = (addon_info and type(addon_info.name) == 'string' and #addon_info.name > 0) and addon_info.name or 'craftstats'
    local config_dir = string.format('%s\\..\\..\\config\\addons\\%s', base_path, addon_name)
    local history_file = string.format('%s\\craft_history.json', config_dir)

    -- Legacy path: previously stored inside the addon's crafts subfolder.
    local legacy_history_file = string.format('%s\\crafts\\craft_history.json', base_path)

    local store = {}

    local function ensure_config_dir()
        pcall(function()
            os.execute(('mkdir "%s" >nul 2>nul'):format(config_dir))
        end)
    end

    function store.empty()
        return { entries = {} }
    end

    local function load_file(path)
        local file = io.open(path, 'r')
        if not file then return nil end
        local content = file:read('*a')
        file:close()
        local ok, loaded = pcall(json.decode, content)
        if ok and type(loaded) == 'table' and type(loaded.entries) == 'table' then
            return loaded
        end
        return nil
    end

    function store.load()
        local current = load_file(history_file)
        if current ~= nil then
            return current
        end

        local legacy = load_file(legacy_history_file)
        if legacy ~= nil then
            -- Migrate from legacy addon crafts folder to config directory.
            store.save(legacy)
            return legacy
        end

        return store.empty()
    end

    function store.save(tbl)
        if type(tbl) ~= 'table' then
            return false
        end

        if type(tbl.entries) ~= 'table' then
            tbl.entries = {}
        end

        ensure_config_dir()

        local file = io.open(history_file, 'w+')
        if not file then
            return false
        end

        local ok, encoded = pcall(json.encode, tbl)
        if not ok or not encoded then
            file:write('{"entries":[]}')
            file:close()
            return false
        end

        file:write(encoded)
        file:close()
        return true
    end

    function store.append(tbl, entry)
        if type(tbl) ~= 'table' then
            return
        end

        if type(tbl.entries) ~= 'table' then
            tbl.entries = {}
        end

        tbl.entries[#tbl.entries + 1] = entry

        local max_entries = 1000
        if #tbl.entries > max_entries then
            local overflow = #tbl.entries - max_entries
            for _ = 1, overflow do
                table.remove(tbl.entries, 1)
            end
        end
    end

    return store
end

return create_craft_history_store
