-- Lua on SlopOS's libc (decisions/0202, 21g): its strings, tables, closures, coroutines, errors, string.format, math
-- and io, each check named; it prints each one that fails, then how many passed, and ends with 1 if any failed.
local passed, failed = 0, 0

local function check(name, ok)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("failed: " .. name)
  end
end

-- Strings and patterns
check("upper", ("slop"):upper() == "SLOP")
check("rep", ("ab"):rep(3, "-") == "ab-ab-ab")
check("find", select(1, ("hello world"):find("o w")) == 5)
check("match", ("key = value"):match("^(%w+)%s*=%s*(%w+)$") == "key")
check("gsub", (("one two three"):gsub("%w+", function(w) return #w end)) == "3 3 5")
check("gmatch", (function()
  local n = 0
  for _ in ("a,b,,c"):gmatch("[^,]+") do n = n + 1 end
  return n
end)() == 3)
check("byte and char", string.char(("A"):byte() + 1) == "B")
check("reverse", ("abc"):reverse() == "cba")
check("utf8", utf8.len("café") == 4 and utf8.char(0x263A) == "\u{263A}")

-- Tables
local t = {5, 3, 8, 1}
table.sort(t)
check("sort", table.concat(t, ",") == "1,3,5,8")
table.insert(t, 1, 0)
check("insert", t[1] == 0 and #t == 5)
check("remove", table.remove(t) == 8 and #t == 4)
check("unpack", select("#", table.unpack({1, 2, 3})) == 3)
local keys = 0
for _ in pairs({a = 1, b = 2, c = 3}) do keys = keys + 1 end
check("pairs", keys == 3)
check("metatables", setmetatable({}, {__index = function(_, k) return k * 2 end})[21] == 42)

-- Closures
local function counter()
  local n = 0
  return function() n = n + 1; return n end
end
local c1, c2 = counter(), counter()
c1(); c1()
check("closures", c1() == 3 and c2() == 1)

-- Coroutines
local gen = coroutine.wrap(function()
  for i = 1, 3 do coroutine.yield(i * i) end
end)
check("coroutine wrap", gen() == 1 and gen() == 4 and gen() == 9)
local co = coroutine.create(function(a, b)
  local c = coroutine.yield(a + b)
  return c * 2
end)
local ok1, sum = coroutine.resume(co, 2, 3)
local ok2, doubled = coroutine.resume(co, 10)
check("coroutine resume", ok1 and sum == 5 and ok2 and doubled == 20 and coroutine.status(co) == "dead")

-- Errors
local ok, message = pcall(error, "boom")
check("pcall", not ok and message == "boom")
ok, message = pcall(function() local x = nil; return x.field end)
check("runtime error", not ok and message:find("attempt to index") ~= nil)
ok, message = pcall(error, {code = 7})
check("error objects", not ok and message.code == 7)
local traced = select(2, xpcall(function() error("deep") end, debug.traceback))
check("traceback", traced:find("stack traceback") ~= nil)

-- string.format
check("format float", string.format("%5.2f", math.pi) == " 3.14")
check("format int", string.format("%d %x %X %o", 255, 255, 255, 8) == "255 ff FF 10")
check("format g", string.format("%g %g", 1e20, 0.5) == "1e+20 0.5")
check("format q", string.format("%q", "a\nb") == "\"a\\\nb\"")
check("format padding", string.format("[%-5s][%5s]", "ab", "cd") == "[ab   ][   cd]")
check("tostring float", tostring(1 / 3) == "0.33333333333333")

-- Math
check("integer division", 7 // 2 == 3 and -7 // 2 == -4 and 7 % -3 == -2)
check("floats", math.floor(-2.5) == -3 and math.ceil(2.1) == 3 and math.abs(-4) == 4)
check("integers", math.type(1) == "integer" and math.type(1.0) == "float" and math.tointeger(8.0) == 8)
check("max and min", math.max(3, 9, 1) == 9 and math.min(3, 9, 1) == 1)
check("sqrt and exp", math.sqrt(16) == 4 and math.abs(math.exp(1) - 2.718281828459) < 1e-9)
check("huge", math.huge > 1e308 and -math.huge < -1e308 and math.maxinteger + 1 == math.mininteger)
check("fmod", math.fmod(7, 3) == 1 and math.fmod(-7, 3) == -1)
check("tonumber", tonumber("0x1F") == 31 and tonumber("1e2") == 100.0 and tonumber("z", 36) == 35)

-- io, beneath the shell's directory
local file = assert(io.open("lua_written.txt", "w"))
file:write("first\n", 42, "\n")
file:close()
local lines = {}
for line in io.lines("lua_written.txt") do lines[#lines + 1] = line end
check("io", #lines == 2 and lines[1] == "first" and lines[2] == "42")
check("os.remove", os.remove("lua_written.txt") == true and io.open("lua_written.txt") == nil)

-- Its own arguments
check("arg", arg[0] == "checks.lua" and arg[1] == "one" and arg[2] == "two" and #arg == 2)

print(string.format("lua checks: %d of %d passed", passed, passed + failed))
os.exit(failed == 0 and 0 or 1)
