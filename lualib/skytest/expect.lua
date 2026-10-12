local function deep_equal(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

local function format_value(v)
    if type(v) == "string" then
        return string.format("%q", v)
    elseif type(v) == "table" then
        local parts = {}
        local n = 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 5 then
                parts[#parts + 1] = "..."
                break
            end
            parts[#parts + 1] = string.format("[%s]=%s", format_value(k), format_value(val))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    else
        return tostring(v)
    end
end

local function fail(msg, level)
    error(msg, (level or 1) + 1)
end

local function make_assertions(value, negated)
    local assertions = {}

    function assertions.equal(expected)
        local eq = deep_equal(value, expected)
        if negated then
            if eq then
                fail(string.format("Expected %s to not equal %s", format_value(value), format_value(expected)), 2)
            end
        else
            if not eq then
                fail(string.format("Expected %s to equal %s", format_value(value), format_value(expected)), 2)
            end
        end
    end

    function assertions.exist()
        if negated then
            if value ~= nil then
                fail(string.format("Expected %s to not exist", format_value(value)), 2)
            end
        else
            if value == nil then
                fail("Expected value to exist, got nil", 2)
            end
        end
    end

    function assertions.be_nil()
        if negated then
            if value == nil then
                fail("Expected value to not be nil", 2)
            end
        else
            if value ~= nil then
                fail(string.format("Expected nil, got %s", format_value(value)), 2)
            end
        end
    end

    function assertions.be_truthy()
        local truthy = value ~= nil and value ~= false
        if negated then
            if truthy then
                fail(string.format("Expected %s to not be truthy", format_value(value)), 2)
            end
        else
            if not truthy then
                fail(string.format("Expected truthy, got %s", format_value(value)), 2)
            end
        end
    end

    function assertions.be_falsy()
        local falsy = value == nil or value == false
        if negated then
            if falsy then
                fail(string.format("Expected %s to not be falsy", format_value(value)), 2)
            end
        else
            if not falsy then
                fail(string.format("Expected falsy, got %s", format_value(value)), 2)
            end
        end
    end

    function assertions.be_type(expected)
        local actual = type(value)
        if negated then
            if actual == expected then
                fail(string.format("Expected type to not be %q", expected), 2)
            end
        else
            if actual ~= expected then
                fail(string.format("Expected type %q, got %q", expected, actual), 2)
            end
        end
    end

    -- The negated comparisons must also fail for NaN and preserve metamethod behavior.
    -- luacheck: push ignore 581
    function assertions.be_gt(n)
        if negated then
            if value > n then
                fail(string.format("Expected %s to not be > %s", format_value(value), format_value(n)), 2)
            end
        else
            if not (value > n) then
                fail(string.format("Expected %s to be > %s", format_value(value), format_value(n)), 2)
            end
        end
    end

    function assertions.be_gte(n)
        if negated then
            if value >= n then
                fail(string.format("Expected %s to not be >= %s", format_value(value), format_value(n)), 2)
            end
        else
            if not (value >= n) then
                fail(string.format("Expected %s to be >= %s", format_value(value), format_value(n)), 2)
            end
        end
    end

    function assertions.be_lt(n)
        if negated then
            if value < n then
                fail(string.format("Expected %s to not be < %s", format_value(value), format_value(n)), 2)
            end
        else
            if not (value < n) then
                fail(string.format("Expected %s to be < %s", format_value(value), format_value(n)), 2)
            end
        end
    end

    function assertions.be_lte(n)
        if negated then
            if value <= n then
                fail(string.format("Expected %s to not be <= %s", format_value(value), format_value(n)), 2)
            end
        else
            if not (value <= n) then
                fail(string.format("Expected %s to be <= %s", format_value(value), format_value(n)), 2)
            end
        end
    end

    -- luacheck: pop
    function assertions.contain(substr)
        if type(value) ~= "string" then
            fail(string.format("Expected string for contain, got %s", type(value)), 2)
        end
        local found = string.find(value, substr, 1, true) ~= nil
        if negated then
            if found then
                fail(string.format("Expected %q to not contain %q", value, substr), 2)
            end
        else
            if not found then
                fail(string.format("Expected %q to contain %q", value, substr), 2)
            end
        end
    end

    function assertions.match(pattern)
        if type(value) ~= "string" then
            fail(string.format("Expected string for match, got %s", type(value)), 2)
        end
        local found = string.find(value, pattern) ~= nil
        if negated then
            if found then
                fail(string.format("Expected %q to not match %q", value, pattern), 2)
            end
        else
            if not found then
                fail(string.format("Expected %q to match pattern %q", value, pattern), 2)
            end
        end
    end

    function assertions.have_key(key)
        if type(value) ~= "table" then
            fail(string.format("Expected table for have_key, got %s", type(value)), 2)
        end
        local has = value[key] ~= nil
        if negated then
            if has then
                fail(string.format("Expected table to not have key %s", format_value(key)), 2)
            end
        else
            if not has then
                fail(string.format("Expected table to have key %s", format_value(key)), 2)
            end
        end
    end

    function assertions.have_length(n)
        local len = #value
        if negated then
            if len == n then
                fail(string.format("Expected length to not be %d", n), 2)
            end
        else
            if len ~= n then
                fail(string.format("Expected length %d, got %d", n, len), 2)
            end
        end
    end

    function assertions.throw(pattern)
        if type(value) ~= "function" then
            fail(string.format("Expected function for throw, got %s", type(value)), 2)
        end
        local ok, err = pcall(value)
        if negated then
            if not ok then
                fail(string.format("Expected function to not throw, but got: %s", tostring(err)), 2)
            end
        else
            if ok then
                fail("Expected function to throw, but it did not", 2)
            end
            if pattern then
                local msg = tostring(err)
                if not string.find(msg, pattern) then
                    fail(string.format("Expected error matching %q, got %q", pattern, msg), 2)
                end
            end
        end
    end

    return assertions
end

local function expect(value)
    local to = make_assertions(value, false)
    local to_not = make_assertions(value, true)
    return { to = to, to_not = to_not }
end

return expect
