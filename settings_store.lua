local function create_settings_store(addon_info, json)
    local base_path
    if addon_info and addon_info.path and type(addon_info.path) == 'string' and #addon_info.path > 0 then
        base_path = addon_info.path
    else
        local ok, install = pcall(function() return AshitaCore:GetInstallPath() end)
        if ok and install and #install > 0 then
            base_path = string.format('%s\\addons\\%s', install, addon_info.name)
        else
            base_path = '.'
        end
    end

    local addon_name = (addon_info and type(addon_info.name) == 'string' and #addon_info.name > 0) and addon_info.name or 'craftstats'
    local config_dir = string.format('%s\\..\\..\\config\\addons\\%s', base_path, addon_name)
    local profiles_dir = string.format('%s\\profiles', config_dir)
    local cached_profile_name = nil

    local store = {}

    local function trim_text(value)
        if type(value) ~= 'string' then
            return ''
        end
        return value:match('^%s*(.-)%s*$') or ''
    end

    local function sanitize_profile_name(name)
        local value = trim_text(name)
        if value == '' then
            return nil
        end
        value = value:gsub('%z', '')
        value = value:gsub('[<>:"/\\|%?%*]', '_')
        value = trim_text(value)
        if value == '' then
            return nil
        end
        return value
    end

    local function ensure_dir(path)
        pcall(function()
            os.execute(('mkdir "%s" >nul 2>nul'):format(path))
        end)
    end

    local function resolve_profile_name()
        if cached_profile_name ~= nil then
            return cached_profile_name
        end

        local ok, party = pcall(function()
            local memory = AshitaCore:GetMemoryManager()
            return memory and memory:GetParty() or nil
        end)
        if not ok or not party then
            return nil
        end

        local ok2, name = pcall(function() return party:GetMemberName(0) end)
        if not ok2 then
            return nil
        end

        local sanitized = sanitize_profile_name(tostring(name or ''))
        if sanitized ~= nil then
            cached_profile_name = sanitized
        end
        return sanitized
    end

    local function get_profile_settings_path(profile_name)
        return string.format('%s\\%s\\settings.json', profiles_dir, profile_name)
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
        return {
            ui_scale_auto = true,
            ui_text_scale_override = nil,
        }
    end

    function store.load()
        local profile_name = resolve_profile_name()
        if profile_name == nil then
            return nil, nil
        end

        local settings_file = get_profile_settings_path(profile_name)
        local loaded = load_file(settings_file)
        if loaded ~= nil then
            return loaded, profile_name
        end

        return store.empty(), profile_name
    end

    function store.save(tbl)
        if type(tbl) ~= 'table' then
            return false
        end

        local profile_name = resolve_profile_name()
        if profile_name == nil then
            return false
        end

        ensure_dir(config_dir)
        ensure_dir(profiles_dir)
        ensure_dir(string.format('%s\\%s', profiles_dir, profile_name))

        local settings_file = get_profile_settings_path(profile_name)
        local file = io.open(settings_file, 'w+')
        if not file then
            return false
        end

        local ok, encoded = pcall(json.encode, tbl)
        if not ok or not encoded then
            file:write('{}')
            file:close()
            return false
        end

        file:write(encoded)
        file:close()
        return true
    end

    return store
end

return create_settings_store