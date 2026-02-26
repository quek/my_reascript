-- jsfx-server.lua — REAPER background script for jsfx-mode Emacs integration
--
-- Install:
--   1. Copy this file to <REAPER resource>/Scripts/jsfx-server.lua
--   2. Actions > Show action list > New action > Load ReaScript...
--   3. Select this script and run it
--   4. (Optional) Add to SWS Startup Actions for auto-start
--
-- Protocol:
--   File-based IPC via <script_dir>/jsfx-ipc/
--   Emacs writes cmd.txt, this script reads it, writes resp.txt

local SCRIPT_NAME = "jsfx-server"
local _, script_path, sectionID, cmdID = reaper.get_action_context()
local script_dir = script_path:match("(.+)[/\\]")
local IPC_DIR = script_dir .. "/jsfx-ipc/"
local CMD_FILE = IPC_DIR .. "cmd.txt"
local RESP_FILE = IPC_DIR .. "resp.txt"
local STATUS_FILE = IPC_DIR .. "status.txt"
local POLL_INTERVAL = 0.05 -- seconds

-- トグルアクションとして登録（再実行で自動終了）
reaper.set_action_options(1)

-- ツールバーボタンの状態を管理
reaper.SetToggleCommandState(sectionID, cmdID, 1)
reaper.RefreshToolbar2(sectionID, cmdID)
reaper.atexit(function()
  os.remove(STATUS_FILE)
  os.remove(CMD_FILE)
  os.remove(RESP_FILE)
  reaper.SetToggleCommandState(sectionID, cmdID, 0)
  reaper.RefreshToolbar2(sectionID, cmdID)
end)

-- Create IPC directory
reaper.RecursiveCreateDirectory(IPC_DIR, 0)

----------------------------------------------------------------
-- Utility
----------------------------------------------------------------

local function write_file(path, text)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(text)
  f:close()
  os.remove(path)
  os.rename(tmp, path)
  return true
end

local function read_and_delete(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  os.remove(path)
  return content
end

local function write_status()
  write_file(STATUS_FILE, "running\n" .. os.time() .. "\n" .. reaper.GetAppVersion() .. "\n")
end

----------------------------------------------------------------
-- Find JSFX on all tracks by filename substring
----------------------------------------------------------------

local function find_jsfx(search)
  local results = {}
  if not search or search == "" then return results end
  search = search:lower()
  local num_tracks = reaper.CountTracks(0)
  for t = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, t)
    local fx_count = reaper.TrackFX_GetCount(track)
    for fx = 0, fx_count - 1 do
      local _, name = reaper.TrackFX_GetFXName(track, fx, "")
      if name:lower():find(search, 1, true) then
        table.insert(results, { track = track, fx = fx, name = name, track_idx = t })
      end
    end
  end
  -- Also check monitoring FX
  local mon_count = reaper.TrackFX_GetCount(reaper.GetMasterTrack(0))
  local master = reaper.GetMasterTrack(0)
  for fx = 0, mon_count - 1 do
    local _, name = reaper.TrackFX_GetFXName(master, fx, "")
    if name:lower():find(search, 1, true) then
      table.insert(results, { track = master, fx = fx, name = name, track_idx = -1 })
    end
  end
  return results
end

----------------------------------------------------------------
-- Command handlers
----------------------------------------------------------------

local handlers = {}

function handlers.PING()
  return "OK " .. reaper.GetAppVersion()
end

function handlers.RELOAD(args)
  -- Force JSFX recompile by toggling offline state
  local matches = find_jsfx(args)
  if #matches == 0 then
    return "OK 0"
  end
  for _, m in ipairs(matches) do
    reaper.TrackFX_SetOffline(m.track, m.fx, true)
    reaper.TrackFX_SetOffline(m.track, m.fx, false)
  end
  return "OK " .. #matches
end

