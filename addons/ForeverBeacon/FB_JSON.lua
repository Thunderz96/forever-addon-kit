-- FB_JSON.lua -- minimal JSON encoder (from Beacon) (encode only)
-- Author: Thunderz
--
-- The bridge reads ForeverBeaconDB.payload and hands it straight to json.loads, so
-- nothing on the Python side ever has to parse a Lua table. Encode only: the
-- addon never needs to read its own payload back, since the working state
-- stays a normal Lua table in ForeverBeaconDB.

local ADDON, ns = ...

local ESCAPES = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function escapeChar(c)
    return ESCAPES[c] or string.format('\\u%04x', string.byte(c))
end

local function encodeString(s)
    -- Escapes quotes, backslashes and control bytes. Anything >= 0x20 passes
    -- through untouched, so UTF-8 realm names (Mal'Ganis, Mug'thol) and WoW
    -- colour codes survive as valid UTF-8 JSON.
    return '"' .. string.gsub(s, '[%c\\"]', escapeChar) .. '"'
end

local function encodeNumber(n)
    -- Secret numbers (Midnight-era clients) cannot be compared or formatted;
    -- they become null rather than killing the whole encode.
    if issecretvalue and issecretvalue(n) then return "null" end
    local ok, s = pcall(function()
        if n ~= n or n == math.huge or n == -math.huge then
            return "null"  -- nan/inf are not valid JSON
        end
        if n == math.floor(n) and math.abs(n) < 1e15 then
            return string.format("%d", n)
        end
        return string.format("%.14g", n)
    end)
    return ok and s or "null"
end

local function isArray(t)
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        count = count + 1
    end
    return count == #t
end

local encodeValue

local function encodeTable(t, out)
    if isArray(t) then
        -- An empty table encodes as []. Every empty container in the Beacon
        -- schema is a list, so that is the right default here.
        out[#out + 1] = "["
        for i = 1, #t do
            if i > 1 then out[#out + 1] = "," end
            encodeValue(t[i], out)
        end
        out[#out + 1] = "]"
    else
        out[#out + 1] = "{"
        local first = true
        for k, v in pairs(t) do
            local kt = type(k)
            if kt == "string" or kt == "number" then
                if not first then out[#out + 1] = "," end
                first = false
                out[#out + 1] = encodeString(tostring(k))
                out[#out + 1] = ":"
                encodeValue(v, out)
            end
        end
        out[#out + 1] = "}"
    end
end

function encodeValue(v, out)
    -- Secret values of ANY type (number, boolean, string) cannot be tested,
    -- compared or formatted on restricted clients. They become null.
    if issecretvalue and issecretvalue(v) then
        out[#out + 1] = "null"
        return
    end
    local t = type(v)
    if v == nil then
        out[#out + 1] = "null"
    elseif t == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif t == "number" then
        out[#out + 1] = encodeNumber(v)
    elseif t == "string" then
        out[#out + 1] = encodeString(v)
    elseif t == "table" then
        encodeTable(v, out)
    else
        out[#out + 1] = "null"  -- functions, userdata
    end
end

ns.JSON = {}

function ns.JSON.encode(value)
    local out = {}
    encodeValue(value, out)
    return table.concat(out)
end
