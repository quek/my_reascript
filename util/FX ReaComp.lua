-- Open ReaComp on track under mouse cursor (insert if not present)
local script_path = debug.getinfo(1, "S").source:match("@(.+[\\/])")
local fx_common = dofile(script_path .. "fx_common.lua")

reaper.defer(function()
  fx_common.open_fx_under_mouse("ReaComp")
end)
