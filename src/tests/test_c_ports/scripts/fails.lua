-- An error nothing catches, which lua reports with where it was raised, and ends with 1 (decisions/0202, 21g).
local function deeper()
  error("on purpose")
end
deeper()
