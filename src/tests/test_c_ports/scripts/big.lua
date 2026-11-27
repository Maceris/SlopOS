-- More memory than a program that asks for none is given (decisions/0202, 21f): 3300 pieces of 1900 bytes, about 6 MiB
-- in all, held at once in a table, so Lua runs only on the 16 MiB it asks for. Each piece is small enough for the
-- heap's 2 KiB blocks, as a bigger block takes pages of its own, several times its size.
local pieces = {}
for i = 1, 3300 do
  pieces[i] = string.rep(string.char(65 + i % 26), 1900)
end
local bytes = 0
for i = 1, #pieces do
  bytes = bytes + #pieces[i]
end
print(string.format("big: %d bytes, %d pieces", bytes, #pieces))
