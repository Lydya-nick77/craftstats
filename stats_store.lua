local function create_stats_store(addon_info, json)
    local base_path
    local stats_file
    local legacy_stats_file
    local crafts_dir

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

    crafts_dir = string.format('%s\\crafts', base_path)
    stats_file = string.format('%s\\craftstats_stats.json', crafts_dir)
    legacy_stats_file = string.format('%s\\craftstats_stats.json', base_path)

    local store = {}

    local function ensure_crafts_dir()
        pcall(function()
            os.execute(('mkdir "%s" >nul 2>nul'):format(crafts_dir))
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

        local legacy = load_file(legacy_stats_file)
        if legacy ~= nil then
            -- Migrate legacy stats location to crafts folder.
            store.save(legacy)
            return legacy
        end

        return store.empty()
    end

    function store.save(tbl)
        if type(tbl) ~= 'table' then
            return
        end

        ensure_crafts_dir()

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