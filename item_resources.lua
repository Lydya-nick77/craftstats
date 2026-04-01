local M = {}

local function get_resource_manager()
    return AshitaCore:GetResourceManager()
end

local function get_item_by_id(resources, id)
    local ok, item = pcall(function()
        if type(resources.GetItemById) == 'function' then
            return resources:GetItemById(id)
        end
        if type(resources.GetItemByID) == 'function' then
            return resources:GetItemByID(id)
        end
        return nil
    end)

    if not ok then
        return nil
    end

    return item
end

function M.get_item_name_by_id(id)
    if id == nil then
        return nil
    end

    local resources = get_resource_manager()
    if resources == nil then
        return nil
    end

    -- Prefer the full display name (Name[1]) over the short log name from GetString.
    -- GetString('items.names', ...) returns abbreviated log names like "Ltng. Crystal"
    -- which don't match the full names used in recipe files ("Lightning Crystal").
    local item = get_item_by_id(resources, id)
    if item ~= nil then
        local probes = {
            function() return item.Name and item.Name[1] end,
            function() return item.Name and item.Name[2] end,
            function() return item.Name and item.Name[0] end,
            function() return item.Name and item.Name:get() end,
            function() return tostring(item.Name) end,
        }
        for _, probe in ipairs(probes) do
            local ok_probe, probe_value = pcall(probe)
            if ok_probe and type(probe_value) == 'string' and probe_value ~= ''
                and not probe_value:find('userdata', 1, true) then
                return probe_value
            end
        end
    end

    -- Fall back to short log name
    local ok, value = pcall(function()
        return resources:GetString('items.names', id)
    end)
    if ok and type(value) == 'string' and value ~= '' then
        return value
    end

    return nil
end

return M
