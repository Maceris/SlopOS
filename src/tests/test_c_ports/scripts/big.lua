-- More memory than a program that asks for none is given (decisions/0202, 21f): 2400 pieces of 4000 bytes, 9.6 MB in
-- all, held at once in a table, so Lua runs only on the 16 MiB it asks for. Each piece is one of the heap's 4 KiB
-- blocks (21i); with a page of its own and one for its handle each, as before, they'd take over 19 MiB.
local pieces = {}
for i = 1, 2400 do
  pieces[i] = string.rep(string.char(65 + i % 26), 4000)
end
local bytes = 0
for i = 1, #pieces do
  bytes = bytes + #pieces[i]
end
print(string.format("big: %d bytes, %d pieces", bytes, #pieces))
