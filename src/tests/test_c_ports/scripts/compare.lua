-- After minigzip (decisions/0202, 21g): its .gz's size and a hash of its bytes, so the same compressed bytes show as
-- the same line on every architecture, then whether what it gave back is what was compressed.
local function read(name)
  local file = io.open(name, "rb")
  if file == nil then return nil end
  local bytes = file:read("a")
  file:close()
  return bytes
end

local which = arg[1]
if which == "gz" then
  local bytes = assert(read("gzip_input.txt.gz"))
  local hash = 2166136261
  for i = 1, #bytes do
    hash = ((hash ~ bytes:byte(i)) * 16777619) & 0xffffffff
  end
  print(string.format("gz: %d bytes, hash %08x", #bytes, hash))
else
  local back, expected = read("gzip_input.txt"), read("gzip_expected.txt")
  print(string.format("gunzipped: %s, %d bytes", tostring(back ~= nil and back == expected), expected and #expected or 0))
end
