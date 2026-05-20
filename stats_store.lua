local function create_stats_store(addon_info, json)
    local base_path
    local stats_file
    local legacy_stats_file
    local legacy_crafts_stats_file
    local config_dir

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
    config_dir = string.format('%s\\..\\..\\config\\addons\\%s', base_path, addon_name)
    stats_file = string.format('%s\\craftstats_stats.json', config_dir)
    -- Legacy paths from earlier versions.
    legacy_crafts_stats_file = string.format('%s\\crafts\\craftstats_stats.json', base_path)
    legacy_stats_file = string.format('%s\\craftstats_stats.json', base_path)

    local store = {}

    local function ensure_config_dir()
        pcall(function()
            os.execute(('mkdir "%s" >nul 2>nul'):format(config_dir))
        end)
    end

    local function load_file(path)
        local file = io.open(path, 'r')
        if not file then
            return nil
        end

        local content = file:read('*a')
        file:close()
        local ok, loaded = pcall(json.decode, content)
        if ok and type(loaded) == 'table' then
            return loaded
        end

        return nil
    end

    function store.empty()
        return { success = 0, break_ = 0, hq = 0, nq = 0, total = 0 }
    end

    function store.load()
        local current = load_file(stats_file)
        if current ~= nil then
            return current
        end

        local legacy_crafts = load_file(legacy_crafts_stats_file)
        if legacy_crafts ~= nil then
            -- Migrate legacy stats location from crafts folder to config directory.
            store.save(legacy_crafts)
            return legacy_crafts
        end

        local legacy = load_file(legacy_stats_file)
        if legacy ~= nil then
            -- Migrate legacy stats location from addon root to config directory.
            store.save(legacy)
            return legacy
        end

        return store.empty()
    end

    function store.save(tbl)
        if type(tbl) ~= 'table' then
            return
        end

        ensure_config_dir()

        local file = io.open(stats_file, 'w+')
        if not file then
            return
        end

        local ok, encoded = pcall(json.encode, tbl)
        if not ok or not encoded then
            file:write('{}')
            file:close()
            return
        end

        file:write(encoded)
        file:close()
    end

    return store
end

return create_stats_store