function handlers.FXLIST(args)
  -- List all FX on selected track (or all tracks if args == "all")
  local lines = {}
  if args == "all" then
    local num_tracks = reaper.CountTracks(0)
    for t = 0, num_tracks - 1 do
      local track = reaper.GetTrack(0, t)
      local _, track_name = reaper.GetTrackName(track)
      local fx_count = reaper.TrackFX_GetCount(track)
      for fx = 0, fx_count - 1 do
        local _, name = reaper.TrackFX_GetFXName(track, fx, "")
        local enabled = reaper.TrackFX_GetEnabled(track, fx)
        local offline = reaper.TrackFX_GetOffline(track, fx)
        local status = offline and "offline" or (enabled and "on" or "bypass")
        table.insert(lines, t .. "\t" .. track_name .. "\t" .. fx .. "\t" .. name .. "\t" .. status)
      end
    end
  else
    local track = reaper.GetSelectedTrack(0, 0)
    if not track then
      return "ERR No track selected"
    end
    local fx_count = reaper.TrackFX_GetCount(track)
    for fx = 0, fx_count - 1 do
      local _, name = reaper.TrackFX_GetFXName(track, fx, "")
      local enabled = reaper.TrackFX_GetEnabled(track, fx)
      local offline = reaper.TrackFX_GetOffline(track, fx)
      local status = offline and "offline" or (enabled and "on" or "bypass")
      table.insert(lines, fx .. "\t" .. name .. "\t" .. status)
    end
  end
  return "OK\n" .. table.concat(lines, "\n")
end

function handlers.FXPARAMS(args)
  -- Get parameter names and values: FXPARAMS <fx_index> [track_index]
  local parts = {}
  for w in args:gmatch("%S+") do table.insert(parts, w) end
  local fx_idx = tonumber(parts[1])
  local track_idx = tonumber(parts[2])
  if not fx_idx then
    return "ERR Invalid FX index"
  end
  local track
  if track_idx then
    if track_idx < 0 then
      track = reaper.GetMasterTrack(0)
    else
      track = reaper.GetTrack(0, track_idx)
    end
  else
    track = reaper.GetSelectedTrack(0, 0)
  end
  if not track then
    return "ERR No track"
  end
  local lines = {}
  local num_params = reaper.TrackFX_GetNumParams(track, fx_idx)
  for p = 0, num_params - 1 do
    local _, pname = reaper.TrackFX_GetParamName(track, fx_idx, p, "")
    local val, minval, maxval = reaper.TrackFX_GetParam(track, fx_idx, p)
    local _, formatted = reaper.TrackFX_GetFormattedParamValue(track, fx_idx, p, "")
    table.insert(lines, p .. "\t" .. pname .. "\t" .. val .. "\t" .. minval .. "\t" .. maxval .. "\t" .. formatted)
  end
  return "OK\n" .. table.concat(lines, "\n")
end

function handlers.SETPARAM(args)
  -- Set parameter value: SETPARAM <fx_index> <param_index> <value> [track_index]
  local parts = {}
  for w in args:gmatch("%S+") do table.insert(parts, w) end
  local fx_idx = tonumber(parts[1])
  local param_idx = tonumber(parts[2])
  local value = tonumber(parts[3])
  local track_idx = tonumber(parts[4])
  if not fx_idx or not param_idx or not value then
    return "ERR Invalid arguments"
  end
  local track
  if track_idx then
    track = track_idx < 0 and reaper.GetMasterTrack(0) or reaper.GetTrack(0, track_idx)
  else
    track = reaper.GetSelectedTrack(0, 0)
  end
  if not track then return "ERR No track" end
  reaper.TrackFX_SetParam(track, fx_idx, param_idx, value)
  return "OK"
end

function handlers.STOP()
  -- Graceful shutdown
  os.remove(STATUS_FILE)
  os.remove(CMD_FILE)
  os.remove(RESP_FILE)
  return "OK STOPPED"
end

----------------------------------------------------------------
-- Command dispatcher
----------------------------------------------------------------

local function process_line(line)
  line = line:match("^%s*(.-)%s*$") -- trim
  if not line or line == "" then return end
  local cmd, args = line:match("^(%S+)%s*(.*)")
  if not cmd then return end
  cmd = cmd:upper()
  local handler = handlers[cmd]
  if handler then
    local ok, result = pcall(handler, args)
    if ok then
      write_file(RESP_FILE, result or "OK")
    else
      write_file(RESP_FILE, "ERR " .. tostring(result))
    end
  else
    write_file(RESP_FILE, "ERR Unknown: " .. cmd)
  end
end

----------------------------------------------------------------
-- Main loop
----------------------------------------------------------------

local stop = false

local function main()
  write_status()
  local content = read_and_delete(CMD_FILE)
  if content and content ~= "" then
    for line in content:gmatch("[^\n]+") do
      process_line(line)
      if line:upper():match("^STOP") then
        stop = true
      end
    end
  end
  if not stop then
    reaper.defer(main)
  end
end

-- reaper.ShowConsoleMsg("[" .. SCRIPT_NAME .. "] Started. IPC dir: " .. IPC_DIR .. "\n")
main()
