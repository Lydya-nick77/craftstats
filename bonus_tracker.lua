require('common')

local function create_bonus_tracker()
    local tracker = {}

    tracker.skill_ids = {1,2,3,4,5,6,7,8}
    tracker.skill_names = {
        [1] = 'Woodworking',
        [2] = 'Smithing',
        [3] = 'Goldsmithing',
        [4] = 'Clothcraft',
        [5] = 'Leathercraft',
        [6] = 'Bonecraft',
        [7] = 'Alchemy',
        [8] = 'Cooking',
    }

    local skill_name_to_id = {
        woodworking = 1,
        smithing = 2,
        goldsmithing = 3,
        clothcraft = 4,
        leathercraft = 5,
        bonecraft = 6,
        alchemy = 7,
        cooking = 8,
    }
    local imagery_skill_by_buff = {
        [236] = 1,
        [237] = 2,
        [238] = 3,
        [239] = 4,
        [240] = 5,
        [241] = 6,
        [242] = 7,
        [243] = 8,
    }
    local imagery_tier_bonus_by_buff = {
        [244] = 1,
        [245] = 2,
        [246] = 3,
        [247] = 4,
        [248] = 5,
        [616] = 3,
    }

    tracker.skills = {}
    tracker.skill_bonuses = {}
    tracker.support_bonus_value = 0
    tracker.support_bonus_skill_id = 0
    tracker.moghancement_bonus_value = 0
    tracker.moghancement_bonus_skill_id = 0
    tracker.gear_bonus_total = 0
    tracker.gear_bonus_by_skill = {}

    local support_tier_override = nil  -- set from chat message when buff ID alone can't encode tier

    local last_bonus_scan = 0
    local bonus_scan_interval = 1.0
    local moghancement_keyitem_id_cache = {}
    local gear_bonus_cache_by_item_id = {}
    local last_gear_bonus_by_skill = {}
    local last_gear_signature = ''
    local last_gear_total = 0

    local function trim_text(value)
        if type(value) ~= 'string' then
            return ''
        end

        return value:match('^%s*(.-)%s*$') or ''
    end

    local function get_skill(id)
        local ok, craftskill = pcall(function()
            return AshitaCore:GetMemoryManager():GetPlayer():GetCraftSkill(id)
        end)

        if ok and craftskill then
            local ok2, skill_number = pcall(function()
                return craftskill:GetSkill()
            end)
            if ok2 and type(skill_number) == 'number' then
                return skill_number
            end
        end

        return nil
    end

    local function reset_skill_bonuses()
        for _, id in ipairs(tracker.skill_ids) do
            tracker.skill_bonuses[id] = 0
        end
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

    local function get_item_description_text(item_id, item_resource)
        local resources = AshitaCore:GetResourceManager()

        if resources and item_id ~= nil then
            local ok_string, value = pcall(function()
                return resources:GetString('items.descriptions', item_id)
            end)
            if ok_string and type(value) == 'string' then
                local cleaned = trim_text(value)
                if cleaned ~= '' and not cleaned:match('userdata') then
                    return cleaned
                end
            end
        end

        local item = item_resource
        if item == nil and resources and item_id ~= nil then
            item = get_item_by_id(resources, item_id)
        end

        if type(item) ~= 'table' then
            return ''
        end

        if type(item.Description) == 'table' then
            local cleaned = trim_text(tostring(item.Description[1] or item.Description[0] or item.Description[2] or ''))
            if cleaned ~= '' and not cleaned:match('userdata') then
                return cleaned
            end
        end

        local probes = {
            function() return item.Description and item.Description[1] end,
            function() return item.Description and item.Description:get() end,
            function() return tostring(item.Description) end,
            function() return tostring(item) end,
        }
        for _, probe in ipairs(probes) do
            local ok_probe, probe_value = pcall(probe)
            if ok_probe and type(probe_value) == 'string' then
                local cleaned = trim_text(probe_value)
                if cleaned ~= '' and not cleaned:match('userdata') then
                    return cleaned
                end
            end
        end

        return ''
    end

    local function parse_skill_bonuses_from_text(bonus_map, text)
        local desc = tostring(text or ''):lower()
        if #desc == 0 then
            return 0
        end

        local added = 0

        for craft_name, craft_id in pairs(skill_name_to_id) do
            local bonus = desc:match(craft_name .. '%s+skill%s*%+%s*(%d+)')
                or desc:match(craft_name .. '.-skill%s*%+%s*(%d+)')
                or desc:match(craft_name .. '%s*%+%s*(%d+)')

            if bonus ~= nil then
                local val = tonumber(bonus) or 0
                bonus_map[craft_id] = (bonus_map[craft_id] or 0) + val
                added = added + val
            end
        end

        local generic_bonus = desc:match('synthesis%s+skill%s*%+%s*(%d+)')
            or desc:match('crafting%s+skill%s*%+%s*(%d+)')
        if generic_bonus ~= nil then
            local val = tonumber(generic_bonus) or 0
            for _, craft_id in ipairs(tracker.skill_ids) do
                bonus_map[craft_id] = (bonus_map[craft_id] or 0) + val
            end
            added = added + (val * #tracker.skill_ids)
        end

        return added
    end

    local function apply_name_based_bonus_fallback(bonus_map, item_name)
        local name_lc = trim_text(tostring(item_name or '')):lower()
        if name_lc == '' then
            return 0
        end

        local is_guild_gear = name_lc:find('apron', 1, true)
            or name_lc:find('gloves', 1, true)
            or name_lc:find('mitts', 1, true)
        if not is_guild_gear then
            return 0
        end

        local guild_to_skill = {
            ["carpenter's"] = 1,
            ["blacksmith's"] = 2,
            ["goldsmith's"] = 3,
            ["weaver's"] = 4,
            ["tanner's"] = 5,
            ["boneworker's"] = 6,
            ["alchemist's"] = 7,
            ["culinarian's"] = 8,
        }

        for guild_name, craft_id in pairs(guild_to_skill) do
            if name_lc:find(guild_name, 1, true) then
                bonus_map[craft_id] = (bonus_map[craft_id] or 0) + 1
                return 1
            end
        end

        return 0
    end

    local function apply_synthesis_support_bonus_from_buffs(bonus_map, buffs)
        local active_skill_id = 0
        local highest_tier_bonus = 0

        for _, buff_id in pairs(buffs or {}) do
            local mapped_skill = imagery_skill_by_buff[buff_id]
            if mapped_skill ~= nil then
                active_skill_id = mapped_skill
            end

            local tier_bonus = imagery_tier_bonus_by_buff[buff_id] or 0
            if tier_bonus > highest_tier_bonus then
                highest_tier_bonus = tier_bonus
            end
        end

        if active_skill_id == 0 then
            return 0, 0
        end

        -- Prefer the value parsed from the chat message; the buff ID alone doesn't encode
        -- tier on HorizonXI (all tiers share the same status ID).
        local bonus = (support_tier_override ~= nil) and support_tier_override or highest_tier_bonus
        if bonus <= 0 then
            bonus = 1
        end

        bonus_map[active_skill_id] = (bonus_map[active_skill_id] or 0) + bonus
        return bonus, active_skill_id
    end

    local function get_keyitem_id_by_name(name)
        local key = trim_text(tostring(name or ''))
        if key == '' then
            return -1
        end

        if moghancement_keyitem_id_cache[key] ~= nil then
            return moghancement_keyitem_id_cache[key]
        end

        local resources = AshitaCore:GetResourceManager()
        if resources == nil then
            moghancement_keyitem_id_cache[key] = -1
            return -1
        end

        local ok, found = pcall(function()
            return resources:GetString('keyitems.names', key, 2)
        end)

        local id = -1
        if ok and type(found) == 'number' then
            id = found
        end

        moghancement_keyitem_id_cache[key] = id
        return id
    end

    local function player_has_keyitem(player, keyitem_id)
        if player == nil or type(keyitem_id) ~= 'number' or keyitem_id <= 0 then
            return false
        end

        local ok, has = pcall(function()
            return player:HasKeyItem(keyitem_id)
        end)

        return ok and has == true
    end

    local function apply_moghancement_bonus_from_keyitems(bonus_map, player)
        if player == nil then
            return 0, 0
        end

        for craft_id, craft_name in pairs(tracker.skill_names) do
            local candidates = {
                string.format('Moghancement: %s', craft_name),
                string.format('Moglification: %s', craft_name),
                string.format('Moghancement %s', craft_name),
                string.format('Moglification %s', craft_name),
            }

            for _, candidate in ipairs(candidates) do
                local keyitem_id = get_keyitem_id_by_name(candidate)
                if player_has_keyitem(player, keyitem_id) then
                    local bonus = 1
                    bonus_map[craft_id] = (bonus_map[craft_id] or 0) + bonus
                    return bonus, craft_id
                end
            end
        end

        return 0, 0
    end

    local function apply_bonus_map(dst, src)
        for _, id in ipairs(tracker.skill_ids) do
            local val = src[id] or 0
            if val ~= 0 then
                dst[id] = (dst[id] or 0) + val
            end
        end
    end

    local function make_gear_signature(inventory)
        local parts = {}
        for slot = 4, 7 do
            local equipped = inventory:GetEquippedItem(slot)
            local raw_index = 0
            if equipped ~= nil and equipped.Index ~= nil then
                raw_index = bit.band(equipped.Index, 0xFFFF)
            end
            parts[#parts + 1] = tostring(raw_index)
        end
        return table.concat(parts, ':')
    end

    local function get_item_bonus_map(item_id, item_name, resource)
        local cached = gear_bonus_cache_by_item_id[item_id]
        if cached ~= nil then
            return cached
        end

        local map = {}
        local desc = get_item_description_text(item_id, resource)
        local parsed_total = parse_skill_bonuses_from_text(map, desc)
        if parsed_total <= 0 then
            apply_name_based_bonus_fallback(map, item_name)
        end

        gear_bonus_cache_by_item_id[item_id] = map
        return map
    end

    local function update_gear_bonuses(inventory, bonus_map)
        local signature = make_gear_signature(inventory)
        if signature == last_gear_signature then
            tracker.gear_bonus_total = last_gear_total
            apply_bonus_map(bonus_map, last_gear_bonus_by_skill)
            return
        end

        local rebuilt = {}
        for _, id in ipairs(tracker.skill_ids) do
            rebuilt[id] = 0
        end

        for slot = 4, 7 do
            local equipped = inventory:GetEquippedItem(slot)
            if equipped ~= nil then
                local index = bit.band(equipped.Index, 0x00FF)
                if index ~= 0 then
                    local container = bit.band(equipped.Index, 0xFF00) / 0x0100
                    local item = inventory:GetContainerItem(container, index)
                    if item and item.Id and item.Id ~= 0 and item.Count and item.Count > 0 then
                        local resource = AshitaCore:GetResourceManager():GetItemById(item.Id)
                        local item_name = trim_text(tostring((resource and resource.Name and resource.Name[1]) or ('Item #' .. tostring(item.Id))))
                        local item_map = get_item_bonus_map(item.Id, item_name, resource)
                        apply_bonus_map(rebuilt, item_map)
                    end
                end
            end
        end

        local gear_total = 0
        for _, id in ipairs(tracker.skill_ids) do
            gear_total = gear_total + (rebuilt[id] or 0)
        end
        tracker.gear_bonus_total = gear_total
        last_gear_total = gear_total

        last_gear_signature = signature
        last_gear_bonus_by_skill = rebuilt
        tracker.gear_bonus_by_skill = rebuilt
        apply_bonus_map(bonus_map, last_gear_bonus_by_skill)
    end

    function tracker.update_skills()
        for _, id in ipairs(tracker.skill_ids) do
            tracker.skills[id] = get_skill(id) or 0
        end
    end

    function tracker.update_skill_bonuses()
        local now = os.clock()
        if (now - last_bonus_scan) < bonus_scan_interval then
            return
        end
        last_bonus_scan = now

        reset_skill_bonuses()
        tracker.support_bonus_value = 0
        tracker.support_bonus_skill_id = 0
        tracker.moghancement_bonus_value = 0
        tracker.moghancement_bonus_skill_id = 0
        tracker.gear_bonus_total = 0

        pcall(function()
            local memory = AshitaCore:GetMemoryManager()
            local inventory = memory and memory:GetInventory() or nil
            local player = memory and memory:GetPlayer() or nil
            if inventory == nil then
                return
            end

            if player ~= nil then
                local buffs = player:GetBuffs()
                tracker.support_bonus_value, tracker.support_bonus_skill_id = apply_synthesis_support_bonus_from_buffs(tracker.skill_bonuses, buffs)
                tracker.moghancement_bonus_value, tracker.moghancement_bonus_skill_id = apply_moghancement_bonus_from_keyitems(tracker.skill_bonuses, player)
            end

            update_gear_bonuses(inventory, tracker.skill_bonuses)
        end)
    end

    -- Called from text_in when a synthesis support message is received.
    -- Maps the phrasing to a numeric bonus so the UI displays the correct tier.
    function tracker.set_support_tier_from_message(msg)
        local m = tostring(msg or ''):lower()
        if m:find('a little', 1, true) then
            support_tier_override = 3
        else
            -- "ever so slightly" or any other phrasing
            support_tier_override = 1
        end
    end

    function tracker.get_total_bonus()
        local total = 0
        for _, id in ipairs(tracker.skill_ids) do
            total = total + (tracker.skill_bonuses[id] or 0)
        end
        return total
    end

    for _, id in ipairs(tracker.skill_ids) do
        tracker.skills[id] = 0
        tracker.skill_bonuses[id] = 0
        tracker.gear_bonus_by_skill[id] = 0
        last_gear_bonus_by_skill[id] = 0
    end

    return tracker
end

return create_bonus_tracker