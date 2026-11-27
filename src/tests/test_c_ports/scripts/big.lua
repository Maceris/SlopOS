-- More memory than the shell's own budget has (decisions/0202, 21f and 21i): 5000 pieces of 4000 bytes, 20 MB in all,
-- held at once in a table, so Lua runs only on the 32 MiB it asks for, out of the session's programs budget, not the
-- shell's 16 MiB. Each piece is one of the heap's 4 KiB blocks (21i).
local pieces = {}
for i = 1, 5000 do
  pieces[i] = string.rep(string.char(65 + i % 26), 4000)
end
local bytes = 0
for i = 1, #pieces do
  bytes = bytes + #pieces[i]
end
print(string.format("big: %d bytes, %d pieces", bytes, #pieces))
