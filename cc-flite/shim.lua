-- wasm2lua targets LuaJIT's `bit`, whose ops return SIGNED 32-bit results.
-- CC's bit32 returns UNSIGNED [0,2^32), so any result with the high bit set
-- comes back as a large positive instead of a negative, and every subsequent
-- sign test takes the wrong branch. Normalise on the way out.
--
-- These are the hottest functions in the program, so: the sign fixup is inlined
-- rather than delegated to a helper, and arity is fixed instead of varargs
-- (Lua 5.1 vararg calls allocate).
local b = bit32
local band, bor, bxor, bnot = b.band, b.bor, b.bxor, b.bnot
local blshift, brshift, barshift = b.lshift, b.rshift, b.arshift
local lrotate, rrotate = b.lrotate, b.rrotate

bit = {
  -- tobit wraps the result of nearly every i32 arithmetic op, so the common
  -- case (already inside signed 32-bit range) skips the native call entirely:
  -- two comparisons instead of a C call into bit32.
  tobit = function(x)
    if x >= -2147483648 and x < 2147483648 then return x end
    local v = band(x, 0xFFFFFFFF)
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
  end,
  band = function(a, c, d, e)
    local v
    if e ~= nil then v = band(a, c, d, e)
    elseif d ~= nil then v = band(a, c, d)
    else v = band(a, c) end
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
  end,
  bor = function(a, c, d, e)
    local v
    if e ~= nil then v = bor(a, c, d, e)
    elseif d ~= nil then v = bor(a, c, d)
    else v = bor(a, c) end
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
  end,
  bxor = function(a, c, d, e)
    local v
    if e ~= nil then v = bxor(a, c, d, e)
    elseif d ~= nil then v = bxor(a, c, d)
    else v = bxor(a, c) end
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
  end,
  bnot = function(x)
    local v = bnot(x)
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
  end,
  lshift = function(x, n)
    local v = blshift(x, n)
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
  end,
  -- rshift by n>=1 can never set the high bit; only n==0 needs the fixup.
  rshift = function(x, n)
    local v = brshift(x, n)
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
  end,
  arshift = function(x, n)
    local v = barshift(x, n)
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
  end,
  rol = function(x, n)
    local v = lrotate(x, n)
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
  end,
  ror = function(x, n)
    local v = rrotate(x, n)
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
  end,
}

math.pow   = math.pow   or function(x,y) return x ^ y end
math.ldexp = math.ldexp or function(m,e) return m * 2.0 ^ e end
math.frexp = math.frexp or function(x)
  if x == 0 then return 0.0, 0 end
  local e = math.floor(math.log(math.abs(x), 2)) + 1
  return x / 2.0 ^ e, e
end
