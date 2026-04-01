-- recipes.lua
-- Central recipe loader and index for craftstats.

local woodworking = require('recipes.woodworking')
local alchemy = require('recipes.alchemy')
local bonecraft = require('recipes.bonecraft')
local clothcraft = require('recipes.clothcraft')
local goldsmith = require('recipes.goldsmith')
local leathercraft = require('recipes.leathercraft')
local smithing = require('recipes.smithing')

local recipes = {
    by_result = {
        -- Keep by-result entries when you know exact item ids.
        [637] = {
            name = 'Mythril Ingot',
            skill = 'Smithing',
            crystal = 'Fire Crystal',
            ingredients = { 'Mythril Ore x4' },
        },
    },
    by_name = {}
}

local function merge_by_name(src)
    if not src or type(src.by_name) ~= 'table' then
        return
    end

    for k, v in pairs(src.by_name) do
        recipes.by_name[k:lower()] = v
    end
end

merge_by_name(woodworking)
merge_by_name(alchemy)
merge_by_name(bonecraft)
merge_by_name(clothcraft)
merge_by_name(goldsmith)
merge_by_name(leathercraft)
merge_by_name(smithing)

return recipes
