--[[
* craftstats Font Utilities
* Mirrors XIDB centralized font management for ImGui.
]]--

local imgui = require('imgui')
local M = {}

local DEFAULT_FONT_SIZE = 14
local FONT_SIZE_TO_INDEX = {
    [14] = 1,
    [18] = 2,
    [24] = 3,
    [32] = 4,
}
local font_cache = { }
local font_cache_initialized = false

local function init_font_cache()
    if font_cache_initialized then
        return
    end

    font_cache_initialized = true

    local ok = pcall(function()
        local io = imgui.GetIO()
        if not io or not io.Fonts or not io.Fonts.Fonts then
            return
        end

        for size_px, index in pairs(FONT_SIZE_TO_INDEX) do
            font_cache[size_px] = io.Fonts.Fonts[index]
        end
    end)

    if not ok then
        font_cache = { }
    end
end

M.SCALES = {
    TINY = 0.8,
    SMALL = 0.9,
    NORMAL = 1.0,
    LARGE = 1.2,
    TITLE = 1.3,
    HEADER = 1.5,
    MASSIVE = 2.0,
}

M.COLORS = {
    GOLD = { 1.0, 0.82, 0.32, 1.0 },
    ORANGE = { 1.0, 0.65, 0.0, 1.0 },
    LIGHT_ORANGE = { 0.95, 0.84, 0.55, 1.0 },
    WHITE = { 1.0, 1.0, 1.0, 1.0 },
    GRAY = { 0.7, 0.7, 0.7, 1.0 },
    LIGHT_GRAY = { 0.85, 0.85, 0.85, 1.0 },
    GREEN = { 0.0, 1.0, 0.0, 1.0 },
    BLUE = { 0.35, 0.65, 1.0, 1.0 },
    RED = { 1.0, 0.0, 0.0, 1.0 },
    YELLOW = { 1.0, 1.0, 0.0, 1.0 },
}

function M.SetScale(scale)
    if imgui.SetWindowFontScale then
        imgui.SetWindowFontScale(scale)
    end
end

function M.ResetScale()
    M.SetScale(M.SCALES.NORMAL)
end

function M.GetFont(size_px)
    init_font_cache()
    local normalized_size = tonumber(size_px) or DEFAULT_FONT_SIZE
    return font_cache[normalized_size]
end

function M.WithFont(size_px, fn)
    if type(fn) ~= 'function' then
        return
    end

    local font = M.GetFont(size_px)
    local pushed = false
    if font then
        pushed = pcall(function()
            imgui.PushFont(font)
        end)
    end

    local ok = pcall(fn)

    if pushed then
        pcall(imgui.PopFont)
    end

    if not ok then
        return
    end
end

function M.TextColoredPx(text, color, size_px, fallback_scale)
    local content = tostring(text or '')
    local resolved_color = color or M.COLORS.WHITE
    local font = M.GetFont(size_px)
    if font then
        M.WithFont(size_px, function()
            imgui.TextColored(resolved_color, content)
        end)
        return
    end

    M.TextColored(content, resolved_color, fallback_scale or ((tonumber(size_px) or DEFAULT_FONT_SIZE) / DEFAULT_FONT_SIZE))
end

function M.TextPx(text, size_px, fallback_scale)
    M.TextColoredPx(text, M.COLORS.WHITE, size_px, fallback_scale)
end

function M.TextColored(text, color, scale)
    local content = tostring(text or '')
    color = color or M.COLORS.WHITE
    if scale and scale ~= M.SCALES.NORMAL then
        M.SetScale(scale)
    end
    imgui.TextColored(color, content)
    if scale and scale ~= M.SCALES.NORMAL then
        M.ResetScale()
    end
end

function M.Title(text)
    M.TextColoredPx(text, M.COLORS.GOLD, 24, M.SCALES.TITLE)
end

function M.Header(text)
    M.TextColoredPx(text, M.COLORS.GOLD, 18, M.SCALES.LARGE)
end

function M.Label(text)
    M.TextColoredPx(text, M.COLORS.WHITE, 18, M.SCALES.LARGE)
end

return M