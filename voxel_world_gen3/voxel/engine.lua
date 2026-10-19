-- Engine module lookup that works inside the mod sandbox.
--
-- A mod's `package` is a stand-in (src/mods/Sandbox.lua drops the real
-- one), so package.loaded["src..."] always comes back empty there.  require
-- is the sanctioned door: it hands back the engine's own, already-loaded
-- module table.  Results are cached so the per-frame lookups cost a table
-- read; a module that fails to load is remembered as absent.

local Engine = {}

local cache = {}

function Engine.get(name)
  local m = cache[name]
  if m ~= nil then return m or nil end
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then
    cache[name] = mod
    return mod
  end
  cache[name] = false
  return nil
end

return Engine
